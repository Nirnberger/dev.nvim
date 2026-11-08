-- idle.lua, deferred attach and the background fill (Task 12)
vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local h = require("tests.helpers")
local c = require("inkmath.config")
local core = require("inkmath.core")
local fill = require("inkmath.fill")
local idle = require("inkmath.idle")
local state = require("inkmath.view.state")
local cache = require("inkmath.render.cache")
local render = require("inkmath.render")
require("inkmath")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local images = require("inkmath.term.images")
local rendered = {} ---@type table<string, true> keys the render stub produced ("the disk cache")
local function stub_img(key) return { key = key, path = "/stub.png", cols = 1, rows = 1, ratio = 0.5 } end
local stubs = {
  { require("inkmath.term.kitty"), "supported", function() return true end },
  { require("inkmath.term.kitty"), "send", function() end },
  { require("inkmath.term.tmux"), "in_tmux", function() return false end },
  { require("inkmath.term.cells"), "cell_size", function() return { w = 10, h = 20 } end },
  { render, "available", function() return { mathjax = false, tectonic = true } end },
  { render, "render", function(n, ctx, cb)
    local key = cache.key(n, ctx, "mathjax")
    vim.schedule(function()
      rendered[key] = true
      cb(stub_img(key))
    end)
  end },
  { render, "cached", function(n, ctx)
    local key = cache.key(n, ctx, "mathjax")
    return rendered[key] and stub_img(key) or nil
  end },
  { vim, "notify", function() end },
}
local saved, bufs = {}, {}

local function big(n)
  local lines = { "\\documentclass{article}", "\\begin{document}" }
  for i = 1, n do lines[#lines + 1] = ("Line %d $x_{%d}$ text."):format(i, i) end
  lines[#lines + 1] = "\\end{document}"
  local b = h.buf(lines, "tex")
  bufs[#bufs + 1] = b
  vim.api.nvim_win_set_buf(0, b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return b
end

T["idle"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for i, s in ipairs(stubs) do saved[i] = s[1][s[2]]; s[1][s[2]] = s[3] end
      rendered = {}
      images._reset()
      saved.lines = vim.o.lines
      vim.o.lines = 24 -- the window shows ~22 rows: its keep band fits max_images below
      c.reset()
      vim.o.termguicolors = true
    end,
    post_case = function()
      for _, b in ipairs(bufs) do
        pcall(core.detach, b)
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
      bufs = {}
      idle.cancel("t")
      images.evict(0, {})
      for i, s in ipairs(stubs) do s[1][s[2]] = saved[i] end
      c.reset()
      images._reset()
      vim.o.lines = saved.lines
    end,
  },
})
local I = T["idle"]

I["idle runs only when idle"] = function()
  local n = 0
  idle.run("t", function() n = n + 1; return n < 3 end, { delay_ms = 10 })
  vim.wait(200, function() return n == 3 end)
  eq(n, 3)
  eq(idle.running("t"), false)
end
I["input postpones a slice"] = function()
  local n = 0
  idle.run("t", function() n = n + 1; return true end, { delay_ms = 40 })
  for _ = 1, 6 do
    vim.api.nvim_exec_autocmds("CursorMoved", {})
    vim.wait(15, function() return false end)
  end
  eq(n, 0) -- the cursor moved every 15 ms: never 40 ms idle
  vim.wait(200, function() return n > 0 end)
  eq(n > 0, true)
  idle.cancel("t")
end
I["attach returns before refresh"] = function()
  local b = big(5)
  local orig, calls = core.refresh, 0
  core.refresh = function(...) calls = calls + 1; return orig(...) end
  local ok = pcall(function()
    core.attach(b)
    eq(calls, 0)
    vim.wait(50, function() return calls > 0 end)
    eq(calls, 1)
  end)
  core.refresh = orig
  eq(ok, true)
end
local function filled(b)
  vim.wait(30000, function() return fill.state(b) == "done" end, 20)
  return fill.state(b)
end
--- refresh, then let the idle trim of far placements run
local function refresh_settled(b)
  core.refresh(b)
  vim.wait(1000, function() return not idle.running("trim:" .. b) end, 5)
end
local function visible_rows()
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  return info.topline - 1, info.botline - 1
end
--- formulas on rows [top, bot] (big(): one per "Line" row) and how many are placed
local function visible_placed(b)
  local top, bot = visible_rows()
  local want, placed = 0, 0
  local at = {}
  for _, e in pairs(state.get(b).nodes) do at[e.node.range.srow] = true end
  for r = top, bot do
    if (vim.api.nvim_buf_get_lines(b, r, r + 1, false)[1] or ""):find("$", 1, true) then
      want = want + 1
      if at[r] then placed = placed + 1 end
    end
  end
  return want, placed
end
I["fill renders off-screen formulas to the cache"] = function()
  c.setup({ fill = { rows_per_step = 300, max_jobs = 50 } })
  local b = big(1500)
  core.attach(b, { sync = true })
  eq(vim.tbl_count(rendered) < 1500, true) -- the first refresh scans the screen and its margin only
  eq(filled(b), "done")
  eq(vim.tbl_count(rendered), 1500)
end
-- final review #1: the fill only warms the disk cache; placements stay near the
-- windows, so resident images respect max_images and ids never run out
I["fill places nothing off-screen: resident images stay within max_images"] = function()
  c.setup({ max_images = 100, image_ids = { span = 200, per_instance = false },
    fill = { rows_per_step = 300, max_jobs = 50 } })
  local b = big(1000)
  core.attach(b, { sync = true })
  eq(filled(b), "done")
  eq(vim.tbl_count(rendered), 1000)
  eq(vim.tbl_count(state.get(b).nodes) <= 100, true)
  eq(images.resident_count() <= 100, true)
  -- jump to the bottom: every visible formula is placed from the cache at once
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(b), 0 })
  refresh_settled(b)
  local want, placed = visible_placed(b)
  eq(want > 5, true)
  eq(placed, want)
  eq(images.resident_count() <= 100, true)
  -- and back to the top: those placements were cleared, the cache places them again
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  refresh_settled(b)
  want, placed = visible_placed(b)
  eq(placed, want)
  local top_row = 2 -- "Line 1 $x_{1}$ text."
  eq(state.get(b).nodes[next(state.get(b).nodes)] ~= nil, true)
  local rows_placed = {}
  for _, e in pairs(state.get(b).nodes) do rows_placed[e.node.range.srow] = true end
  eq(rows_placed[top_row], true)
  eq(rows_placed[900] == nil, true) -- far from the window: not placed
