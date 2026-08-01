local M = {}

function M.setup(opts)
  local conf = require("ziege.config").setup(opts)
  local compatibility = require("ziege.oil.compat")
  if compatibility.install() then
    require("ziege.oil.icons").install()
    require("ziege.oil.workspace").install()
  end

  pcall(vim.api.nvim_del_user_command, "Ziege")
  vim.api.nvim_create_user_command("Ziege", function(args)
    local system = args.args ~= "" and args.args or conf.default_system
    require("oil").open("abap://" .. require("ziege.model").encode_segment(system) .. "/packages/")
  end, { nargs = "?", desc = "Open an ABAP object browser" })

  return compatibility.status()
end

return M
