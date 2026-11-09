local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local recover = require("inkmath.detect.recover")

local function scan(lines, first) return recover.scan(lines, first or 0) end
local function srcs(lines)
  return vim.tbl_map(function(n) return n.src end, scan(lines))
end

T["inline dollar with byte range"] = function()
  local n = scan({ "a $x$ b" })
  eq(#n, 1)
  eq(n[1].kind, "inline")
  eq(n[1].src, "x")
  eq(n[1].range, { srow = 0, scol = 2, erow = 0, ecol = 5 })
end
T["first_row offset and byte columns"] = function()
  local n = scan({ "äö $x$" }, 3)
  eq(n[1].range.srow, 3)
  eq(n[1].range.scol, 5)
end
T["unpaired trailing dollar stays source"] = function()
  eq(srcs({ "$a$ and $b" }), { "a" })
  eq(srcs({ "$a$ $b$ $c" }), { "a", "b" })
end
T["paragraph boundary"] = function()
  eq(srcs({ "$a$", "", "$b" }), { "a" })
  eq(srcs({ "$b", "", "$c$" }), { "c" })
end
T["escaped dollar"] = function()
  eq(srcs({ "\\$5 and $x$" }), { "x" })
  eq(srcs({ "\\\\$x$" }), { "x" })
end
T["comments are skipped"] = function() eq(srcs({ "% $x$", "$y$" }), { "y" }) end
T["display dollars"] = function()
  local n = scan({ "$$a$$" })
  eq(n[1].kind, "display")
  eq(n[1].src, "a")
  eq(srcs({ "$$ a", "", "$y$" }), { "y" })
end
T["paren and bracket delimiters"] = function()
  local n = scan({ "\\(x\\) \\[y\\]" })
  eq(n[1].kind, "inline")
  eq(n[1].src, "x")
  eq(n[2].kind, "display")
  eq(n[2].src, "y")
end
T["environment spans blank lines"] = function()
  local n = scan({ "\\begin{align}", "a&=b", "", "c", "\\end{align}" })
  eq(#n, 1)
  eq(n[1].kind, "block")
  eq(n[1].env, "align")
  eq(n[1].range, { srow = 0, scol = 0, erow = 4, ecol = 11 })
end
T["environment without end"] = function() eq(#scan({ "\\begin{align}", "a&=b" }), 0) end
T["verbatim and verb are ignored"] = function()
  eq(#scan({ "\\begin{verbatim}", "$x$", "\\end{verbatim}" }), 0)
  eq(srcs({ "\\verb|$|, $x$" }), { "x" })
end

return T
