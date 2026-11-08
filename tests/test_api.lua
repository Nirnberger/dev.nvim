vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local h = require("tests.helpers")
local c = require("inkmath.config")
local enable = require("inkmath.enable")
local api = require("inkmath.api")
local core = require("inkmath.core")
local images = require("inkmath.term.images")
local kitty = require("inkmath.term.kitty")
local render = require("inkmath.render")
local cache = require("inkmath.render.cache")
require("inkmath")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local match = require("tests.expect").match

local cell_w, cell_h = 10, 20
local real_render = render.render
local stubs = {
  { kitty, "supported", function() return true end },
  { kitty, "send", function() end },
  { require("inkmath.term.tmux"), "in_tmux", function() return false end },
  { require("inkmath.term.cells"), "cell_size", function() return { w = cell_w, h = cell_h } end },
  { render, "available", function() return { mathjax = false, tectonic = true } end },
  { vim, "notify", function() end },
}
local saved, bufs, events, au = {}, {}, {}, nil

--- render stub: async (vim.schedule) like a worker; "\\bad" fails
local function stub_render()
  render.render = function(n, ctx, cb)
    vim.schedule(function()
      if n.src:find("\\bad", 1, true) then return cb(nil, { message = "bad formula" }) end
      cb({ key = cache.key(n, ctx, "mathjax"), path = "/stub.png", cols = 1, rows = 1, ratio = 0.5 })
    end)
  end
end

