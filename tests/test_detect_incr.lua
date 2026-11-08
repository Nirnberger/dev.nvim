-- Incremental detection must equal a full detect after every edit.
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local h = require("tests.helpers")
local detect = require("inkmath.detect")
local incr = require("inkmath.detect.incr")

local function norm(nodes)
  local out = {}
  for _, n in ipairs(nodes) do
    local r = n.range
    out[#out + 1] = table.concat({ n.id, n.kind, n.src, n.env or "", r.srow, r.scol, r.erow, r.ecol }, "|")
  end
  return out
end

local TEX = {
  "\\documentclass{article}", "\\begin{document}",
  "Text $a+b$ and $c$ here.", "", "\\[ x^2 \\]", "Some prose.",
  "\\begin{align}", "  a &= b \\\\", "  c &= d", "\\end{align}",
  "% a comment $hidden$", "More $\\frac{1}{2}$ text \\verb|$no$| end.",
  "\\begin{equation}", "  e = mc^2", "\\end{equation}", "Last $z$.", "\\end{document}",
}
local MD = {
  "# Title", "", "Para $a$ and $b+c$.", "Second line $d$.", "", "$$", "x^2", "$$", "",
  "```", "$code$", "```", "", "Inline `$span$` and $e$.", "", "$$f = g$$", "", "End $h$.",
}

-- balanced snippets keep the tree error-free (incremental path); risky ones may break it
local TEX_SNIPS = {
  safe = { " $q$ ", "word ", "\n", "\nMore $r_1$ text.\n", "\\[ y \\]", "\\alpha", "x", "  ",
    "\n\\begin{equation}\n  w\n\\end{equation}\n", "% " },
  risky = { "$", "{", "}", "\\[" },
}
local MD_SNIPS = {
  safe = { " $q$ ", "word ", "\n", "\n\nNew $r$ para.\n", "x", "  ", "\n\n$$\ns\n$$\n\n" },
  risky = { "$$", "\n$$\n", "`", "$", "```\n" },
}

local function random_edit(buf, snips)
  local n = vim.api.nvim_buf_line_count(buf)
  local row = math.random(0, n - 1)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  local col = math.random(0, #line)
  local op = math.random(1, 10)
  if op <= 6 then
    local list = math.random(1, 6) == 1 and snips.risky or snips.safe
    local s = list[math.random(#list)]
    vim.api.nvim_buf_set_text(buf, row, col, row, col, vim.split(s, "\n", { plain = true }))
  elseif op <= 8 then
    -- delete a few characters (possibly across a line end)
    local erow = math.min(n - 1, row + math.random(0, 1))
    local eline = vim.api.nvim_buf_get_lines(buf, erow, erow + 1, false)[1]
    local ecol = erow == row and math.min(#line, col + math.random(0, 4)) or math.random(0, #eline)
    vim.api.nvim_buf_set_text(buf, row, col, erow, ecol, {})
  elseif op == 9 and n > 3 then
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, {}) -- delete a line
  else
    vim.api.nvim_buf_set_lines(buf, row, row, false, { "Fresh $k_" .. row .. "$ line." })
  end
end

local function run(lines, ft, snips, seed, steps, hl)
  math.randomseed(seed)
  local buf = h.buf(lines, ft)
  eq(norm(incr.detect(buf)), norm(detect.detect(buf)))
  local before = vim.deepcopy(incr.stats)
  local function dump()
    local out = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do out[i] = (i - 1) .. ": " .. l end
    return table.concat(out, "\n")
  end
  for step = 1, steps do
    local prev = dump()
    -- sometimes several edits between two detections (debounced refresh)
    for _ = 1, math.random(1, 3) do random_edit(buf, snips) end
    -- hl: the treesitter highlighter parses (with injections) before the refresh
    if hl then vim.treesitter.get_parser(buf, "markdown"):parse(true) end
    local got = norm(incr.detect(buf))
    local full, info = detect.detect(buf)
    local want = norm(full)
    -- a broken tree makes every detection full: start over now and then
    if info.has_error and math.random(1, 2) == 1 then vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines) end
    if not vim.deep_equal(got, want) then
      error(("seed %d step %d: incremental != full\nbefore the edits:\n%s\nbuffer:\n%s\nonly in incremental:\n%s\nonly in full:\n%s"):format(seed, step,
        prev, dump(),
        table.concat(vim.tbl_filter(function(x) return not vim.tbl_contains(want, x) end, got), "\n"),
        table.concat(vim.tbl_filter(function(x) return not vim.tbl_contains(got, x) end, want), "\n")))
    end
  end
  incr.forget(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  return incr.stats.incr - before.incr
end

T["tex: random edits match a full detect"] = function()
  local n = 0
  for seed = 1, 10 do n = n + run(TEX, "tex", TEX_SNIPS, seed, 80) end
  MiniTest.expect.equality(n > 80, true) -- the incremental path was exercised
end

T["markdown: random edits match a full detect"] = function()
  local n = 0
  for seed = 1, 10 do n = n + run(MD, "markdown", MD_SNIPS, seed, 80) end
  MiniTest.expect.equality(n > 80, true)
end

local MD_HL = vim.list_extend(vim.deepcopy(MD), {
  "> quote $q$ and", "> more `x $y` z$", "", "- item $i$", "  cont $j$", "",
  "| a | $t$ |", "|---|---|", "| `$u` | $v$ |",
})
local MD_HL_SNIPS = {
  safe = { " $q$ ", "word ", "\n", "\n\nNew $r$ para.\n", "x", "  ", "\n\n$$\ns\n$$\n\n" },
  risky = { "$$", "\n$$\n", "`", "$", "```\n", "> ", "| " },
}

T["markdown: random edits with a highlighter parse in between match a full detect"] = function()
  local n = 0
  for seed = 1, 10 do n = n + run(MD_HL, "markdown", MD_HL_SNIPS, seed, 80, true) end
  MiniTest.expect.equality(n > 80, true)
end

T["unchanged buffer reuses the previous detection"] = function()
  local buf = h.buf(TEX, "tex")
  incr.detect(buf)
  local r0 = incr.stats.reuse
  local a = incr.detect(buf)
  eq(incr.stats.reuse, r0 + 1)
  a[1].id = "mutated" -- callers get copies
  eq(norm(incr.detect(buf)), norm(detect.detect(buf)))
  incr.forget(buf)
end

T["edit far from math re-detects only nearby rows"] = function()
  local lines = {}
  for i = 1, 400 do lines[i] = ("Line %d $x_{%d}$ text."):format(i, i) end
  local buf = h.buf(lines, "tex")
  incr.detect(buf)
  local f0, i0 = incr.stats.full, incr.stats.incr
  vim.api.nvim_buf_set_text(buf, 200, 0, 200, 0, { "word " })
  local got = incr.detect(buf)
  eq(incr.stats.full, f0)
  eq(incr.stats.incr, i0 + 1)
  eq(norm(got), norm(detect.detect(buf)))
  eq(got[201].range, { srow = 200, scol = 14, erow = 200, ecol = 23 })
  incr.forget(buf)
end

T["markdown bounded detect equals the full result in range"] = function()
  local buf = h.buf(MD, "markdown")
  local all = detect.detect(buf)
  local part = detect.detect(buf, 2, 8)
  local want = vim.tbl_filter(function(n) return n.range.srow <= 8 and n.range.erow >= 2 end, all)
  eq(norm(part), norm(want))
end

local function numbered(n)
  local lines = { "\\documentclass{article}", "\\begin{document}" }
  for i = 1, n do lines[#lines + 1] = ("L%d $x_%d$ t."):format(i, i) end
  lines[#lines + 1] = "\\end{document}"
  return lines
end

local function edit_and_compare(buf)
  vim.api.nvim_buf_set_lines(buf, 5, 5, false, { "new line", "another" })
  vim.api.nvim_buf_set_text(buf, 30, 0, 30, 0, { "word " })
  eq(norm(incr.detect(buf)), norm(detect.detect(buf)))
end

T["forget then re-detect: edits are applied once"] = function()
  local buf = h.buf(numbered(40), "tex")
  incr.detect(buf)
  incr.forget(buf) -- core.detach
  incr.detect(buf) -- attach again
  edit_and_compare(buf)
  for _ = 1, 3 do -- repeated toggles
    incr.forget(buf)
    incr.detect(buf)
  end
  edit_and_compare(buf)
  incr.forget(buf)
end

T["language change: edits are applied once"] = function()
  local buf = h.buf(numbered(40), "tex")
  incr.detect(buf)
  vim.bo[buf].filetype = "markdown"
  incr.detect(buf)
  edit_and_compare(buf)
  vim.bo[buf].filetype = "tex"
  incr.detect(buf)
  edit_and_compare(buf)
  incr.forget(buf)
end

-- Task 11: precheck skip, bounded fallbacks with stale rows, parse-free keystroke path

local function prose_tex(n)
  local lines = { "\\documentclass{article}", "\\begin{document}" }
  for i = 1, n do
    lines[#lines + 1] = ("Text %d with $x_{%d}$ here."):format(i, i)
    lines[#lines + 1] = "Plain prose line."
  end
  lines[#lines + 1] = "\\end{document}"
  return lines
end
--- run fn with async treesitter parses finishing at once (no pending detect)
local function sync(fn)
  return function()
    vim.g._ts_force_sync_parsing = true
    local ok, err = pcall(fn)
    vim.g._ts_force_sync_parsing = nil
    if not ok then error(err, 0) end
  end
end
local function type_at(buf, row, text) vim.api.nvim_buf_set_text(buf, row, 0, row, 0, { text }) end
local function in_rows(nodes, ranges)
  return vim.tbl_filter(function(n)
    for _, w in ipairs(ranges) do
      if n.range.srow <= w[2] and n.range.erow >= w[1] then return true end
    end
    return false
  end, nodes)
end

T["prose edit skips detection"] = function()
  local b = h.buf(prose_tex(50), "tex")
  incr.detect(b)
  local s0 = incr.stats.skip
  type_at(b, 11, "word") -- row 11: "Plain prose line."
  local got = incr.detect(b)
  eq(incr.stats.skip, s0 + 1)
  eq(norm(got), norm(detect.detect(b)))
  incr.forget(b)
end
T["edit on a formula's row is not skipped"] = function()
  local b = h.buf(prose_tex(50), "tex")
  incr.detect(b)
  local s0 = incr.stats.skip
  type_at(b, 10, "word") -- "Text ... $x$": a node on the row
  eq(norm(incr.detect(b)), norm(detect.detect(b)))
  eq(incr.stats.skip, s0)
  incr.forget(b)
end
T["deleting a delimiter is not skipped"] = function()
  local b = h.buf(prose_tex(50), "tex")
  incr.detect(b)
  local l = vim.api.nvim_buf_get_lines(b, 20, 21, false)[1]
  local c = l:find("%$") - 1
  vim.api.nvim_buf_set_text(b, 20, c, 20, c + 1, {})
  eq(norm(incr.detect(b)), norm(detect.detect(b)))
  incr.forget(b)
end
-- final review #2: the trigger scan sees only the text after an edit, so a deleted
-- trigger (no highlighter: no tree change seen either) must not be skipped
for _, case in ipairs({
  { "comment", { "\\begin{comment}", "hello", "x $a$ y", "\\end{comment}", "z" } },
  { "verbatim", { "\\begin{verbatim}", "hello", "x $a$ y", "\\end{verbatim}", "z" } },
}) do
  T["deleting a \\begin{" .. case[1] .. "} line is not skipped"] = sync(function()
    local b = h.buf(vim.list_extend({ "\\documentclass{article}", "\\begin{document}" },
      vim.list_extend(vim.deepcopy(case[2]), { "\\end{document}" })), "tex")
    incr.detect(b)
    local s0 = incr.stats.skip
    vim.api.nvim_buf_set_lines(b, 2, 3, false, {}) -- dd on the \begin line
    eq(norm(incr.detect(b)), norm(detect.detect(b)))
    eq(incr.stats.skip, s0)
    -- a later prose keystroke may skip again, and the result still matches
    type_at(b, 2, "w")
    eq(norm(incr.detect(b)), norm(detect.detect(b)))
    incr.forget(b)
  end)
end
T["deleting a backslash is not skipped"] = sync(function()
  local b = h.buf({ "\\documentclass{article}", "\\begin{document}", "a \\\\ b", "x $a$ y", "\\end{document}" }, "tex")
  incr.detect(b)
  local s0 = incr.stats.skip
  vim.api.nvim_buf_set_text(b, 2, 2, 2, 3, {}) -- "\\" -> "\"
  eq(norm(incr.detect(b)), norm(detect.detect(b)))
  eq(incr.stats.skip, s0)
  incr.forget(b)
end)
T["pure insertions of prose still skip"] = function()
  local b = h.buf(prose_tex(50), "tex")
  incr.detect(b)
  local s0 = incr.stats.skip
  type_at(b, 11, "w")
  type_at(b, 11, "o")
  incr.detect(b)
  eq(incr.stats.skip, s0 + 1)
  incr.forget(b)
end
T["markdown: joining paragraphs is not skipped"] = function()
  local b = h.buf({ "cost $5", "# head", "and $7 more", "", "x" }, "markdown")
  incr.detect(b)
  vim.api.nvim_buf_set_text(b, 1, 0, 1, 2, {}) -- "# head" -> "head": one paragraph now
  eq(norm(incr.detect(b)), norm(detect.detect(b)))
  incr.forget(b)
end
T["bounded large edit marks stale"] = sync(function()
  local b = h.buf(prose_tex(100), "tex")
  incr.detect(b)
  local paste = {}
  for i = 1, 2000 do paste[i] = ("Pasted %d $p_{%d}$."):format(i, i) end
  vim.api.nvim_buf_set_lines(b, 100, 100, false, paste)
  local nodes, _, stale = incr.detect(b, { { 0, 50 } })
  eq(#stale > 0, true)
  for _, r in ipairs(stale) do eq(r[1] > 50, true) end
  eq(norm(in_rows(nodes, { { 0, 50 } })), norm(in_rows(detect.detect(b), { { 0, 50 } })))
  for _, n in ipairs(nodes) do
    if n.range.srow <= 50 then eq(n.stale, nil) end
  end
  -- off-screen rows come back once they are wanted (background fill)
  local again = incr.detect(b, { { 1000, 1300 } })
  eq(norm(in_rows(again, { { 1000, 1300 } })), norm(in_rows(detect.detect(b), { { 1000, 1300 } })))
  -- the full path re-detects whatever is still stale
  eq(norm(incr.detect(b)), norm(detect.detect(b)))
  incr.forget(b)
end)
T["markdown: a new $$ line marks later blocks stale outside the view"] = sync(function()
  local lines = { "# t", "" }
  for i = 1, 300 do vim.list_extend(lines, { "$$", "a_" .. i, "$$", "", "Para $b_" .. i .. "$.", "" }) end
  local b = h.buf(lines, "markdown")
  vim.treesitter.stop(b)
  incr.detect(b)
  vim.api.nvim_buf_set_lines(b, 3, 3, false, { "$$" }) -- re-pairs every later block
  local want = { { 0, 40 } }
  local nodes, _, stale = incr.detect(b, want)
  eq(#stale > 0, true)
  eq(norm(in_rows(nodes, want)), norm(in_rows(detect.detect(b), want)))
  eq(norm(incr.detect(b)), norm(detect.detect(b)))
  incr.forget(b)
end)

local function run_want(lines, ft, snips, seed, steps)
  math.randomseed(seed)
  local buf = h.buf(lines, ft)
  pcall(vim.treesitter.stop, buf)
  incr.detect(buf)
  for step = 1, steps do
    for _ = 1, math.random(1, 3) do random_edit(buf, snips) end
    local n = vim.api.nvim_buf_line_count(buf)
    local lo = math.random(0, n - 1)
    local want = { { lo, math.min(n - 1, lo + math.random(0, 8)) } }
    if math.random(1, 3) == 1 then
      local lo2 = math.random(0, n - 1)
      want[2] = { lo2, math.min(n - 1, lo2 + 3) }
    end
    local got = norm(in_rows(incr.detect(buf, want), want))
    local full, info = detect.detect(buf)
    local exp = norm(in_rows(full, want))
    if info.has_error and math.random(1, 2) == 1 then vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines) end
    if not vim.deep_equal(got, exp) then
      error(("seed %d step %d want %s: bounded != full\n%s\nvs\n%s"):format(seed, step, vim.inspect(want),
        table.concat(got, "\n"), table.concat(exp, "\n")))
    end
  end
  incr.forget(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["equivalence property"] = function()
  vim.g._ts_force_sync_parsing = true -- async parses finish at once (no pending)
  local ok, err = pcall(function()
    for seed = 1, 100 do run_want(TEX, "tex", TEX_SNIPS, seed, 20) end
    for seed = 101, 200 do run_want(MD_HL, "markdown", MD_HL_SNIPS, seed, 20) end
  end)
  vim.g._ts_force_sync_parsing = nil
  if not ok then error(err, 0) end
end

T["no parse when highlighter will"] = function()
  local b = h.buf(MD, "markdown")
  vim.api.nvim_win_set_buf(0, b)
  vim.treesitter.start(b)
  local want = { { 0, 17 } }
  incr.detect(b, want)
  local ready = 0
  incr.on_ready(function(x) if x == b then ready = ready + 1 end end)
  local p = vim.treesitter.get_parser(b)
  local orig, calls = p.parse, 0
  p.parse = function(...) calls = calls + 1; return orig(...) end
  vim.api.nvim_buf_set_text(b, 3, 0, 3, 0, { "$y$ " })
  local nodes, _, stale = incr.detect(b, want)
  p.parse = orig
  eq(calls, 0)
  eq(#stale > 0, true) -- the edited rows wait for the highlighter's parse
  for _, n in ipairs(nodes) do eq(n.src ~= "y", true) end
  vim.cmd("redraw")
  vim.wait(1000, function() return ready > 0 end)
  incr.on_ready(function() end)
  eq(ready, 1)
  local found = false
  for _, n in ipairs(incr.detect(b, want)) do found = found or n.src == "y" end
  eq(found, true)
  incr.forget(b)
  vim.api.nvim_buf_delete(b, { force = true })
end

T["tex: async parse, then ready"] = function()
  local b = h.buf(prose_tex(3000), "tex")
  local want = { { 2990, 3010 } }
  incr.detect(b, want)
  local ready = 0
  incr.on_ready(function(x) if x == b then ready = ready + 1 end end)
  local l = vim.api.nvim_buf_get_lines(b, 3000, 3001, false)[1]
  local c = l:find("%$")
  vim.api.nvim_buf_set_text(b, 3000, c, 3000, c, { "y" })
  local t = vim.uv.hrtime()
  local _, _, stale = incr.detect(b, want)
  local ms = (vim.uv.hrtime() - t) / 1e6
  if #stale > 0 then -- the parse did not finish in its first 3 ms slice
    vim.wait(2000, function() return ready > 0 end)
    eq(ready, 1)
  end
  incr.on_ready(function() end)
  eq(norm(in_rows(incr.detect(b, want), want)), norm(in_rows(detect.detect(b), want)))
  eq(ms < 50, true)
  incr.forget(b)
end

return T
