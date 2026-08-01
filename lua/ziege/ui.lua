local M = {}

function M.select(items, opts, callback)
  vim.ui.select(items, opts, callback)
end

function M.input(opts, callback)
  opts = opts or {}
  local prompt = (opts.prompt or "Input"):gsub(":%s*$", "")
  local columns = vim.o.columns
  local width = math.max(1, math.min(math.max(40, #prompt + 4), columns - 4))
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].filetype = "ziege_input"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { opts.default or "" })

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - 3) / 2),
    col = math.floor((columns - width) / 2),
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = " " .. prompt .. " ",
    title_pos = "left",
  })
  vim.wo[winid].wrap = false

  local finished = false
  local function finish(value)
    if finished then
      return
    end
    finished = true
    if vim.fn.mode():sub(1, 1) == "i" then
      vim.cmd.stopinsert()
    end
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_close(winid, true)
      end
      callback(value)
    end)
  end
  local function confirm()
    local value = vim.api.nvim_buf_get_lines(bufnr, 0, 1, true)[1]
    finish(value)
  end

  vim.keymap.set({ "i", "n" }, "<CR>", confirm, { buffer = bufnr, nowait = true })
  vim.keymap.set({ "i", "n" }, "<C-c>", function()
    finish(nil)
  end, { buffer = bufnr, nowait = true })
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    finish(nil)
  end, { buffer = bufnr, nowait = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      finish(nil)
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = bufnr,
    once = true,
    callback = function()
      finish(nil)
    end,
  })

  vim.api.nvim_win_set_cursor(winid, { 1, #(opts.default or "") })
  vim.cmd.startinsert({ bang = true })
end

return M
