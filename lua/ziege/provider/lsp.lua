local M = {}

local function project_uri(root)
  return vim.uri_from_fname(vim.fn.fnamemodify(root, ":p"))
end

local function content_lines(content)
  local lines = vim.split(content:gsub("\r\n", "\n"), "\n", { plain = true })
  if content:match("\r?\n$") then
    table.remove(lines)
  end
  if #lines == 0 then
    return { "" }
  end
  return lines
end

function M.new(opts)
  opts = opts or {}
  local manager = opts.manager or require("ziege.daemon").new(opts.daemon)
  local provider = { manager = manager }

  function provider:load_project(root, callback)
    self.manager:request(root, "ziege/project/systems", {
      projectUri = project_uri(root),
    }, function(err, result)
      if err then
        callback(err)
      elseif type(result) ~= "table" or type(result.systems) ~= "table" then
        callback("Language server returned an invalid project system list")
      else
        callback(nil, { systems = result.systems })
      end
    end)
  end

  function provider:list(request, callback)
    local root = request.system.project_root
    if not root then
      callback("Ziege filesystem requests require a .ziege project")
      return
    end
    self.manager:request(root, "ziege/fileSystem/readDirectory", {
      projectUri = project_uri(root),
      system = request.system.name,
      parentId = request.path[#request.path],
    }, function(err, result)
      if err then
        callback(err)
      elseif type(result) ~= "table" or type(result.entries) ~= "table" then
        callback("Language server returned an invalid directory listing")
      else
        local entries = {}
        for _, entry in ipairs(result.entries) do
          table.insert(entries, {
            id = entry.id,
            name = entry.name,
            type = entry.type,
            extension = entry.extension,
            virtual = entry.virtualFolder == true,
          })
        end
        callback(nil, { entries = entries, modifiable = false })
      end
    end)
  end

  function provider:read(request, callback)
    local root = request.system.project_root
    local resource_id = request.path[#request.path]
    if not root or not resource_id then
      callback("Ziege file reads require a project and resource ID")
      return
    end
    self.manager:request(root, "ziege/fileSystem/readFile", {
      projectUri = project_uri(root),
      system = request.system.name,
      resourceId = resource_id,
    }, function(err, result)
      if err then
        callback(err)
      elseif type(result) ~= "table" or type(result.content) ~= "string" then
        callback("Language server returned invalid file content")
      else
        callback(nil, {
          lines = content_lines(result.content),
          filetype = result.languageId or "abap",
          revision = result.revision,
          writable = false,
        })
      end
    end)
  end

  function provider:creation_options(request, callback)
    local root = request.system.project_root
    if not root then
      callback("Object creation requires a .ziege project")
      return
    end
    self.manager:request(root, "ziege/objectCreation/options", {
      projectUri = project_uri(root),
      system = request.system.name,
      parentId = request.path[#request.path],
    }, callback)
  end

  function provider:refresh_transports(request, callback)
    local root = request.system.project_root
    self.manager:request(root, "ziege/objectCreation/refreshTransports", {
      projectUri = project_uri(root),
      system = request.system.name,
      parentId = request.path[#request.path],
      contextToken = request.context_token,
      revision = request.revision,
    }, callback)
  end

  function provider:create_object(request, callback)
    local root = request.system.project_root
    self.manager:request(root, "ziege/objectCreation/create", {
      projectUri = project_uri(root),
      system = request.system.name,
      parentId = request.path[#request.path],
      contextToken = request.context_token,
      revision = request.revision,
      objectType = request.object_type,
      answers = request.answers,
      transport = request.transport,
    }, callback)
  end

  return provider
end

return M
