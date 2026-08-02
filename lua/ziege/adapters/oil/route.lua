local codec = require("ziege.codec")

local M = {}

local SCHEME = "abap://"
local systems_by_segment = {}
local system_segments_by_token = {}
local directories = {}

local function split_path(path)
  local result = {}
  for part in path:gmatch("[^/]+") do
    table.insert(result, part)
  end
  return result
end

local function addslash(url)
  return url:gsub("/+$", "") .. "/"
end

local function readable_segment(name)
  local segment = codec.encode_segment(name)
  if segment == "." then
    return "%2E"
  elseif segment == ".." then
    return "%2E%2E"
  end
  return segment
end

local function unique_segment(base, occupied, identity)
  local segment = base
  local suffix = 2
  while occupied[segment] and occupied[segment] ~= identity do
    segment = string.format("%s~%d", base, suffix)
    suffix = suffix + 1
  end
  return segment
end

local function system_segment(system)
  local existing = system_segments_by_token[system.token]
  if existing then
    systems_by_segment[existing] = system.token
    return existing
  end

  local root = vim.fs.normalize(system.project_root)
  local project_name = vim.fs.basename(root)
  if not project_name or project_name == "" then
    project_name = "root"
  end
  local base = readable_segment(string.format("%s@%s", system.folder or system.name, project_name))
  local segment = unique_segment(base, systems_by_segment, system.token)
  systems_by_segment[segment] = system.token
  system_segments_by_token[system.token] = segment
  return segment
end

local function with_system(segment, url)
  local token = systems_by_segment[segment]
  if not token then
    return nil, string.format("Unknown Ziege system route '%s'; reopen its project portal", segment)
  end
  local system = require("ziege.project").resolve_system(token)
  if not system then
    return nil, string.format("Project context for system route '%s' is not loaded", segment)
  end

  return {
    url = url,
    system = system.name,
    system_token = token,
    system_config = system.config,
    project_root = system.project_root,
    project_system = system,
    path = {},
    nodes = {},
  }
end

function M.is_url(url)
  return type(url) == "string" and vim.startswith(url, SCHEME)
end

function M.system_url(system)
  return SCHEME .. system_segment(system) .. "/"
end

function M.system_token(url)
  if not M.is_url(url) then
    return nil
  end
  local segment = url:sub(#SCHEME + 1):match("^([^/]+)")
  return segment and systems_by_segment[segment] or nil
end

function M.update_directory(parent_url, nodes)
  parent_url = addslash(parent_url)
  local names = {}
  for _, node in ipairs(nodes) do
    if names[node.name] then
      return nil, string.format("Provider returned duplicate node name '%s'", node.name)
    end
    names[node.name] = true
  end

  local directory = directories[parent_url] or { by_id = {}, by_segment = {} }
  local present = {}
  for _, node in ipairs(nodes) do
    present[node.id] = true
  end

  for id, record in pairs(directory.by_id) do
    if not present[id] then
      directory.by_id[id] = nil
      directory.by_segment[record.segment] = nil
    end
  end

  local segments = {}
  for _, node in ipairs(nodes) do
    local record = directory.by_id[node.id]
    if record and (record.name ~= node.name or record.type ~= node.type) then
      directory.by_id[node.id] = nil
      directory.by_segment[record.segment] = nil
      record = nil
    end
    if not record then
      local segment = readable_segment(node.name)
      if directory.by_segment[segment] and directory.by_segment[segment] ~= node.id then
        return nil, string.format("Provider node name '%s' has a route collision", node.name)
      end
      record = { id = node.id, name = node.name, type = node.type, segment = segment }
      directory.by_id[node.id] = record
      directory.by_segment[segment] = node.id
    end
    segments[node.id] = record.segment
  end
  directories[parent_url] = directory
  return segments
end

function M.node_url(parent_url, id)
  parent_url = addslash(parent_url)
  local directory = directories[parent_url]
  local record = directory and directory.by_id[id]
  if not record then
    return nil, string.format("Node '%s' is not registered below %s", id, parent_url)
  end
  return parent_url .. record.segment .. (record.type == "directory" and "/" or "")
end

function M.parse(url)
  if not M.is_url(url) then
    return nil, "Not a Ziege URL"
  end
  local segments = split_path(url:sub(#SCHEME + 1))
  if #segments == 0 then
    return { url = SCHEME, root = true, path = {}, nodes = {} }
  end

  local route, err = with_system(segments[1], url)
  if not route then
    return nil, err
  end
  local parent_url = SCHEME .. segments[1] .. "/"
  for index = 2, #segments do
    local directory = directories[parent_url]
    local id = directory and directory.by_segment[segments[index]]
    local node = id and directory.by_id[id]
    if not node then
      return nil, string.format(
        "Unknown node route '%s'; reopen its parent directory",
        codec.decode_segment(segments[index])
      )
    end
    table.insert(route.path, node.id)
    table.insert(route.nodes, vim.deepcopy(node))
    parent_url = parent_url .. node.segment .. "/"
  end
  return route
end

function M.parent(url)
  local parsed, err = M.parse(url)
  if not parsed then
    return nil, err
  elseif parsed.root then
    return SCHEME
  elseif #parsed.path == 0 then
    return "oil://" .. require("oil.fs").os_to_posix_path(parsed.project_system.project_root)
  end

  local without_slash = url:gsub("/+$", "")
  return without_slash:match("^(.*[/])[^/]*$")
end

function M.clear()
  systems_by_segment = {}
  system_segments_by_token = {}
  directories = {}
end

return M
