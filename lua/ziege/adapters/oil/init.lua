local cache = require("oil.cache")
local config = require("ziege.config")
local constants = require("oil.constants")
local loading = require("oil.loading")
local route = require("ziege.adapters.oil.route")

local M = {}

local FIELD_META = constants.FIELD_META

local function system_context(parsed)
  return {
    name = parsed.system,
    scope = parsed.system_token,
    config = parsed.system_config,
    project_root = parsed.project_root,
  }
end

local function provider_for(parsed)
  return config.provider_for(system_context(parsed))
end

local function validate_node(node)
  if type(node) ~= "table" then
    return "Provider entries must be tables"
  elseif type(node.id) ~= "string" or node.id == "" then
    return "Provider entries require a non-empty string id"
  elseif type(node.name) ~= "string" or node.name == "" then
    return string.format("Provider node '%s' requires a non-empty string name", node.id)
  elseif node.type ~= "file" and node.type ~= "directory" then
    return string.format("Provider node '%s' has unsupported type '%s'", node.id, node.type)
  end
end

local function create_entry(url, node, segment)
  local entry = cache.create_entry(url, segment, node.type)
  entry[constants.FIELD_TYPE] = node.type
  entry[FIELD_META] = {
    display_name = node.name,
    ziege = { node = vim.deepcopy(node) },
  }
  return entry
end

function M.normalize_url(url, callback)
  local token = route.system_token(url)
  if not token then
    callback(url)
    return
  end
  require("ziege.project").ensure_system(token, function(err)
    if err then
      vim.notify("[ziege] " .. err, vim.log.levels.ERROR)
    end
    callback(url)
  end)
end

function M.get_parent(url)
  return route.parent(url) or url
end

function M.get_column(_)
  return nil
end

function M.is_modifiable(_)
  return false
end

function M.list(url, _, callback)
  local parsed, err = route.parse(url)
  if not parsed then
    callback(err)
    return
  elseif parsed.root then
    callback("Standalone system browsing is disabled; open a directory containing .ziege")
    return
  end

  provider_for(parsed):list({
    system = system_context(parsed),
    path = vim.list_slice(parsed.path, 1, #parsed.path),
  }, function(list_err, page)
    if list_err then
      callback(list_err)
      return
    elseif type(page) ~= "table" or type(page.entries) ~= "table" then
      callback("Provider list() must return a table containing entries")
      return
    end

    local entries = {}
    local seen = {}
    for _, node in ipairs(page.entries) do
      local entry_error = validate_node(node)
      if entry_error then
        callback(entry_error)
        return
      elseif seen[node.id] then
        callback(string.format("Provider returned duplicate node id '%s'", node.id))
        return
      end
      seen[node.id] = true
    end
    local segments, route_error = route.update_directory(url, page.entries)
    if not segments then
      callback(route_error)
      return
    end
    for _, node in ipairs(page.entries) do
      table.insert(entries, create_entry(url, node, segments[node.id]))
    end
    callback(nil, entries)
  end)
end

function M.read_file(bufnr)
  local parsed, err = route.parse(vim.api.nvim_buf_get_name(bufnr))
  if not parsed or #parsed.path == 0 then
    loading.set_loading(bufnr, false)
    vim.notify(err or "Cannot read a provider system root as a file", vim.log.levels.ERROR)
    return
  end

  local cached = cache.get_entry_by_url(vim.api.nvim_buf_get_name(bufnr))
  local meta = cached and cached[FIELD_META]
  local node = meta and meta.ziege and meta.ziege.node
  provider_for(parsed):read({
    system = system_context(parsed),
    path = vim.list_slice(parsed.path, 1, #parsed.path),
    node = node and vim.deepcopy(node),
  }, vim.schedule_wrap(function(read_err, result)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    loading.set_loading(bufnr, false)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_exec_autocmds("BufReadPre", { buffer = bufnr, modeline = false })
    if read_err then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { read_err })
    elseif type(result) ~= "table" or type(result.lines) ~= "table" then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Provider read() returned no lines" })
    else
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, result.lines)
      vim.b[bufnr].ziege_revision = result.revision
    end
    vim.bo[bufnr].modified = false
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr, modeline = false })
    if not read_err and result and result.filetype then
      vim.bo[bufnr].filetype = result.filetype
    end
  end))
end

function M.write_file(_)
  vim.notify("[ziege] Remote ABAP sources are read-only", vim.log.levels.ERROR)
end

return M
