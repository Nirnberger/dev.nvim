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

T["starred environment keeps the star in env"] = function()
  local n = scan({ "\\begin{align*}", "a", "\\end{align*}" })
  eq(n[1].env, "align*")
end

-- open_at: the formula being typed (unpaired opener before the cursor), for the live preview
T["open_at: unclosed dollar and paren"] = function()
  local n = recover.open_at({ "Some text $x^2" }, 0, 0, 14)
  eq({ n.kind, n.src, n.range }, { "inline", "x^2", { srow = 0, scol = 10, erow = 0, ecol = 14 } })
  n = recover.open_at({ "Some text \\(x^2" }, 0, 0, 15)
  eq({ n.kind, n.src, n.range }, { "inline", "x^2", { srow = 0, scol = 10, erow = 0, ecol = 15 } })
end
T["open_at: display openers"] = function()
  local n = recover.open_at({ "a \\[x" }, 0, 0, 5)
  eq({ n.kind, n.src }, { "display", "x" })
  n = recover.open_at({ "a $$x" }, 0, 0, 5)
  eq({ n.kind, n.src }, { "display", "x" })
end
T["open_at: only the cursor's paragraph, with row offset"] = function()
  local lines = { "Intro $a$ text.", "", "Some text $x^2", "", "Later $b$ ..." }
  local n = recover.open_at(lines, 10, 12, 14)
  eq({ n.src, n.range }, { "x^2", { srow = 12, scol = 10, erow = 12, ecol = 14 } })
  eq(recover.open_at(lines, 10, 14, 13), nil)
  eq(recover.open_at(lines, 10, 11, 0), nil) -- blank line
end
T["open_at: the body ends at the cursor"] = function()
  -- the paragraph runs on into \end{document} / \item: those are not part of the formula
  local n = recover.open_at({ "\\begin{document}", "Some text $x^2", "\\end{document}" }, 0, 1, 14)
  eq({ n.src, n.range }, { "x^2", { srow = 1, scol = 10, erow = 1, ecol = 14 } })
  n = recover.open_at({ "\\item Some text $x^2", "\\item next", "\\end{itemize}" }, 0, 0, 20)
  eq(n.src, "x^2")
  n = recover.open_at({ "Some $x^2 and the rest." }, 0, 0, 9)
  eq({ n.src, n.range }, { "x^2", { srow = 0, scol = 5, erow = 0, ecol = 9 } })
end
T["open_at: cursor on a later row of the paragraph"] = function()
  local n = recover.open_at({ "Text $x +", "y + z more", "", "w" }, 0, 1, 5)
  eq({ n.src, n.range }, { "x +\ny + z", { srow = 0, scol = 5, erow = 1, ecol = 5 } })
end
T["open_at: empty body (cursor on or right after the opener) is nil"] = function()
  eq(recover.open_at({ "Some text $" }, 0, 0, 11), nil)
  eq(recover.open_at({ "Some text $x" }, 0, 0, 10), nil) -- on the opener
  eq(recover.open_at({ "a \\(x" }, 0, 0, 3), nil) -- inside the opener
end
T["open_at: typing a $$ closer keeps the display formula"] = function()
  local n = recover.open_at({ "a $$x^2$" }, 0, 0, 8)
  eq({ n.kind, n.src, n.range }, { "display", "x^2", { srow = 0, scol = 2, erow = 0, ecol = 8 } })
end
T["open_at: nothing open before the cursor"] = function()
  eq(recover.open_at({ "$a$ b" }, 0, 0, 5), nil)
  eq(recover.open_at({ "Some text $x^2" }, 0, 0, 4), nil) -- cursor before the opener
  eq(recover.open_at({ "% $x" }, 0, 0, 4), nil)
  eq(recover.open_at({ "\\$x" }, 0, 0, 3), nil)
end
T["open_at: the last unpaired opener wins"] = function()
  eq(recover.open_at({ "$a$ b $c" }, 0, 0, 8).src, "c")
  eq(recover.open_at({ "$a b \\(c" }, 0, 0, 8).src, "c")
end

return T
