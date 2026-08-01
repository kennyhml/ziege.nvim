local cache = require("oil.cache")
local config = require("ziege.config")
local constants = require("oil.constants")
local model = require("ziege.model")
local route = require("ziege.route")

local M = {}

local FIELD_META = constants.FIELD_META

local function is_abap_url(url)
  return type(url) == "string" and vim.startswith(url, "abap://")
end

local function action_urls(action)
  if action.type == "move" or action.type == "copy" then
    return action.src_url, action.dest_url
  end
  return action.url
end

local function choose_kind(resolved, callback)
  if resolved.kind then
    return callback(resolved.kind)
  elseif #resolved.choices == 1 then
    return callback(resolved.choices[1].name)
  end
  config.get().ui.select(resolved.choices, {
    prompt = "ABAP object type",
    format_item = function(choice)
      return string.format("%s (%s)", choice.definition.label, choice.definition.suffix)
    end,
  }, function(choice)
    callback(choice and choice.name or nil)
  end)
end

local function endpoint(url, forced_kind, callback)
  local parent, projected, err = route.parent_and_leaf(url)
  if not parent or parent.kind ~= "facet" then
    return callback(nil, err or "ABAP mutations must occur inside a virtual facet")
  end
  local resolved, resolve_error = model.resolve_projected_name(projected, parent.facet)
  if not resolved then
    return callback(nil, resolve_error)
  end
  if forced_kind then
    local allowed = false
    for _, choice in ipairs(resolved.choices) do
      if choice.name == forced_kind then
        allowed = true
        break
      end
    end
    if not allowed or (resolved.kind and resolved.kind ~= forced_kind) then
      return callback(
        nil,
        string.format("The %s facet does not accept %s objects", parent.facet, forced_kind)
      )
    end
    resolved.kind = forced_kind
  end

  choose_kind(resolved, function(kind_name)
    if not kind_name then
      return callback(nil)
    end
    local object_name = resolved.name
    if resolved.bare then
      for _, choice in ipairs(resolved.choices) do
        if choice.name == kind_name then
          object_name = choice.object_name
          break
        end
      end
    end
    local normalized = model.project(object_name, kind_name)
    callback({
      kind = kind_name,
      name = object_name,
      package = parent.package,
      system = parent.system,
      system_token = parent.system_token,
      system_config = parent.system_config,
      project_root = parent.project_root,
      projected = normalized,
      input = projected,
      url = route.replace_leaf(url, normalized),
    })
  end)
end

local function source_info(url)
  local entry = cache.get_entry_by_url(url)
  local meta = entry and entry[FIELD_META]
  local ziege_meta = meta and meta.ziege
  if not ziege_meta then
    return nil
  end
  return {
    kind = ziege_meta.kind,
    provider_name = ziege_meta.provider_name or ziege_meta.name,
  }
end

local function prepare_action(action, callback)
  if action.type == "copy" then
    return callback(nil, "Copying ABAP objects is not supported yet")
  elseif action.type == "change" then
    return callback(nil, "Editing Oil columns is not supported for ABAP objects")
  end
  local first, second = action_urls(action)
  if second and is_abap_url(first) ~= is_abap_url(second) then
    return callback(nil, "ABAP objects cannot be moved across Oil adapters")
  end
  if
    (first and first:find("__oil_tmp_", 1, true)) or (second and second:find("__oil_tmp_", 1, true))
  then
    return callback(nil, "Cyclic ABAP renames are not supported")
  end

  if action.type == "create" then
    endpoint(action.url, nil, function(destination, err)
      if not destination then
        return callback(nil, err)
      end
      config.get().ui.input({
        prompt = string.format("%s description: ", model.kind(destination.kind).label),
      }, function(description)
        if description == nil then
          return callback(nil)
        end
        action.url = destination.url
        action.entry_type = model.kind(destination.kind).entry_type
        callback({
          type = "create",
          kind = destination.kind,
          system = destination.system,
          system_token = destination.system_token,
          system_config = destination.system_config,
          project_root = destination.project_root,
          destination = destination,
          description = description,
        })
      end)
    end)
  elseif action.type == "delete" then
    local source_metadata = source_info(action.url)
    if not source_metadata then
      return callback(nil, "Could not determine the deleted ABAP object's type")
    end
    local kind_name = source_metadata.kind
    endpoint(action.url, kind_name, function(source, err)
      if not source then
        return callback(nil, err)
      end
      source.display_name = source.name
      source.name = source_metadata.provider_name
      callback({
        type = "delete",
        kind = kind_name,
        system = source.system,
        system_token = source.system_token,
        system_config = source.system_config,
        project_root = source.project_root,
        source = source,
      })
    end)
  elseif action.type == "move" then
    local source_metadata = source_info(action.src_url)
    if not source_metadata then
      return callback(nil, "Could not determine the moved ABAP object's type")
    end
    local kind_name = source_metadata.kind
    endpoint(action.src_url, kind_name, function(source, source_error)
      if not source then
        return callback(nil, source_error)
      end
      endpoint(action.dest_url, kind_name, function(destination, destination_error)
        if not destination then
          return callback(nil, destination_error)
        elseif source.system_token ~= destination.system_token then
          return callback(nil, "ABAP objects cannot be moved between SAP systems")
        end
        action.dest_url = destination.url
        action.entry_type = model.kind(kind_name).entry_type
        if action.src_url == action.dest_url then
          return callback({ type = "noop" })
        end
        source.display_name = source.name
        source.name = source_metadata.provider_name
        callback({
          type = "move",
          kind = kind_name,
          system = source.system,
          system_token = source.system_token,
          system_config = source.system_config,
          project_root = source.project_root,
          source = source,
          destination = destination,
        })
      end)
    end)
  else
    callback(nil, string.format("Unsupported Oil action '%s'", action.type))
  end
