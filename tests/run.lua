local failures = 0
local tests = {}

local function test(name, callback)
  table.insert(tests, { name = name, callback = callback })
end

local function assert_equal(expected, actual, context)
  if not vim.deep_equal(expected, actual) then
    error(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        context or "Values differ",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

local function assert_true(value, context)
  if not value then
    error(context or "Expected a truthy value", 2)
  end
end

local function wait_for(predicate, context)
  assert_true(vim.wait(3000, predicate, 10), context or "Timed out")
end

local function line_with(lines, value)
  for index, line in ipairs(lines) do
    if line:find(value, 1, true) then
      return index, line
    end
  end
end

local function open_oil(url)
  require("oil").open(url)
  local bufnr = vim.api.nvim_get_current_buf()
  wait_for(function()
    return vim.api.nvim_buf_is_valid(bufnr)
      and vim.b[bufnr].oil_ready
      and not vim.b[bufnr].oil_rendering
  end, "Oil did not finish rendering " .. url)
  return bufnr
end

test("wizard UI uses a floating input and delegates selections", function()
  local ui = require("ziege.ui")
  local source_buf = vim.api.nvim_get_current_buf()
  local source_modifiable = vim.bo[source_buf].modifiable
  vim.bo[source_buf].modifiable = false
  vim.v.errmsg = ""
  local done = false
  local value
  ui.input({ prompt = "Purpose" }, function(result)
    value = result
    done = true
  end)
  local bufnr = vim.api.nvim_get_current_buf()
  assert_equal("ziege_input", vim.bo[bufnr].filetype)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "test value" })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
  wait_for(function()
    return done
  end, "Floating input did not complete")
  assert_equal("test value", value)
  assert_true(vim.fn.mode():sub(1, 1) ~= "i")
  assert_true(not vim.v.errmsg:find("E21", 1, true), vim.v.errmsg)
  vim.bo[source_buf].modifiable = source_modifiable

  local original_select = vim.ui.select
  local delegated = false
  vim.ui.select = function(items, _, callback)
    delegated = true
    callback(items[2])
  end
  ui.select({ "one", "two" }, {}, function(result)
    value = result
  end)
  vim.ui.select = original_select
  assert_true(delegated)
  assert_equal("two", value)
end)

test("Oil routes are readable while preserving opaque provider identities", function()
  local codec = require("ziege.codec")
  local route = require("ziege.adapters.oil.route")
  local value = "/Acme/Mixed Name.widget.json"
  assert_equal(value, codec.decode_segment(codec.encode_segment(value)))
  route.clear()

  local first_system = {
    token = "opaque-system-one",
    name = "S4",
    folder = "S4",
    project_root = "/tmp/one/project",
  }
  local second_system = vim.tbl_extend("force", {}, first_system, {
    token = "opaque-system-two",
    project_root = "/tmp/two/project",
  })
  local first_root = route.system_url(first_system)
  local second_root = route.system_url(second_system)
  assert_equal("abap://S4@project/", first_root)
  assert_equal("abap://S4@project~2/", second_root)

  route.update_directory(first_root, {
    { id = "folder/id", name = "Flight", type = "directory" },
    { id = "class:42", name = "(dmo)tatfta.clas.abap", type = "file" },
    { id = "slash", name = "/dmo/tatfta.clas.abap", type = "file" },
  })
  assert_equal("abap://S4@project/Flight/", assert(route.node_url(first_root, "folder/id")))
  assert_equal(
    "abap://S4@project/(dmo)tatfta.clas.abap",
    assert(route.node_url(first_root, "class:42"))
  )
  assert_equal(
    "abap://S4@project/%2Fdmo%2Ftatfta.clas.abap",
    assert(route.node_url(first_root, "slash"))
  )
  local duplicate_routes, duplicate_error = route.update_directory(first_root, {
    { id = "duplicate-one", name = "Duplicate", type = "file" },
    { id = "duplicate-two", name = "Duplicate", type = "file" },
  })
  assert_equal(nil, duplicate_routes)
  assert_equal("Provider returned duplicate node name 'Duplicate'", duplicate_error)
end)

test("wizard preserves false confirmation answers", function()
  require("ziege.config").setup({
    ui = {
      input = function() end,
      select = function(items, _, callback)
        callback(items[2])
      end,
    },
  })
  local answers
  require("ziege.wizard").ask({
    { id = "confirmed", kind = "confirm", prompt = "Continue?" },
  }, function(result)
    answers = result
  end)
  assert_equal({ confirmed = false }, answers)
end)

