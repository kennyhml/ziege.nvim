local cache = require("oil.cache")
local config = require("ziege.config")
local constants = require("oil.constants")
local loading = require("oil.loading")
local model = require("ziege.model")
local route = require("ziege.route")

local M = {}

local FIELD_META = constants.FIELD_META

local function create_entry(url, name, kind_name, metadata)
  local kind = assert(model.kind(kind_name))
  local normalized, err = model.normalize_name(name, kind_name)
  if not normalized then
    return nil, err
  end
  local projected = model.project(normalized, kind_name)
  local entry = cache.create_entry(url, model.encode_segment(projected), kind.entry_type)
  entry[FIELD_META] = {
    display_name = projected,
    ziege = vim.tbl_extend("force", metadata or {}, {
      kind = kind_name,
      name = normalized,
      provider_name = name,
    }),
  }
  return entry
end

function M.normalize_url(url, callback)
  local _, path = require("oil.util").parse_url(url)
  local encoded_token = path and path:match("^([^/]+)")
  local token = encoded_token and model.decode_segment(encoded_token)
  local scoped = token and require("ziege.project").decode_system_token(token)
  if not scoped then
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
  local parsed = route.parse(url)
  if parsed then
    return route.parent(url)
  end
  local parent = route.parent_and_leaf(url)
  return parent and parent.url or url
end

function M.get_column(_)
  return nil
end

function M.is_modifiable(bufnr)
  if not require("ziege.oil.compat").is_supported() then
    return false
  end
  local parsed = route.parse(vim.api.nvim_buf_get_name(bufnr))
  return parsed ~= nil and parsed.kind == "facet"
end

function M.list(url, _, callback)
  local parsed, err = route.parse(url)
  if not parsed then
    return callback(err)
  end

  if parsed.kind == "system" then
    local entry = cache.create_entry(url, "packages", "directory")
    entry[FIELD_META] = {
      display_name = "packages",
      ziege = { virtual = true, facet = "packages" },
    }
    return callback(nil, { entry })
  elseif parsed.kind == "root" then
    local provider = config.get().provider
    local function render_systems(list_err, systems)
      if list_err then
        return callback(list_err)
      end
      local entries = {}
      for _, system in ipairs(systems or { config.get().default_system }) do
        local entry = cache.create_entry(url, model.encode_segment(system), "directory")
        entry[FIELD_META] = { display_name = system, ziege = { virtual = true, system = system } }
        table.insert(entries, entry)
      end
      callback(nil, entries)
    end
    if provider.list_systems then
      return provider:list_systems(render_systems)
    end
    return render_systems(nil, { config.get().default_system })
  elseif parsed.kind == "package" then
    local entries = {}
    for _, facet_name in ipairs(config.get().facet_order) do
      local facet = config.get().facets[facet_name]
      if facet then
        local entry = cache.create_entry(url, facet_name, "directory")
        entry[FIELD_META] = {
          display_name = facet.label,
          ziege = { virtual = true, facet = facet_name },
        }
        table.insert(entries, entry)
      end
    end
    return callback(nil, entries)
  elseif parsed.kind ~= "facet" then
    return callback(string.format("Cannot list Ziege route '%s'", url))
  end

  config.get().provider:list(parsed, function(list_err, supplied)
    if list_err then
      return callback(list_err)
    end
    local entries = {}
    for _, item in ipairs(supplied or {}) do
      local facet = config.get().facets[parsed.facet]
      local allowed = false
      for _, kind_name in ipairs(facet.kinds) do
        if kind_name == item.kind then
          allowed = true
          break
        end
      end
      if not allowed then
        return callback(
          string.format("Provider returned kind '%s' for the '%s' facet", item.kind, parsed.facet)
        )
      end
      local entry, entry_error = create_entry(url, item.name, item.kind, {
        description = item.description,
        package = parsed.package,
        system = parsed.system,
        system_token = parsed.system_token,
        system_config = parsed.system_config,
        project_root = parsed.project_root,
      })
      if not entry then
        return callback(entry_error)
      end
      table.insert(entries, entry)
    end
    callback(nil, entries)
  end)
end

local function display_url(url)
  local parent, projected = route.parent_and_leaf(url)
  if not parent then
    return url
  end
  return string.format("%s:%s/%s", parent.system, parent.facet, projected)
end

function M.render_action(action)
  if action.type == "create" or action.type == "delete" then
    return string.format("%s %s", action.type:upper(), display_url(action.url))
  elseif action.type == "move" then
    return string.format("MOVE %s -> %s", display_url(action.src_url), display_url(action.dest_url))
  elseif action.type == "copy" then
    return string.format("COPY %s -> %s", display_url(action.src_url), display_url(action.dest_url))
  end
  return string.format("%s ABAP object", action.type:upper())
end

function M.perform_action(action, callback)
  if not action.ziege then
    return callback("ABAP action was not prepared by the Ziege wizard")
  end
  config.get().provider:perform(action.ziege, callback)
end

function M.read_file(bufnr)
  local provider = config.get().provider
  if not provider.read then
    loading.set_loading(bufnr, false)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Ziege provider does not implement read()" })
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
    return
  end
  local url = vim.api.nvim_buf_get_name(bufnr)
  local parent, projected, err = route.parent_and_leaf(url)
  if not parent then
    loading.set_loading(bufnr, false)
    return vim.notify(err, vim.log.levels.ERROR)
  end
  local cached = cache.get_entry_by_url(url)
  local meta = cached and cached[FIELD_META]
  local ziege_meta = meta and meta.ziege
  provider:read(
    {
      route = parent,
      projected = projected,
      kind = ziege_meta and ziege_meta.kind,
      name = ziege_meta and ziege_meta.provider_name,
    },
    vim.schedule_wrap(function(read_err, lines)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      loading.set_loading(bufnr, false)
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_exec_autocmds("BufReadPre", { buffer = bufnr, modeline = false })
      if read_err then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { read_err })
        vim.bo[bufnr].modifiable = false
      else
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines or {})
      end
      vim.bo[bufnr].modified = false
      vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr, modeline = false })
      if not read_err and (vim.bo[bufnr].filetype == "" or vim.bo[bufnr].filetype == "oil") then
        vim.bo[bufnr].filetype = "abap"
      end
    end)
  )
end

function M.write_file(bufnr)
  local provider = config.get().provider
  if not provider.write then
    vim.notify("Ziege provider does not implement write()", vim.log.levels.ERROR)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.bo[bufnr].modified = true
      end
    end)
    return
  end
  local parent, projected, err = route.parent_and_leaf(vim.api.nvim_buf_get_name(bufnr))
  if not parent then
    return vim.notify(err, vim.log.levels.ERROR)
  end
  vim.api.nvim_exec_autocmds("BufWritePre", { buffer = bufnr, modeline = false })
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local cached = cache.get_entry_by_url(vim.api.nvim_buf_get_name(bufnr))
  local meta = cached and cached[FIELD_META]
  local ziege_meta = meta and meta.ziege
  vim.bo[bufnr].modifiable = false
  provider:write(
    {
      route = parent,
      projected = projected,
      kind = ziege_meta and ziege_meta.kind,
      name = ziege_meta and ziege_meta.provider_name,
      lines = lines,
    },
    vim.schedule_wrap(function(write_err)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      vim.bo[bufnr].modifiable = true
      if write_err then
        vim.bo[bufnr].modified = true
        vim.notify(write_err, vim.log.levels.ERROR)
      else
        vim.bo[bufnr].modified = false
        vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
      end
    end)
  )
end

return M
