local M = {}

local defaults = {
  default_system = "S4",
  project_file = ".ziege",
  daemon = {
    command = { "abap-language-server" },
    host = "127.0.0.1",
    port = 9257,
    startup_timeout_ms = 5000,
    request_timeout_ms = 30000,
  },
  presentation = {
    namespace_delimiter = "parentheses",
  },
  keymaps = {
    create = "<localleader>c",
    delete = "<localleader>d",
    rename = "<localleader>r",
    refresh = "<localleader>R",
  },
}

local values

function M.setup(opts)
  opts = opts or {}
  local provider = opts.provider
  local project_provider = opts.project_provider
  local providers = opts.providers
  local resolve_provider = opts.resolve_provider
  local ui = opts.ui
  local merge_opts = vim.deepcopy(opts)
  merge_opts.provider = nil
  merge_opts.project_provider = nil
  merge_opts.providers = nil
  merge_opts.resolve_provider = nil
  merge_opts.ui = nil
  values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), merge_opts)
  if
    values.presentation.namespace_delimiter ~= "parentheses"
    and values.presentation.namespace_delimiter ~= "slash"
  then
    error("presentation.namespace_delimiter must be 'parentheses' or 'slash'")
  end
  values.daemon.initialization_options = {
    presentation = {
      namespaceDelimiter = values.presentation.namespace_delimiter,
    },
  }
  local daemon_provider = require("ziege.provider.lsp").new({ daemon = values.daemon })
  values.provider = provider or daemon_provider
  values.project_provider = project_provider
    or (provider and provider.load_project and provider)
    or daemon_provider
  values.providers = providers
  values.resolve_provider = resolve_provider
  values.ui = ui or require("ziege.ui")
  return values
end

function M.get()
  if not values then
    return M.setup()
  end
  return values
end

function M.provider_for(system)
  local conf = M.get()
  if conf.resolve_provider then
    local provider = conf.resolve_provider(system)
    if provider then
      return provider
    end
  end
  local name = system and system.config and system.config.provider
  return (name and conf.providers and conf.providers[name]) or conf.provider
end

return M
