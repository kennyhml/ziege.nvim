local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
local oil_path = vim.env.OIL_NVIM_PATH

if not oil_path or oil_path == "" then
  error("OIL_NVIM_PATH must point to an oil.nvim checkout")
end

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(oil_path)
