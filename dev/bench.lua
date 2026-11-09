-- Headless benchmark of the inkmath pipeline (real MathJax worker, kitty.send stubbed).
-- Run: make bench   (NVIM_APPNAME=inkmath-dev, never the default config/data dirs)
-- Env: BENCH_ONLY=worker,tex1000,tex5000,md2000,md2000nohl,opendollar,scroll,warmup  (comma list; default all)
--      BENCH_WORKERS=n  pool size for the open/scroll benchmarks; BENCH_PROFILE=1  time refresh parts
--      BENCH_JSON=path  also write the results as JSON
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.env.XDG_CACHE_HOME = vim.fn.tempname() -- empty render cache (stdpath("cache") follows)
package.path = root .. "/?.lua;" .. package.path

local cells = require("inkmath.term.cells")
local config = require("inkmath.config")
local core = require("inkmath.core")
local detect = require("inkmath.detect")
local fill = require("inkmath.fill")
local images = require("inkmath.term.images")
local kitty = require("inkmath.term.kitty")
local mathjax = require("inkmath.render.mathjax")
local render = require("inkmath.render")
local state = require("inkmath.view.state")
local tmux = require("inkmath.term.tmux")

kitty.send = function() end
kitty.supported = function() return true end
tmux.in_tmux = function() return false end
cells.cell_size = function() return { w = 10, h = 20 } end
vim.notify = function() end
vim.o.termguicolors = true
vim.o.lines, vim.o.columns = 52, 120
config.setup({})

local ONLY = {}
for w in (vim.env.BENCH_ONLY or ""):gmatch("[^,]+") do
  ONLY[w] = true
end
local function want(n) return next(ONLY) == nil or ONLY[n] end

local function now() return vim.uv.hrtime() / 1e6 end

-- every render request through render.render: outstanding count and main-thread
-- time spent in the callbacks core passes (deliver, place, evict, cursor update)
local outstanding, cb_ms, cb_n, cb_max = 0, 0, 0, 0
local orig_render = render.render
render.render = function(node, ctx, cb, opts)
  outstanding = outstanding + 1
  return orig_render(node, ctx, function(...)
    outstanding = outstanding - 1
    local t = now()
    cb(...)
    local d = now() - t
    cb_ms, cb_n, cb_max = cb_ms + d, cb_n + 1, math.max(cb_max, d)
  end, opts)
end
-- main-thread time in cache.put (metadata write after each finished render)
local put_ms = 0
do
  local cache = require("inkmath.render.cache")
  local put = cache.put
  cache.put = function(...)
    local t = now()
    local r = put(...)
    put_ms = put_ms + now() - t
    return r
  end
end
local function reset_cb()
  cb_ms, cb_n, cb_max, put_ms = 0, 0, 0, 0
end

-- BENCH_PROFILE=1: time the main pieces of refresh (module functions core calls)
local prof = {}
if vim.env.BENCH_PROFILE then
  local function wrap(mod, name, label)
    local f = mod[name]
    mod[name] = function(...)
      local t = now()
      local r = { f(...) }
      prof[label] = (prof[label] or 0) + now() - t
      return unpack(r)
    end
  end
  local ok, incr = pcall(require, "inkmath.detect.incr")
  if ok then wrap(incr, "detect", "detect (incr)") end
  wrap(detect, "detect", "detect (full/bounded)")
  wrap(require("inkmath.detect.markdown"), "block_pairs", "markdown.block_pairs")
  wrap(require("inkmath.detect.precheck"), "triggers", "precheck.triggers")
  local LT = getmetatable(vim.treesitter.get_string_parser("x", "markdown")).__index
  wrap(LT, "parse", "LanguageTree:parse (any caller)")
  wrap(require("inkmath.ctx"), "build", "ctx.build")
  wrap(require("inkmath.labels"), "apply", "labels.apply")
  wrap(images, "evict", "images.evict")
  wrap(require("inkmath.view.cursor"), "update", "cursor.update")
  wrap(require("inkmath.view.folds"), "hidden", "folds.hidden")
  wrap(require("inkmath.render.cache"), "key", "cache.key")
  wrap(require("inkmath.render.cache"), "get", "cache.get")
  wrap(render, "render", "render.render (sync part)")
  wrap(mathjax, "request", "mathjax.request")
end
local function prof_report(label, n)
  if not vim.env.BENCH_PROFILE then return end
  local keys = vim.tbl_keys(prof)
  table.sort(keys)
  for _, k in ipairs(keys) do
    io.stderr:write(("    %-40s %.2f ms/refresh\n"):format(label .. " " .. k, prof[k] / n))
  end
  prof = {}
