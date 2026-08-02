local source = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(source, ":p:h:h")
local project_root = vim.fn.fnamemodify(vim.env.ZIEGE_LIVE_ROOT or plugin_root, ":p")
local command = vim.env.ZIEGE_LSP_COMMAND
local port = tonumber(vim.env.ZIEGE_LSP_PORT) or 9257

if not command or command == "" then
  error("ZIEGE_LSP_COMMAND must point to abap-language-server")
end

vim.opt.runtimepath:prepend(plugin_root)

require("ziege.config").setup({
  presentation = {
    namespace_delimiter = "slash",
  },
  daemon = {
    command = { command },
    port = port,
    startup_timeout_ms = 10000,
    request_timeout_ms = 60000,
  },
})

local provider = require("ziege.config").get().provider
local finished = false
local failure
local visited = 0
local queue = { {} }

local function fail(message)
  failure = message
  finished = true
end

local function read_first_source(system, path, name)
  provider:read({
    system = system,
    path = path,
  }, function(err, file)
    if err then
      fail(err)
      return
    end
    print(string.format(
      "LIVE source=%s lines=%d revision=%s",
      name,
      #file.lines,
      file.revision or "none"
    ))
    finished = true
  end)
end

local function visit_next(system)
  local path = table.remove(queue, 1)
  if not path then
    fail("No supported source file was found in the configured mounts")
    return
  end
  visited = visited + 1
  if visited > 250 then
    fail("Stopped after visiting 250 live directories")
    return
  end
  provider:list({ system = system, path = path }, function(err, page)
    if err then
      fail(err)
      return
    end
    for _, entry in ipairs(page.entries) do
      local child_path = vim.list_extend(vim.list_slice(path, 1, #path), { entry.id })
      if entry.type == "file" then
        read_first_source(system, child_path, entry.name)
        return
      end
      table.insert(queue, child_path)
    end
    visit_next(system)
  end)
end

provider:load_project(project_root, function(err, project)
  if err then
    fail(err)
    return
  end
  local configured = project.systems[1]
  if not configured then
    fail("The live project has no systems")
    return
  end
  print(string.format("LIVE project=%s system=%s folder=%s", project_root, configured.name, configured.folder))
  visit_next({
    name = configured.name,
    project_root = project_root,
  })
end)

if not vim.wait(120000, function()
  return finished
end, 20) then
  error("Timed out waiting for the live Ziege smoke test")
end
if failure then
  error(failure)
end
