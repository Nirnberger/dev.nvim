-- :InkMath status, clear-cache count, build re-attach, re-armed warnings (Task 14)
vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local h = require("tests.helpers")
local c = require("inkmath.config")
local core = require("inkmath.core")
local commands = require("inkmath.commands")
local log = require("inkmath.log")
local status = require("inkmath.status")
local render = require("inkmath.render")
local cache = require("inkmath.render.cache")
require("inkmath")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local match = require("tests.expect").match

local avail = { mathjax = false, tectonic = true }
local stubs = {
  { require("inkmath.term.kitty"), "supported", function() return true end },
  { require("inkmath.term.kitty"), "send", function() end },
  { require("inkmath.term.tmux"), "in_tmux", function() return false end },
  { require("inkmath.term.cells"), "cell_size", function() return { w = 10, h = 20 } end },
  { render, "available", function() return avail end },
  { render, "render", function(n, ctx, cb)
    cb({ key = cache.key(n, ctx, "mathjax"), path = "/stub.png", cols = 1, rows = 1, ratio = 0.5 })
  end },
}
local saved, bufs, notes = {}, {}, {}

local function buf(lines)
  local b = h.buf(lines or { "a $x$ b" }, "markdown")
  bufs[#bufs + 1] = b
  vim.api.nvim_win_set_buf(0, b)
  return b
end

T["status"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for i, s in ipairs(stubs) do saved[i] = s[1][s[2]]; s[1][s[2]] = s[3] end
      saved.notify = vim.notify
      notes = {}
      vim.notify = function(m) notes[#notes + 1] = m end
      avail = { mathjax = false, tectonic = true }
      c.reset()
      vim.o.termguicolors = true
    end,
    post_case = function()
      for _, b in ipairs(bufs) do
        pcall(core.detach, b)
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
      bufs = {}
      require("inkmath.term.images").evict(0, {})
      for i, s in ipairs(stubs) do s[1][s[2]] = saved[i] end
      vim.notify = saved.notify
      c.reset()
      log.rearm()
    end,
  },
})
local S = T["status"]

S["status lists attached"] = function()
  local b = buf()
  core.attach(b, { sync = true })
  local t = status.collect()
  eq(t.attached[1].buf, b)
  eq(t.attached[1].formulas, 1)
  eq(t.backend, { mathjax = false, tectonic = true })
  local text = table.concat(status.format(t), "\n")
  match(text, "workers")
  match(text, "cache: ")
  match(text, "…") -- the cache walk has not finished
  match(text, "kitty ids: ")
end
-- final review #13: the numbers that matter for residency and the fill
S["status shows resident images vs max_images, placed and fill state"] = function()
  c.setup({ max_images = 77, fill = { enabled = false } })
  local b = buf()
  core.attach(b, { sync = true })
  local t = status.collect()
  eq(t.ids.max_images, 77)
  eq(t.attached[1].placed, 1)
  eq(t.attached[1].fill, "off")
  local text = table.concat(status.format(t), "\n")
  match(text, "resident / max_images 77")
  match(text, "1 placed")
  match(text, "fill off")
end
S[":InkMath status prints through nvim_echo"] = function()
  local b = buf()
  core.attach(b, { sync = true })
  local orig, got = vim.api.nvim_echo, nil
  vim.api.nvim_echo = function(chunks) got = chunks end
  commands.run({ fargs = { "status" } })
  vim.wait(1000, function() return got ~= nil end)
  vim.api.nvim_echo = orig
  local text = table.concat(vim.tbl_map(function(ch) return ch[1] end, got or {}), "")
  match(text, "inkmath status")
  match(text, "files")
end
S["clear-cache notifies count"] = function()
  c.setup({ cache_dir = vim.fn.tempname() })
  vim.fn.mkdir(cache.dir(), "p")
  vim.fn.writefile({ "x" }, cache.dir() .. "/a.json")
  vim.fn.writefile({ "x" }, cache.dir() .. "/b.json")
  commands.run({ fargs = { "clear-cache" } })
  match(notes[#notes], "cache cleared %(2 files%)")
end
S["build success re-attaches"] = function()
  avail = { mathjax = false, tectonic = false } -- no backend: attach refuses
  local b = buf()
  eq(core.attach(b, { sync = true }), false)
  local orig = vim.system
  vim.system = function(_, _, cb)
    avail = { mathjax = true, tectonic = false } -- npm ci installed the worker
    cb({ code = 0, stdout = "", stderr = "" })
    return {}
  end
  commands.run({ fargs = { "build" } })
  vim.system = orig
  vim.wait(2000, function() return core.is_attached(b) end)
  eq(core.is_attached(b), true)
  match(table.concat(notes, "\n"), "worker built")
end
S["rearm after fix"] = function()
  log.rearm()
  log.once("backend", "x")
  log.rearm("backend")
  log.once("backend", "x")
  eq(#notes, 2)
end
S["env warnings point at checkhealth and re-arm on FocusGained"] = function()
  avail = { mathjax = false, tectonic = false }
  local b = buf()
  core.attach(b, { sync = true })
  core.attach(b, { sync = true })
  local n = #notes
  match(notes[n], "%(:checkhealth inkmath%)$")
  eq(#vim.tbl_filter(function(m) return m:find("no renderer", 1, true) end, notes), 1) -- once
  vim.api.nvim_exec_autocmds("FocusGained", {})
  core.attach(b, { sync = true })
  eq(#vim.tbl_filter(function(m) return m:find("no renderer", 1, true) end, notes), 2)
  vim.cmd("InkMath refresh")
  core.attach(b, { sync = true })
  eq(#vim.tbl_filter(function(m) return m:find("no renderer", 1, true) end, notes), 3)
end

-- every env warning fits v:echospace in an 80-column terminal: a longer message
-- stops startup at "Press ENTER" (seen in Terminal.app and Alacritty)
S["env warnings fit one 80-column message line"] = function()
  local env = require("inkmath.env")
  local kitty, tmux = require("inkmath.term.kitty"), require("inkmath.term.tmux")
  local saved = { kitty.supported, tmux.in_tmux, tmux.passthrough_enabled, vim.o.termguicolors }
  local cases = {
    function() kitty.supported = function() return false end end,
    function() tmux.in_tmux = function() return true end; tmux.passthrough_enabled = function() return false end end,
    function() avail = { mathjax = false, tectonic = false } end,
    function() vim.o.termguicolors = false end,
  }
  local ok, err = pcall(function()
    for _, setup in ipairs(cases) do
      kitty.supported, tmux.in_tmux, tmux.passthrough_enabled, vim.o.termguicolors = saved[1], saved[2], saved[3], true
      kitty.supported = function() return true end
      tmux.in_tmux = function() return false end
      avail = { mathjax = true, tectonic = true }
      setup()
      log.rearm()
      notes = {}
      env.check()
      eq(#notes, 1)
      eq(#notes[1] <= env.MAX_MSG, true)
    end
  end)
  kitty.supported, tmux.in_tmux, tmux.passthrough_enabled, vim.o.termguicolors = unpack(saved)
  assert(ok, err)
end

return T