end
I["keep_screens bounds the placements around the window"] = function()
  c.setup({ keep_screens = 1, fill = { enabled = false } })
  local b = big(600)
  core.attach(b, { sync = true })
  vim.wait(2000, function() local w, p = visible_placed(b); return p == w end, 10)
  local h = vim.api.nvim_win_get_height(0)
  vim.api.nvim_win_set_cursor(0, { 300, 0 })
  refresh_settled(b)
  local top, bot = visible_rows()
  for _, e in pairs(state.get(b).nodes) do
    local r = e.node.range
    eq(r.srow <= bot + h and r.erow >= top - h, true)
  end
end
-- a step's renders finishing starts the next step at once (idle.poke), so the fill
-- runs at the renderers' pace, not max_jobs renders per idle delay (was 4 per 50 ms)
I["fill takes its next step when the queued renders finish"] = function()
  c.setup({ fill = { rows_per_step = 300, max_jobs = 4 } })
  local b = big(400)
  core.attach(b, { sync = true })
  local t0 = vim.uv.hrtime()
  eq(filled(b), "done")
  local ms = (vim.uv.hrtime() - t0) / 1e6
  -- ~100 steps: one idle delay (50 ms) each would take 5 s; the scaled limit stays below that
  eq(ms < math.min(2500 * h.perf_factor, 4000), true)
end

I["edit cancels fill"] = function()
  c.setup({ fill = { rows_per_step = 50, max_jobs = 1 } })
  local b = big(1500)
  core.attach(b, { sync = true })
  vim.wait(500, function() return fill.running(b) end, 5)
  eq(fill.running(b), true)
  vim.api.nvim_buf_set_text(b, 3, 0, 3, 0, { "w" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = b })
  eq(fill.running(b), false)
  vim.wait(1000, function() return fill.running(b) end, 5) -- the refresh started it again
  eq(fill.running(b), true)
end
I["fill.enabled = false"] = function()
  c.setup({ fill = { enabled = false } })
  local b = big(800)
  core.attach(b, { sync = true })
  eq(fill.running(b), false)
end
I["fill detects rows a large paste left stale"] = function()
  c.setup({ fill = { rows_per_step = 400, max_jobs = 50 } })
  local b = big(50)
  core.attach(b, { sync = true })
  local paste = {}
  for i = 1, 2000 do paste[i] = ("Pasted %d $p_{%d}$."):format(i, i) end
  vim.api.nvim_buf_set_lines(b, 40, 40, false, paste)
  vim.g._ts_force_sync_parsing = true
  core.refresh(b)
  vim.g._ts_force_sync_parsing = nil
  eq(filled(b), "done")
  eq(vim.tbl_count(rendered), 2050)
  local _, _, stale = require("inkmath.detect.incr").detect(b)
  eq(stale, {})
end
I["fill.enabled = false stops a running pass"] = function()
  c.setup({ fill = { rows_per_step = 20, max_jobs = 1 } })
  local b = big(1500)
  core.attach(b, { sync = true })
  vim.wait(500, function() return fill.running(b) end, 5)
  eq(fill.running(b), true)
  c.setup({ fill = { enabled = false } })
  vim.wait(500, function() return not fill.running(b) end, 5)
  eq(fill.running(b), false)
end
I["WinScrolled counts as input"] = function()
  local n = 0
  idle.run("t", function() n = n + 1; return true end, { delay_ms = 40 })
  for _ = 1, 6 do
    vim.api.nvim_exec_autocmds("WinScrolled", {})
    vim.wait(15, function() return false end)
  end
  eq(n, 0)
  idle.cancel("t")
end

return T
