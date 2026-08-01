local config = require("ziege.config")

local M = {}

local function is_unreserved(byte)
  return (byte >= 48 and byte <= 57)
    or (byte >= 65 and byte <= 90)
    or (byte >= 97 and byte <= 122)
    or byte == 45
    or byte == 46
    or byte == 95
    or byte == 126
end

function M.encode_segment(value)
  return (
    value:gsub(".", function(char)
      local byte = string.byte(char)
      if is_unreserved(byte) then
        return char
      end
      return string.format("%%%02X", byte)
    end)
  )
end

function M.decode_segment(value)
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function validate_part(part)
  return part ~= "" and part:match("^[A-Za-z0-9_]+$") ~= nil
end

function M.normalize_name(name, kind_name)
  local policy = config.get().object_policy
  local normalize = policy and policy.normalize_name
  local normalized = name
  if normalize then
    local ok, result = pcall(normalize, name, kind_name, config.get().kinds[kind_name])
    if not ok then
      return nil, "Object policy failed: " .. result
    end
    normalized = result
  end
  if type(normalized) ~= "string" or normalized == "" then
    return nil, "Object policy must return a non-empty name"
  end
  return normalized
end

function M.validate_name(kind_name, name)
  local kind = config.get().kinds[kind_name]
  if not kind then
    return string.format("Unknown ABAP object kind '%s'", kind_name)
  end
  if name == "" then
    return "Object name cannot be empty"
  end
  if #name > kind.max_length then
    return string.format("%s names cannot exceed %d characters", kind.label, kind.max_length)
  end
  local function validate_policy()
    local policy = config.get().object_policy
    if policy and policy.validate_name then
      return policy.validate_name(name, kind_name, kind)
    end
  end
  if kind_name == "package" and name:lower() == "$tmp" then
    return validate_policy()
  end

  local namespace, local_name = name:match("^/([^/]+)/([^/]+)$")
  if namespace then
    if not validate_part(namespace) or not validate_part(local_name) then
      return "Namespaced object names may only contain letters, digits, and underscore"
    end
    return validate_policy()
  end
  if name:find("/", 1, true) then
    return "Namespaces must use the form /NAMESPACE/OBJECT"
  end
  local pattern = kind_name == "package" and "^[A-Za-z0-9_$]+$" or "^[A-Za-z0-9_]+$"
  if not name:match(pattern) then
    return string.format("%s names may only contain letters, digits, and underscore", kind.label)
  end
  return validate_policy()
end

function M.facet(name)
  return config.get().facets[name]
end

function M.kind(name)
  return config.get().kinds[name]
end

function M.project(name, kind_name)
  local kind = assert(M.kind(kind_name), string.format("Unknown kind '%s'", kind_name))
  local normalized, err = M.normalize_name(name, kind_name)
  assert(normalized, err)
  return normalized .. kind.suffix
end

function M.allowed_kinds(facet_name)
  local facet = M.facet(facet_name)
  if not facet then
    return nil, string.format("Unknown virtual facet '%s'", facet_name)
  end
  local result = {}
  for _, kind_name in ipairs(facet.kinds) do
    local kind = M.kind(kind_name)
    if not kind then
      return nil, string.format("Facet '%s' references unknown kind '%s'", facet_name, kind_name)
    end
    table.insert(result, { name = kind_name, definition = kind })
  end
  return result
end

function M.resolve_projected_name(projected, facet_name)
  local allowed, err = M.allowed_kinds(facet_name)
  if not allowed then
    return nil, err
  end

  local matched_kind
  local matched_base
  local projected_lower = projected:lower()
  for kind_name, kind in pairs(config.get().kinds) do
    if vim.endswith(projected_lower, kind.suffix:lower()) then
      if not matched_kind or #kind.suffix > #matched_kind.definition.suffix then
        matched_kind = { name = kind_name, definition = kind }
        matched_base = projected:sub(1, #projected - #kind.suffix)
      end
    end
  end

  if matched_kind then
    local permitted = false
    for _, candidate in ipairs(allowed) do
      if candidate.name == matched_kind.name then
        permitted = true
        break
      end
    end
    if not permitted then
      return nil,
        string.format(
          "Suffix '%s' is not allowed in the %s facet",
          matched_kind.definition.suffix,
          M.facet(facet_name).label
        )
    end
    matched_base, err = M.normalize_name(matched_base, matched_kind.name)
    if not matched_base then
      return nil, err
    end
    err = M.validate_name(matched_kind.name, matched_base)
    if err then
      return nil, err
    end
    return {
      bare = false,
      name = matched_base,
      projected = M.project(matched_base, matched_kind.name),
      kind = matched_kind.name,
      definition = matched_kind.definition,
      choices = { matched_kind },
    }
  end

  if projected:find("%.") then
    return nil, string.format("Unknown or incomplete object suffix in '%s'", projected)
  end

  local choices = {}
  local validation_error
  for _, candidate in ipairs(allowed) do
    local normalized, normalize_error = M.normalize_name(projected, candidate.name)
    local candidate_error = normalize_error or M.validate_name(candidate.name, normalized)
    if not candidate_error then
      local choice = vim.deepcopy(candidate)
      choice.object_name = normalized
      table.insert(choices, choice)
    elseif not validation_error then
      validation_error = candidate_error
    end
  end
  if #choices == 0 then
    return nil, validation_error or "Invalid ABAP object name"
  end
  return {
    bare = true,
    name = choices[1].object_name,
    projected = projected,
    input = projected,
    choices = choices,
  }
end

return M
