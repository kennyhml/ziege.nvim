local cache = require("oil.cache")
local columns = require("oil.columns")
local constants = require("oil.constants")
local model = require("ziege.model")
local route = require("ziege.route")
local util = require("oil.util")
local view = require("oil.view")

local M = {}

local FIELD_ID = constants.FIELD_ID
local FIELD_META = constants.FIELD_META
local FIELD_NAME = constants.FIELD_NAME
local FIELD_TYPE = constants.FIELD_TYPE

local function parse_directory(name)
  local is_directory = vim.endswith(name, "/")
  if is_directory then
    name = name:sub(1, #name - 1)
  end
  return name, is_directory
end

local function add_error(errors, line, message)
  table.insert(errors, {
    message = message,
    lnum = line - 1,
    end_lnum = line,
    col = 0,
  })
end

function M.parse(bufnr, parse_line)
  local diffs = {}
  local errors = {}
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local adapter = util.get_adapter(bufnr, true)
  local parsed_route, route_error = route.parse(bufname)
  if not adapter or not parsed_route or parsed_route.kind ~= "facet" then
    add_error(errors, 1, route_error or string.format("Cannot edit Ziege route '%s'", bufname))
    return diffs, errors
  end

  local column_defs = columns.get_supported_columns(adapter)
  local original_entries = {}
  for _, child in pairs(cache.list_url(bufname)) do
    local name = child[FIELD_NAME]
    if view.should_display(name, bufnr) then
      original_entries[name] = child[FIELD_ID]
    end
  end

  local seen_names = {}
  local function check_duplicate(projected, line)
    local key = projected:upper()
    if seen_names[key] then
      add_error(errors, line, "Duplicate ABAP object name")
    else
      seen_names[key] = true
    end
  end

  for line_number, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)) do
    if line:match("^/%d+") then
      local result, parse_error = parse_line(adapter, line, column_defs)
      if not result or parse_error then
        add_error(errors, line_number, parse_error or "Could not parse Oil entry")
      elseif result.data.id ~= 0 then
        local parsed_entry = result.data
        local entry = result.entry
        if not parsed_entry.name then
          add_error(errors, line_number, "No object name found")
        elseif not entry then
          add_error(errors, line_number, "Could not find existing entry (was the ID changed?)")
        else
          local ok, source_parent = pcall(cache.get_parent_url, parsed_entry.id)
          local meta = entry[FIELD_META]
          local ziege_meta = meta and meta.ziege
          if not ok or not vim.startswith(source_parent, "abap://") or not ziege_meta then
            add_error(errors, line_number, "Entries cannot be copied from another Oil adapter")
          else
            local resolved, resolve_error =
              model.resolve_projected_name(parsed_entry.name, parsed_route.facet)
            if not resolved then
              add_error(errors, line_number, resolve_error)
            else
              local expected_kind = model.kind(ziege_meta.kind)
              local resolved_kind = resolved.kind
              if resolved_kind and resolved_kind ~= ziege_meta.kind then
                add_error(errors, line_number, "Renaming cannot change an ABAP object's type")
              elseif expected_kind.entry_type ~= parsed_entry._type then
                add_error(
                  errors,
                  line_number,
                  string.format(
                    "%s entries must be %ss",
                    expected_kind.label,
                    expected_kind.entry_type
                  )
                )
              else
                check_duplicate(parsed_entry.name, line_number)
                local internal_name
                if meta.display_name == parsed_entry.name then
                  internal_name = entry[FIELD_NAME]
                else
                  internal_name = model.encode_segment(parsed_entry.name)
                end

                if original_entries[internal_name] == parsed_entry.id then
                  if entry[FIELD_TYPE] == parsed_entry._type then
                    original_entries[internal_name] = nil
                  else
                    table.insert(diffs, {
                      type = "new",
                      name = internal_name,
                      entry_type = parsed_entry._type,
                    })
                  end
                else
                  table.insert(diffs, {
                    type = "new",
                    name = internal_name,
                    entry_type = parsed_entry._type,
                    id = parsed_entry.id,
                  })
                end

                for _, column_def in ipairs(column_defs) do
                  local column_name = util.split_config(column_def)
                  if columns.compare(adapter, column_name, entry, parsed_entry[column_name]) then
                    table.insert(diffs, {
                      type = "change",
                      name = internal_name,
                      entry_type = entry[FIELD_TYPE],
                      column = column_name,
                      value = parsed_entry[column_name],
                    })
                  end
                end
              end
            end
          end
        end
      end
    else
      local projected, is_directory = parse_directory(vim.trim(line))
      if projected ~= "" then
        if projected:find(" -> ", 1, true) then
          add_error(errors, line_number, "ABAP object links are not supported")
        else
          local resolved, resolve_error =
            model.resolve_projected_name(projected, parsed_route.facet)
          if not resolved then
            add_error(errors, line_number, resolve_error)
          else
            if
              not resolved.bare
              and resolved.definition.entry_type ~= (is_directory and "directory" or "file")
            then
              add_error(
                errors,
                line_number,
                string.format(
                  "%s entries must be %ss",
                  resolved.definition.label,
                  resolved.definition.entry_type
                )
              )
            else
              check_duplicate(projected, line_number)
              table.insert(diffs, {
                type = "new",
                name = model.encode_segment(projected),
                entry_type = is_directory and "directory" or "file",
              })
            end
          end
        end
      end
    end
  end

  for name, id in pairs(original_entries) do
    table.insert(diffs, { type = "delete", name = name, id = id })
  end
  return diffs, errors
end

return M
