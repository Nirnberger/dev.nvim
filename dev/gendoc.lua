-- Regenerates the options section of doc/inkmath.txt from inkmath.config.schema.
-- `make doc` runs it; tests/test_doc.lua checks the file is up to date.
local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
M.doc_path = root .. "/doc/inkmath.txt"
M.BEGIN, M.END = "<!-- BEGIN OPTIONS -->", "<!-- END OPTIONS -->"

local WIDTH = 78

local function wrap(text, indent)
  local out, line = {}, indent
  for word in text:gmatch("%S+") do
    if #line + #word + 1 > WIDTH and line ~= indent then
      out[#out + 1] = line
      line = indent
    end
    line = line == indent and indent .. word or line .. " " .. word
  end
  out[#out + 1] = line
  return out
end

--- the default at the option's path (a table for entries with children, e.g. conceal)
local function default_of(o, defaults)
  local v = defaults
  for key in o.path:gmatch("[^.]+") do
    if type(v) == "table" then
      v = v[key]
    else
      v = nil
    end
  end
  return vim.inspect(v, { newline = " ", indent = "" })
end

---@return string[] lines between the markers
function M.render_options()
  local schema = require("inkmath.config.schema")
  local out, defaults = {}, schema.defaults()
  for _, o in ipairs(schema.options) do
    local tag = "*inkmath." .. o.path .. "*"
    out[#out + 1] = (" "):rep(WIDTH - #tag) .. tag
    local scope = o.scope == "buffer" and "  (also in |inkmath-overrides|)" or ""
    out[#out + 1] = ("%s ~"):format(o.path)
    out[#out + 1] = ("    Default: `%s`%s"):format(default_of(o, defaults), scope)
    vim.list_extend(out, wrap(o.doc, "    "))
    out[#out + 1] = ""
  end
  if out[#out] == "" then out[#out] = nil end
  return out
end

--- the lines currently between the markers in `lines`, and the marker indexes
---@param lines string[]
---@return string[] section, integer begin, integer end
function M.section_of(lines)
  local b, e
  for i, l in ipairs(lines) do
    if l == M.BEGIN then
      b = i
    elseif l == M.END then
      e = i
    end
  end
  assert(b and e and b < e, "options markers missing in doc/inkmath.txt")
  return vim.list_slice(lines, b + 1, e - 1), b, e
end

function M.write()
  local lines = vim.fn.readfile(M.doc_path)
  local _, b, e = M.section_of(lines)
  local out = vim.list_slice(lines, 1, b)
  vim.list_extend(out, M.render_options())
  vim.list_extend(out, vim.list_slice(lines, e))
  vim.fn.writefile(out, M.doc_path)
end

if not ... then M.write() end -- `luafile dev/gendoc.lua`

return M
