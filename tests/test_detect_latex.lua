local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local h = require("tests.helpers")
local detect = require("inkmath.detect")

local function r(a, b, c, d) return { srow = a, scol = b, erow = c, ecol = d } end
local function d(lines) return detect.detect(h.buf(lines, "tex")) end

T["inline dollar"] = function()
  local n = d({ "$x$" })
  eq(#n, 1)
  eq(n[1].kind, "inline")
  eq(n[1].src, "x")
end
T["inline paren"] = function()
  local n = d({ "\\(x\\)" })
  eq(#n, 1)
  eq(n[1].kind, "inline")
  eq(n[1].src, "x")
end
T["display bracket"] = function()
  local n = d({ "\\[a\\]" })
  eq(#n, 1)
  eq(n[1].kind, "display")
end
T["align block"] = function()
  local lines = { "\\begin{align}", "a&=b\\\\", "c&=d", "\\end{align}" }
  local n = d(lines)
  eq(#n, 1)
  eq(n[1].kind, "block")
  eq(n[1].env, "align")
  eq(n[1].range, r(0, 0, 3, 11))
  eq(n[1].src, table.concat(lines, "\n"))
end
for _, env in ipairs({ "equation*", "gather", "multline" }) do
  T["block " .. env] = function()
    local n = d({ "\\begin{" .. env .. "}", "a", "\\end{" .. env .. "}" })
    eq(#n, 1)
    eq(n[1].kind, "block")
    eq(n[1].env, env)
  end
end
T["escaped dollar"] = function() eq(#d({ "\\$5" }), 0) end
T["verb"] = function() eq(#d({ "\\verb|$x$|" }), 0) end
T["comment"] = function() eq(#d({ "% $x$" }), 0) end
T["preamble"] = function()
  local b = h.buf(
    { "\\documentclass{article}", "\\newcommand{\\R}{\\mathbb{R}}", "\\begin{document}", "$\\R$", "\\end{document}" },
    "tex"
  )
  eq(require("inkmath.detect.latex").preamble(b), { "\\documentclass{article}", "\\newcommand{\\R}{\\mathbb{R}}" })
end
T["preamble none"] = function() eq(require("inkmath.detect.latex").preamble(h.buf({ "$x$" }, "tex")), {}) end

T["dollar display"] = function()
  local n = d({ "$$x$$" })
  eq(#n, 1)
  eq(n[1].kind, "display")
  eq(n[1].src, "x")
end
T["nested env outermost only"] = function()
  local n = d({ "\\begin{equation}", "\\begin{split}a&=b\\end{split}", "\\end{equation}" })
  eq(#n, 1)
  eq(n[1].env, "equation")
end
T["verb star"] = function() eq(#d({ "\\verb*|$x$|" }), 0) end
T["verb then math"] = function()
  local n = d({ "\\verb|a| $y$" })
  eq(#n, 1)
  eq(n[1].src, "y")
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

local function srcs(n)
  return vim.tbl_map(function(x) return x.src end, n)
end

T["recovers formulas around an unclosed dollar"] = function()
  local n, info = detect.detect(h.buf({ "$a$ $b$ $c", "", "$y$", "", "\\[z\\]" }, "tex"))
  eq(srcs(n), { "a", "b", "y", "z" })
  eq(info.has_error, false)
  eq(info.tree_error, true)
end

T["recovery keeps later paragraphs after a broken command"] = function()
  local n = d({ "$\\frac{$ a", "", "$y$" })
  assert(vim.tbl_contains(srcs(n), "y"))
end

T["error-free text has no tree_error"] = function()
  local n, info = detect.detect(h.buf({ "$a$ and $b$" }, "tex"))
  eq(#n, 2)
  eq(info.tree_error, false)
  eq(info.has_error, false)
end

T["recovered nodes have the same ids as in clean text"] = function()
  local clean = d({ "$y$", "", "\\begin{align}", "a&=b", "\\end{align}" })
  local broken = d({ "$x", "", "$y$", "", "\\begin{align}", "a&=b", "\\end{align}" })
  local ids = {}
  for _, x in ipairs(broken) do
    ids[x.src] = x.id
  end
  for _, x in ipairs(clean) do
    eq(ids[x.src], x.id)
  end
end

T["row-bounded detect still works on a broken tree"] = function()
  local b = h.buf({ "$a$ $b$ $c", "", "$y$", "", "$z$" }, "tex")
  local n, info = detect.detect(b, 4, 4)
  eq(srcs(n), { "z" })
  eq(info.tree_error, true)
end

T["starred environment: same id and env in a broken paragraph"] = function()
  for _, env in ipairs({ "align*", "equation*", "multline*" }) do
    local body = { "\\begin{" .. env .. "}", "a&=b \\\\", "c", "\\end{" .. env .. "}" }
    local clean = d(body)
    local broken_lines = vim.list_extend(vim.deepcopy(body), { "x \\frac{ oops" })
    local broken = d(broken_lines)
    eq(#broken, 1)
    eq(broken[1].env, clean[1].env)
    eq(broken[1].id, clean[1].id)
  end
end

T["verbatim with a blank line is not math in a broken paragraph"] = function()
  local n = d({ "\\begin{lstlisting}", "a", "", "$notmath$", "\\end{lstlisting}", "\\frac{" })
  eq(srcs(n), {})
end

local DOC = {
  "\\begin{document}",
  "Text $a+$b$ and $c$ here.",
  "",
  "Para two $d$ and \\(e\\).",
  "More $f$.",
  "}",
  "\\[ x^2 \\]",
  "",
  "\\begin{align}",
  "  a &= b",
  "\\end{align}",
  "",
  "Last $z$ $and $$w$$.",
  "x $g$ y",
  "\\end{document}",
}

local function key(n) return vim.inspect({ n.kind, n.src, n.env, n.id, n.range }) end

local function parity(lines, bounds)
  local b = h.buf(lines, "tex")
  local full = detect.detect(b)
  for _, rg in ipairs(bounds) do
    local want =
      vim.tbl_map(key, vim.tbl_filter(function(n) return n.range.srow <= rg[2] and n.range.erow >= rg[1] end, full))
    local got = vim.tbl_map(key, (detect.detect(b, rg[1], rg[2])))
    eq(got, want)
  end
end

T["range detect equals the filtered full detect (mis-paired node above the range)"] = function()
  parity(DOC, { { 13, 13 } })
end

T["range detect parity on random broken buffers"] = function()
  local pieces =
    { "$a$", "$", "$$", "\\(", "\\)", "\\[", "\\]", "{", "}", "x", "\\frac{", "\\begin{align}", "\\end{align}", "" }
  math.randomseed(7)
  for _ = 1, 25 do
    local lines = {}
    for i = 1, 14 do
      local t = {}
      for _ = 1, math.random(0, 3) do
        t[#t + 1] = pieces[math.random(#pieces)]
      end
      lines[i] = table.concat(t, " ")
    end
    local bounds = {}
    for _ = 1, 4 do
      local a = math.random(0, 13)
      bounds[#bounds + 1] = { a, math.min(13, a + math.random(0, 2)) }
    end
    parity(lines, bounds)
  end
end

return T
