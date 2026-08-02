local source = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(source, ":p:h:h")
local oil_path = vim.env.OIL_NVIM_PATH
local command = vim.env.ZIEGE_LSP_COMMAND
local port = tonumber(vim.env.ZIEGE_LSP_PORT) or 9257

if not oil_path or oil_path == "" then
  error("OIL_NVIM_PATH must point to an oil.nvim checkout")
elseif not command or command == "" then
  error("ZIEGE_LSP_COMMAND must point to abap-language-server")
end

vim.opt.runtimepath:prepend(plugin_root)
vim.opt.runtimepath:append(oil_path)

local project_root = vim.fn.tempname()
vim.fn.mkdir(project_root, "p")
vim.fn.writefile(vim.fn.readfile(plugin_root .. "/.ziege"), project_root .. "/.ziege")

require("ziege").setup({
  presentation = {
    namespace_delimiter = "slash",
  },
  daemon = {
    command = { command },
    port = port,
    startup_timeout_ms = 10000,
    request_timeout_ms = 60000,
  },
})
require("oil").setup({
  adapters = {
    ["abap://"] = "ziege",
  },
  columns = {},
})

local workspace_url = "oil://"
  .. require("oil.util").addslash(require("oil.fs").os_to_posix_path(project_root))
require("oil").open(workspace_url)
if not vim.wait(10000, function()
  return (vim.uv or vim.loop).fs_stat(project_root .. "/S4") ~= nil
end, 20) then
  error("Live system portal was not created")
end

require("oil").open(workspace_url .. "S4/")
if not vim.wait(120000, function()
  return vim.startswith(vim.api.nvim_buf_get_name(0), "abap://")
    and vim.b.oil_ready
    and not vim.b.oil_rendering
end, 20) then
  error("Live system portal did not open the remote tree")
end
if vim.bo.modifiable then
  error("Live remote Oil buffer is modifiable")
end

local remote_root = vim.api.nvim_buf_get_name(0)
if not remote_root:find("^abap://S4@") or remote_root:find("ziege%-project") then
  error("Live system route is not readable: " .. remote_root)
end
local listing = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, true), "\n")
if not listing:find("Flight/", 1, true) then
  error("Live remote tree did not contain the configured Flight mount")
end
require("oil").open(remote_root .. "Flight/")
if not vim.wait(120000, function()
  return vim.api.nvim_buf_get_name(0) == remote_root .. "Flight/"
    and vim.b.oil_ready
    and not vim.b.oil_rendering
end, 20) then
  error("Live readable Flight route did not open")
end
if vim.bo.modifiable then
  error("Live Flight Oil buffer is modifiable")
end
print(string.format("LIVE_OIL url=%sFlight/ readonly=true", remote_root))
vim.fn.delete(project_root, "rf")
vim.cmd.quitall({ bang = true })
