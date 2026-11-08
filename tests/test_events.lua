local events = require("inkmath.events")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function au(pattern, fn)
  return vim.api.nvim_create_autocmd("User", { pattern = pattern, once = true, callback = fn })
end

T["emit fires User with data"] = function()
  local got
  au("InkMathAttach", function(ev) got = ev.data end)
  events.emit("Attach", { buf = 7 })
  eq(got, { buf = 7 })
end
T["emit swallows handler errors"] = function()
  local orig = vim.notify
  vim.notify = function() end
  au("InkMathRender", function() error("boom") end)
  MiniTest.expect.no_error(function() events.emit("Render", {}) end)
  vim.notify = orig
end

return T
