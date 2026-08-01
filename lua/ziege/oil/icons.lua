local M = {}

local installed = false

local function icon_for(entry)
  local constants = require("oil.constants")
  local meta = entry[constants.FIELD_META]
  if not meta then
    return nil
  end

  local ziege = meta.ziege
  if meta.ziege_system or (ziege and ziege.virtual and ziege.system) then
    return require("ziege.config").get().icons.system
  elseif ziege and (ziege.kind == "package" or ziege.facet == "packages") then
    return require("ziege.config").get().icons.package
  end
end

local function render_icon(spec, conf)
  if spec == false then
    return nil
  end

  local glyph
  local highlight
  if type(spec) == "string" then
    glyph = spec
  elseif type(spec) == "table" then
    glyph = spec.glyph
    highlight = spec.hl
  end
  if not glyph or glyph == "" then
    return nil
  end

  if not conf or conf.add_padding ~= false then
    glyph = glyph .. " "
  end
  if conf and conf.highlight then
    if type(conf.highlight) == "function" then
      highlight = conf.highlight(glyph)
    else
      highlight = conf.highlight
    end
  end
  return highlight and { glyph, highlight } or glyph
end

function M.install()
  if installed then
    return true
  end

  local columns = require("oil.columns")
  local original = columns.get_column(require("oil.adapters.files"), "icon")
  if not original then
    return false
  end

  local definition = vim.tbl_extend("force", {}, original)
  definition.render = function(entry, conf, bufnr)
    local rendered = render_icon(icon_for(entry), conf)
    if rendered then
      return rendered
    end
    return original.render(entry, conf, bufnr)
  end
  columns.register("icon", definition)
  installed = true
  return true
end

return M
