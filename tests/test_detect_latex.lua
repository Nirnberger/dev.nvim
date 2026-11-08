local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local h = require("tests.helpers")
local detect = require("inkmath.detect")

local function r(a, b, c, d) return { srow = a, scol = b, erow = c, ecol = d } end
local function d(lines) return detect.detect(h.buf(lines, "tex")) end

T["inline dollar"] = function()
  local n = d({ "$x$" })
  eq(#n, 1); eq(n[1].kind, "inline"); eq(n[1].src, "x")
end
T["inline paren"] = function()
  local n = d({ "\\(x\\)" })
  eq(#n, 1); eq(n[1].kind, "inline"); eq(n[1].src, "x")
end
T["display bracket"] = function()
  local n = d({ "\\[a\\]" })
  eq(#n, 1); eq(n[1].kind, "display")
end
T["align block"] = function()
  local lines = { "\\begin{align}", "a&=b\\\\", "c&=d", "\\end{align}" }
  local n = d(lines)
  eq(#n, 1); eq(n[1].kind, "block"); eq(n[1].env, "align")
  eq(n[1].range, r(0, 0, 3, 11)); eq(n[1].src, table.concat(lines, "\n"))
end
for _, env in ipairs({ "equation*", "gather", "multline" }) do
  T["block " .. env] = function()
    local n = d({ "\\begin{" .. env .. "}", "a", "\\end{" .. env .. "}" })
    eq(#n, 1); eq(n[1].kind, "block"); eq(n[1].env, env)
  end
end
T["escaped dollar"] = function() eq(#d({ "\\$5" }), 0) end
T["verb"] = function() eq(#d({ "\\verb|$x$|" }), 0) end
T["comment"] = function() eq(#d({ "% $x$" }), 0) end
T["preamble"] = function()
  local b = h.buf({ "\\documentclass{article}", "\\newcommand{\\R}{\\mathbb{R}}", "\\begin{document}", "$\\R$", "\\end{document}" }, "tex")
  eq(require("inkmath.detect.latex").preamble(b), { "\\documentclass{article}", "\\newcommand{\\R}{\\mathbb{R}}" })
end
T["preamble none"] = function()
  eq(require("inkmath.detect.latex").preamble(h.buf({ "$x$" }, "tex")), {})
end

T["dollar display"] = function()
  local n = d({ "$$x$$" })
  eq(#n, 1); eq(n[1].kind, "display"); eq(n[1].src, "x")
end
T["nested env outermost only"] = function()
  local n = d({ "\\begin{equation}", "\\begin{split}a&=b\\end{split}", "\\end{equation}" })
  eq(#n, 1); eq(n[1].env, "equation")
end
T["verb star"] = function() eq(#d({ "\\verb*|$x$|" }), 0) end
T["verb then math"] = function()
  local n = d({ "\\verb|a| $y$" })
  eq(#n, 1); eq(n[1].src, "y")
end

T["detect is fast on a large buffer"] = function()
  local lines = {}
  for i = 1, 5000 do
    if i % 5 == 0 then
      lines[i] = "\\begin{equation} a_{" .. i .. "} \\end{equation} and text"
    elseif i % 5 < 3 then
      lines[i] = "text $x_{" .. i .. "}$ more"
    else
      lines[i] = "plain text line " .. i
    end
  end
  local b = h.buf(lines, "tex")
  local latex = require("inkmath.detect.latex")
  local n = latex.detect(b) -- warm up (query parse, tree)
  eq(#n, 3000)
  local best = math.huge
  for _ = 1, 3 do
    local t0 = vim.uv.hrtime()
    latex.detect(b)
    best = math.min(best, (vim.uv.hrtime() - t0) / 1e6)
  end
  local limit = 40 * h.perf_factor
  assert(best < limit, ("latex.detect took %.1f ms (limit %.0f)"):format(best, limit))
end

T["row-bounded detect matches the full result"] = function()
  local b = h.buf({ "$a$", "\\begin{align}", "x \\text{$b$}", "\\end{align}", "$c$" }, "tex")
  local full = detect.detect(b, 2, 2)
  eq(#full, 1)
  eq(full[1].kind, "block")
  local n = require("inkmath.detect.latex").detect(b, 4, 4)
  eq(#n, 1)
  eq(n[1].src, "c")
end

return T
