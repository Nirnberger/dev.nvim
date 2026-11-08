local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
T["defaults"] = function()
  local c = require("inkmath.config"); c.setup({})
  local g = c.get()
  eq(g.filetypes, { "tex", "markdown", "quarto", "rmd" }); eq(g.backend, "mathjax"); eq(g.fallback, true)
  eq(g.inline.x_height, 0.45); eq(g.inline.baseline, 0.78); eq(g.inline.promote, false)
  eq(g.preview.debounce_ms, 50); eq(g.debounce_ms, 80); eq(g.max_images, 512)
end
T["deep merge keeps unspecified nested defaults"] = function()
  local c = require("inkmath.config"); c.setup({ inline = { baseline = 0.8 } })
  eq(c.get().inline.baseline, 0.8); eq(c.get().inline.x_height, 0.45)
end
T["invalid backend errors"] = function()
  MiniTest.expect.error(function() require("inkmath.config").setup({ backend = "foo" }) end, "backend")
end
T["conceal options are validated"] = function()
  local c = require("inkmath.config")
  c.setup({})
  eq(c.get().conceal, { level = 2, cursor = "nvic" })
  eq(pcall(c.setup, { conceal = { level = 4 } }), false)
  eq(pcall(c.setup, { conceal = { cursor = "x" } }), false)
  eq(pcall(c.setup, { conceal = { level = 3, cursor = "" } }), true)
  c.setup({})
end
T["vimtex options are validated"] = function()
  local c = require("inkmath.config")
  c.setup({})
  eq(c.get().vimtex, { math_conceal = false })
  eq(pcall(c.setup, { vimtex = { math_conceal = "no" } }), false)
  eq(pcall(c.setup, { vimtex = { math_conceal = true } }), true)
  c.setup({})
end

-- v2: layering (vim.g.inkmath < setup() < overrides[ft]) and the public setup()
local function public() return require("inkmath") end
T["v2"] = MiniTest.new_set({
  hooks = {
    pre_case = function() vim.g.inkmath = nil; require("inkmath.config").reset() end,
    post_case = function() vim.g.inkmath = nil; require("inkmath.config").reset() end,
  },
})
T["v2"]["second setup extends"] = function()
  local c = require("inkmath.config")
  public().setup({ scale = 2 })
  public().setup({ debounce_ms = 40 })
  eq(c.get().scale, 2); eq(c.get().debounce_ms, 40)
end
T["v2"]["failed setup keeps old config and notifies once"] = function()
  local c, notes, orig = require("inkmath.config"), {}, vim.notify
  vim.notify = function(m, l) notes[#notes + 1] = { m, l } end
  public().setup({ scale = 2 })
  local ok = public().setup({ backend = "x", workers = 0 })
  vim.notify = orig
  eq(ok, false); eq(c.get().scale, 2); eq(c.get().backend, "mathjax")
  eq(#notes, 1); eq(notes[1][2], vim.log.levels.ERROR)
  require("tests.expect").match(notes[1][1], "backend.*\n.*workers")
end
T["v2"]["config.setup raises one readable error"] = function()
  local c = require("inkmath.config")
  c.setup({ scale = 2 })
  local ok, err = pcall(c.setup, { backend = "x" })
  eq(ok, false); require("tests.expect").match(err, "^inkmath: invalid config:\n  %- backend")
  eq(c.get().scale, 2)
end
T["v2"]["unknown keys warn"] = function()
  local notes, orig = {}, vim.notify
  vim.notify = function(m, l) notes[#notes + 1] = { m, l } end
  public().setup({ scal = 2 })
  vim.notify = orig
  eq(notes[1][2], vim.log.levels.WARN); require("tests.expect").match(notes[1][1], "did you mean 'scale'")
end
T["v2"]["vim.g.inkmath is the base layer"] = function()
  local c = require("inkmath.config")
  vim.g.inkmath = { scale = 3 }; c.reset()
  eq(c.get().scale, 3)
  c.setup({ scale = 4 }); eq(c.get().scale, 4)
  c.setup({ debounce_ms = 5 }); eq(c.get().scale, 3)
end
T["v2"]["overrides per filetype"] = function()
  local c = require("inkmath.config")
  local md_buf = vim.api.nvim_create_buf(false, true); vim.bo[md_buf].filetype = "markdown"
  local tex_buf = vim.api.nvim_create_buf(false, true); vim.bo[tex_buf].filetype = "tex"
  public().setup({ overrides = { markdown = { scale = 1.5, inline = { baseline = 0.7 } } } })
  eq(c.get(md_buf).scale, 1.5); eq(c.get(tex_buf).scale, 1.0)
  eq(c.get(md_buf).inline.x_height, 0.45); eq(c.get(md_buf).inline.baseline, 0.7)
  public().setup({ overrides = { markdown = { debounce_ms = 9 } } })
  eq(c.get(md_buf).scale, 1.5); eq(c.get(md_buf).debounce_ms, 9)
  local g = c.generation
  public().setup({})
  eq(c.generation, g + 1)
  vim.api.nvim_buf_delete(md_buf, { force = true }); vim.api.nvim_buf_delete(tex_buf, { force = true })
end
T["v2"]["overrides reach the cache key"] = function()
  local md_buf = vim.api.nvim_create_buf(false, true); vim.bo[md_buf].filetype = "markdown"
  local cache, cells = require("inkmath.render.cache"), require("inkmath.term.cells")
  local orig = cells.cell_size
  cells.cell_size = function() return { w = 10, h = 20 } end
  local node = { id = "1", kind = "inline", src = "x", range = { srow = 0, scol = 0, erow = 0, ecol = 1 } }
  local k1 = cache.key(node, require("inkmath.ctx").build(md_buf), "mathjax")
  public().setup({ overrides = { markdown = { scale = 2 } } })
  local k2 = cache.key(node, require("inkmath.ctx").build(md_buf), "mathjax")
  cells.cell_size = orig
  MiniTest.expect.no_equality(k1, k2)
  vim.api.nvim_buf_delete(md_buf, { force = true })
end

T["v2"]["false then table refills the defaults (every layer)"] = function()
  local c = require("inkmath.config")
  vim.g.inkmath = { conceal = false }; c.reset()
  public().setup({ conceal = { level = 1 } })
  eq(c.get().conceal, { level = 1, cursor = "nvic" })
  vim.g.inkmath = nil; c.reset()
  public().setup({ conceal = false })
  public().setup({ conceal = { level = 3 } })
  eq(c.get().conceal, { level = 3, cursor = "nvic" })
  c.reset()
  public().setup({ conceal = false, overrides = { markdown = { conceal = { level = 1 } } } })
  local b = vim.api.nvim_create_buf(false, true); vim.bo[b].filetype = "markdown"
  eq(c.get(b).conceal, { level = 1, cursor = "nvic" })
  eq(c.get().conceal, false)
  vim.api.nvim_buf_delete(b, { force = true })
end
T["v2"]["log.level in vim.g.inkmath filters its own warnings"] = function()
  local c, notes, orig = require("inkmath.config"), {}, vim.notify
  vim.notify = function(m) notes[#notes + 1] = m end
  vim.g.inkmath = { log = { level = "error" }, bogus = 1 }; c.reset()
  c.get()
  vim.notify = orig
  eq(notes, {})
end

return T