end

local function reorder_actions(actions)
  local original = {}
  for _, action in ipairs(actions) do
    original[action] = true
  end
  local ok, ordered =
    pcall(require("oil.mutator").enforce_action_order, vim.list_slice(actions, 1, #actions))
  if not ok then
    return ordered
  end
  for _, action in ipairs(ordered) do
    local first, second = action_urls(action)
    if (is_abap_url(first) or is_abap_url(second)) and not original[action] then
      return "Canonical names create a cyclic rename, which is not supported"
    end
  end
  for index = #actions, 1, -1 do
    table.remove(actions, index)
  end
  vim.list_extend(actions, ordered)
end

local function assign_transports(operations, callback)
  local provider = config.get().provider
  if not provider.list_transports then
    return callback()
  end
  local by_system = {}
  local system_tokens = {}
  for _, operation in ipairs(operations) do
    local token = operation.system_token or operation.system
    if not by_system[token] then
      by_system[token] = {}
      table.insert(system_tokens, token)
    end
    table.insert(by_system[token], operation)
  end

  local index = 1
  local function next_system()
    local token = system_tokens[index]
    index = index + 1
    if not token then
      return callback()
    end
    local operations_for_system = by_system[token]
    local system = operations_for_system[1].system
    provider:list_transports(system, operations_for_system, function(err, transports)
      if err then
        return callback(err)
      elseif not transports or #transports == 0 then
        return next_system()
      end
      config.get().ui.select(transports, {
        prompt = string.format("Transport for %s", system),
        format_item = function(transport)
          if type(transport) == "table" then
            return transport.label or transport.id
          end
          return transport
        end,
      }, function(transport)
        if transport == nil then
          return callback("Canceled")
        end
        local value = type(transport) == "table" and transport.id or transport
        for _, operation in ipairs(operations_for_system) do
          operation.transport = value
        end
        next_system()
      end)
    end)
  end
  next_system()
end

function M.prepare(actions, callback)
  local abap_actions = {}
  for _, action in ipairs(actions) do
    local first, second = action_urls(action)
    if is_abap_url(first) or is_abap_url(second) then
      table.insert(abap_actions, action)
    end
  end
  if #abap_actions == 0 then
    return callback(true)
  end

  local prepared_actions = {}
  local index = 1
  local function fail(message)
    if message and message ~= "Canceled" then
      vim.notify("[ziege] " .. message, vim.log.levels.ERROR)
    end
    callback(false)
  end
  local function next_action()
    local action = abap_actions[index]
    index = index + 1
    if not action then
      local operations = {}
      local operation_by_action = {}
      for prepared_index = #prepared_actions, 1, -1 do
        local prepared = prepared_actions[prepared_index]
        if prepared.operation.type == "noop" then
          for action_index = #actions, 1, -1 do
            if actions[action_index] == prepared.action then
              table.remove(actions, action_index)
              break
            end
          end
        else
          operation_by_action[prepared.action] = prepared.operation
          table.insert(operations, 1, prepared.operation)
        end
      end

      return assign_transports(operations, function(transport_error)
        if transport_error then
          return fail(transport_error)
        end
        local seen_destinations = {}
        for prepared_action, operation in pairs(operation_by_action) do
          prepared_action.ziege = operation
          local endpoint_value = operation.destination
          local destination = endpoint_value
            and table.concat({
              endpoint_value.system_token or endpoint_value.system,
              operation.kind,
              endpoint_value.name,
            }, "\0")
          if destination then
            if seen_destinations[destination] then
              return fail(
                string.format(
                  "Multiple actions target %s %s in %s",
                  operation.kind,
                  endpoint_value.name,
                  endpoint_value.system
                )
              )
            end
            seen_destinations[destination] = true
          end
        end

        local reorder_error = reorder_actions(actions)
        if reorder_error then
          return fail(reorder_error)
        end

        local ordered_operations = {}
        for _, ordered_action in ipairs(actions) do
          if ordered_action.ziege then
            table.insert(ordered_operations, ordered_action.ziege)
          end
        end
        local provider = config.get().provider
        if provider.validate then
          provider:validate(ordered_operations, function(validation_error)
            if validation_error then
              return fail(validation_error)
            end
            callback(true)
          end)
        else
          callback(true)
        end
      end)
    end

    prepare_action(action, function(operation, err)
      if not operation then
        return fail(err)
      end
      table.insert(prepared_actions, { action = action, operation = operation })
      next_action()
    end)
  end
  next_action()
end

return M
