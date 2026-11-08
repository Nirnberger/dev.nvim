local h = require("tests.helpers")
local c = require("inkmath.config")
local enable = require("inkmath.enable")
local api = require("inkmath.api")
local core = require("inkmath.core")
require("inkmath") -- plugin/: :InkMath, FileType autocmd
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local stubs = {
  { require("inkmath.term.kitty"), "supported", function() return true end },
  { require("inkmath.term.tmux"), "in_tmux", function() return false end },
  { require("inkmath.term.cells"), "cell_size", function() return { w = 10, h = 20 } end },
  { require("inkmath.render"), "available", function() return { mathjax = false, tectonic = true } end },
  {
    require("inkmath.render"),
    "render",
    function(n, ctx, cb)
      cb({
        key = require("inkmath.render.cache").key(n, ctx, "mathjax"),
        path = "/stub.png",
        cols = 1,
        rows = 1,
        ratio = 0.5,
      })
    end,
  },
  { vim, "notify", function() end },
}
local saved, bufs = {}, {}

local function buf(lines, ft, show)
  local b = h.buf(lines or { "a $x$ b" }, ft or "markdown")
  bufs[#bufs + 1] = b
  if show ~= false then vim.api.nvim_win_set_buf(0, b) end
  return b
end

--- (re)load plugin/ (test_core deletes its FileType autocmd)
local function reload_plugin()
  vim.g.loaded_inkmath = nil
  vim.cmd.source(vim.api.nvim_get_runtime_file("plugin/inkmath.lua", false)[1])
end

--- run the scheduled FileType attach
local function flush_schedule()
  vim.wait(20, function() return false end)
end

T["policy"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for i, s in ipairs(stubs) do
        saved[i] = s[1][s[2]]
        s[1][s[2]] = s[3]
      end
      reload_plugin()
      vim.g.inkmath_disable = nil
      c.reset()
      enable._reset()
    end,
    post_case = function()
      flush_schedule()
      for _, b in ipairs(bufs) do
        pcall(core.detach, b)
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
      bufs = {}
      for i, s in ipairs(stubs) do
        s[1][s[2]] = saved[i]
      end
      vim.g.inkmath_disable = nil
      c.reset()
      enable._reset()
    end,
  },
})
local P = T["policy"]