test("LSP provider translates filesystem and creation requests", function()
  local requests = {}
  local manager = {}
  function manager:request(root, method, params, callback)
    table.insert(requests, { root = root, method = method, params = vim.deepcopy(params) })
    if method == "ziege/project/systems" then
      callback(nil, {
        systems = {
          { name = "S4", folder = "SAP-DEV", provider = "adt", destination = "DEV" },
        },
      })
    elseif method == "ziege/fileSystem/readDirectory" then
      callback(nil, {
        modifiable = false,
        entries = {
          { id = "node:1", name = "Objects", type = "directory", virtualFolder = true },
          { id = "source:2", name = "zexample.prog.abap", type = "file" },
        },
      })
    elseif method == "ziege/fileSystem/readFile" then
      callback(nil, {
        content = "REPORT zexample.\r\nWRITE 'ok'.\r\n",
        languageId = "abap",
        revision = '"etag-1"',
        writable = false,
      })
    elseif method == "ziege/objectCreation/options" then
      callback(nil, { supported = false, forms = {}, transports = {} })
    elseif method == "ziege/objectCreation/refreshTransports" then
      callback(nil, { supported = false, transports = {} })
    elseif method == "ziege/objectCreation/create" then
      callback(nil, {})
    else
      callback("unexpected method")
    end
  end

  local provider = require("ziege.provider.lsp").new({ manager = manager })
  local project
  provider:load_project("/tmp/example", function(err, result)
    assert_equal(nil, err)
    project = result
  end)
  assert_equal("S4", project.systems[1].name)

  local system = { name = "S4", project_root = "/tmp/example" }
  local page
  provider:list({ system = system, path = {} }, function(err, result)
    assert_equal(nil, err)
    page = result
  end)
  assert_equal(false, page.modifiable)
  assert_equal(true, page.entries[1].virtual)

  local file
  provider:read({ system = system, path = { "source:2" } }, function(err, result)
    assert_equal(nil, err)
    file = result
  end)
  assert_equal({ "REPORT zexample.", "WRITE 'ok'." }, file.lines)
  assert_equal(false, file.writable)

  provider:creation_options({ system = system, path = { "node:1" } }, function() end)
  provider:refresh_transports({
    system = system,
    path = { "node:1" },
    context_token = "token",
    revision = "1",
  }, function() end)
  provider:create_object({
    system = system,
    path = { "node:1" },
    context_token = "token",
    revision = "2",
    object_type = "CLAS/OC",
    answers = { name = "ZCL_EXAMPLE" },
    transport = "LOCAL",
  }, function() end)

  assert_equal({
    "ziege/project/systems",
    "ziege/fileSystem/readDirectory",
    "ziege/fileSystem/readFile",
    "ziege/objectCreation/options",
    "ziege/objectCreation/refreshTransports",
    "ziege/objectCreation/create",
  }, vim.tbl_map(function(request)
    return request.method
  end, requests))
  assert_equal("node:1", requests[4].params.parentId)
  assert_equal("CLAS/OC", requests[6].params.objectType)
end)

