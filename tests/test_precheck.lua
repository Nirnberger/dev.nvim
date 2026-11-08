local precheck = require("inkmath.detect.precheck")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["precheck"] = function()
  eq(precheck.triggers({ "plain prose" }), false)
  eq(precheck.triggers({ "a $x" }), true)
  eq(precheck.triggers({ "\\begin{x}" }), true)
end
T["every trigger"] = function()
  for _, t in ipairs({ "$", "\\(", "\\)", "\\[", "\\]", "\\begin", "\\end", "%", "```", "\\\\" }) do
    eq(precheck.triggers({ "a", "x" .. t .. "y" }), true)
  end
  eq(precheck.triggers({ "\\alpha `code` {braces} 50 percent" }), false)
  eq(precheck.triggers({}), false)
end

return T
