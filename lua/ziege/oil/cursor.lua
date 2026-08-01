local model = require("ziege.model")
local route = require("ziege.route")

local M = {}

local pending

function M.capture(actions)
  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if not vim.startswith(bufname, "abap://") then
    pending = nil
    return
  end
  local parsed_route = route.parse(bufname)
  local entry = require("oil").get_cursor_entry()
  if not parsed_route or not entry or not entry.parsed_name then
    pending = nil
    return
  end

  local resolved = model.resolve_projected_name(entry.parsed_name, parsed_route.facet)
  if not resolved then
    pending = nil
    return
  end
  local target = model.encode_segment(entry.parsed_name)
  if resolved.bare and entry.meta and entry.meta.ziege then
    target = model.encode_segment(model.project(resolved.name, entry.meta.ziege.kind))
  end
  for _, action in ipairs(actions) do
    local operation = action.ziege
    local destination = operation and operation.destination
    if
      destination
      and destination.system_token == parsed_route.system_token
      and destination.package == parsed_route.package
      and destination.name == resolved.name
      and destination.input == entry.parsed_name
      and (not resolved.kind or destination.kind == resolved.kind)
    then
      target = model.encode_segment(destination.projected)
      break
    end
  end
  pending = { bufnr = bufnr, name = target }
end

function M.clear()
  pending = nil
end

function M.restore()
  local target = pending
  pending = nil
  if not target or not vim.api.nvim_buf_is_valid(target.bufnr) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(target.bufnr)
  for line_number = 1, line_count do
    local entry = require("oil").get_entry_on_line(target.bufnr, line_number)
    if entry and entry.name == target.name then
      local line = vim.api.nvim_buf_get_lines(target.bufnr, line_number - 1, line_number, true)[1]
      local column = line:find(entry.parsed_name or entry.name, 1, true) or 1
      for _, winid in ipairs(vim.fn.win_findbuf(target.bufnr)) do
        pcall(vim.api.nvim_win_set_cursor, winid, { line_number, column - 1 })
      end
      return
    end
  end
end

return M