test("physical portals open a read-only remote tree with explicit actions", function()
  local workspace_root = vim.fn.tempname()
  vim.fn.mkdir(workspace_root, "p")
  vim.fn.writefile({ "local file" }, workspace_root .. "/local.txt")
  vim.fn.writefile({ "version: 1", "systems:", "  S4:" }, workspace_root .. "/.ziege")

  local calls = {}
  local created_request
  local read_request
  local provider = {}
  function provider:list(request, callback)
    table.insert(calls, "list")
    if #request.path == 0 then
      callback(nil, {
        entries = {
          { id = "objects", name = "Objects", type = "directory", virtual = true },
          {
            id = "source",
            name = "/acme/zcl_example.clas.abap",
            type = "file",
            filetype = "abap",
          },
        },
      })
    else
      callback(nil, { entries = {} })
    end
  end
  function provider:read(request, callback)
    table.insert(calls, "read")
    read_request = vim.deepcopy(request)
    callback(nil, { lines = { "CLASS zcl_example DEFINITION.", "ENDCLASS." }, filetype = "abap" })
  end
  function provider:creation_options(_, callback)
    table.insert(calls, "options")
    callback(nil, {
      supported = true,
      contextToken = "creation-token",
      revision = "1",
      forms = {
        {
          id = "PROG/P",
          label = "Program",
          questions = {},
        },
        {
          id = "CLAS/OC",
          label = "Class",
          questions = {
            { id = "name", kind = "input", prompt = "Name" },
            {
              id = "visibility",
              kind = "select",
              prompt = "Visibility",
              choices = {
                { label = "Public", value = "public" },
                { label = "Private", value = "private" },
              },
            },
          },
        },
      },
      transports = {
        { id = "DEVK900001", label = "DEVK900001: Initial" },
      },
    })
  end
  function provider:refresh_transports(_, callback)
    table.insert(calls, "refresh-transports")
    callback(nil, {
      contextToken = "creation-token",
      revision = "2",
      transports = {
        { id = "LOCAL", label = "Local Object", value = "LOCAL" },
      },
    })
  end
  function provider:create_object(request, callback)
    table.insert(calls, "create")
    created_request = vim.deepcopy(request)
    callback(nil, {})
  end

  local project_provider = {}
  function project_provider:load_project(_, callback)
    callback(nil, {
      systems = {
        { name = "S4", folder = "S4", provider = "mock" },
      },
    })
  end

  local transport_selections = 0
  local ui = {}
  function ui.input(opts, callback)
    assert_equal("Name", opts.prompt)
    callback("ZCL_CREATED")
  end
  function ui.select(items, opts, callback)
    if opts.prompt == "Object type" then
      callback(items[2])
    elseif opts.prompt == "Visibility" then
      callback(items[1])
    elseif opts.prompt == "Transport" then
      transport_selections = transport_selections + 1
      if transport_selections == 1 then
        callback(items[#items])
      else
        callback(items[1])
      end
    else
      error("Unexpected selection prompt " .. tostring(opts.prompt))
    end
  end

  require("ziege.project").clear_cache()
  require("ziege.adapters.oil.route").clear()
  local conf = require("ziege").setup({
    default_system = "S4",
    provider = provider,
    project_provider = project_provider,
    providers = { mock = provider },
    ui = ui,
    presentation = { namespace_delimiter = "slash" },
  })
  assert_equal("slash", conf.presentation.namespace_delimiter)
  assert_equal("slash", conf.daemon.initialization_options.presentation.namespaceDelimiter)
  require("oil").setup({
    adapters = {
      ["abap://"] = "ziege",
      ["oil-test://"] = "test",
    },
    columns = {},
  })

  local workspace_url = "oil://"
    .. require("oil.util").addslash(require("oil.fs").os_to_posix_path(workspace_root))
  local workspace_buf = open_oil(workspace_url)
  wait_for(function()
    return (vim.uv or vim.loop).fs_stat(workspace_root .. "/S4") ~= nil
  end, "System portal was not created")
  wait_for(function()
    return line_with(vim.api.nvim_buf_get_lines(workspace_buf, 0, -1, true), "S4/") ~= nil
  end, "System portal was not rendered")
  local workspace_lines = vim.api.nvim_buf_get_lines(workspace_buf, 0, -1, true)
  assert_true(line_with(workspace_lines, "local.txt") ~= nil)

  require("oil").open(workspace_url .. "S4/")
  wait_for(function()
    return vim.startswith(vim.api.nvim_buf_get_name(0), "abap://")
      and vim.b.oil_ready
      and not vim.b.oil_rendering
  end, "Physical portal did not redirect to the remote tree")
  local remote_buf = vim.api.nvim_get_current_buf()
  assert_true(vim.api.nvim_buf_get_name(remote_buf):find("^abap://S4@") ~= nil)
  assert_true(vim.api.nvim_buf_get_name(remote_buf):find("ziege%-project") == nil)
  assert_equal(false, vim.bo[remote_buf].modifiable)
  local remote_lines = vim.api.nvim_buf_get_lines(remote_buf, 0, -1, true)
  assert_true(line_with(remote_lines, "Objects/") ~= nil)
  assert_true(line_with(remote_lines, "/acme/zcl_example.clas.abap") ~= nil)
  assert_true(vim.fn.maparg("<localleader>c", "n") ~= "")
  assert_true(vim.fn.maparg("<localleader>R", "n") ~= "")

  require("ziege.adapters.oil.actions").create(remote_buf)
  assert_equal({ "options", "refresh-transports", "create" }, vim.tbl_filter(function(call)
    return call ~= "list"
  end, calls))
  assert_equal("CLAS/OC", created_request.object_type)
  assert_equal({ name = "ZCL_CREATED", visibility = "public" }, created_request.answers)
  assert_equal("LOCAL", created_request.transport)
  assert_equal("2", created_request.revision)

  local route = require("ziege.adapters.oil.route")
  local source_url = assert(route.node_url(vim.api.nvim_buf_get_name(remote_buf), "source"))
  assert_true(vim.endswith(source_url, "/%2Facme%2Fzcl_example.clas.abap"))
  assert_true(source_url:find("node%3A", 1, true) == nil)
  require("oil").open(source_url)
  local source_buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    return not require("oil.loading").is_loading(source_buf)
  end, "Remote source did not finish loading")
  assert_equal({ "CLASS zcl_example DEFINITION.", "ENDCLASS." }, vim.api.nvim_buf_get_lines(source_buf, 0, -1, true))
  assert_equal(false, vim.bo[source_buf].modifiable)
  assert_equal({ "source" }, read_request.path)

  vim.fn.delete(workspace_root .. "/S4", "d")
  vim.api.nvim_exec_autocmds("User", { pattern = "OilActionsPost", modeline = false })
  wait_for(function()
    return (vim.uv or vim.loop).fs_stat(workspace_root .. "/S4") ~= nil
  end, "Deleted system portal was not recreated")

  local nested_root = workspace_root .. "/nested"
  vim.fn.mkdir(nested_root, "p")
  vim.fn.writefile({ "systems:", "  S4:" }, nested_root .. "/.ziege")
  local nested_url = "oil://"
    .. require("oil.util").addslash(require("oil.fs").os_to_posix_path(nested_root))
  open_oil(nested_url)
  wait_for(function()
    return (vim.uv or vim.loop).fs_stat(nested_root .. "/S4") ~= nil
  end, "Nested project did not create its own portal")

  vim.fn.writefile({ "must remain local" }, workspace_root .. "/S4/local.txt")
  local original_notify = vim.notify
  vim.notify = function() end
  local local_portal_buf = open_oil(workspace_url .. "S4/")
  vim.notify = original_notify
  assert_equal(workspace_url .. "S4/", vim.api.nvim_buf_get_name(local_portal_buf))
  assert_equal({ "must remain local" }, vim.fn.readfile(workspace_root .. "/S4/local.txt"))

  vim.fn.delete(workspace_root, "rf")
end)

test("nonempty directories and symlinks are not claimed as portals", function()
  local portal = require("ziege.adapters.oil.portal")
  local project = require("ziege.project")
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/S4", "p")
  vim.fn.writefile({ "owned locally" }, root .. "/S4/local.txt")
  vim.fn.writefile({ "systems:", "  S4:" }, root .. "/.ziege")
  project.clear_cache()

  local err
  portal.load_directory(root, function(load_error)
    err = load_error
  end)
  wait_for(function()
    return err ~= nil
  end)
  assert_true(err:find("must be empty", 1, true) ~= nil)
  assert_equal(nil, portal.system_for_path(root .. "/S4"))
  assert_equal({ "owned locally" }, vim.fn.readfile(root .. "/S4/local.txt"))

  vim.fn.delete(root .. "/S4", "rf")
  vim.uv.fs_symlink(root, root .. "/S4")
  project.clear_cache()
  err = nil
  portal.load_directory(root, function(load_error)
    err = load_error
  end)
  wait_for(function()
    return err ~= nil
  end)
  assert_true(err:find("conflicts with a link", 1, true) ~= nil)
  assert_equal(nil, portal.system_for_path(root .. "/S4"))
  vim.fn.delete(root, "rf")
end)

test("invalid provider folder types are callback errors", function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ "systems:", "  S4:" }, root .. "/.ziege")
  local provider = { list = function() end, read = function() end }
  require("ziege.config").setup({
    provider = provider,
    project_provider = {
      load_project = function(_, _, callback)
        callback(nil, { systems = { { name = "S4", folder = 42 } } })
      end,
    },
  })
  require("ziege.project").clear_cache()
  local err
  require("ziege.project").load_directory(root, function(load_error)
    err = load_error
  end)
  wait_for(function()
    return err ~= nil
  end)
  assert_true(err:find("System folder names must be non-empty strings", 1, true) ~= nil)
  vim.fn.delete(root, "rf")
end)

for _, spec in ipairs(tests) do
  local ok, err = xpcall(spec.callback, debug.traceback)
  if ok then
    print("PASS " .. spec.name)
  else
    failures = failures + 1
    print("FAIL " .. spec.name .. "\n" .. err)
  end
end

if failures > 0 then
  vim.cmd.cquit(failures)
else
  print(string.format("PASS %d tests", #tests))
  vim.cmd.quitall({ bang = true })
end
