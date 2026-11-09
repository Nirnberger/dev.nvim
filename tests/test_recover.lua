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

T["nested same-name environment"] = function()
  local n = scan({ "\\begin{align}", "\\begin{align}", "x", "\\end{align}", "\\end{align}", "$y$" })
  eq(#n, 2)
  eq(n[1].range.erow, 4)
  eq(n[2].src, "y")
end
T["dollar inside environment is not scanned separately"] = function()
  eq(#scan({ "\\begin{equation}", "a $b$ c", "\\end{equation}" }), 1)
end
T["escaped percent is not a comment"] = function() eq(srcs({ "50\\% $x$" }), { "x" }) end
T["empty input"] = function() eq(scan({}), {}) end
T["multi-line display is trimmed"] = function()
  local n = scan({ "$$", "a", "$$" })
  eq(n[1].src, "a")
  eq(n[1].range, { srow = 0, scol = 0, erow = 2, ecol = 2 })
  eq(srcs({ "\\[", "b", "\\]" }), { "b" })
end
T["unmatched paren and bracket"] = function()
  eq(srcs({ "\\( x $y$" }), { "y" })
  eq(srcs({ "\\[ x $y$" }), { "y" })
end
T["lstlisting is ignored"] = function() eq(#scan({ "\\begin{lstlisting}", "$x$", "\\end{lstlisting}" }), 0) end
T["space between begin and brace"] = function() eq(#scan({ "\\begin {align}", "x", "\\end {align}" }), 1) end
T["stray begin before nested same-name env"] = function()
  local n = scan({ "\\begin{align}", "\\begin{align}", "x", "\\end{align}" })
  eq(#n, 1)
  eq(n[1].range.srow, 1)
  eq(n[1].range.erow, 3)
end
T["stray begin before balanced env"] = function()
  local n = scan({ "\\begin{align} oops", "text", "", "\\begin{align}", "a", "\\end{align}" })
  eq(#n, 1)
  eq(n[1].range.srow, 3)
  eq(n[1].range.erow, 5)
end
T["pathological inputs stay fast"] = function()
  local h = require("tests.helpers")
  local function rep(s)
    local t = {}
    for i = 1, 20000 do
      t[i] = s
    end
    return t
  end
  local t0 = vim.uv.hrtime()
  scan(rep("text $x$ more $y$"))
  scan(rep("\\begin{align} x"))
  scan(rep("\\( x"))
  scan(rep("\\[ x"))
  local ms = (vim.uv.hrtime() - t0) / 1e6
  eq(ms < 1000 * h.perf_factor, true)
end

return T