P["normal markdown buffer allowed"] = function() eq({ enable.allowed(buf()) }, { true }) end
P["nofile buffer not auto-attached"] = function()
  local b = vim.api.nvim_create_buf(false, true)
  bufs[#bufs + 1] = b
  vim.bo[b].filetype = "markdown"
  eq({ enable.allowed(b) }, { false, "buftype" })
end
P["force bypasses buftype"] = function()
  local b = vim.api.nvim_create_buf(false, true)
  bufs[#bufs + 1] = b
  vim.bo[b].filetype = "markdown"
  eq(enable.allowed(b, { force = true }), true)
end
P["b:inkmath_disable"] = function()
  local b = buf()
  vim.b[b].inkmath_disable = true
  eq({ enable.allowed(b) }, { false, "buffer" })
end
P["g:inkmath_disable"] = function()
  local b = buf()
  vim.g.inkmath_disable = true
  eq({ enable.allowed(b) }, { false, "global" })
end
P["filetype not configured or not registered"] = function()
  c.setup({ filetypes = { "tex" } })
  local b = buf()
  eq({ enable.allowed(b) }, { false, "filetype" })
  eq(enable.allowed(b, { force = true }), true) -- explicit enable: registered is enough
  vim.bo[b].filetype = "text"
  eq({ enable.allowed(b, { force = true }) }, { false, "filetype" })
end
P["enabled predicate"] = function()
  local b = buf()
  c.setup({ enabled = function(x) return x ~= b end })
  eq({ enable.allowed(b) }, { false, "enabled" })
  eq(enable.allowed(buf()), true)
end
P["enabled predicate error counts as false"] = function()
  c.setup({ enabled = function() error("boom") end })
  eq({ enable.allowed(buf()) }, { false, "enabled" })
end
P["enabled per filetype through overrides"] = function()
  c.setup({ overrides = { tex = { enabled = false } } })
  eq(enable.allowed(buf(nil, "markdown")), true)
  eq({ enable.allowed(buf({ "$x$" }, "tex")) }, { false, "enabled" })
end
P["max_file_size"] = function()
  c.setup({ max_file_size = 0.001 })
  local big = buf({ string.rep("x", 2000) })
  eq({ enable.allowed(big) }, { false, "size" })
  eq(enable.allowed(big, { force = true }), true)
end
P["float-only buffer skipped"] = function()
  local b = buf(nil, nil, false)
  local w = vim.api.nvim_open_win(b, false, { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
  eq({ enable.allowed(b) }, { false, "float" })
  vim.api.nvim_win_close(w, true)
end
P["floats keep their window options"] = function()
  local b = buf()
  vim.wo[0].conceallevel = 0
  local w = vim.api.nvim_open_win(b, false, { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
  vim.wo[w].conceallevel = 0
  api.enable(b)
  eq(vim.wo[0].conceallevel, 2)
  eq(vim.wo[w].conceallevel, 0)
  vim.api.nvim_win_close(w, true)
end
P["FileType auto-attaches"] = function()
  local b = buf()
  flush_schedule()
  eq(core.is_attached(b), true)
end
P["FileType skips a guarded buffer"] = function()
  local b = vim.api.nvim_create_buf(false, true)
  bufs[#bufs + 1] = b
  vim.api.nvim_win_set_buf(0, b)
  vim.bo[b].filetype = "markdown"
  flush_schedule()
  eq(core.is_attached(b), false)
end
P[":InkMath enable works on a scratch buffer"] = function()
  local b = vim.api.nvim_create_buf(false, true)
  bufs[#bufs + 1] = b
  vim.api.nvim_win_set_buf(0, b)
  vim.bo[b].filetype = "markdown"
  vim.cmd("InkMath enable")
  eq(core.is_attached(b), true)
end
P["sticky disable survives FileType and :e!"] = function()
  local b = buf()
  api.enable(b)
  vim.cmd("InkMath disable")
  eq(core.is_attached(b), false)
  vim.bo[b].filetype = "markdown"
  flush_schedule()
  eq(core.is_attached(b), false)
  eq({ enable.allowed(b) }, { false, "sticky" })
  vim.cmd("InkMath enable")
  eq(core.is_attached(b), true)
end
P["sticky state is dropped on wipeout"] = function()
  local b = buf()
  enable.set_sticky(b, true)
  vim.api.nvim_buf_delete(b, { force = true })
  local b2 = buf()
  eq(enable.allowed(b2), true)
end
P["setup survives a sticky disable"] = function()
  local b = buf()
  api.disable(b)
  require("inkmath").setup({ scale = 2 })
  eq(core.is_attached(b), false)
end
P["setup re-applies to open buffers"] = function()
  local md_b = buf()
  api.enable(md_b)
  require("inkmath").setup({ filetypes = { "tex" } })
  eq(core.is_attached(md_b), false)
  require("inkmath").setup({ filetypes = { "tex", "markdown" } })
  flush_schedule() -- setup() attaches like FileType: deferred
  eq(core.is_attached(md_b), true)
end
P["setup attaches already-open buffers"] = function()
  vim.api.nvim_clear_autocmds({ group = "inkmath_filetype" }) -- as if the plugin loaded later
  local b = buf()
  local hidden = buf(nil, nil, false)
  require("inkmath").setup({})
  flush_schedule()
  eq(core.is_attached(b), true)
  eq(core.is_attached(hidden), false)
  vim.api.nvim_win_set_buf(0, hidden)
  flush_schedule()
  eq(core.is_attached(hidden), true)
end
P["setup applies new conceal options to attached buffers"] = function()
  local b = buf()
  api.enable(b)
  require("inkmath").setup({ conceal = { level = 1, cursor = "" } })
  eq(vim.wo[0].conceallevel, 1)
end
P[":InkMath! disable / enable are global"] = function()
  local b = buf()
  api.enable(b)
  vim.cmd("InkMath! disable")
  eq(vim.g.inkmath_disable, true)
  eq(core.is_attached(b), false)
  vim.cmd("InkMath! enable")
  eq(vim.g.inkmath_disable, nil)
  eq(core.is_attached(b), true)
  vim.cmd("InkMath! toggle")
  eq(enable.global(), false)
  vim.cmd("InkMath! toggle")
  eq(enable.global(), true)
end
P["global toggle map exists"] = function() eq(vim.fn.maparg("<Plug>(inkmath-toggle-global)", "n") ~= "", true) end

P["setup() inside FileType: a later FileType handler's b:inkmath_disable wins"] = function()
  vim.api.nvim_clear_autocmds({ group = "inkmath_filetype" }) -- lazy.nvim ft= loads the plugin inside FileType
  local g = vim.api.nvim_create_augroup("inkmath_test_ft", { clear = true })
  vim.api.nvim_create_autocmd(
    "FileType",
    { group = g, pattern = "markdown", callback = function() require("inkmath").setup({}) end }
  )
  vim.api.nvim_create_autocmd(
    "FileType",
    { group = g, pattern = "markdown", callback = function(ev) vim.b[ev.buf].inkmath_disable = true end }
  )
  local b = buf(nil, "text")
  vim.bo[b].filetype = "markdown"
  flush_schedule()
  vim.api.nvim_del_augroup_by_id(g)
  eq(core.is_attached(b), false)
end
P["register_filetype attaches open buffers of that filetype"] = function()
  local b = buf({ "$x$" }, "inkmathtestft")
  api.register_filetype("inkmathtestft", { lang = "markdown", detector = "inkmath.detect.markdown", ctx = "markdown" })
  flush_schedule()
  eq(core.is_attached(b), true)
end
P["is_attached(0) is the current buffer"] = function()
  local b = buf()
  api.enable(b)
  eq(core.is_attached(0), true)
end

return T
