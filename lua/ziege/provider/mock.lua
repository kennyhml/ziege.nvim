local M = {}

local function ensure_system(self, name)
  local system = self.systems[name]
  if not system then
    system = { children = {} }
    self.systems[name] = system
  end
  system.children = system.children or {}
  return system
end

local function find_child(parent, id)
  for index, child in ipairs(parent.children or {}) do
    if child.id == id then
      return child, index
    end
  end
end

local function resolve(self, system_name, path)
  local node = ensure_system(self, system_name)
  for _, id in ipairs(path or {}) do
    node = find_child(node, id)
    if not node then
      return nil, string.format("Mock node '%s' does not exist", id)
    end
  end
  return node
end

local function resolve_parent(self, system_name, path)
  if not path or #path == 0 then
    return nil, nil, nil, "Mock node path is empty"
  end
  local parent, err = resolve(self, system_name, vim.list_slice(path, 1, #path - 1))
  if not parent then
    return nil, nil, nil, err
  end
  local child, index = find_child(parent, path[#path])
  if not child then
    return nil, nil, nil, string.format("Mock node '%s' does not exist", path[#path])
  end
  return parent, index, child
end

local function node_snapshot(node)
  local snapshot = {}
  for key, value in pairs(node) do
    if key ~= "children" and key ~= "source" then
      snapshot[key] = vim.deepcopy(value)
    end
  end
  return snapshot
end

local function path_key(system, path)
  return system.scope .. "\0" .. table.concat(path or {}, "\0")
end

local function destination_key(system, parent, name)
  return path_key(system, parent) .. "\0" .. name
end

local function starts_with_path(path, prefix)
  if #prefix > #path then
    return false
  end
  for index, value in ipairs(prefix) do
    if path[index] ~= value then
      return false
    end
  end
  return true
end

function M.new(opts)
  opts = opts or {}
  local provider = {
    performed = {},
    systems = vim.deepcopy(opts.systems or { S4 = { children = {} } }),
    normalize = opts.normalize,
    validate_name = opts.validate_name,
    extension = opts.extension,
    extensions = vim.deepcopy(opts.extensions or {}),
    filetypes = vim.deepcopy(opts.filetypes or {}),
    questions = opts.questions,
    next_id = 1,
  }

  function provider:list_systems(callback)
    local systems = vim.tbl_keys(self.systems)
    table.sort(systems)
    callback(nil, systems)
  end

  function provider:list(request, callback)
    local parent, err = resolve(self, request.system.name, request.path)
    if not parent then
      return callback(err)
    elseif parent.type and parent.type ~= "directory" then
      return callback(string.format("Mock node '%s' is not a directory", parent.name))
    end
    local entries = {}
    for _, child in ipairs(parent.children or {}) do
      table.insert(entries, node_snapshot(child))
    end
    callback(nil, {
      entries = entries,
      modifiable = parent.modifiable ~= false,
    })
  end

  function provider:extension_for(change, name, entry_type, request)
    if self.extension then
      return self.extension(change, name, entry_type, request)
    end
    local selected
    for _, extension in ipairs(self.extensions) do
      if
        vim.endswith(name, "." .. extension)
        and (not selected or #extension > #selected)
      then
        selected = extension
      end
    end
    return selected
  end

  function provider:prepare(request, callback)
    local questions = self.questions
    if type(questions) == "function" then
      questions = questions(request)
    end
    local unanswered = {}
    for _, question in ipairs(questions or {}) do
      if request.answers[question.id] == nil then
        table.insert(unanswered, question)
      end
    end
    if #unanswered > 0 then
      callback(nil, { status = "questions", questions = unanswered })
      return
    end

    local operations = {}
    local vacated = {}
    for _, change in ipairs(request.changes) do
      if
        change.source
        and (change.type == "delete" or change.type == "move" or change.type == "rename")
      then
        vacated[path_key(change.source.system, change.source.path)] = true
      end
    end

    local destinations = {}
    for _, change in ipairs(request.changes) do
      local prepared = {
        change_id = change.change_id,
        data = { answers = vim.deepcopy(request.answers) },
      }
      if change.destination then
        if
          change.source
          and change.destination.system.scope ~= change.source.system.scope
        then
          return callback(nil, {
            status = "rejected",
            errors = {
              { change_id = change.change_id, message = "Mock cross-system changes are disabled" },
            },
          })
        end
        local destination_system = change.destination.system
        local parent, parent_error =
          resolve(self, destination_system.name, change.destination.parent)
        if not parent then
          return callback(nil, {
            status = "rejected",
            errors = { { change_id = change.change_id, message = parent_error } },
          })
        elseif parent.type and parent.type ~= "directory" then
          return callback(nil, {
            status = "rejected",
            errors = {
              { change_id = change.change_id, message = "Destination is not a directory" },
            },
          })
        end

        local name = change.destination.input
        local entry_type = change.destination.type_hint
        if self.normalize then
          local normalized, normalize_error = self.normalize(change, name, entry_type, request)
          if not normalized then
            return callback(nil, {
              status = "rejected",
              errors = {
                { change_id = change.change_id, message = normalize_error or "Invalid name" },
              },
            })
          end
          name = normalized
        end
        if self.validate_name then
          local validation_error = self.validate_name(change, name, entry_type, request)
          if validation_error then
            return callback(nil, {
              status = "rejected",
              errors = { { change_id = change.change_id, message = validation_error } },
            })
          end
        end

        local id
        if change.type == "move" or change.type == "rename" then
          id = change.source.id
        else
          id = string.format("mock-%d", self.next_id)
          self.next_id = self.next_id + 1
        end
        prepared.destination = {
          id = id,
          name = name,
          type = entry_type,
          extension = self:extension_for(change, name, entry_type, request),
        }
        prepared.destination.filetype = self.filetypes[prepared.destination.extension]
        prepared.summary = string.format("%s %s", change.type:upper(), name)

        local key = destination_key(destination_system, change.destination.parent, name)
        if destinations[key] then
          return callback(nil, {
            status = "rejected",
            errors = { { change_id = change.change_id, message = "Duplicate destination name" } },
          })
        end
        destinations[key] = true
        for _, child in ipairs(parent.children or {}) do
          local child_path = vim.list_extend(
            vim.list_slice(change.destination.parent, 1, #change.destination.parent),
            { child.id }
          )
          if child.name == name and not vacated[path_key(destination_system, child_path)] then
            return callback(nil, {
              status = "rejected",
              errors = { { change_id = change.change_id, message = "Destination already exists" } },
            })
          end
        end

        if
          change.type == "rename"
          and change.source.name == name
          and change.source.type == entry_type
        then
          prepared.noop = true
        elseif
          change.type == "move"
          and change.source.type == "directory"
          and starts_with_path(change.destination.parent, change.source.path)
        then
          return callback(nil, {
            status = "rejected",
            errors = {
              { change_id = change.change_id, message = "Cannot move a node into itself" },
            },
          })
        end
      else
        prepared.summary = string.format("DELETE %s", change.source.name)
      end
      table.insert(operations, prepared)
    end
    callback(nil, { status = "ready", operations = operations })
  end

  function provider:perform(request, callback)
    local change = request.change
    local prepared = request.prepared
    local system_name = request.system.name
    if change.type == "create" then
      local parent, err = resolve(self, system_name, change.destination.parent)
      if not parent then
        return callback(err)
      end
      local node = vim.deepcopy(prepared.destination)
      node.source = {}
      if node.type == "directory" then
        node.children = {}
      end
      table.insert(parent.children, node)
    elseif change.type == "copy" then
      local _, _, source = resolve_parent(self, system_name, change.source.path)
      local destination_parent, err = resolve(self, system_name, change.destination.parent)
      if not source or not destination_parent then
        return callback(err or "Mock copy source does not exist")
      end
      local copy = vim.deepcopy(source)
      copy.id = prepared.destination.id
      copy.name = prepared.destination.name
      copy.type = prepared.destination.type
      copy.extension = prepared.destination.extension
      copy.filetype = prepared.destination.filetype
      table.insert(destination_parent.children, copy)
    elseif change.type == "move" or change.type == "rename" then
      local source_parent, source_index, source =
        resolve_parent(self, system_name, change.source.path)
      local destination_parent, err = resolve(self, system_name, change.destination.parent)
      if not source or not destination_parent then
        return callback(err or "Mock move source does not exist")
      end
      table.remove(source_parent.children, source_index)
      source.name = prepared.destination.name
      source.type = prepared.destination.type
      source.extension = prepared.destination.extension
      source.filetype = prepared.destination.filetype
      table.insert(destination_parent.children, source)
    elseif change.type == "delete" then
      local parent, index, _, err = resolve_parent(self, system_name, change.source.path)
      if not parent then
        return callback(err)
      end
      table.remove(parent.children, index)
    else
      return callback(string.format("Unsupported mock change '%s'", change.type))
    end
    table.insert(self.performed, vim.deepcopy(request))
    callback()
  end

  function provider:read(request, callback)
    local node, err = resolve(self, request.system.name, request.path)
    if not node then
      return callback(err)
    elseif node.type ~= "file" then
      return callback("Mock directories cannot be read as files")
    end
    callback(nil, {
      lines = vim.deepcopy(node.source or {}),
      filetype = node.filetype,
      revision = node.revision,
      writable = node.writable ~= false,
    })
  end

  function provider:write(request, callback)
    local node, err = resolve(self, request.system.name, request.path)
    if not node then
      return callback(err)
    elseif node.type ~= "file" then
      return callback("Mock directories cannot be written as files")
    elseif node.writable == false then
      return callback("Mock node is read-only")
    end
    node.source = vim.deepcopy(request.lines)
    node.revision = tostring((tonumber(node.revision) or 0) + 1)
    callback(nil, { revision = node.revision })
  end

  return provider
end

return M
