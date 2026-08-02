local config = require("ziege.config")
local route = require("ziege.adapters.oil.route")

local M = {}
local installed = false

local function notify(message, level)
  vim.notify("[ziege] " .. message, level or vim.log.levels.ERROR)
end

local function directory_context(bufnr)
  local parsed, err = route.parse(vim.api.nvim_buf_get_name(bufnr or 0))
  if not parsed or parsed.root then
    return nil, err or "This action requires a Ziege system directory"
  end
  local system = {
    name = parsed.system,
    scope = parsed.system_token,
    config = parsed.system_config,
    project_root = parsed.project_root,
  }
  return {
    provider = config.provider_for(system),
    system = system,
    path = vim.list_slice(parsed.path, 1, #parsed.path),
  }
end

local function select_form(forms, callback)
  if #forms == 1 then
    callback(forms[1])
    return
  end
  config.get().ui.select(forms, {
    prompt = "Object type",
    format_item = function(form)
      return form.description and string.format("%s - %s", form.label, form.description)
        or form.label
    end,
  }, callback)
end

local function select_transport(context, state, callback)
  local choices = vim.deepcopy(state.transports or {})
  table.insert(choices, { label = "Refresh transports", refresh = true })
  config.get().ui.select(choices, {
    prompt = "Transport",
    format_item = function(choice)
      return choice.label or tostring(choice.value or choice.id)
    end,
  }, function(choice)
    if not choice then
      callback(nil)
    elseif not choice.refresh then
      callback(choice)
    elseif type(context.provider.refresh_transports) ~= "function" then
      notify("The provider cannot refresh transports")
      callback(nil)
    else
      context.provider:refresh_transports({
        system = context.system,
        path = context.path,
        context_token = state.contextToken,
        revision = state.revision,
      }, function(err, refreshed)
        if err then
          notify(err)
          callback(nil)
        elseif type(refreshed) ~= "table" or type(refreshed.transports) ~= "table" then
          notify("The provider returned an invalid transport list")
          callback(nil)
        else
          state.contextToken = refreshed.contextToken or state.contextToken
          state.revision = refreshed.revision or state.revision
          state.transports = refreshed.transports
          select_transport(context, state, callback)
        end
      end)
    end
  end)
end

function M.create(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local context, context_error = directory_context(bufnr)
  if not context then
    notify(context_error)
    return
  elseif type(context.provider.creation_options) ~= "function" then
    notify("Object creation is not supported by this provider")
    return
  end

  context.provider:creation_options({
    system = context.system,
    path = context.path,
  }, function(err, result)
    if err then
      notify(err)
      return
    elseif type(result) ~= "table" or result.supported == false then
      notify((result and result.message) or "Object creation is not supported by the server")
      return
    elseif type(result.forms) ~= "table" or #result.forms == 0 then
      notify("The server returned no object creation forms")
      return
    end

    select_form(result.forms, function(form)
      if not form then
        return
      end
      require("ziege.wizard").ask(form.questions or {}, function(answers)
        if not answers then
          return
        end
        select_transport(context, result, function(transport)
          if not transport then
            return
          elseif type(context.provider.create_object) ~= "function" then
            notify("Object creation is not implemented by this provider")
            return
          end
          context.provider:create_object({
            system = context.system,
            path = context.path,
            context_token = result.contextToken,
            revision = result.revision,
            object_type = form.id,
            answers = answers,
            transport = transport.value or transport.id,
          }, function(create_error)
            if create_error then
              notify(create_error)
              return
            end
            if vim.api.nvim_buf_is_valid(bufnr) then
              vim.api.nvim_buf_call(bufnr, function()
                vim.cmd.edit({ bang = true })
              end)
            end
          end)
        end)
      end)
    end)
  end)
end

function M.delete(_)
  notify("Object deletion is not supported by the server")
end

function M.rename(_)
  notify("Object renaming is not supported by the server")
end

function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd.edit({ bang = true })
    end)
  end
end

local function install_buffer(bufnr)
  if not route.is_url(vim.api.nvim_buf_get_name(bufnr)) then
    return
  end
  local keymaps = config.get().keymaps
  local mappings = {
    { keymaps.create, M.create, "Create ABAP object" },
    { keymaps.delete, M.delete, "Delete ABAP object" },
    { keymaps.rename, M.rename, "Rename ABAP object" },
    { keymaps.refresh, M.refresh, "Refresh ABAP directory" },
  }
  for _, mapping in ipairs(mappings) do
    if mapping[1] and mapping[1] ~= "" then
      vim.keymap.set("n", mapping[1], function()
        mapping[2](bufnr)
      end, { buffer = bufnr, desc = mapping[3], nowait = true })
    end
  end
end

function M.install()
  if installed then
    return
  end
  installed = true
  local group = vim.api.nvim_create_augroup("ZiegeOilActions", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OilEnter",
    callback = function(args)
      install_buffer(args.data.buf)
    end,
  })
end

return M
