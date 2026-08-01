local config = require("ziege.config")
local model = require("ziege.model")

local M = {}

local SCHEME = "abap://"

local function split_path(path)
  local result = {}
  for part in path:gmatch("[^/]+") do
    table.insert(result, part)
  end
  return result
end

local function package_from_segment(segment)
  local projected = model.decode_segment(segment)
  local suffix = config.get().kinds.package.suffix
  if not vim.endswith(projected:lower(), suffix:lower()) then
    return nil, string.format("Package path segment '%s' must end in %s", projected, suffix)
  end
  local name = projected:sub(1, #projected - #suffix)
  local normalized, err = model.normalize_name(name, "package")
  if not normalized then
    return nil, err
  end
  return normalized
end

local function package_url(system_token, packages)
  local parts = { SCHEME, model.encode_segment(system_token), "/packages/" }
  for index, package_name in ipairs(packages) do
    if index > 1 then
      table.insert(parts, "packages/")
    end
    table.insert(parts, model.encode_segment(model.project(package_name, "package")))
    table.insert(parts, "/")
  end
  return table.concat(parts)
end

function M.parse(url)
  if not vim.startswith(url, SCHEME) then
    return nil, "Not a Ziege URL"
  end
  local path = url:sub(#SCHEME + 1)
  local segments = split_path(path)
  if #segments == 0 then
    return { kind = "root", url = SCHEME }
  end

  local system_token = model.decode_segment(segments[1])
  local project = require("ziege.project")
  local system_context = project.resolve_system(system_token)
  local scoped_system, scoped_error = project.decode_system_token(system_token)
  if scoped_error then
    return nil, scoped_error
  elseif scoped_system and not system_context then
    return nil, string.format("Project context for system '%s' is not loaded", scoped_system.name)
  end
  local system = system_context and system_context.name or system_token
  local function with_system(values)
    values.system = system
    values.system_token = system_token
    if system_context then
      values.system_config = system_context.config
      values.project_root = system_context.project_root
      values.project_system = system_context
    end
    return values
  end
  if #segments == 1 then
    return with_system({ kind = "system", url = url })
  end
  if model.decode_segment(segments[2]) ~= "packages" then
    return nil, "Expected the packages route"
  end
  if #segments == 2 then
    return with_system({
      kind = "facet",
      facet = "packages",
      packages = {},
      package = nil,
      url = url,
    })
  end

  local packages = {}
  local index = 3
  while index <= #segments do
    local package_name, err = package_from_segment(segments[index])
    if not package_name then
      return nil, err
    end
    table.insert(packages, package_name)
    if index == #segments then
      return with_system({
        kind = "package",
        packages = packages,
        package = package_name,
        url = url,
      })
    end

    local facet_name = model.decode_segment(segments[index + 1])
    if not model.facet(facet_name) then
      return nil, string.format("Unknown virtual facet '%s'", facet_name)
    end
    if index + 1 == #segments then
      return with_system({
        kind = "facet",
        packages = packages,
        package = package_name,
        facet = facet_name,
        url = url,
      })
    end
    if facet_name ~= "packages" then
      return nil, string.format("Unexpected path below the %s facet", facet_name)
    end
    index = index + 2
  end
end

function M.parent(url)
  local parsed = assert(M.parse(url))
  if parsed.kind == "root" then
    return SCHEME
  elseif parsed.kind == "system" and parsed.project_system then
    return require("ziege.project").root_url(parsed.project_system)
  elseif parsed.kind == "system" then
    return SCHEME
  elseif parsed.kind == "facet" and #parsed.packages == 0 then
    return SCHEME .. model.encode_segment(parsed.system_token) .. "/"
  elseif parsed.kind == "facet" then
    return package_url(parsed.system_token, parsed.packages)
  elseif parsed.kind == "package" then
    if #parsed.packages == 1 then
      return SCHEME .. model.encode_segment(parsed.system_token) .. "/packages/"
    end
    local parents = vim.list_slice(parsed.packages, 1, #parsed.packages - 1)
    return package_url(parsed.system_token, parents) .. "packages/"
  end
end

function M.parent_and_leaf(url)
  local without_slash = url:gsub("/+$", "")
  local parent, leaf = without_slash:match("^(.*[/])([^/]*)$")
  if not parent or leaf == "" then
    return nil, nil, "Malformed action URL"
  end
  local parsed, err = M.parse(parent)
  if not parsed then
    return nil, nil, err
  end
  return parsed, model.decode_segment(leaf)
end

function M.replace_leaf(url, projected)
  local without_slash = url:gsub("/+$", "")
  local parent = without_slash:match("^(.*[/])[^/]*$")
  assert(parent, "Malformed action URL")
  return parent .. model.encode_segment(projected)
end

function M.package_url(system_token, packages)
  return package_url(system_token, packages)
end

return M
