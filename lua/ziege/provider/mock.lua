local M = {}

local function object_key(kind, name)
  return kind .. ":" .. name
end

local function ensure_system(self, name)
  local system = self.systems[name]
  if not system then
    system = { packages = {}, objects = {}, transports = {} }
    self.systems[name] = system
  end
  system.packages = system.packages or {}
  system.objects = system.objects or {}
  system.transports = system.transports or {}
  return system
end

function M.new(opts)
  opts = opts or {}
  local provider = {
    performed = {},
    systems = vim.deepcopy(opts.systems or {
      S4 = { packages = {}, objects = {}, transports = {} },
    }),
  }

  function provider:list_systems(callback)
    local systems = vim.tbl_keys(self.systems)
    table.sort(systems)
    callback(nil, systems)
  end

  function provider:list(route, callback)
    local system = ensure_system(self, route.system)
    local entries = {}
    if route.facet == "packages" then
      for name, package in pairs(system.packages) do
        if package.parent == route.package then
          table.insert(entries, {
            kind = "package",
            name = name,
            description = package.description,
          })
        end
      end
    else
      local allowed = {}
      for _, kind_name in ipairs(require("ziege.config").get().facets[route.facet].kinds) do
        allowed[kind_name] = true
      end
      for _, object in pairs(system.objects) do
        if object.package == route.package and allowed[object.kind] then
          table.insert(entries, vim.deepcopy(object))
        end
      end
    end
    table.sort(entries, function(left, right)
      return left.name < right.name
    end)
    callback(nil, entries)
  end

  function provider:list_transports(system_name, _, callback)
    callback(nil, vim.deepcopy(ensure_system(self, system_name).transports))
  end

  function provider:validate(operations, callback)
    local vacated = {}
    for _, operation in ipairs(operations) do
      if operation.type == "delete" or operation.type == "move" then
        vacated[operation.system .. "\0" .. object_key(operation.kind, operation.source.name)] =
          true
      end
    end
    for _, operation in ipairs(operations) do
      local system = ensure_system(self, operation.system)
      local destination = operation.destination or operation.source
      if operation.type == "create" then
        local destination_key = object_key(operation.kind, destination.name)
        local destination_vacated = vacated[operation.system .. "\0" .. destination_key]
        if
          operation.kind == "package"
          and system.packages[destination.name]
          and not destination_vacated
        then
          return callback(string.format("Package %s already exists", destination.name))
        elseif
          operation.kind ~= "package"
          and system.objects[destination_key]
          and not destination_vacated
        then
          return callback(string.format("%s %s already exists", operation.kind, destination.name))
        end
      elseif operation.type == "move" then
        local keeps_name = operation.source.name == destination.name
        if
          operation.kind == "package"
          and not keeps_name
          and system.packages[destination.name]
          and not vacated[operation.system .. "\0" .. object_key(operation.kind, destination.name)]
        then
          return callback(string.format("Package %s already exists", destination.name))
        elseif
          operation.kind ~= "package"
          and not keeps_name
          and system.objects[object_key(operation.kind, destination.name)]
          and not vacated[operation.system .. "\0" .. object_key(operation.kind, destination.name)]
        then
          return callback(string.format("%s %s already exists", operation.kind, destination.name))
        end
      elseif operation.type == "delete" and operation.kind == "package" then
        for _, package in pairs(system.packages) do
          if package.parent == operation.source.name then
            return callback("Mock provider refuses to delete a package with child packages")
          end
        end
        for _, object in pairs(system.objects) do
          if object.package == operation.source.name then
            return callback("Mock provider refuses to delete a package containing objects")
          end
        end
      end
    end
    callback()
  end

  function provider:perform(operation, callback)
    local system = ensure_system(self, operation.system)
    local source = operation.source
    local destination = operation.destination
    if operation.type == "create" then
      if operation.kind == "package" then
        system.packages[destination.name] = {
          parent = destination.package,
          description = operation.description,
        }
      else
        system.objects[object_key(operation.kind, destination.name)] = {
          kind = operation.kind,
          name = destination.name,
          package = destination.package,
          description = operation.description,
          source = {},
        }
      end
    elseif operation.type == "move" then
      if operation.kind == "package" then
        local package = system.packages[source.name]
        if not package then
          return callback(string.format("Package %s does not exist", source.name))
        end
        system.packages[source.name] = nil
        package.parent = destination.package
        system.packages[destination.name] = package
        if source.name ~= destination.name then
          for _, child in pairs(system.packages) do
            if child.parent == source.name then
              child.parent = destination.name
            end
          end
          for _, object in pairs(system.objects) do
            if object.package == source.name then
              object.package = destination.name
            end
          end
        end
      else
        local key = object_key(operation.kind, source.name)
        local object = system.objects[key]
        if not object then
          return callback(string.format("%s %s does not exist", operation.kind, source.name))
        end
        system.objects[key] = nil
        object.name = destination.name
        object.package = destination.package
        system.objects[object_key(operation.kind, destination.name)] = object
      end
    elseif operation.type == "delete" then
      if operation.kind == "package" then
        system.packages[source.name] = nil
      else
        system.objects[object_key(operation.kind, source.name)] = nil
      end
    else
      return callback(string.format("Unsupported mock operation '%s'", operation.type))
    end
    table.insert(self.performed, vim.deepcopy(operation))
    callback()
  end

  local function find_object(self, request)
    local kind_name = request.kind
    local object_name = request.name
    if not kind_name or not object_name then
      local resolved, err =
        require("ziege.model").resolve_projected_name(request.projected, request.route.facet)
      if not resolved or not resolved.kind then
        return nil, err or "Object files must include their canonical suffix"
      end
      kind_name = resolved.kind
      object_name = resolved.name
    end
    local system = ensure_system(self, request.route.system)
    local object = system.objects[object_key(kind_name, object_name)]
    if not object or object.package ~= request.route.package then
      return nil, string.format("%s %s does not exist", kind_name, object_name)
    end
    return object
  end

  function provider:read(request, callback)
    local object, err = find_object(self, request)
    if not object then
      return callback(err)
    end
    callback(nil, vim.deepcopy(object.source or {}))
  end

  function provider:write(request, callback)
    local object, err = find_object(self, request)
    if not object then
      return callback(err)
    end
    object.source = vim.deepcopy(request.lines)
    callback()
  end

  return provider
end

return M
