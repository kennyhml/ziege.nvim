local M = {}
local uv = vim.uv or vim.loop

local active_projects = {}
local portals = {}
local pending_refresh = {}
local installed = false

local function normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function unregister_root(root)
  local project = active_projects[root]
  if project then
    for _, system in ipairs(project.systems) do
      portals[normalize(project.root .. system.folder)] = nil
    end
  end
  active_projects[root] = nil
end

local function ensure_empty_directory(path)
  local stat, stat_error = uv.fs_lstat(path)
  if not stat then
    local created, mkdir_error = uv.fs_mkdir(path, 493)
    if not created then
      return nil, mkdir_error
    end
    return true
  elseif stat.type ~= "directory" then
    return nil, string.format("System portal '%s' conflicts with a %s", path, stat.type)
  end

  local scan, scan_error = uv.fs_scandir(path)
  if not scan then
    return nil, scan_error
  elseif uv.fs_scandir_next(scan) then
    return nil, string.format("System portal '%s' must be empty", path)
  end
  return false
end

local function sync(project)
  local root = normalize(project.root)
  unregister_root(root)
  local prepared = {}
  local created = false
  for _, system in ipairs(project.systems) do
    local path = normalize(project.root .. system.folder)
    local was_created, err = ensure_empty_directory(path)
    if err then
      return nil, err
    end
    created = created or was_created
    table.insert(prepared, { path = path, system = system })
  end
  active_projects[root] = project
  for _, portal in ipairs(prepared) do
    portals[portal.path] = portal.system
  end
  return created
end

local function refresh_local_buffer(bufnr, path)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
      return
    end
    local _, current_path = require("oil.util").parse_url(vim.api.nvim_buf_get_name(bufnr))
    if current_path and normalize(path) == normalize(require("oil.fs").posix_to_os_path(current_path)) then
      vim.cmd.edit({ bang = true })
    end
  end)
end

local function redirect(bufnr, path)
  path = normalize(path)
  local system = portals[path]
  if not system then
    return false
  end
  local stat = uv.fs_lstat(path)
  local scan = stat and stat.type == "directory" and uv.fs_scandir(path)
  if not scan or uv.fs_scandir_next(scan) then
    portals[path] = nil
    return false
  end
  local source_url = vim.api.nvim_buf_get_name(bufnr)
  vim.schedule(function()
    if
      vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_get_current_buf() == bufnr
      and vim.api.nvim_buf_get_name(bufnr) == source_url
    then
      require("oil").open(require("ziege.adapters.oil.route").system_url(system))
    end
  end)
  return true
end

function M.load_directory(root, callback)
  root = normalize(root)
  require("ziege.project").load_directory(root, function(err, project)
    if err or not project then
      unregister_root(root)
      pending_refresh[root] = nil
      callback(err, project)
      return
    end
    local _, portal_error = sync(project)
    callback(portal_error, portal_error and nil or project)
  end)
end

local function project_root_for(path)
  local marker = vim.fs.find(require("ziege.config").get().project_file, {
    path = path,
    upward = true,
    limit = 1,
    type = "file",
  })[1]
  if marker then
    return normalize(vim.fs.dirname(marker))
  end
  local nearest
  for root in pairs(active_projects) do
    if
      (path == root or vim.startswith(path .. "/", root .. "/"))
      and (not nearest or #root > #nearest)
    then
      nearest = root
    end
  end
  return nearest
end

local function handle_local_buffer(bufnr)
  local scheme, oil_path = require("oil.util").parse_url(vim.api.nvim_buf_get_name(bufnr))
  if scheme ~= "oil://" or not oil_path then
    return
  end
  local path = normalize(require("oil.fs").posix_to_os_path(oil_path))
  local root = project_root_for(path)
  if not root then
    return
  end
  require("ziege.project").load_directory(root, function(err, project)
    if err then
      vim.notify_once("[ziege] " .. err, vim.log.levels.ERROR)
      return
    elseif not project then
      unregister_root(root)
      pending_refresh[root] = nil
      return
    end
    local created, portal_error = sync(project)
    if portal_error then
      vim.notify_once("[ziege] " .. portal_error, vim.log.levels.ERROR)
      return
    elseif redirect(bufnr, path) then
      return
    elseif created then
      pending_refresh[normalize(project.root)] = true
    end
    if path == normalize(project.root) and pending_refresh[path] then
      pending_refresh[path] = nil
      refresh_local_buffer(bufnr, path)
    end
  end)
end

local function ensure_active()
  for root in pairs(vim.deepcopy(active_projects)) do
    require("ziege.project").load_directory(root, function(err, project)
      if err then
        vim.notify_once("[ziege] " .. err, vim.log.levels.ERROR)
      elseif not project then
        unregister_root(root)
        pending_refresh[root] = nil
      else
        local _, portal_error = sync(project)
        if portal_error then
          vim.notify_once("[ziege] " .. portal_error, vim.log.levels.ERROR)
        end
      end
    end)
  end
end

function M.install()
  if installed then
    return
  end
  installed = true
  local group = vim.api.nvim_create_augroup("ZiegeOilPortals", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "oil://*",
    callback = function(args)
      handle_local_buffer(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OilActionsPost",
    callback = ensure_active,
  })
end

function M.system_for_path(path)
  return portals[normalize(path)]
end

return M
