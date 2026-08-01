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

local function open_oil(url)
  require("oil").open(url)
  local bufnr = vim.api.nvim_get_current_buf()
  wait_for(function()
    return vim.b[bufnr].oil_ready and not vim.b[bufnr].oil_rendering
  end, "Oil did not finish rendering " .. url)
  return bufnr
end

local function set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
  vim.bo[bufnr].modified = true
end

local function save_oil()
  local done = false
  local save_error
  require("oil").save({ confirm = false }, function(err)
    save_error = err
    done = true
  end)
  wait_for(function()
    return done
  end, "Oil save did not finish")
  return save_error
end

test("wizard UI uses a floating input and delegates selections", function()
  local ui = require("ziege.ui")
  local source_buf = vim.api.nvim_get_current_buf()
  local source_modifiable = vim.bo[source_buf].modifiable
  vim.bo[source_buf].modifiable = false
  vim.v.errmsg = ""
  local done = false
  local value
  ui.input({ prompt = "Description" }, function(result)
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

test("segment codec preserves atomic slash names", function()
  local model = require("ziege.model")
  local encoded = model.encode_segment("/ACME/ZCL_ORDER.clas.abap")
  assert_equal("%2FACME%2FZCL_ORDER.clas.abap", encoded)
  assert_equal("/ACME/ZCL_ORDER.clas.abap", model.decode_segment(encoded))
end)

test("routes retain package and facet context", function()
  local route = require("ziege.route")
  local parsed = assert(route.parse("abap://S4/packages/%2FACME%2FCORE.devc/classes/"))
  assert_equal("facet", parsed.kind)
  assert_equal("S4", parsed.system)
  assert_equal("/acme/core", parsed.package)
  assert_equal("classes", parsed.facet)
  assert_equal("abap://S4/packages/%2Facme%2Fcore.devc/", route.parent(parsed.url))
  local nested = assert(
    route.parse("abap://S4/packages/%2FACME%2FCORE.devc/packages/%2FACME%2FSUB.devc/interfaces/")
  )
  assert_equal({ "/acme/core", "/acme/sub" }, nested.packages)
  assert_equal(
    "abap://S4/packages/%2Facme%2Fcore.devc/packages/%2Facme%2Fsub.devc/",
    route.parent(nested.url)
  )
end)

test("bare names are constrained by their facet", function()
  require("ziege.config").setup({
    facet_order = { "source" },
    facets = {
      source = { label = "Source Library", kinds = { "class", "interface" } },
    },
  })
  local model = require("ziege.model")
  local bare = assert(model.resolve_projected_name("ZCL_ORDER", "source"))
  assert_equal(2, #bare.choices)
  assert_true(bare.bare)
  assert_equal("zcl_order", bare.name)
  local explicit = assert(model.resolve_projected_name("ZCL_ORDER.clas.abap", "source"))
  assert_equal("class", explicit.kind)
  assert_equal("zcl_order", explicit.name)
  local _, suffix_error = model.resolve_projected_name("ZCL_ORDER.devc", "source")
  assert_true(suffix_error:find("not allowed", 1, true) ~= nil)
  local lowercase = assert(model.resolve_projected_name("zcl_order", "source"))
  assert_equal("zcl_order", lowercase.name)
  local mixed_case = assert(model.resolve_projected_name("/ZZZ/xtlrfutfrt.clas.abap", "classes"))
  assert_equal("/zzz/xtlrfutfrt", mixed_case.name)

  require("ziege.config").setup({
    object_policy = require("ziege.policy").uppercase,
    facets = {
      source = { label = "Source Library", kinds = { "class", "interface" } },
    },
  })
  local uppercase = assert(model.resolve_projected_name("zcl_order.clas.abap", "source"))
  assert_equal("ZCL_ORDER", uppercase.name)
end)

test("Oil integration supports normal ABAP buffer edits", function()
  local mock = require("ziege.provider.mock").new({
    systems = {
      S4 = {
        transports = { "DEVK900001" },
        packages = {
          ["/acme/core"] = { description = "Core package" },
          ["/acme/other"] = { description = "Other package" },
        },
        objects = {
          ["class:/acme/zcl_order"] = {
            kind = "class",
            name = "/acme/zcl_order",
            package = "/acme/core",
            description = "Order service",
            source = { "CLASS zcl_order DEFINITION.", "ENDCLASS." },
          },
        },
      },
    },
  })
  local provider_routes = {}
  local mock_list = mock.list
  function mock:list(route, callback)
    table.insert(provider_routes, vim.deepcopy(route))
    mock_list(self, route, callback)
  end
  local ui = {
    input = function(_, callback)
      callback("Created by the test wizard")
    end,
    select = function(items, _, callback)
      callback(items[1])
    end,
  }
  local columns = require("oil.columns")
  local fallback_renders = 0
  columns.register("icon", {
    render = function()
      fallback_renders = fallback_renders + 1
      return { "F ", "FallbackIcon" }
    end,
    parse = function(line)
      return line:match("^(%S+)%s+(.*)$")
    end,
  })
  local status = require("ziege").setup({
    provider = mock,
    ui = ui,
    icons = {
      system = { glyph = "S", hl = "SystemIcon" },
      package = { glyph = "P", hl = "PackageIcon" },
    },
  })
  assert_true(status.supported, status.reason)
  require("oil").setup({
    adapters = {
      ["abap://"] = "ziege",
      ["oil-test://"] = "test",
    },
    columns = {},
    skip_confirm_for_simple_edits = false,
  })
  assert_true(
    require("oil.config").get_adapter_by_scheme("abap://") ~= nil,
    "Ziege adapter did not load"
  )

  local icon_column = assert(columns.get_column(require("oil.adapters.files"), "icon"))
  local field_meta = require("oil.constants").FIELD_META
  assert_equal(
    { "S ", "SystemIcon" },
    icon_column.render({ [field_meta] = { ziege_system = {} } }, nil, 0)
  )
  assert_equal(
    { "S ", "SystemIcon" },
    icon_column.render(
      { [field_meta] = { ziege = { virtual = true, system = "S4" } } },
      nil,
      0
    )
  )
  assert_equal(
    { "P ", "PackageIcon" },
    icon_column.render({ [field_meta] = { ziege = { kind = "package" } } }, nil, 0)
  )
  assert_equal(
    { "P", "OverrideIcon" },
    icon_column.render(
      { [field_meta] = { ziege = { virtual = true, facet = "packages" } } },
      { add_padding = false, highlight = "OverrideIcon" },
      0
    )
  )
  assert_equal(
    { "F ", "FallbackIcon" },
    icon_column.render({ [field_meta] = {} }, nil, 0),
    "Normal entries must retain Oil's original icon renderer"
  )
  assert_equal(1, fallback_renders)

  local workspace_root = vim.fn.tempname()
  vim.fn.mkdir(workspace_root, "p")
  vim.fn.writefile({ "local file" }, workspace_root .. "/local.txt")
  vim.fn.writefile({
    "systems:",
    "  DEV:",
    "    folder: SAP-DEV",
    "    url: https://example.invalid",
  }, workspace_root .. "/.ziege")
  require("ziege.project").clear_cache()
  local workspace_url = "oil://"
    .. require("oil.util").addslash(require("oil.fs").os_to_posix_path(workspace_root))
  local workspace_buf = open_oil(workspace_url)
  local workspace_lines = vim.api.nvim_buf_get_lines(workspace_buf, 0, -1, true)
  local workspace_text = table.concat(workspace_lines, "\n")
  assert_true(workspace_text:find("SAP-DEV/", 1, true) ~= nil)
  assert_true(workspace_text:find("local.txt", 1, true) ~= nil)

  local system_line
  local without_system = vim.deepcopy(workspace_lines)
  for index = #without_system, 1, -1 do
    if without_system[index]:find("SAP-DEV/", 1, true) then
      system_line = index
      table.remove(without_system, index)
    end
  end
  assert_true(system_line ~= nil)
  set_lines(workspace_buf, without_system)
  local parser = require("oil.mutator.parser")
  local _, protected_errors = parser.parse(workspace_buf)
  assert_equal(
    "Virtual system folders cannot be renamed, copied, or deleted",
    protected_errors[1].message
  )
  assert_equal("Error parsing oil buffers", save_oil())
  assert_true((vim.uv or vim.loop).fs_stat(workspace_root .. "/SAP-DEV") == nil)

  set_lines(workspace_buf, workspace_lines)
  vim.bo[workspace_buf].modified = false
  table.insert(workspace_lines, "created.txt")
  set_lines(workspace_buf, workspace_lines)
  assert_equal(nil, save_oil())
  assert_true((vim.uv or vim.loop).fs_stat(workspace_root .. "/created.txt") ~= nil)
  workspace_lines = vim.api.nvim_buf_get_lines(workspace_buf, 0, -1, true)
  for index, line in ipairs(workspace_lines) do
    if line:find("SAP-DEV/", 1, true) then
      system_line = index
      break
    end
  end
  vim.api.nvim_win_set_cursor(0, { system_line, 0 })
  local selected = false
  require("oil").select(nil, function(err)
    assert_equal(nil, err)
    selected = true
  end)
  wait_for(function()
    return selected and vim.b.oil_ready and not vim.b.oil_rendering
  end, "Virtual system did not open")
  local system_route = assert(require("ziege.route").parse(vim.api.nvim_buf_get_name(0)))
  assert_equal("DEV", system_route.system)
  assert_equal("https://example.invalid", system_route.system_config.url)
  assert_equal(vim.fn.fnamemodify(workspace_root, ":p"), system_route.project_root)
  assert_equal("https://example.invalid", provider_routes[#provider_routes].system_config.url)

  local scoped_url = vim.api.nvim_buf_get_name(0)
  vim.api.nvim_buf_delete(0, { force = true })
  require("ziege.project").clear_cache()
  open_oil(scoped_url)
  local restored_route = assert(require("ziege.route").parse(vim.api.nvim_buf_get_name(0)))
  assert_equal("DEV", restored_route.system)
  local system_root_url = scoped_url:gsub("packages/$", "")
  assert_equal(workspace_url, require("ziege.route").parent(system_root_url))

  if vim.api.nvim_buf_is_valid(workspace_buf) then
    vim.api.nvim_buf_delete(workspace_buf, { force = true })
  end
  vim.fn.mkdir(workspace_root .. "/SAP-DEV")
  local original_notify = vim.notify
  vim.notify = function() end
  local collision_buf = open_oil(workspace_url)
  vim.notify = original_notify
  local collision_entry
  for line_number, line in ipairs(vim.api.nvim_buf_get_lines(collision_buf, 0, -1, true)) do
    if line:find("SAP-DEV/", 1, true) then
      collision_entry = require("oil").get_entry_on_line(collision_buf, line_number)
      break
    end
  end
  assert_true(collision_entry ~= nil)
  assert_true(not collision_entry.meta or not collision_entry.meta.ziege_system)
  vim.fn.delete(workspace_root .. "/SAP-DEV", "d")

  local package_buf = open_oil("abap://S4/packages/")
  local package_lines = vim.api.nvim_buf_get_lines(package_buf, 0, -1, true)
  assert_true(package_lines[1]:find("/acme/core.devc", 1, true) ~= nil)
  set_lines(package_buf, vim.list_extend(vim.deepcopy(package_lines), { "ZNEWPKG" }))
  assert_equal(nil, save_oil())
  assert_true(mock.systems.S4.packages.znewpkg ~= nil)
  local package_text = table.concat(vim.api.nvim_buf_get_lines(package_buf, 0, -1, true), "\n")
  assert_true(package_text:find("znewpkg.devc/", 1, true) ~= nil)

  local package_root = open_oil("abap://S4/packages/%2Facme%2Fcore.devc/")
  assert_equal(false, vim.bo[package_root].modifiable, "Virtual facet roots must be read-only")
  local root_text = table.concat(vim.api.nvim_buf_get_lines(package_root, 0, -1, true), "\n")
  assert_true(root_text:find("Classes/", 1, true) ~= nil)
  assert_true(root_text:find("Interfaces/", 1, true) ~= nil)

  local class_url = "abap://S4/packages/%2Facme%2Fcore.devc/classes/"
  local class_buf = open_oil(class_url)
  local original_lines = vim.api.nvim_buf_get_lines(class_buf, 0, -1, true)
  assert_equal(1, #original_lines)
  assert_true(original_lines[1]:find("/acme/zcl_order.clas.abap", 1, true) ~= nil)

  local unchanged_diffs, unchanged_errors = parser.parse(class_buf)
  assert_equal({}, unchanged_diffs, "An untouched display name must not produce actions")
  assert_equal({}, unchanged_errors)

  set_lines(
    class_buf,
    vim.list_extend(vim.deepcopy(original_lines), {
      "/ACME/ZIF_WRONG.intf.abap",
    })
  )
  local _, suffix_errors = parser.parse(class_buf)
  assert_equal(1, #suffix_errors)
  assert_true(suffix_errors[1].message:find("not allowed", 1, true) ~= nil)

  set_lines(
    class_buf,
    vim.list_extend(vim.deepcopy(original_lines), {
      "/ACME/ZCL_NEW",
    })
  )
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local create_diffs, create_errors = parser.parse(class_buf)
  assert_equal({}, create_errors)
  assert_equal("%2FACME%2FZCL_NEW", create_diffs[1].name)
  assert_true(create_diffs[1].name:find("/", 1, true) == nil, "The Oil name must remain atomic")
  assert_equal(nil, save_oil())
  assert_true(mock.systems.S4.objects["class:/acme/zcl_new"] ~= nil)
  assert_equal(
    "%2Facme%2Fzcl_new.clas.abap",
    require("oil").get_cursor_entry().name,
    "Cursor should follow a bare name after its suffix is added"
  )

  local created_lines = vim.api.nvim_buf_get_lines(class_buf, 0, -1, true)
  local created_index
  for index, line in ipairs(created_lines) do
    if line:find("/acme/zcl_new.clas.abap", 1, true) then
      created_index = index
      created_lines[index] = line:gsub("zcl_new", "ZCL_RENAMED")
      break
    end
  end
  assert_true(created_index ~= nil, "Created class was not rerendered with its canonical suffix")
  set_lines(class_buf, created_lines)
  assert_equal(nil, save_oil())
  assert_true(mock.systems.S4.objects["class:/acme/zcl_new"] == nil)
  assert_true(mock.systems.S4.objects["class:/acme/zcl_renamed"] ~= nil)

  local renamed_lines = vim.api.nvim_buf_get_lines(class_buf, 0, -1, true)
  for index = #renamed_lines, 1, -1 do
    if renamed_lines[index]:find("/acme/zcl_renamed.clas.abap", 1, true) then
      table.remove(renamed_lines, index)
    end
  end
  set_lines(class_buf, renamed_lines)
  assert_equal(nil, save_oil())
  assert_true(mock.systems.S4.objects["class:/acme/zcl_renamed"] == nil)

  local source_lines = vim.api.nvim_buf_get_lines(class_buf, 0, -1, true)
  local order_line
  for index = #source_lines, 1, -1 do
    if source_lines[index]:find("/acme/zcl_order.clas.abap", 1, true) then
      order_line = table.remove(source_lines, index)
    end
  end
  assert_true(order_line ~= nil)
  local destination_buf = open_oil("abap://S4/packages/%2Facme%2Fother.devc/classes/")
  set_lines(class_buf, source_lines)
  set_lines(destination_buf, { order_line })
  assert_equal(nil, save_oil())
  assert_equal("/acme/other", mock.systems.S4.objects["class:/acme/zcl_order"].package)

  local replacement_lines = vim.api.nvim_buf_get_lines(destination_buf, 0, -1, true)
  for index, line in ipairs(replacement_lines) do
    if line:find("/acme/zcl_order.clas.abap", 1, true) then
      replacement_lines[index] = line:gsub("zcl_order", "ZCL_ORDER_2")
    end
  end
  table.insert(replacement_lines, "/ACME/ZCL_ORDER")
  set_lines(destination_buf, replacement_lines)
  assert_equal(nil, save_oil())
  assert_true(mock.systems.S4.objects["class:/acme/zcl_order"] ~= nil)
  assert_true(mock.systems.S4.objects["class:/acme/zcl_order_2"] ~= nil)
  local performed = #mock.performed

  local noop_lines = vim.api.nvim_buf_get_lines(destination_buf, 0, -1, true)
  for index, line in ipairs(noop_lines) do
    if line:find("/acme/zcl_order_2.clas.abap", 1, true) then
      noop_lines[index] = line:gsub("%.clas%.abap", "")
    end
  end
  set_lines(destination_buf, noop_lines)
  assert_equal(nil, save_oil())
  assert_equal(performed, #mock.performed, "Removing a redundant suffix must be a no-op")

  local object_url = "abap://S4/packages/%2Facme%2Fother.devc/classes/"
    .. "%2Facme%2Fzcl_order_2.clas.abap"
  require("oil").open(object_url)
  local object_buf = vim.api.nvim_get_current_buf()
  local loaded = vim.wait(3000, function()
    return not require("oil.loading").is_loading(object_buf)
      and vim.bo[object_buf].filetype == "abap"
  end, 10)
  assert_true(loaded, "ABAP object did not finish loading: " .. vim.inspect({
    loading = require("oil.loading").is_loading(object_buf),
    filetype = vim.bo[object_buf].filetype,
    lines = vim.api.nvim_buf_get_lines(object_buf, 0, -1, true),
    error = vim.v.errmsg,
  }))
  assert_equal(
    { "CLASS zcl_order DEFINITION.", "ENDCLASS." },
    vim.api.nvim_buf_get_lines(object_buf, 0, -1, true)
  )
  assert_equal(
    "abap://S4/packages/%2Facme%2Fother.devc/classes/",
    require("oil").get_buffer_parent_url(object_url, true)
  )
  set_lines(object_buf, { "CLASS zcl_order_2 DEFINITION.", "ENDCLASS." })
  vim.cmd.write()
  assert_equal(false, vim.bo[object_buf].modifiable, "Object buffer must be locked during a write")
  wait_for(function()
    return vim.bo[object_buf].modifiable and not vim.bo[object_buf].modified
  end, "ABAP object did not finish writing")
  assert_equal(
    { "CLASS zcl_order_2 DEFINITION.", "ENDCLASS." },
    mock.systems.S4.objects["class:/acme/zcl_order_2"].source
  )

  vim.api.nvim_set_current_buf(destination_buf)

  local before_cancel = vim.api.nvim_buf_get_lines(destination_buf, 0, -1, true)
  set_lines(destination_buf, vim.list_extend(vim.deepcopy(before_cancel), { "/ACME/ZCL_CANCEL" }))
  ui.input = function(_, callback)
    callback(nil)
  end
  assert_equal("Canceled", save_oil())
  assert_true(vim.bo[destination_buf].modified, "Cancellation must preserve Oil modifications")
  assert_true(mock.systems.S4.objects["class:/acme/zcl_cancel"] == nil)
  set_lines(destination_buf, before_cancel)
  vim.bo[destination_buf].modified = false

  local normal_buf = open_oil("oil-test:///foo/")
  set_lines(normal_buf, { "/ACME/NOT_ABAP" })
  local _, normal_errors = parser.parse(normal_buf)
  assert_equal("Paths cannot start with '/'", normal_errors[1].message)
  local performed_before_normal_save = #mock.performed
  set_lines(normal_buf, { "normal.txt" })
  assert_equal(nil, save_oil())
  assert_equal(performed_before_normal_save, #mock.performed)

  local root_buf = open_oil("abap://")
  local root_lines = table.concat(vim.api.nvim_buf_get_lines(root_buf, 0, -1, true), "\n")
  assert_true(root_lines:find("S4/", 1, true) ~= nil)

  local broken_root = vim.fn.tempname()
  vim.fn.mkdir(broken_root, "p")
  vim.fn.writefile({ "still visible" }, broken_root .. "/local.txt")
  vim.fn.writefile({ "systems: [" }, broken_root .. "/.ziege")
  require("ziege.project").clear_cache()
  original_notify = vim.notify
  vim.notify = function() end
  local broken_url = "oil://"
    .. require("oil.util").addslash(require("oil.fs").os_to_posix_path(broken_root))
  local broken_buf = open_oil(broken_url)
  vim.notify = original_notify
  local broken_text = table.concat(vim.api.nvim_buf_get_lines(broken_buf, 0, -1, true), "\n")
  assert_true(broken_text:find("local.txt", 1, true) ~= nil)
  vim.fn.delete(broken_root, "rf")
  vim.fn.delete(workspace_root, "rf")
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
