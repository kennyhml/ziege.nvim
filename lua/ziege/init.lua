local M = {}

function M.setup(opts)
  local conf = require("ziege.config").setup(opts)
  local portal = require("ziege.adapters.oil.portal")
  portal.install()
  require("ziege.adapters.oil.actions").install()

  pcall(vim.api.nvim_del_user_command, "Ziege")
  vim.api.nvim_create_user_command("Ziege", function(args)
    local root = vim.fs.root(0, conf.project_file) or vim.fs.root(vim.fn.getcwd(), conf.project_file)
    if not root then
      vim.notify("[ziege] No .ziege project found", vim.log.levels.ERROR)
      return
    end
    portal.load_directory(root, function(err, project)
      if err then
        vim.notify("[ziege] " .. err, vim.log.levels.ERROR)
        return
      end
      local name = args.args ~= "" and args.args or conf.default_system
      for _, system in ipairs(project and project.systems or {}) do
        if system.name == name then
          require("oil").open(require("ziege.adapters.oil.route").system_url(system))
          return
        end
      end
      vim.notify(string.format("[ziege] System '%s' is not configured", name), vim.log.levels.ERROR)
    end)
  end, { nargs = "?", desc = "Open a Ziege provider tree" })

  return conf
end

return M
