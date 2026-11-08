local log = require("inkmath.log")
local c = require("inkmath.config")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local notes, orig = {}, nil
T["log"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      notes, orig = {}, vim.notify
      vim.notify = function(m, l) notes[#notes + 1] = { m, l } end
      log.rearm()
      c.reset()
    end,
    post_case = function()
      vim.notify = orig
      log.rearm()
      c.reset()
    end,
  },
})
T["log"]["once fires once until rearm"] = function()
  log.once("x", "m"); log.once("x", "m"); eq(#notes, 1)
  log.rearm("x"); log.once("x", "m"); eq(#notes, 2)
end
T["log"]["rearm by prefix"] = function()
  log.once("error:a", "a"); log.once("kitty", "k")
  log.rearm("error:")
  log.once("error:a", "a"); log.once("kitty", "k")
  eq(#notes, 3)
end
T["log"]["level filter"] = function()
  c.setup({ log = { level = "error" } })
  log.notify("w", vim.log.levels.WARN); eq(#notes, 0)
  log.notify("e", vim.log.levels.ERROR); eq(#notes, 1)
end
T["log"]["debug only at debug level"] = function()
  log.debug("x %d", 1); eq(#notes, 0)
  c.setup({ log = { level = "debug" } })
  log.debug("x %d", 1); eq(notes[1][1], "inkmath: x 1")
end
T["log"]["log.level is validated"] = function()
  eq(pcall(c.setup, { log = { level = "loud" } }), false)
end
T["log"]["core._reset_notified rearms"] = function()
  log.once("kitty", "k")
  require("inkmath.core")._reset_notified()
  log.once("kitty", "k")
  eq(#notes, 2)
end
T["log"]["unregistered filetype warns"] = function()
  c.setup({ filetypes = { "markdown", "rst" } })
  eq(#notes, 1)
  require("tests.expect").match(notes[1][1], "'rst'.*register_filetype")
end

return T