local function buf(lines, ft)
  local b = h.buf(lines or { "$a$", "x", "$b$" }, ft or "markdown")
  bufs[#bufs + 1] = b
  vim.api.nvim_win_set_buf(0, b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return b
end

local function wait_idle() vim.wait(200, function() return false end, 10) end
local function last_event(name)
  for i = #events, 1, -1 do
    if events[i].name == name then return events[i].data end
  end
end
local function count_events(name)
  return #vim.tbl_filter(function(e) return e.name == name end, events)
end

T["api"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for i, s in ipairs(stubs) do saved[i] = s[1][s[2]]; s[1][s[2]] = s[3] end
      stub_render()
      vim.g.inkmath_disable = nil
      c.reset()
      enable._reset()
      events = {}
      au = vim.api.nvim_create_autocmd("User", {
        pattern = "InkMath*",
        callback = function(ev) events[#events + 1] = { name = ev.match, data = ev.data } end,
      })
    end,
    post_case = function()
      wait_idle()
      vim.api.nvim_del_autocmd(au)
      for _, b in ipairs(bufs) do
        pcall(core.detach, b)
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
      bufs = {}
      for i, s in ipairs(stubs) do s[1][s[2]] = saved[i] end
      render.render = real_render
      vim.g.inkmath_disable = nil
      c.reset()
      enable._reset()
      images.evict(0, {})
    end,
  },
})
local A = T["api"]

A["get_formulas range"] = function()
  local b = buf()
  core.attach(b, { sync = true })
  eq(#api.get_formulas(b, { srow = 2, erow = 2 }), 1)
  local f = api.get_formulas(b)[1]
  eq({ f.src, f.kind, f.range }, { "a", "inline", { srow = 0, scol = 0, erow = 0, ecol = 3 } })
end
A["get_formulas: rendered and error"] = function()
  local b = buf({ "$a$", "", "$\\bad$" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  core.attach(b, { sync = true })
  wait_idle()
  local fs = api.get_formulas(0)
  eq({ fs[1].rendered, fs[1].error }, { true, nil })
  eq({ fs[2].rendered, fs[2].error }, { false, "bad formula" })
  eq(fs[1].id ~= fs[2].id, true)
end
A["get_formulas of a buffer that is not attached"] = function()
  local b = buf({ "$a$ $a$" })
  local fs = api.get_formulas(b)
  eq(#fs, 2)
  eq(fs[1].id ~= fs[2].id, true) -- duplicates numbered like core's placements
  eq(fs[1].rendered, false)
end
A["formula_at_cursor"] = function()
  local b = buf()
  local win = vim.api.nvim_get_current_win()
  core.attach(b, { sync = true })
  vim.api.nvim_win_set_cursor(win, { 1, 1 })
  eq(api.formula_at_cursor(win).src, "a")
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  eq(api.formula_at_cursor(win), nil)
  vim.api.nvim_win_set_cursor(win, { 3, 2 })
  eq(api.formula_at_cursor().src, "b")
end
A["render returns image"] = function()
  render.render = real_render
  local res
  api.render("x^2", {}, function(r) res = r end)
  vim.wait(15000, function() return res end)
  eq(vim.uv.fs_stat(res.path) ~= nil, true)
  eq(res.width, res.cols * cell_w)
  eq(res.height, res.rows * cell_h)
end
A["render error"] = function()
  render.render = real_render
  c.setup({ fallback = false })
  local err
  api.render("\\frac{", {}, function(_, e) err = e end)
  vim.wait(15000, function() return err end)
  match(err, ".")
end
A["render options reach the ctx"] = function()
  local got
  render.render = function(n, ctx) got = { n = n, ctx = ctx } end
  api.render("y", { kind = "display", color = "#123456", scale = 2, width = 30, macros = { RR = "\\mathbb{R}" } }, function() end)
  eq({ got.n.kind, got.n.src, got.ctx.color, got.ctx.container_px, got.ctx.opts.scale, got.ctx.macros.RR },
    { "display", "y", "#123456", 30 * cell_w, 2, "\\mathbb{R}" })
  eq(c.get().scale, 1.0) -- the global config is untouched
end
A["placeholder transmits and pins until release"] = function()
  local sent = {}
  kitty.send = function(s) sent[#sent + 1] = s end
  local ph = api.placeholder({ key = "api-test", path = "/stub.png", cols = 2, rows = 1 })
  eq(#ph.lines, 1)
  eq(ph.hl, "InkMathImg" .. ph.id)
  match(sent[1], "i=" .. ph.id .. ",")
  images.evict(0, {})
  eq(#vim.tbl_filter(function(s) return s:find("a=d", 1, true) ~= nil end, sent), 0)
  api.release(ph.id)
  images.evict(0, {})
  match(sent[#sent], "a=d,d=I,i=" .. ph.id)
end
A["global disable detaches all"] = function()
  local b = buf()
  core.attach(b, { sync = true })
  api.disable()
  eq(core.is_attached(b), false)
  eq(vim.g.inkmath_disable, true)
  eq(api.is_enabled(), false)
  api.enable()
  eq(core.is_attached(b), true)
  eq(api.is_enabled(), true)
  eq(api.is_enabled(b), true)
end
A["Toggle event"] = function()
  local b = buf()
  core.attach(b, { sync = true })
  api.toggle(b)
  eq(last_event("InkMathToggle"), { buf = b, enabled = false, scope = "buffer" })
  api.toggle(0)
  eq(last_event("InkMathToggle"), { buf = b, enabled = true, scope = "buffer" })
  api.toggle()
  eq(last_event("InkMathToggle"), { enabled = false, scope = "global" })
  api.toggle()
end
A["Render event once per drain"] = function()
  local b = buf({ "$a$", "", "$b$", "", "$\\bad$" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  core.attach(b, { sync = true })
  wait_idle()
  eq(count_events("InkMathRender"), 1)
  eq(last_event("InkMathRender"), { buf = b, placed = 2, errors = 1, srow = 0, erow = 4 })
  core.refresh(b) -- everything placed: drains at once
  eq(count_events("InkMathRender"), 2)
end
A["Attach and Detach events"] = function()
  local b = buf()
  core.attach(b, { sync = true })
  eq(last_event("InkMathAttach").buf, b)
  core.detach(b)
  eq(last_event("InkMathDetach").buf, b)
  local n = count_events("InkMathDetach")
  core.detach(b) -- not attached: no event
  eq(count_events("InkMathDetach"), n)
end
A["Attach fires before the first Render (all cache hits)"] = function()
  render.render = function(n, ctx, cb) cb({ key = cache.key(n, ctx, "mathjax"), path = "/stub.png", cols = 1, rows = 1, ratio = 0.5 }) end
  local b = buf()
  core.attach(b, { sync = true })
  local names = vim.tbl_map(function(e) return e.name end, vim.tbl_filter(function(e) return e.name ~= "InkMathToggle" end, events))
  eq(names[1], "InkMathAttach")
  eq(vim.tbl_contains(names, "InkMathRender"), true)
end
A["render cb errors are reported on both paths"] = function()
  local notes = {}
  vim.notify = function(m) notes[#notes + 1] = m end
  require("inkmath.log").rearm("error:render cb")
  render.render = function(n, ctx, cb) cb({ key = "k", path = "/p.png", cols = 1, rows = 1, ratio = 1 }) end -- cache hit: sync
  MiniTest.expect.no_error(function() api.render("x", {}, function() error("sync boom") end) end)
  eq(#notes, 1)
  match(notes[1], "sync boom")
  require("inkmath.log").rearm("error:render cb")
  stub_render() -- async
  api.render("y", {}, function() error("async boom") end)
  vim.wait(200, function() return #notes == 2 end)
  match(notes[2] or "", "async boom")
end
A[":InkMath and <Plug> maps go through the api"] = function()
  local calls = {}
  local orig = {}
  for _, k in ipairs({ "enable", "disable", "toggle", "refresh", "clear_cache" }) do
    orig[k] = api[k]
    api[k] = function(...) calls[#calls + 1] = { k, ... } end
  end
  vim.cmd("InkMath enable")
  vim.cmd("InkMath! disable")
  vim.cmd("InkMath clear-cache")
  vim.cmd("execute \"normal \\<Plug>(inkmath-toggle)\"")
  for k, f in pairs(orig) do api[k] = f end
  eq(calls, { { "enable", 0 }, { "disable" }, { "clear_cache" }, { "toggle", 0 } })
end

return T
