local M = {}
local policy = require("ziege.policy")

local defaults = {
  default_system = "S4",
  project_file = ".ziege",
  object_policy = policy.lowercase,
  icons = {
    system = { glyph = "󰒋", hl = "MiniIconsAzure" },
    package = { glyph = "", hl = "MiniIconsYellow" },
  },
  facet_order = { "packages", "classes", "interfaces" },
  facets = {
    packages = { label = "Packages", kinds = { "package" } },
    classes = { label = "Classes", kinds = { "class" } },
    interfaces = { label = "Interfaces", kinds = { "interface" } },
  },
  kinds = {
    package = { label = "Package", suffix = ".devc", entry_type = "directory", max_length = 30 },
    class = { label = "Class", suffix = ".clas.abap", entry_type = "file", max_length = 30 },
    interface = {
      label = "Interface",
      suffix = ".intf.abap",
      entry_type = "file",
      max_length = 30,
    },
  },
}

local values

function M.setup(opts)
  opts = opts or {}
  local provider = opts.provider
  local ui = opts.ui
  local merge_opts = vim.deepcopy(opts)
  merge_opts.provider = nil
  merge_opts.ui = nil
  values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), merge_opts)
  values.provider = provider or require("ziege.provider.mock").new()
  values.ui = ui or require("ziege.ui")
  return values
end

function M.get()
  if not values then
    return M.setup()
  end
  return values
end

return M
