local M = {}

M.lowercase = {
  normalize_name = function(name)
    return name:lower()
  end,
}

M.uppercase = {
  normalize_name = function(name)
    return name:upper()
  end,
}

M.preserve = {
  normalize_name = function(name)
    return name
  end,
}

return M
