local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local h = require("tests.helpers")
local detect = require("inkmath.detect")

local function r(a, b, c, d) return { srow = a, scol = b, erow = c, ecol = d } end

T["inline"] = function()
  local n = detect.detect(h.buf({ "a $x^2$ b" }, "markdown"))
  eq(#n, 1)
  eq(n[1].kind, "inline")
  eq(n[1].src, "x^2")
  eq(n[1].range, r(0, 2, 0, 7))
end
T["display single line"] = function()
  local n = detect.detect(h.buf({ "$$a+b$$" }, "markdown"))
  eq(#n, 1)
  eq(n[1].kind, "display")
  eq(n[1].src, "a+b")
end
T["display multi line"] = function()
  local n = detect.detect(h.buf({ "$$", "a \\\\ b", "$$" }, "markdown"))
  eq(#n, 1)
  eq(n[1].kind, "display")
  eq(n[1].range, r(0, 0, 2, 2))
  eq(n[1].src, "\\begin{gathered}a \\\\ b\\end{gathered}")
end
T["no wrap inside env"] = function()
  local s = "\\begin{aligned}a&=b\\\\c&=d\\end{aligned}"
  local n = detect.detect(h.buf({ "$$", s, "$$" }, "markdown"))
  eq(#n, 1)
  eq(n[1].src, s)
end
T["escaped dollar"] = function() eq(#detect.detect(h.buf({ "costs \\$5 and \\$6" }, "markdown")), 0) end
T["code fence ignored"] = function() eq(#detect.detect(h.buf({ "```", "$x$", "```" }, "markdown")), 0) end
T["inline code ignored"] = function()
  local n = detect.detect(h.buf({ "`$x$` and $y$" }, "markdown"))
  eq(#n, 1)
  eq(n[1].src, "y")
end
T["row range filter"] = function()
  local n = detect.detect(h.buf({ "$a$", "$a$", "$a$" }, "markdown"), 1, 1)
  eq(#n, 1)
  eq(n[1].range.srow, 1)
end
T["id stable"] = function()
  local n = detect.detect(h.buf({ "$a$ and $a$" }, "markdown"))
  eq(#n, 2)
  eq(n[1].id, n[2].id)
  eq(#n[1].id, 16)
end
T["other filetype empty"] = function() eq(detect.detect(h.buf({ "$a$" }, "text")), {}) end
T["display inside code span ignored"] = function()
  local n = detect.detect(h.buf({ "`$$x$$` and $y$" }, "markdown"))
  eq(#n, 1)
  eq(n[1].src, "y")
end
T["code span with unclosed dollar"] = function()
  local n = detect.detect(h.buf({ "a `$x` b $y$" }, "markdown"))
  eq(#n, 1)
  eq(n[1].src, "y")
end
T["empty display"] = function() eq(#detect.detect(h.buf({ "$$$$" }, "markdown")), 0) end
T["unclosed dollar"] = function() eq(#detect.detect(h.buf({ "price $5 and more" }, "markdown")), 0) end
T["missing parser yields no nodes"] = function()
  local b = h.buf({ "a $x$ b" }, "markdown")
  local orig = vim.treesitter.get_parser
  vim.treesitter.get_parser = function() error("no parser for markdown") end
  local ok, n = pcall(detect.detect, b)
  vim.treesitter.get_parser = orig
  eq(ok, true)
  eq(n, {})
end

return T
