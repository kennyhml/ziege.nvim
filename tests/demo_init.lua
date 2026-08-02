local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
local oil_path = vim.env.OIL_NVIM_PATH

if not oil_path or oil_path == "" then
  error("OIL_NVIM_PATH must point to an oil.nvim checkout")
end

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(oil_path)

local provider = require("ziege.provider.mock").new({
  systems = {
    S4 = {
      children = {
        {
          id = "objects",
          name = "Objects",
          type = "directory",
          virtual = true,
          children = {
            {
              id = "order",
              name = "/acme/zcl_order.clas.abap",
              type = "file",
              extension = "clas.abap",
              filetype = "abap",
              source = {
                "CLASS /acme/zcl_order DEFINITION PUBLIC FINAL CREATE PUBLIC.",
                "ENDCLASS.",
              },
            },
          },
        },
      },
    },
  },
  extensions = { "clas.abap" },
})

require("ziege").setup({
  default_system = "S4",
  provider = provider,
})

require("oil").setup({
  adapters = {
    ["abap://"] = "ziege",
  },
  columns = {},
})

vim.schedule(function()
  vim.cmd("Ziege S4")
end)
