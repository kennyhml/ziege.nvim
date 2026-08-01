local M = {}

local installed = false

local function virtual_system_entry(url, system)
  local cache = require("oil.cache")
  local constants = require("oil.constants")
  local entry = cache.create_entry(url, system.folder, "directory")
  entry[constants.FIELD_META] = {
    ziege_system = system,
  }
  return entry
end

function M.install()
  if installed then
    return
  end
  installed = true

  local files = require("oil.adapters.files")
  local original_list = files.list
  local original_get_entry_path = files.get_entry_path

  files.list = function(url, column_defs, callback)
    require("ziege.project").load_oil_url(url, function(project_error, project)
      if project_error then
        vim.notify_once("[ziege] " .. project_error, vim.log.levels.ERROR)
        project = nil
      end
      local injected = false
      original_list(url, column_defs, function(list_error, entries, fetch_more)
        if list_error then
          callback(list_error)
          return
        end
        for _, entry in ipairs(entries or {}) do
          local constants = require("oil.constants")
          local meta = entry[constants.FIELD_META]
          if meta then
            meta.ziege_system = nil
          end
        end
        if project and not injected then
          entries = entries or {}
          for _, system in ipairs(project.systems) do
            table.insert(entries, virtual_system_entry(url, system))
          end
          injected = true
        end
        callback(nil, entries, fetch_more)
      end)
    end)
  end

  files.get_entry_path = function(url, entry, callback)
    local system = entry.meta and entry.meta.ziege_system
    if system then
      callback(require("ziege.project").system_url(system))
      return
    end
    original_get_entry_path(url, entry, callback)
  end
end

function M.protect_diffs(bufnr, diffs, errors)
  if not vim.startswith(vim.api.nvim_buf_get_name(bufnr), "oil://") then
    return diffs, errors
  end
  local cache = require("oil.cache")
  local constants = require("oil.constants")
  local lines_by_id = {}
  for line_number, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)) do
    local id = tonumber(line:match("^/(%d+)"))
    if id then
      lines_by_id[id] = line_number
    end
  end

  local reported = {}
  for _, diff in ipairs(diffs) do
    if diff.id and not reported[diff.id] then
      local entry = cache.get_entry_by_id(diff.id)
      local meta = entry and entry[constants.FIELD_META]
      if meta and meta.ziege_system then
        local line_number = lines_by_id[diff.id] or 1
        table.insert(errors, {
          message = "Virtual system folders cannot be renamed, copied, or deleted",
          lnum = line_number - 1,
          end_lnum = line_number,
          col = 0,
        })
        reported[diff.id] = true
      end
    end
  end
  return diffs, errors
end

return M
