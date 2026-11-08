-- Render queue: visible-first ordering with directional prefetch, the in-flight cap,
-- and dropping requests for nodes that left the view or were edited away.
vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local helpers = require("tests.helpers")
local cache = require("inkmath.render.cache")
local cells = require("inkmath.term.cells")
local config = require("inkmath.config")
local core = require("inkmath.core")
local queue = require("inkmath.render.queue")
local kitty = require("inkmath.term.kitty")
local render = require("inkmath.render")
local tmux = require("inkmath.term.tmux")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local orig, bufs = {}, {}
local calls ---@type {node: inkmath.MathNode, cb: function, ctx: table}[]

T["queue"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      orig.send, orig.supported, orig.in_tmux, orig.cell_size, orig.render, orig.cap =
        kitty.send, kitty.supported, tmux.in_tmux, cells.cell_size, render.render, queue.max_inflight
      kitty.send = function() end
      kitty.supported = function() return true end
      tmux.in_tmux = function() return false end
      cells.cell_size = function() return { w = 10, h = 20 } end
      config.setup({})
      vim.o.termguicolors = true
      calls = {}
      -- held renders: completed by release()
      render.render = function(n, ctx, cb) calls[#calls + 1] = { node = n, cb = cb, ctx = ctx } end
    end,
    post_case = function()
      for _, b in ipairs(bufs) do
        pcall(core.detach, b)
      end
      bufs = {}
      queue.reset() -- held renders never finish
      require("inkmath.term.images").evict(0, {})
      kitty.send, kitty.supported, tmux.in_tmux, cells.cell_size, render.render, queue.max_inflight =
        orig.send, orig.supported, orig.in_tmux, orig.cell_size, orig.render, orig.cap
    end,
  },
})

local function doc(n)
  local lines = {}
  for i = 1, n do
    lines[i] = ("Line %d $x_{%d}$ text."):format(i, i)
  end
  return lines
end

local function setup(n, top)
  local buf = helpers.buf(doc(n), "markdown")
  vim.api.nvim_win_set_buf(0, buf)
  bufs[#bufs + 1] = buf
  vim.fn.winrestview({ topline = top + 1, lnum = top + 1 })
  vim.cmd("redraw")
  return buf
end

local function view()
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  return info.topline - 1, info.botline - 1, vim.api.nvim_win_get_height(0)
end

local function rows(nodes)
  return vim.tbl_map(function(n) return n.range.srow end, nodes)
end

local function release(list)
  for _, c in ipairs(list) do
    c.cb({ key = cache.key(c.node, c.ctx, "mathjax"), path = "/stub.png", cols = 1, rows = 1, ratio = 0.5 })
  end
end

local function range(a, b, step)
  local out = {}
  for r = a, b, step or 1 do
    out[#out + 1] = r
  end
  return out
end

T["queue"]["visible first, then the screen ahead, then the rest"] = function()
  queue.max_inflight = 0 -- nothing starts: inspect the queue order
  local buf = setup(300, 100)
  core.attach(buf, { sync = true })
  local top, bot, h = view()
  local q = queue.list(buf)
  -- no scroll yet: downwards is ahead
  local want = range(top, bot)
  vim.list_extend(want, range(bot + 1, math.min(299, bot + h)))
  vim.list_extend(want, range(top - 1, math.max(0, top - h), -1))
  eq(rows(q), want)
  eq(#calls, 0)

  -- scroll up: the screen above becomes the one ahead
  vim.fn.winrestview({ topline = top - 10 + 1, lnum = top - 10 + 1 })
  vim.cmd("redraw")
  core.refresh(buf)
  local top2, bot2, h2 = view()
  want = range(top2, bot2)
  vim.list_extend(want, range(top2 - 1, math.max(0, top2 - h2), -1))
  vim.list_extend(want, range(bot2 + 1, math.min(299, bot2 + h2)))
  eq(rows(queue.list(buf)), want)
end

T["queue"]["requests are started visible first"] = function()
  queue.max_inflight = 1000
  local buf = setup(300, 150)
  core.attach(buf, { sync = true })
  local top, bot = view()
  local got = rows(vim.tbl_map(function(c) return c.node end, calls))
  eq(vim.list_slice(got, 1, bot - top + 1), range(top, bot))
end

T["queue"]["at most max_inflight renders run at once"] = function()
  local buf = setup(300, 0)
  core.attach(buf, { sync = true })
  eq(#calls, 8)
  local _, active = queue.list(buf)
  eq(active, 8)
  -- each finished render starts the next queued one
  release({ calls[1], calls[2] })
  vim.wait(200, function() return #calls == 10 end, 5)
  eq(#calls, 10)
  local _, active2 = queue.list(buf)
  eq(active2, 8)
end

T["queue"]["requests for nodes scrolled out of view are dropped"] = function()
  local buf = setup(400, 0)
  core.attach(buf, { sync = true })
  eq(#calls, 8) -- the first 8 rows are in flight; the rest of the margin is queued
  -- jump far away before any render finished
  vim.fn.winrestview({ topline = 301, lnum = 301 })
  vim.cmd("redraw")
  core.refresh(buf)
  local top, bot, h = view()
  local first = vim.list_slice(calls, 1, 8)
  release(first)
  vim.wait(500, function() return #calls >= 16 end, 5)
  -- everything requested after the jump is in the new scan range, visible first
  for k = 9, #calls do
    local r = calls[k].node.range.srow
    MiniTest.expect.equality(r >= top - h and r <= bot + h, true)
  end
  eq(calls[9].node.range.srow, top)
end

T["queue"]["requests for edited-away nodes are dropped"] = function()
  local buf = setup(300, 0)
  core.attach(buf, { sync = true })
  eq(#calls, 8)
  -- an edit (its debounced refresh has not run yet) makes the queued jobs stale
  vim.api.nvim_buf_set_text(buf, 50, 0, 50, 0, { "x" })
  release(vim.list_slice(calls, 1, 8))
  vim.wait(30) -- the scheduled pump runs; less than debounce_ms
  eq(#calls, 8)
  -- the refresh queues them again with the new text
  core.refresh(buf)
  eq(#calls, 16)
end

return T
