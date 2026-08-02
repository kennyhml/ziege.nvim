local config = require("ziege.config")

local M = {}
local uv = vim.uv or vim.loop

local cache = {}
local pending = {}
local systems_by_token = {}
local generation = 0
local TOKEN_PREFIX = "ziege-project:"

local function finish_pending(path, err, project)
  local request = pending[path]
  pending[path] = nil
  for _, callback in ipairs(request and request.callbacks or {}) do
    callback(err, project)
  end
end

local function stat_key(stat)
  return table.concat({
    stat.dev or "",
    stat.ino or "",
    stat.size,
    stat.mtime.sec,
    stat.mtime.nsec,
    stat.ctime.sec,
    stat.ctime.nsec,
  }, ":")
end

local function validate_folder(folder)
  if type(folder) ~= "string" or folder == "" then
    return "System folder names must be non-empty strings"
  elseif folder:sub(1, 1) == "." or folder:find("[/\\]") or folder:find("%c") then
    return string.format("Invalid system folder '%s'", folder)
  elseif vim.fn.has("win32") == 1 and (folder:find('[<>:"|?*]') or folder:match("[%. ]$")) then
    return string.format("Invalid Windows system folder '%s'", folder)
  end
end

local function system_token(root, name)
  return TOKEN_PREFIX .. #root .. ":" .. root .. name
end

local function unregister_project(project)
  if not project then
    return
  end
  for _, system in ipairs(project.systems) do
    if systems_by_token[system.token] == system then
      systems_by_token[system.token] = nil
    end
  end
end

local function register_systems(project)
  for _, system in ipairs(project.systems) do
    local owner = systems_by_token[system.token]
    if owner and owner.project_root ~= system.project_root then
      return string.format("Project system token collision for '%s'", system.name)
    end
    systems_by_token[system.token] = system
  end
end

local function normalize_systems(root, data)
  if type(data) ~= "table" or type(data.systems) ~= "table" then
    return nil, ".ziege must contain a 'systems' mapping or list"
  end

  local raw_systems = {}
  if vim.islist(data.systems) then
    for _, value in ipairs(data.systems) do
      if type(value) ~= "table" then
        return nil, "Each systems list entry must be a mapping"
      end
      local name = value.name or value.id
      if type(name) ~= "string" or name == "" then
        return nil, "Each systems list entry requires a name or id"
      end
      table.insert(raw_systems, { name = name, config = value })
    end
  else
    for name, value in pairs(data.systems) do
      if type(name) ~= "string" or name == "" then
        return nil, "System mapping keys must be non-empty strings"
      end
      if value == vim.NIL or value == nil then
        value = {}
      elseif type(value) ~= "table" then
        value = { value = value }
      end
      table.insert(raw_systems, { name = name, config = value })
    end
  end

  table.sort(raw_systems, function(left, right)
    return left.name < right.name
  end)

  local folders = {}
  local names = {}
  local systems = {}
  for _, raw in ipairs(raw_systems) do
    local folder = raw.config.folder or raw.name
    local folder_error = validate_folder(folder)
    if folder_error then
      return nil, folder_error
    end
    local folder_key = (vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1) and folder:lower()
      or folder
    if folders[folder_key] then
      return nil, string.format("Duplicate system folder '%s'", folder)
    elseif names[raw.name] then
      return nil, string.format("Duplicate system name '%s'", raw.name)
    end
    folders[folder_key] = true
    names[raw.name] = true
    local system = {
      name = raw.name,
      folder = folder,
      config = raw.config,
      project_root = root,
      token = system_token(root, raw.name),
    }
    table.insert(systems, system)
  end
  return systems
end

local function register_project(path, key, root, data)
  local systems, err = normalize_systems(root, data)
  if not systems then
    return nil, err
  end
  local previous = cache[path]
  if previous and previous.project then
    unregister_project(previous.project)
  end
  cache[path] = nil
  local project = {
    file = path,
    root = root,
    systems = systems,
    config = data,
  }
  local registration_error = register_systems(project)
  if registration_error then
    return nil, registration_error
  end
  cache[path] = { key = key, project = project }
  return project
end

function M.load_directory(root, callback)
  root = vim.fn.fnamemodify(root, ":p")
  local path = root .. config.get().project_file
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    local cached = cache[path]
    unregister_project(cached and cached.project)
    cache[path] = nil
    callback(nil, nil)
    return
  end

  local key = stat_key(stat)
  local cached = cache[path]
  if cached and cached.key == key then
    local registration_error = register_systems(cached.project)
    if registration_error then
      callback(registration_error)
      return
    end
    callback(nil, cached.project)
    return
  end
  if pending[path] then
    table.insert(pending[path].callbacks, callback)
    return
  end
  pending[path] = { callbacks = { callback }, generation = generation, root = root }

  local provider = config.get().project_provider
  if not provider or not provider.load_project then
    finish_pending(path, "Configured project provider does not implement load_project()")
    return
  end
  provider:load_project(root, function(load_error, data)
    vim.schedule(function()
      local request = pending[path]
      if not request or request.generation ~= generation then
        return
      end
      local current_stat = uv.fs_stat(path)
      if not current_stat or current_stat.type ~= "file" then
        local previous = cache[path]
        unregister_project(previous and previous.project)
        cache[path] = nil
        finish_pending(path, nil, nil)
        return
      elseif stat_key(current_stat) ~= key then
        local callbacks = request.callbacks
        pending[path] = nil
        for _, waiting in ipairs(callbacks) do
          M.load_directory(root, waiting)
        end
        return
      end
      if load_error then
        local previous = cache[path]
        unregister_project(previous and previous.project)
        cache[path] = nil
        finish_pending(path, load_error)
        return
      end
      local project, err = register_project(path, key, root, data)
      finish_pending(path, err, project)
    end)
  end)
end

function M.resolve_system(token)
  return systems_by_token[token]
end

function M.decode_system_token(token)
  if not vim.startswith(token, TOKEN_PREFIX) then
    return nil
  end
  local rest = token:sub(#TOKEN_PREFIX + 1)
  local length_text, offset = rest:match("^(%d+):()")
  local length = tonumber(length_text)
  if not length or not offset then
    return nil, "Malformed project system token"
  end
  local root = rest:sub(offset, offset + length - 1)
  local name = rest:sub(offset + length)
  if #root ~= length or name == "" then
    return nil, "Malformed project system token"
  end
  return { root = root, name = name }
end

function M.ensure_system(token, callback)
  local system = systems_by_token[token]
  local decoded, err = M.decode_system_token(token)
  if not decoded and system then
    callback(nil, system)
    return
  end
  if not decoded then
    callback(err or "Not a project-scoped system")
    return
  end
  M.load_directory(decoded.root, function(load_error, project)
    if load_error then
      callback(load_error)
      return
    end
    for _, candidate in ipairs(project and project.systems or {}) do
      if candidate.token == token and candidate.name == decoded.name then
        callback(nil, candidate)
        return
      end
    end
    callback(string.format("System '%s' is not configured in %s", decoded.name, decoded.root))
  end)
end

function M.clear_cache()
  generation = generation + 1
  for _, cached in pairs(cache) do
    unregister_project(cached.project)
  end
  for path, request in pairs(pending) do
    pending[path] = nil
    for _, callback in ipairs(request.callbacks) do
      callback("Project cache was cleared while loading " .. path)
    end
  end
  cache = {}
  systems_by_token = {}
end

return M
