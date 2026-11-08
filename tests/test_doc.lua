local gendoc = require("dev.gendoc")
local schema = require("inkmath.config.schema")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local match = require("tests.expect").match

local function doc_lines() return vim.fn.readfile(gendoc.doc_path) end

T["options section matches schema (run `make doc`)"] = function()
  eq(gendoc.section_of(doc_lines()), gendoc.render_options())
end
T["every schema path documented"] = function()
  local text = table.concat(doc_lines(), "\n")
  for _, o in ipairs(schema.options) do match(text, "%f[%w]" .. vim.pesc(o.path) .. "%f[^%w.]") end
end
T["defaults are rendered, false included"] = function()
  local text = table.concat(gendoc.render_options(), "\n")
  match(text, "inline.promote ~\n    Default: `false`")
  match(text, "cell_size ~\n    Default: `nil`")
end
T["generated lines fit in 78 columns"] = function()
  for _, l in ipairs(gendoc.render_options()) do eq(vim.fn.strdisplaywidth(l) <= 78, true) end
end
T["helptags clean"] = function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/doc", "p")
  vim.fn.writefile(doc_lines(), tmp .. "/doc/inkmath.txt")
  vim.v.errmsg = ""
  vim.cmd("helptags " .. vim.fn.fnameescape(tmp .. "/doc"))
  eq(vim.v.errmsg, "")
  local tags = table.concat(vim.fn.readfile(tmp .. "/doc/tags"), "\n")
  for _, t in ipairs({ "inkmath", "inkmath-install", "inkmath-config", "inkmath-options", "inkmath-overrides",
    "inkmath-commands", "inkmath-mappings", "inkmath-api", "inkmath-events", "inkmath-highlights",
    "inkmath-interop", "inkmath-health", "inkmath-limitations", "inkmath.scale" }) do
    match(tags, "\n?" .. vim.pesc(t) .. "\t")
  end
end
T["commands and plug maps are documented"] = function()
  local text = table.concat(doc_lines(), "\n")
  for _, name in ipairs({ "enable", "disable", "toggle", "refresh", "clear-cache", "build" }) do
    match(text, "\n  " .. vim.pesc(name) .. " ")
  end
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if m.lhs:find("^<Plug>%(inkmath") then match(text, vim.pesc(m.lhs)) end
  end
end

T["every public api function and event is documented"] = function()
  local text = table.concat(doc_lines(), "\n")
  for name, v in pairs(require("inkmath.api")) do
    if type(v) == "function" and not name:find("^_") then match(text, "%*inkmath%." .. vim.pesc(name) .. "%(%)%*") end
  end
  for _, ev in ipairs({ "InkMathAttach", "InkMathDetach", "InkMathToggle", "InkMathRender" }) do match(text, "%*" .. ev .. "%*") end
end

return T
