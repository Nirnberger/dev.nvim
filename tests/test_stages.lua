-- Render stages: the queue's worker slots are freed when the MathJax stage ends (no
-- head-of-line blocking behind tectonic), tectonic work batches, and the MathJax
-- stage is shared by the normal and the live-preview flow.
vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local cells = require("inkmath.term.cells")
local config = require("inkmath.config")
local core = require("inkmath.core")
local queue = require("inkmath.render.queue")
local kitty = require("inkmath.term.kitty")
local mathjax = require("inkmath.render.mathjax")
local render = require("inkmath.render")
local state = require("inkmath.view.state")
local tectonic = require("inkmath.render.tectonic")
local tmux = require("inkmath.term.tmux")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local orig, bufs = {}, {}

T["stages"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      orig.send, orig.supported, orig.in_tmux, orig.cell_size = kitty.send, kitty.supported, tmux.in_tmux, cells.cell_size
      orig.submit, orig.available, orig.run, orig.request = tectonic.submit, tectonic.available, tectonic._run, mathjax.request
      orig.lines, orig.notify = vim.o.lines, vim.notify
      kitty.send = function() end
      kitty.supported = function() return true end
      tmux.in_tmux = function() return false end
      cells.cell_size = function() return { w = 10, h = 20 } end
      vim.notify = function() end
      vim.o.termguicolors = true
      vim.o.lines = 70
      config.setup({})
    end,
    post_case = function()
      for _, b in ipairs(bufs) do pcall(core.detach, b) end
      bufs = {}
      queue.reset()
      require("inkmath.term.images").evict(0, {})
      kitty.send, kitty.supported, tmux.in_tmux, cells.cell_size = orig.send, orig.supported, orig.in_tmux, orig.cell_size
      tectonic.submit, tectonic.available, tectonic._run, mathjax.request = orig.submit, orig.available, orig.run, orig.request
      vim.o.lines, vim.notify = orig.lines, orig.notify
      config.setup({})
    end,
  },
})

local function open(lines)
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "tex"
  vim.api.nvim_win_set_buf(0, b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  bufs[#bufs + 1] = b
  return b
end

local function placed(buf, pat)
  local n = 0
  for _, e in pairs(state.get(buf).nodes) do
    if e.node.src:match(pat) then n = n + 1 end
  end
  return n
end

T["stages"]["MathJax renders are not delayed behind pending tectonic fallbacks"] = function()
  local held = 0
  tectonic.available = function() return true end
  tectonic.submit = function() held = held + 1 end -- fallbacks never finish
  local salt = tostring(vim.uv.hrtime())
  local lines = { "\\documentclass{article}", "\\begin{document}" }
  -- \textsc is not MathJax: these go to the fallback, and come first (top of the view)
  for i = 1, 12 do lines[#lines + 1] = ("Fb %d $\\textsc{ab%d%s}$ x."):format(i, i, salt) end
  for i = 1, 30 do lines[#lines + 1] = ("Mj %d $y_{%d}^{%s}$ x."):format(i, i, salt) end
  lines[#lines + 1] = "\\end{document}"
  local buf = open(lines)
  core.attach(buf, { sync = true })
  vim.wait(20000, function() return placed(buf, "^y_") == 30 end, 10)
  eq(placed(buf, "^y_"), 30)
  eq(held, 12)
end

T["stages"]["backend = tectonic: the visible formulas go into few tectonic runs"] = function()
  config.setup({ backend = "tectonic" })
  local runs = 0
  tectonic._run = function(cmd, cb)
    if cmd[1]:find("tectonic", 1, true) then runs = runs + 1 end
    return orig.run(cmd, cb)
  end
  local salt = tostring(vim.uv.hrtime())
  local lines = { "\\documentclass{article}", "\\begin{document}" }
  for i = 1, 24 do lines[#lines + 1] = ("Text %d $x_{%d}^{%s}$ end."):format(i, i, salt) end
  lines[#lines + 1] = "\\end{document}"
  local buf = open(lines)
  core.attach(buf, { sync = true })
  vim.wait(120000, function() return placed(buf, "^x_") == 24 end, 50)
  eq(placed(buf, "^x_"), 24)
  MiniTest.expect.equality(runs <= 3, true)
end

T["stages"]["preview and normal render of the same node share one worker request"] = function()
  local requests = 0
  mathjax.request = function(...)
    requests = requests + 1
    return orig.request(...)
  end
  local node = { id = "p", kind = "inline", src = "p_{" .. vim.uv.hrtime() .. "}", range = { srow = 0, scol = 0, erow = 0, ecol = 1 } }
  local ctx = { color = "#c0caf5", cell_w = 10, cell_h = 20, container_px = 800, macros = {} }
  local got = {}
  render.render(node, ctx, function(img) got[#got + 1] = img end)
  render.render(node, ctx, function(img) got[#got + 1] = img end, { no_fallback = true })
  vim.wait(15000, function() return #got == 2 end, 10)
  eq(requests, 1)
  eq(#got, 2)
  eq(got[1].path, got[2].path)
end

return T
