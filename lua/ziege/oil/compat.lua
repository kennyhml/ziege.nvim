local M = {}

local supported_hashes = {
  ["oil.mutator.parser"] = {
    ["a836c4f7a253a412af80c5592ba0253c1163459f24d4fb2daefa770d0f5162eb"] = true,
  },
  ["oil.mutator.confirmation"] = {
    ["71d2cf3742cf2db1d30c7347b4300ca4a37a86accb452cc13aa41f98f30c6fad"] = true,
  },
  ["oil.mutator"] = {
    ["539a44e6b852e2c61dc3a4caa67964db7f6ce5c80857f36008470f4ba90a7311"] = true,
  },
}

local state = {
  installed = false,
  supported = false,
  reason = "Ziege has not been set up",
}

local function module_hash(module_name)
  local module_path = module_name:gsub("%.", "/")
  local paths = vim.api.nvim_get_runtime_file("lua/" .. module_path .. ".lua", false)
  if #paths == 0 then
    paths = vim.api.nvim_get_runtime_file("lua/" .. module_path .. "/init.lua", false)
  end
  local path = paths[1]
  if not path then
    return nil, string.format("Could not locate %s", module_name)
  end
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local contents = file:read("*a")
  file:close()
  return vim.fn.sha256(contents)
end

local function check_version()
  for module_name, hashes in pairs(supported_hashes) do
    local hash, err = module_hash(module_name)
    if not hash then
      return false, err
    elseif not hashes[hash] then
      return false, string.format("Unsupported %s source fingerprint %s", module_name, hash)
    end
  end
  return true
end

function M.install()
  if state.installed then
    return state.supported
  end
  state.installed = true

  local ok, reason = check_version()
  if not ok then
    state.reason = reason
    vim.notify_once(
      "[ziege] " .. reason .. "; ABAP Oil buffers will be read-only",
      vim.log.levels.WARN
    )
    return false
  end

  local parser = require("oil.mutator.parser")
  local confirmation = require("oil.mutator.confirmation")
  if type(parser.parse) ~= "function" or type(parser.parse_line) ~= "function" then
    state.reason = "Oil parser has an unexpected shape"
    return false
  elseif type(confirmation.show) ~= "function" then
    state.reason = "Oil confirmation module has an unexpected shape"
    return false
  end

  local original_parse = parser.parse
  local original_confirmation = confirmation.show
  parser.parse = function(bufnr)
    if vim.startswith(vim.api.nvim_buf_get_name(bufnr), "abap://") then
      return require("ziege.oil.parser").parse(bufnr, parser.parse_line)
    end
    local diffs, errors = original_parse(bufnr)
    return require("ziege.oil.workspace").protect_diffs(bufnr, diffs, errors)
  end
  confirmation.show = function(actions, should_confirm, callback)
    local has_abap_action = false
    for _, action in ipairs(actions) do
      if
        (action.url and vim.startswith(action.url, "abap://"))
        or (action.src_url and vim.startswith(action.src_url, "abap://"))
        or (action.dest_url and vim.startswith(action.dest_url, "abap://"))
      then
        has_abap_action = true
        break
      end
    end
    if not has_abap_action then
      return original_confirmation(actions, should_confirm, callback)
    end
    vim.schedule(function()
      require("ziege.wizard").prepare(actions, function(proceed)
        if proceed then
          original_confirmation(actions, should_confirm, function(confirmed)
            if confirmed then
              require("ziege.oil.cursor").capture(actions)
            else
              require("ziege.oil.cursor").clear()
            end
            callback(confirmed)
          end)
        else
          require("ziege.oil.cursor").clear()
          callback(false)
        end
      end)
    end)
  end

  local group = vim.api.nvim_create_augroup("ZiegeOilCompatibility", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OilMutationComplete",
    callback = function()
      require("ziege.oil.cursor").restore()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OilActionsPost",
    callback = function(args)
      if args.data and args.data.err then
        require("ziege.oil.cursor").clear()
      end
    end,
  })

  state.supported = true
  state.reason = nil
  return true
end

function M.is_supported()
  return state.installed and state.supported
end

function M.status()
  return vim.deepcopy(state)
end

return M
