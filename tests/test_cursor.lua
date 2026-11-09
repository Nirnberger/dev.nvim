local helpers = require("tests.helpers")
local images = require("inkmath.term.images")
local placer = require("inkmath.view.placer")
local state = require("inkmath.view.state")
local render = require("inkmath.render")
local cursor = require("inkmath.view.cursor")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local orig_ensure, orig_render
local function marks(buf) return vim.api.nvim_buf_get_extmarks(buf, placer.ns, 0, -1, {}) end

local function node(id, r)
  return { id = id, kind = "inline", src = id, range = { srow = r[1], scol = r[2], erow = r[3], ecol = r[4] } }
end

local ids = {}
local function fake_ensure(img)
  ids[img.key] = ids[img.key] or (#vim.tbl_keys(ids) + 1)
  return ids[img.key]
end

local function setup_buf(lines)
  local buf = helpers.buf(lines, "tex")
  vim.api.nvim_win_set_buf(0, buf)
  state.reset(buf)
  return buf
end

T["cases"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      orig_ensure, orig_render = images.ensure, render.render
      ids = {}
      images.ensure = fake_ensure
      render.render = function(n, _, cb) cb({ key = n.src, path = "/x", cols = 2, rows = 1 }) end
    end,
    post_case = function()
      images.ensure, render.render = orig_ensure, orig_render
      pcall(vim.cmd, "stopinsert")
      pcall(vim.cmd, "only")
    end,
  },
})

