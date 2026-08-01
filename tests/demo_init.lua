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
      transports = {
        { id = "DEVK900001", label = "DEVK900001: Ziege demo" },
        { id = "DEVK900002", label = "DEVK900002: Local experiments" },
      },
      packages = {
        ["/acme/core"] = { description = "Core package" },
        ["/acme/sales"] = { description = "Sales package" },
        ["/acme/core_test"] = { parent = "/acme/core", description = "Core tests" },
      },
      objects = {
        ["class:/acme/zcl_order"] = {
          kind = "class",
          name = "/acme/zcl_order",
          package = "/acme/core",
          description = "Order service",
          source = {
            "CLASS /acme/zcl_order DEFINITION PUBLIC FINAL CREATE PUBLIC.",
            "ENDCLASS.",
            "",
            "CLASS /acme/zcl_order IMPLEMENTATION.",
            "ENDCLASS.",
          },
        },
        ["interface:/acme/zif_order"] = {
          kind = "interface",
          name = "/acme/zif_order",
          package = "/acme/core",
          description = "Order contract",
          source = {
            "INTERFACE /acme/zif_order PUBLIC.",
            "ENDINTERFACE.",
          },
        },
      },
    },
  },
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
  require("oil").open("abap://S4/packages/")
end)
