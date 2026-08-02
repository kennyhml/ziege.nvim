local M = {}

local function is_unreserved(byte)
  return (byte >= 48 and byte <= 57)
    or (byte >= 65 and byte <= 90)
    or (byte >= 97 and byte <= 122)
    or byte == 45
    or byte == 46
    or byte == 95
    or byte == 126
    or byte == 33
    or byte == 36
    or byte == 38
    or byte == 39
    or byte == 40
    or byte == 41
    or byte == 42
    or byte == 43
    or byte == 44
    or byte == 58
    or byte == 59
    or byte == 61
    or byte == 64
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

return M