T["cases"]["reveal on enter"] = function()
  local buf = setup_buf({ "a $x$ b" })
  local n = node("n1", { 0, 2, 0, 5 })
  placer.place(buf, n, { key = "x", cols = 2, rows = 1 })
  eq(#marks(buf), 1)
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  cursor.update(buf, 0)
  eq(#marks(buf), 0)
  eq(state.get(buf).revealed["n1"] ~= nil, true)
end

T["cases"]["restore on leave"] = function()
  local buf = setup_buf({ "a $x$ b" })
  placer.place(buf, node("n1", { 0, 2, 0, 5 }), { key = "x", cols = 2, rows = 1 })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  cursor.update(buf, 0)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  cursor.update(buf, 0)
  eq(#marks(buf), 1)
  eq(next(state.get(buf).revealed), nil)
  eq(state.get(buf).nodes["n1"] ~= nil, true)
end

T["cases"]["edited revealed node is not restored stale"] = function()
  local buf = setup_buf({ "a $x$ b" })
  placer.place(buf, node("n1", { 0, 2, 0, 5 }), { key = "x", cols = 2, rows = 1 })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  cursor.update(buf, 0)
  vim.api.nvim_buf_set_text(buf, 0, 3, 0, 4, { "xyz" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  cursor.update(buf, 0)
  eq(#marks(buf), 0)
  cursor.forget_stale(buf)
  eq(next(state.get(buf).revealed), nil)
  eq(#marks(buf), 0)
end

T["cases"]["insert mode end inclusive"] = function()
  local buf = setup_buf({ "a $x$ b" })
  placer.place(buf, node("n1", { 0, 2, 0, 5 }), { key = "x", cols = 2, rows = 1 })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  local orig = vim.fn.mode
  vim.fn.mode = function() return "i" end
  cursor.update(buf, 0)
  vim.fn.mode = orig
  eq(#marks(buf), 0)
  eq(state.get(buf).revealed["n1"] ~= nil, true)
end

T["cases"]["end exclusive in normal mode"] = function()
  local buf = setup_buf({ "a $x$ b" })
  placer.place(buf, node("n1", { 0, 2, 0, 5 }), { key = "x", cols = 2, rows = 1 })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  cursor.update(buf, 0)
  eq(#marks(buf), 1)
end

T["cases"]["visual reveals all selected"] = function()
  local buf = setup_buf({ "$x$", "$y$", "z" })
  placer.place(buf, node("n1", { 0, 0, 0, 3 }), { key = "x", cols = 2, rows = 1 })
  placer.place(buf, node("n2", { 1, 0, 1, 3 }), { key = "y", cols = 2, rows = 1 })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_feedkeys("Vj", "x", false)
  cursor.update(buf, 0)
  eq(#marks(buf), 0)
  eq(state.get(buf).revealed["n1"] ~= nil, true)
  eq(state.get(buf).revealed["n2"] ~= nil, true)
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
end

local function float_wins()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then out[#out + 1] = w end
  end
  return out
end

T["cases"]["preview renders without fallback"] = function()
  local buf = setup_buf({ "a $x$ b" })
  local seen
  render.render = function(n, _, cb, opts)
    seen = opts
    cb({ key = n.src, path = "/x", cols = 2, rows = 1 })
  end
  cursor.preview(buf, 0, node("n1", { 0, 2, 0, 5 }), {})
  cursor.close_preview(buf)
  eq(seen and seen.no_fallback, true)
end

T["cases"]["preview opens float"] = function()
  local buf = setup_buf({ "a $x$ b" })
  cursor.preview(buf, 0, node("n1", { 0, 2, 0, 5 }), {})
  local fw = float_wins()
  eq(#fw, 1)
  eq(#vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(fw[1]), 0, -1, false), 1)
  cursor.close_preview(buf)
  eq(#float_wins(), 0)
end

T["cases"]["stale preview dropped"] = function()
  local buf = setup_buf({ "a $x$ b" })
  local calls = 0
  render.render = function(n, _, cb)
    calls = calls + 1
    local img = { key = n.src, path = "/x", cols = 2, rows = 1 }
    if calls == 1 then
      vim.defer_fn(function() cb(img) end, 100)
    else
      cb(img)
    end
  end
  cursor.preview(buf, 0, node("A", { 0, 2, 0, 5 }), {})
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a $xy$ b" })
  cursor.preview(buf, 0, node("B", { 0, 2, 0, 6 }), {})
  vim.wait(250)
  local fw = float_wins()
  eq(#fw, 1)
  local fb = vim.api.nvim_win_get_buf(fw[1])
  local em = vim.api.nvim_buf_get_extmarks(fb, -1, 0, -1, { details = true })
  eq(em[1][4].hl_group, images.hl(ids["B"]))
  cursor.close_preview(buf)
end

T["cases"]["newest request wins without edit"] = function()
  local buf = setup_buf({ "a $x$ b" })
  local calls = 0
  render.render = function(n, _, cb)
    calls = calls + 1
    local img = { key = n.src, path = "/x", cols = 2, rows = 1 }
    if calls == 1 then
      vim.defer_fn(function() cb(img) end, 100)
    else
      cb(img)
    end
  end
  cursor.preview(buf, 0, node("A", { 0, 2, 0, 5 }), {})
  cursor.preview(buf, 0, node("B", { 0, 2, 0, 5 }), {})
  vim.wait(250)
  local fw = float_wins()
  eq(#fw, 1)
  local fb = vim.api.nvim_win_get_buf(fw[1])
  local em = vim.api.nvim_buf_get_extmarks(fb, -1, 0, -1, { details = true })
  eq(em[1][4].hl_group, images.hl(ids["B"]))
  cursor.close_preview(buf)
end

T["cases"]["close invalidates in-flight"] = function()
  local buf = setup_buf({ "a $x$ b" })
  render.render = function(n, _, cb)
    vim.defer_fn(function() cb({ key = n.src, path = "/x", cols = 2, rows = 1 }) end, 50)
  end
  cursor.preview(buf, 0, node("A", { 0, 2, 0, 5 }), {})
  cursor.close_preview(buf)
  vim.wait(150)
  eq(#float_wins(), 0)
end

local function preview_cfg(buf)
  cursor.preview(buf, 0, node("n1", { 0, 2, 0, 5 }), {})
  local w = float_wins()[1]
  return vim.api.nvim_win_get_config(w), w
end

T["cases"]["preview border honours winborder"] = function()
  local buf = setup_buf({ "a $x$ b" })
  local orig = vim.o.winborder
  vim.o.winborder = "single"
  local ok, err = pcall(function() eq(preview_cfg(buf).border[1], "┌") end)
  vim.o.winborder = orig
  cursor.close_preview(buf)
  assert(ok, err)
end

T["cases"]["preview opens with a custom winborder list"] = function()
  local buf = setup_buf({ "a $x$ b" })
  local orig = vim.o.winborder
  vim.o.winborder = "+,-,+,|,+,-,+,|"
  local ok, err = pcall(function() eq(preview_cfg(buf).border[1], "+") end)
  vim.o.winborder = orig
  cursor.close_preview(buf)
  assert(ok, err)
end

T["cases"]["preview border option and highlight"] = function()
  local config = require("inkmath.config")
  config.setup({ preview = { border = "double" } })
  local buf = setup_buf({ "a $x$ b" })
  local cfg, w = preview_cfg(buf)
  local whl = vim.wo[w].winhighlight
  cursor.close_preview(buf)
  config.setup({})
  eq(cfg.border[1], "╔")
  eq(whl, "FloatBorder:InkMathPreviewBorder")
end

T["cases"]["preview position above"] = function()
  local config = require("inkmath.config")
  config.setup({ preview = { position = "above" } })
  local buf = setup_buf({ "", "a $x$ b" })
  cursor.preview(buf, 0, node("n1", { 1, 2, 1, 5 }), {})
  local cfg = vim.api.nvim_win_get_config(float_wins()[1])
  cursor.close_preview(buf)
  config.setup({})
  eq(cfg.anchor, "SW")
  eq(cfg.bufpos, { 1, 2 })
end

-- preview.avoid_text: the float goes where blank lines hold it
T["blank_rows"] = function()
  local lines = { "x", "", "  ", "a $y$", "", "b" }
  eq({ cursor._blank_rows(lines, 0, 3, 3, 0, 5) }, { 2, 1 })
  eq({ cursor._blank_rows(lines, 0, 3, 3, 2, 4) }, { 1, 1 }) -- only visible rows count
  eq({ cursor._blank_rows(lines, 0, 0, 0, 0, 5) }, { 0, 2 }) -- first/last row of the buffer
  eq({ cursor._blank_rows({ "a $y$" }, 0, 0, 0, 0, 0) }, { 0, 0 })
end

local function avoid_cfg(preview, lines, row)
  local config = require("inkmath.config")
  config.setup({ preview = preview })
  local buf = setup_buf(lines)
  cursor.preview(buf, 0, node("n1", { row, 2, row, 5 }), {})
  local cfg = vim.api.nvim_win_get_config(float_wins()[1])
  cursor.close_preview(buf)
  config.setup({})
  return cfg
end

T["cases"]["avoid_text: blank lines above take the float despite position below"] = function()
  local cfg = avoid_cfg({}, { "t", "", "", "", "a $x$ b", "text" }, 4)
  eq(cfg.anchor, "SW")
  eq(cfg.bufpos, { 4, 2 })
end

T["cases"]["avoid_text: blank lines below take the float despite position above"] = function()
  local cfg = avoid_cfg({ position = "above" }, { "text", "a $x$ b", "", "  ", "", "t" }, 1)
  eq(cfg.anchor, "NW")
  eq(cfg.bufpos, { 1, 2 })
end

T["cases"]["avoid_text: configured side first when both fit"] = function()
  local lines = { "t", "", "", "", "a $x$ b", "", "", "", "t" }
  eq(avoid_cfg({}, lines, 4).anchor, "NW")
  eq(avoid_cfg({ position = "above" }, lines, 4).anchor, "SW")
end

T["cases"]["avoid_text: too few blank lines fall back to position"] = function()
  local lines = { "t", "", "a $x$ b", "", "t" } -- image 1 row + border 2 needs 3
  eq(avoid_cfg({}, lines, 2).anchor, "NW")
  eq(avoid_cfg({ position = "above" }, lines, 2).anchor, "SW")
end

T["cases"]["avoid_text: without a border one blank line is enough"] = function()
  local cfg = avoid_cfg({ border = "none" }, { "t", "", "a $x$ b", "text" }, 2)
  eq(cfg.anchor, "SW")
end

T["cases"]["avoid_text = false keeps position"] = function()
  local cfg = avoid_cfg({ avoid_text = false }, { "t", "", "", "", "a $x$ b", "text" }, 4)
  eq(cfg.anchor, "NW")
end

-- Task 13: the preview float shows the TeX error
local function err_render()
  render.render = function(n, _, cb)
    if n.src:find("\\frac{", 1, true) then
      return cb(nil, {
        message = "TeX parse error: Missing close brace after \\frac in the formula you are typing right now",
        backend = "mathjax",
      })
    end
    cb({ key = n.src, path = "/x", cols = 2, rows = 1 })
  end
end
local function float_buf() return vim.api.nvim_win_get_buf(float_wins()[1]) end
local function float_lines() return vim.api.nvim_buf_get_lines(float_buf(), 0, -1, false) end
local function float_hl()
  local ns = vim.api.nvim_get_namespaces()["inkmath_preview"]
  local m = vim.api.nvim_buf_get_extmarks(float_buf(), ns or -1, 0, -1, { details = true })
  return m[1] and m[1][4].hl_group
end

T["cases"]["error replaces stale image"] = function()
  err_render()
  local buf = setup_buf({ "a $x$ b" })
  cursor.preview(buf, 0, node("x^2", { 0, 2, 0, 5 }), {})
  eq(#float_wins(), 1)
  cursor.preview(buf, 0, node("\\frac{", { 0, 2, 0, 5 }), {})
  eq(#float_wins(), 1)
  local lines = float_lines()
  MiniTest.expect.no_equality(lines[1]:match("%S"), nil)
  eq(lines[1]:find("TeX parse error", 1, true), 1)
  eq(#lines <= 3, true)
  eq(float_hl(), "InkMathPreviewError")
  local cfg = vim.api.nvim_win_get_config(float_wins()[1])
  eq(vim.inspect(cfg.title):find("TeX error", 1, true) ~= nil, true)
  eq(cursor.preview_keys(), {}) -- the stale image is no longer shown (evictable)
  cursor.close_preview(buf)
end
-- a preview image deleted from the terminal (its PNG gone at retransmit) closes the
-- float instead of leaving it blank; the caller shows the preview again
T["cases"]["drop_key closes the preview that showed the image"] = function()
  local buf = setup_buf({ "a $x$ b" })
  cursor.preview(buf, 0, node("x", { 0, 2, 0, 5 }), {})
  eq(#float_wins(), 1)
  eq(cursor.drop_key("other"), {})
  eq(#float_wins(), 1)
  eq(cursor.drop_key("x"), { buf })
  eq(#float_wins(), 0)
  eq(cursor.preview_keys(), {})
end

T["cases"]["valid after error shows image again"] = function()
  err_render()
  local buf = setup_buf({ "a $x$ b" })
  cursor.preview(buf, 0, node("\\frac{", { 0, 2, 0, 5 }), {})
  cursor.preview(buf, 0, node("y", { 0, 2, 0, 5 }), {})
  eq(#float_wins(), 1)
  eq(cursor.preview_keys(), { "y" })
  eq(float_hl(), "InkMathImg" .. ids["y"])
  local title = vim.api.nvim_win_get_config(float_wins()[1]).title
  eq(title == nil or vim.inspect(title):find("TeX error", 1, true) == nil, true)
  cursor.close_preview(buf)
end
T["cases"]["error_lines=0 closes"] = function()
  require("inkmath.config").setup({ preview = { error_lines = 0 } })
  err_render()
  local buf = setup_buf({ "a $x$ b" })
  cursor.preview(buf, 0, node("x", { 0, 2, 0, 5 }), {})
  eq(#float_wins(), 1)
  cursor.preview(buf, 0, node("\\frac{", { 0, 2, 0, 5 }), {})
  eq(#float_wins(), 0)
  require("inkmath.config").setup({ preview = { error_lines = 3 } })
end
T["cases"]["error wraps to the window width"] = function()
  local lines = cursor._wrap(("word "):rep(40), 20, 3)
  eq(#lines, 3)
  for _, l in ipairs(lines) do
    eq(vim.fn.strdisplaywidth(l) <= 20, true)
  end
  eq(vim.endswith(lines[3], "…"), true)
  eq(cursor._wrap("short", 20, 3), { "short" })
end

return T
