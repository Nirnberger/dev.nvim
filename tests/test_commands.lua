local commands = require("inkmath.commands")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local match = require("tests.expect").match

local notes, orig = {}, nil
T["cmd"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      notes, orig = {}, vim.notify
      vim.notify = function(m) notes[#notes + 1] = m end
    end,
    post_case = function() vim.notify = orig end,
  },
})
T["cmd"]["completion sorted"] = function()
  eq(commands.complete("", "InkMath "), { "build", "clear-cache", "disable", "enable", "refresh", "status", "toggle" })
  eq(commands.complete("t", "InkMath t"), { "toggle" })
  eq(commands.complete("", "InkMath! "), commands.complete("", "InkMath "))
end
T["cmd"]["no-arg prints usage"] = function()
  commands.run({ fargs = {}, bang = false })
  match(notes[1], "usage: :InkMath build|clear%-cache|")
end
T["cmd"]["unknown subcommand prints usage"] = function()
  commands.run({ fargs = { "nope" }, bang = false })
  match(notes[1], "unknown subcommand 'nope'.*usage")
end
T["cmd"]["registered subcommand gets args, bang and completion"] = function()
  local got
  commands.register("zz-test", {
    desc = "test",
    run = function(args, bang) got = { args, bang } end,
    complete = function() return { "two", "one" } end,
  })
  commands.run({ fargs = { "zz-test", "a", "b" }, bang = true })
  eq(got, { { "a", "b" }, true })
  eq(commands.complete("", "InkMath zz-test "), { "one", "two" })
  eq(commands.complete("o", "InkMath zz-test o"), { "one" })
end
T["cmd"][":InkMath is defined by require('inkmath')"] = function()
  require("inkmath")
  eq(vim.fn.exists(":InkMath"), 2)
end
T["cmd"]["require('inkmath') exposes the api"] = function() eq(require("inkmath").toggle, require("inkmath.api").toggle) end

return T