end

local function stats(xs)
  table.sort(xs)
  local sum = 0
  for _, x in ipairs(xs) do
    sum = sum + x
  end
  local function q(p) return xs[math.max(1, math.ceil(#xs * p))] end
  return { median = q(0.5), p95 = q(0.95), max = xs[#xs], mean = sum / #xs, n = #xs }
end

-- ~1 formula per 2 lines: inline on most text lines, plus \[..\], $$..$$, equation
-- and align blocks. Every formula is distinct (no cache sharing between them).
local function gen_tex(n)
  local lines =
    { "\\documentclass{article}", "\\usepackage{amsmath}", "\\newcommand{\\R}{\\mathbb{R}}", "\\begin{document}" }
  local i = 0
  while #lines < n - 1 do
    i = i + 1
    local k = i % 12
    if k == 0 then
      vim.list_extend(lines, {
        "\\begin{align}",
        ("  f_{%d}(x) &= \\sum_{k=0}^{%d} a_k x^k \\\\"):format(i, i),
        ("  g_{%d}(x) &= \\int_0^x f_{%d}(t)\\,dt"):format(i, i),
        "\\end{align}",
        "",
      })
    elseif k == 6 then
      lines[#lines + 1] = ("\\[ \\frac{\\partial^{%d} u}{\\partial x^{%d}} = \\lambda_{%d} \\nabla^2 u \\]"):format(
        i,
        i,
        i
      )
      lines[#lines + 1] = ""
    elseif k == 9 then
      vim.list_extend(lines, {
        "\\begin{equation}",
        ("  e^{i\\pi %d} + \\sqrt{%d} = \\R^{%d}"):format(i, i, i),
        "\\end{equation}",
        "Plain prose follows the block here.",
      })
    else
      lines[#lines + 1] = ("Text %d with $x_{%d}^2 + \\alpha_{%d}$ and words around it."):format(i, i, i)
      lines[#lines + 1] = "Another line of prose without any math at all in it."
    end
  end
  lines[#lines + 1] = "\\end{document}"
  return lines
end

local function gen_md(n)
  local lines = { "# Notes", "" }
  local i = 0
  while #lines < n do
    i = i + 1
    local k = i % 10
    if k == 0 then
      vim.list_extend(lines, { "$$", ("\\sum_{k=1}^{%d} k^2 = \\frac{n(n+1)(2n+1)}{6}"):format(i), "$$", "" })
    elseif k == 5 then
      lines[#lines + 1] = ("$$\\int_0^{%d} e^{-x^2}\\,dx$$"):format(i)
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = ("Paragraph %d has $a_{%d} + b_{%d}$ inline math in it."):format(i, i, i)
      lines[#lines + 1] = "A line of plain text without math."
    end
  end
  return lines
end

local NOHL = false -- md without the treesitter highlighter (inkmath's own cost)
local function new_buf(lines, ft)
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = ft
  vim.api.nvim_win_set_buf(0, b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  if NOHL then
    pcall(vim.treesitter.stop, b)
    return b
  end
  -- a full parse with injections before the clock starts, as the treesitter
  -- highlighter (on for markdown by default) does for the first screen; the baseline
  -- detection did it itself (parse(true)), so the numbers stay comparable
  pcall(function() vim.treesitter.get_parser(b):parse(true) end)
  return b
end

--- ids (as core makes them) of the detected nodes within [lo, hi]
local function ids_in(buf, lo, hi)
  local nodes = detect.detect(buf)
  local count, out = {}, {}
  local md = vim.bo[buf].filetype == "markdown"
  for _, n in ipairs(nodes) do
    count[n.id] = (count[n.id] or 0) + 1
    local id = n.id .. "#" .. count[n.id]
    if
      n.range.srow <= hi
      and n.range.erow >= lo
      and not (md and n.kind ~= "inline" and require("inkmath.ctx").macro_only(n.src))
    then
      out[#out + 1] = id
    end
  end
  return out
end

local function view()
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  return info.topline - 1, info.botline - 1
end

local function visible_ids(buf)
  local top, bot = view()
  return ids_in(buf, top, bot)
end

local function all_placed(buf, ids)
  local s = state.get(buf)
  for _, id in ipairs(ids) do
    if not (s.nodes[id] or s.revealed[id]) then return false end
  end
  return true
end

local function wait_placed(buf, ids, t0)
  local ok = vim.wait(30000, function() return all_placed(buf, ids) end, 1)
  return ok and (now() - t0) or -1
end

local function wait_idle()
  vim.wait(60000, function() return outstanding == 0 end, 5)
end

local function redraw() vim.cmd("redraw") end

local function timed_refresh(buf)
  local t = now()
  core.refresh(buf)
  return now() - t
end

local results = {}
local function fmt(v)
  if type(v) == "table" then
    return table.concat(vim.tbl_map(function(x) return ("%.1f"):format(x) end, v), " / ")
  end
  return ("%.1f"):format(v)
end
local function record(name, value)
  results[#results + 1] = { name = name, value = value }
  io.stderr:write(("%-66s %s\n"):format(name, fmt(value)))
end

--- worker load time: spawn to the first answer
local function bench_worker()
  mathjax.shutdown()
  local t0, t_ans = now(), nil
  mathjax.request({
    tex = "x",
    display = false,
    macros = {},
    color = "#ffffff",
    cell_w = 10,
    cell_h = 20,
    container_px = 800,
    x_height = 0.45,
    baseline = 0.78,
    scale = 1,
    out = vim.fn.tempname() .. ".png",
  }, function() t_ans = now() end)
  vim.wait(60000, function() return t_ans ~= nil end, 1)
  record("worker: spawn -> first answer (ms)", t_ans - t0)
  -- steady-state throughput: 40 distinct formulas back to back, per pool size; and
  -- 40 trivial ones (the per-request overhead that batching could save)
  local function burst(n, trivial, tag)
    local done = 0
    local t1 = now()
    for i = 1, n do
      local tex = trivial and ("x_%d"):format(i) or ("\\frac{a_{%d}}{b^{%d}} + \\sqrt{x_%d}"):format(i, i, i)
      mathjax.request({
        tex = tag .. tex,
        display = not trivial,
        macros = {},
        color = "#ffffff",
        cell_w = 10,
        cell_h = 20,
        container_px = 800,
        x_height = 0.45,
        baseline = 0.78,
        scale = 1,
        out = vim.fn.tempname() .. ".png",
      }, function() done = done + 1 end)
    end
    vim.wait(60000, function() return done == n end, 1)
    return now() - t1
  end
  local sizes = config.get().workers and { 1, 2, 4 } or { 1 }
  for _, w in ipairs(sizes) do
    config.setup({ workers = w })
    mathjax.shutdown()
    mathjax.start()
    burst(40, false, "w") -- every worker loaded and warmed up (JIT)
    vim.wait(200)
    record(("worker: 40 renders, total (ms) [workers=%d]"):format(w), burst(40, false, "" .. w))
    record(("worker: 40 trivial renders, total (ms) [workers=%d]"):format(w), burst(40, true, "t" .. w))
  end
  -- the default pool (or BENCH_WORKERS), warmed up like the pools above (the
  -- cold-open numbers below measure an empty render cache, not node/MathJax start-up
  -- or JIT warm-up)
  config.setup({ workers = tonumber(vim.env.BENCH_WORKERS) })
  mathjax.shutdown()
  mathjax.start()
  burst(40, false, "d")
  burst(40, false, "e")
  vim.wait(200)
end

-- keystroke targets (plan v2, Task 11): sync main-thread time of the refresh after one keystroke
local TARGETS = { ["tex 5000"] = 5, ["md 2000"] = 8 }

--- (a) cold and warm open; (b) per-keystroke refresh cost; returns the buffer
local function bench_open(name, lines, ft)
  -- cold: empty cache, worker already started by bench_worker (its load time is
  -- reported separately)
  vim.env.XDG_CACHE_HOME = vim.fn.tempname()
  images.evict(0, {})
  reset_cb()
  config.setup({ fill = { enabled = false } }) -- cold numbers: the screen and its margin only
  local buf = new_buf(lines, ft)
  redraw()
  local vis = visible_ids(buf) -- (before the clock starts: detection costs time)
  prof = {}
  local t0 = now()
  core.attach(buf)
  local attach_ms = now() - t0
  prof_report(name .. " cold attach:", 1)
  local cold = wait_placed(buf, vis, t0)
  wait_idle()
  local cold_all = now() - t0
  record(name .. ": attach (sync main thread, ms)", attach_ms)
  record(name .. ": cold, visible placed (ms) [" .. #vis .. " formulas]", cold)
  record(name .. ": cold, visible+margin done (ms)", cold_all)
  record(name .. ": cold, callbacks main-thread total (ms) [" .. cb_n .. " cbs]", cb_ms)
  record(name .. ": cold, callback max (ms)", cb_max)
  record(name .. ": cold, cache writes main-thread total (ms)", put_ms)
  core.detach(buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  -- warm: same cache, fresh buffer and image registry, no worker running
  config.setup({ fill = { enabled = true } })
  images.evict(0, {})
  mathjax.shutdown()
  buf = new_buf(lines, ft)
  redraw()
  vis = visible_ids(buf)
  local total = #ids_in(buf, 0, #lines)
  local first_ms
  local orig_refresh = core.refresh
  core.refresh = function(...)
    local t = now()
    local r = orig_refresh(...)
    first_ms = first_ms or (now() - t)
    return r
  end
  t0 = now()
  core.attach(buf)
  local att = now() - t0
  record(name .. ": warm, attach (sync main thread, ms)", att)
  record(name .. ": attach (sync) (target < 10 ms)", att)
  local vp = wait_placed(buf, vis, t0)
  core.refresh = orig_refresh
  record(name .. ": warm, visible placed (ms)", vp)
  record(name .. ": attach -> visible placed (warm cache, ms)", vp)
  record(name .. ": first refresh after attach (deferred, main thread, ms)", first_ms or -1)
  record(name .. ": warm open: workers spawned", #mathjax.pids())
  -- background fill: every formula of the buffer rendered to the disk cache (off-screen
  -- ones were not rendered by the cold open: they render now, fill.max_jobs per idle
  -- step); nothing off-screen is placed, so the resident images stay near max_images
  local filled = vim.wait(120000, function() return fill.state(buf) == "done" end, 20)
  record(name .. ": background fill complete (ms) [" .. total .. " formulas]", filled and (now() - t0) or -1)
  wait_idle()
  record(
    name .. ": after fill: placed / resident images (max_images " .. config.get().max_images .. ")",
    { vim.tbl_count(state.get(buf).nodes), images.resident_count() }
  )
  -- jumps far into the filled document: placed from the disk cache, no render
  local tj = {}
  for i = 1, 5 do
    local row = math.floor(#lines * i / 6)
    vim.fn.winrestview({ topline = row, lnum = row })
    redraw()
    local vis = visible_ids(buf)
    local t1 = now()
    core.refresh(buf)
    tj[#tj + 1] = wait_placed(buf, vis, t1)
    wait_idle()
  end
  local sj = stats(tj)
  record(name .. ": after fill: jump far, visible placed median/max (ms)", { sj.median, sj.max })
  wait_idle()
  config.setup({ fill = { enabled = false } }) -- the keystroke numbers below: no fill in between

  -- (b) keystrokes in the middle: prose edit (no render) and formula edit (one render)
  local mid = math.floor(#lines / 2)
  local prose, math_row
  for r = mid, #lines do
    local l = vim.api.nvim_buf_get_lines(buf, r - 1, r, false)[1]
    if not prose and l:match("^A") then prose = r end
    if not math_row and l:match("^[TP]") and l:find("%$") then math_row = r end
    if prose and math_row then break end
  end
  vim.api.nvim_win_set_cursor(0, { mid, 0 })
  vim.cmd("normal! zz")
  redraw()
  core.refresh(buf)
  wait_idle()
  local incr = require("inkmath.detect.incr")
  local parser = vim.treesitter.get_parser(buf)
  local hl = vim.treesitter.highlighter.active[buf] ~= nil
  -- with the treesitter highlighter on, its parse runs during the refresh debounce
  -- (after the redraw that follows a keystroke): it is the highlighter's work, done
  -- with or without inkmath, so it happens before the clock starts
  local function settle()
    if not hl then return end
    redraw()
    vim.wait(200, function() return parser:is_valid(true) end, 1)
  end
  local tp, tm, tl = {}, {}, {}
  prof = {}
  local skip0 = incr.stats.skip
  for i = 1, 30 do
    vim.api.nvim_buf_set_text(buf, prose - 1, 0, prose - 1, 0, { "x" })
    settle()
    tp[#tp + 1] = timed_refresh(buf)
    vim.wait(0) -- let a pending parse finish (as the next keystroke would)
    wait_idle()
  end
  local skip_ratio = (incr.stats.skip - skip0) / 30
  prof_report(name .. " prose:", 30)
  prof = {}
  for i = 1, 30 do
    local l = vim.api.nvim_buf_get_lines(buf, math_row - 1, math_row, false)[1]
    local c = l:find("%$") -- insert right after the opening $
    vim.api.nvim_buf_set_text(buf, math_row - 1, c, math_row - 1, c, { "y" })
    local src = vim.api.nvim_buf_get_lines(buf, math_row - 1, math_row, false)[1]:match("%$(.-)%$")
    local t0 = now()
    settle()
    tm[#tm + 1] = timed_refresh(buf)
    -- keystroke -> the edited formula placed: the async parse (or the highlighter's),
    -- the refresh it triggers and the render
    local ok = vim.wait(10000, function()
      for _, e in pairs(state.get(buf).nodes) do
        if e.node.src == src and e.node.range.srow == math_row - 1 then return true end
      end
      return false
    end, 1)
    tl[#tl + 1] = ok and (now() - t0) or -1
    wait_idle()
  end
  prof_report(name .. " formula:", 30)
  local sp, sm, sl = stats(tp), stats(tm), stats(tl)
  record(name .. ": keystroke refresh, prose edit median/p95 (ms)", { sp.median, sp.p95 })
  record(name .. ": keystroke refresh, formula edit median/p95 (ms)", { sm.median, sm.p95 })
  local target = TARGETS[name]
  if target then
    record(
      ("%s: keystroke prose / formula%s, sync main-thread (target < %d ms)"):format(
        name,
        hl and ", TS highlighter on" or "",
        target
      ),
      { sp.median, sm.median }
    )
  end
  record(name .. ": keystroke -> formula placed median/p95 (ms)", { sl.median, sl.p95 })
  record(name .. ": prose keystroke precheck skip ratio", skip_ratio)
  -- breakdown: full-buffer detection alone
  local td = {}
  for i = 1, 20 do
    vim.api.nvim_buf_set_text(buf, prose - 1, 0, prose - 1, 0, { "x" })
    local t = now()
    detect.detect(buf)
    td[#td + 1] = now() - t
  end
  record(name .. ": full detect after an edit median (ms)", stats(td).median)
  return buf
end

--- (c2) detection with an open `$` in the middle of a large document: tree errors are
--- re-scanned per paragraph by detect/recover.lua
local function bench_opendollar(lines)
  local buf = new_buf(lines, "tex")
  local function run(label)
    local tt = {}
    for _ = 1, 20 do
      vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { "" }) -- dirty the tree like an edit
      local t = now()
      detect.detect(buf)
      tt[#tt + 1] = now() - t
    end
    record("tex 1000: full detect " .. label .. " median (ms)", stats(tt).median)
  end
  run("clean")
  local row = 500
  while not lines[row]:match("^Text") do
    row = row + 1
  end
  local l = lines[row]
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "an open $ " })
  run("with an open $")
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, #"an open $ ", { "" })
  assert(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] == l)
  vim.api.nvim_buf_delete(buf, { force = true })
end

--- (d) scrolling in a large document
local function bench_scroll(lines)
  config.setup({ fill = { enabled = false } }) -- comparable with v1: no background renders
  vim.env.XDG_CACHE_HOME = vim.fn.tempname()
  images.evict(0, {})
  local buf = new_buf(lines, "tex")
  redraw()
  core.attach(buf)
  wait_idle()
  local h = vim.api.nvim_win_get_height(0)
  local function scroll_to(top)
    vim.fn.winrestview({ topline = top + 1, lnum = top + 1 })
    redraw()
  end

  -- one screen down (prefetched by the previous refresh's margin)
  local top = view()
  local ts, tv = {}, {}
  for i = 1, 8 do
    top = top + h
    scroll_to(top)
    local vis = visible_ids(buf)
    local t0 = now()
    ts[#ts + 1] = timed_refresh(buf)
    tv[#tv + 1] = wait_placed(buf, vis, t0)
    wait_idle()
  end
  local s1, v1 = stats(ts), stats(tv)
  record("scroll 1 screen: refresh main-thread median/p95 (ms)", { s1.median, s1.p95 })
  record("scroll 1 screen: visible placed median/max (ms)", { v1.median, v1.max })

  -- fast scrolling into unrendered text: 6 screens in quick succession, one refresh
  -- each (as WinScrolled after each Ctrl-F would), then time to the final screen
  local tf = {}
  for rep = 1, 3 do
    top = math.floor(#lines * (0.25 * rep)) - 3 * h
    scroll_to(top)
    local t0, vis
    for i = 1, 6 do
      top = top + h
      scroll_to(top)
      if i == 6 then vis = visible_ids(buf) end
      t0 = now()
      core.refresh(buf)
      if i < 6 then vim.wait(30, function() return false end) end -- ~one keyrepeat interval
    end
    tf[#tf + 1] = wait_placed(buf, vis, t0)
    wait_idle()
  end
  local f = stats(tf)
  record("fast scroll 6 screens: final screen placed median/max (ms)", { f.median, f.max })

  -- held-down Ctrl-F with no pause: 10 screens, one refresh each, back to back
  local tb = {}
  for rep = 1, 3 do
    top = math.floor(#lines * (0.15 + 0.25 * rep)) - 10 * h
    scroll_to(top)
    local t0, vis
    for i = 1, 10 do
      top = top + h
      scroll_to(top)
      if i == 10 then vis = visible_ids(buf) end
      t0 = now()
      core.refresh(buf)
    end
    tb[#tb + 1] = wait_placed(buf, vis, t0)
    wait_idle()
  end
  local fb = stats(tb)
  record("burst scroll 10 screens: final screen placed median/max (ms)", { fb.median, fb.max })

  -- jump into a cold region (e.g. G or a search)
  local tj, tjr = {}, {}
  for rep = 1, 3 do
    top = math.floor(#lines * (0.1 + 0.2 * rep))
    scroll_to(top)
    local vis = visible_ids(buf)
    local t0 = now()
    tjr[#tjr + 1] = timed_refresh(buf)
    tj[#tj + 1] = wait_placed(buf, vis, t0)
    wait_idle()
  end
  local j, jr = stats(tj), stats(tjr)
  record("jump to cold region: refresh main-thread median (ms)", jr.median)
  record("jump to cold region: visible placed median/max (ms)", { j.median, j.max })
  core.detach(buf)
end

--- (5) warm-up: a warm open (every visible formula cached, so no render starts a
--- worker), then, 300 ms later, an edit in a visible formula: time until it is placed
local function bench_warmup(lines)
  config.setup({ fill = { enabled = false } })
  vim.env.XDG_CACHE_HOME = vim.fn.tempname()
  images.evict(0, {})
  local buf = new_buf(lines, "tex")
  redraw()
  core.attach(buf)
  wait_idle()
  core.detach(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  local tf = {}
  for rep = 1, 3 do
    mathjax.shutdown()
    images.evict(0, {})
    buf = new_buf(lines, "tex")
    redraw()
    core.attach(buf)
    -- the user enters insert mode to edit: InsertEnter warms one worker up (attach
    -- itself spawns none)
    vim.wait(50, function() return false end)
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buf })
    vim.wait(250, function() return false end)
    local row
    for r = 1, 40 do
      local l = vim.api.nvim_buf_get_lines(buf, r - 1, r, false)[1]
      if l:match("^Text") then
        row = r
        break
      end
    end
    local l = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    local c = l:find("%$")
    vim.api.nvim_buf_set_text(buf, row - 1, c, row - 1, c, { "q" .. rep })
    local vis = visible_ids(buf)
    local t0 = now()
    core.refresh(buf)
    tf[#tf + 1] = wait_placed(buf, vis, t0)
    wait_idle()
    core.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  local f = stats(tf)
  record(
    "warm open, workers not running: first edited formula placed (InsertEnter warm-up) median/max (ms)",
    { f.median, f.max }
  )
end

local ok, err = xpcall(function()
  if want("worker") then bench_worker() end
  if want("tex1000") then
    local b = bench_open("tex 1000", gen_tex(1000), "tex")
    core.detach(b)
  end
  if want("tex5000") then
    local b = bench_open("tex 5000", gen_tex(5000), "tex")
    core.detach(b)
  end
  if want("md2000") then
    local b = bench_open("md 2000", gen_md(2000), "markdown")
    core.detach(b)
  end
  if want("md2000nohl") then
    NOHL = true
    local b = bench_open("md 2000, no TS highlighter", gen_md(2000), "markdown")
    core.detach(b)
    NOHL = false
  end
  if want("opendollar") then bench_opendollar(gen_tex(1000)) end
  if want("scroll") then bench_scroll(gen_tex(5000)) end
  if want("warmup") then bench_warmup(gen_tex(1000)) end
end, debug.traceback)

if not ok then io.stderr:write("ERROR: " .. tostring(err) .. "\n") end
if vim.env.BENCH_JSON then vim.fn.writefile({ vim.json.encode(results) }, vim.env.BENCH_JSON) end
render.shutdown()
vim.cmd(ok and "qa!" or "cq!")
