local M = {}
local uv = vim.uv or vim.loop

local function normalize_root(root)
  return vim.fs.normalize(vim.fn.fnamemodify(root, ":p"))
end

local function error_message(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

local function probe(host, port, callback)
  local socket = uv.new_tcp()
  local timer = uv.new_timer()
  if not socket or not timer then
    if socket then
      socket:close()
    end
    if timer then
      timer:close()
    end
    callback(false)
    return
  end
  local finished = false
  local function finish(ready)
    if finished then
      return
    end
    finished = true
    timer:stop()
    timer:close()
    socket:close()
    vim.schedule(function()
      callback(ready)
    end)
  end
  timer:start(1000, 0, function()
    finish(false)
  end)
  socket:connect(host, port, function(err)
    finish(err == nil)
  end)
end

function M.new(opts)
  opts = vim.deepcopy(opts or {})
  local manager = {
    opts = opts,
    clients = {},
    pending = {},
    initialization_timers = {},
  }

  function manager:_stop_initialization_timer(root)
    local timer = self.initialization_timers[root]
    self.initialization_timers[root] = nil
    if timer then
      timer:stop()
      timer:close()
    end
  end

  function manager:_finish(root, err, client)
    self:_stop_initialization_timer(root)
    local callbacks = self.pending[root] or {}
    self.pending[root] = nil
    if client then
      self.clients[root] = client.id
    end
    for _, callback in ipairs(callbacks) do
      callback(err, client)
    end
  end

  function manager:_start_client(root)
    local id
    id = vim.lsp.start({
      name = "ziege",
      cmd = vim.lsp.rpc.connect(self.opts.host, self.opts.port),
      root_dir = root,
      init_options = self.opts.initialization_options,
      workspace_folders = {
        { uri = vim.uri_from_fname(root), name = root },
      },
      on_init = function(client)
        if not self.pending[root] then
          client:stop(true)
          return
        end
        local experimental = client.server_capabilities.experimental or {}
        local capability = experimental.ziege or {}
        if capability.protocolVersion ~= 1 then
          client:stop(true)
          self:_finish(root, "Language server does not support Ziege protocol version 1")
          return
        end
        self:_finish(root, nil, client)
      end,
      on_exit = function(_, _, client_id)
        if self.clients[root] == client_id then
          self.clients[root] = nil
        end
        if self.pending[root] then
          self:_finish(root, "LSP connection closed before initialization")
        end
      end,
    }, {
      attach = false,
      silent = true,
      reuse_client = function(client)
        return client.id == self.clients[root]
      end,
    })
    if not id then
      self:_finish(root, "Could not start the Ziege LSP client")
      return
    elseif not self.pending[root] then
      return
    end
    local timer = uv.new_timer()
    if not timer then
      local client = vim.lsp.get_client_by_id(id)
      if client then
        client:stop(true)
      end
      self:_finish(root, "Could not create the LSP initialization timer")
      return
    end
    self.initialization_timers[root] = timer
    timer:start(self.opts.startup_timeout_ms, 0, function()
      vim.schedule(function()
        if not self.pending[root] then
          return
        end
        local client = vim.lsp.get_client_by_id(id)
        if client then
          client:stop(true)
        end
        self:_finish(root, "Timed out waiting for the Ziege LSP client to initialize")
      end)
    end)
  end

  function manager:_wait_for_daemon(root, started_at)
    probe(self.opts.host, self.opts.port, function(ready)
      if ready then
        self:_start_client(root)
      elseif uv.now() - started_at >= self.opts.startup_timeout_ms then
        self:_finish(root, string.format(
          "Timed out waiting for the Ziege daemon at %s:%d",
          self.opts.host,
          self.opts.port
        ))
      else
        vim.defer_fn(function()
          self:_wait_for_daemon(root, started_at)
        end, 50)
      end
    end)
  end

  function manager:ensure(root, callback)
    root = normalize_root(root)
    local id = self.clients[root]
    local client = id and vim.lsp.get_client_by_id(id)
    if client and not client:is_stopped() then
      callback(nil, client)
      return
    end
    self.clients[root] = nil
    if self.pending[root] then
      table.insert(self.pending[root], callback)
      return
    end
    self.pending[root] = { callback }

    probe(self.opts.host, self.opts.port, function(ready)
      if ready then
        self:_start_client(root)
        return
      end
      local job = vim.fn.jobstart(self.opts.command, { detach = true })
      if job <= 0 then
        self:_finish(root, "Could not spawn the Ziege daemon: " .. vim.inspect(self.opts.command))
        return
      end
      self:_wait_for_daemon(root, uv.now())
    end)
  end

  function manager:request(root, method, params, callback)
    self:ensure(root, function(ensure_error, client)
      if ensure_error then
        callback(ensure_error)
        return
      end
      local finished = false
      local request_id
      local function finish(err, result)
        if finished then
          return
        end
        finished = true
        callback(err and error_message(err) or nil, result)
      end
      local ok
      ok, request_id = client:request(method, params, finish)
      if not ok then
        finish("Could not send " .. method)
        return
      end
      vim.defer_fn(function()
        if finished then
          return
        end
        client:cancel_request(request_id)
        finish(string.format("Timed out waiting for %s", method))
      end, self.opts.request_timeout_ms)
    end)
  end

  return manager
end

return M
