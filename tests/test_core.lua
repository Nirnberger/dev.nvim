vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local helpers = require("tests.helpers")
local config = require("inkmath.config")
local core = require("inkmath.core")
require("inkmath") -- registers :InkMath
local cells = require("inkmath.term.cells")
local kitty = require("inkmath.term.kitty")
local tmux = require("inkmath.term.tmux")
local placer = require("inkmath.view.placer")
local state = require("inkmath.view.state")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local sent = {} ---@type string[]
local history = {} ---@type string[] every sequence sent in this file (not reset per case)
local notes = {} ---@type string[]
local orig = {}
local bufs = {}

--- ids of all transmits (a=T) recorded in this case (or in `list`)
local function transmits(list)
  local out = {}
  for _, s in ipairs(list or sent) do
    if s:find("_Ga=T", 1, true) then out[#out + 1] = tonumber(s:match("i=(%d+)")) end
  end
  return out
end

local function marks(buf) return vim.api.nvim_buf_get_extmarks(buf, placer.ns, 0, -1, { details = true }) end

local function inline_marks(buf)
  return vim.tbl_filter(function(m) return m[4].virt_text_pos == "inline" end, marks(buf))
end

local function setup_buf(lines, ft)
  local buf = helpers.buf(lines, ft or "markdown")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  bufs[#bufs + 1] = buf
  return buf
end

--- ids transmitted since `before` (a snapshot of transmits(history)) that were never
--- transmitted earlier in this file; retransmits of resident ids do not count
local function new_ids(before)
  local seen = {}
  for _, id in ipairs(before) do
    seen[id] = true
  end
  local out = {}
  for _, id in ipairs(transmits(history)) do
    if not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  return out
end

T["cases"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      orig.send, orig.supported, orig.in_tmux, orig.cell_size, orig.notify =
        kitty.send, kitty.supported, tmux.in_tmux, cells.cell_size, vim.notify
      sent, notes = {}, {}
      kitty.send = function(s)
        sent[#sent + 1] = s
        history[#history + 1] = s
      end
      kitty.supported = function() return true end
      tmux.in_tmux = function() return false end
      cells.cell_size = function() return { w = 10, h = 20 } end
      vim.notify = function(msg) notes[#notes + 1] = msg end
      config.setup({})
      vim.o.conceallevel, vim.o.concealcursor = 0, ""
      vim.o.termguicolors = true
    end,
    post_case = function()
      for _, b in ipairs(bufs) do
        pcall(core.detach, b)
      end
      bufs = {}
      -- leave the image registry empty for other test files (kitty.send still stubbed)
      require("inkmath.term.images").evict(0, {})
      kitty.send, kitty.supported, tmux.in_tmux, cells.cell_size, vim.notify =
        orig.send, orig.supported, orig.in_tmux, orig.cell_size, orig.notify
      if orig.render then
        require("inkmath.render").render, orig.render = orig.render, nil
      end
      if orig.cached then
        require("inkmath.render").cached, orig.cached = orig.cached, nil
      end
      if orig.mode then
        core._mode, orig.mode = orig.mode, nil
      end
      if orig.start then
        require("inkmath.render.mathjax").start, orig.start = orig.start, nil
      end
      if orig.preview then
        require("inkmath.view.cursor").preview, orig.preview = orig.preview, nil
      end
      config.setup({})
      core._reset_notified()
    end,
  },
})

T["cases"]["attach renders visible math"] = function()
  local buf = setup_buf({ "a $x$ b" })
  eq(core.attach(buf, { sync = true }), true)
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  eq(#inline_marks(buf), 1)
  eq(#transmits(), 1)
end

T["cases"]["edit updates image"] = function()
  local buf = setup_buf({ "a $x$ b" })
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  local before = transmits(history)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a $y$ b" })
  vim.cmd("doautocmd TextChanged")
  vim.wait(15000, function() return #new_ids(before) > 0 end, 20)
  eq(#inline_marks(buf), 1)
  eq(#new_ids(before), 1)
end

T["cases"]["tex error becomes diagnostic"] = function()
  local buf = setup_buf({ "$\\frac{$" })
  core.attach(buf, { sync = true })
  vim.wait(90000, function() return #vim.diagnostic.get(buf, { namespace = core.ns_err }) == 1 end, 50)
  local d = vim.diagnostic.get(buf, { namespace = core.ns_err })
  eq(#d, 1)
  eq(d[1].source, "inkmath")
  eq(d[1].severity, vim.diagnostic.severity.ERROR)
  eq(#marks(buf), 0)
end

T["cases"]["colorscheme change re-renders"] = function()
  local buf = setup_buf({ "a $z^2$ b" })
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  local before = transmits(history)
  local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
  vim.api.nvim_set_hl(0, "Normal", { fg = "#112233" })
  vim.cmd("doautocmd ColorScheme")
  vim.wait(15000, function() return #new_ids(before) > 0 and #inline_marks(buf) == 1 end, 20)
  vim.api.nvim_set_hl(0, "Normal", normal)
  eq(#new_ids(before), 1)
  eq(#inline_marks(buf), 1)
end

T["cases"]["cell size change re-renders"] = function()
  local buf = setup_buf({ "a $w_1$ b" })
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  local before = transmits(history)
  cells.cell_size = function() return { w = 12, h = 24 } end
  vim.cmd("doautocmd VimResized")
  vim.wait(15000, function() return #new_ids(before) > 0 end, 20)
  eq(#new_ids(before), 1)
  eq(#inline_marks(buf), 1)
end

T["cases"]["unsupported terminal does not attach"] = function()
  kitty.supported = function() return false end
  local buf = setup_buf({ "a $x$ b" })
  eq(core.attach(buf, { sync = true }), false)
  vim.wait(200)
  eq(#marks(buf), 0)
  eq(#notes, 1)
  eq(core.attach(buf, { sync = true }), false)
  eq(#notes, 1)
end

T["cases"]["disable clears"] = function()
  local buf = setup_buf({ "a $x$ b" })
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  vim.cmd("InkMath disable")
  eq(#marks(buf), 0)
  eq(next(state.get(buf).nodes), nil)
end

T["cases"]["inline promote"] = function()
  -- \frac{a}{b} renders at ratio ~1.08, so lower the threshold below that
  config.setup({ inline = { promote = true, promote_ratio = 1.0 } })
  local buf = setup_buf({ "a $\\frac{a}{b}$ b", "next" })
  core.attach(buf, { sync = true })
  local function vl()
    return vim.tbl_filter(function(m) return m[4].virt_lines ~= nil and m[2] == 0 end, marks(buf))
  end
  vim.wait(15000, function() return #inline_marks(buf) == 1 and #vl() == 1 end, 20)
  eq(#inline_marks(buf), 1)
  eq(#vl(), 1)
  local promoted = vim.tbl_filter(
    function(k) return k:match(":promoted$") ~= nil end,
    vim.tbl_keys(state.get(buf).nodes)
  )
  eq(#promoted, 1)
end

T["cases"]["refresh never places the node under the cursor"] = function()
  local buf = setup_buf({ "a $q$ b" })
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  vim.cmd("doautocmd CursorMoved")
  eq(#marks(buf), 0)
  core.refresh(buf)
  vim.wait(100)
  eq(#marks(buf), 0)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("doautocmd CursorMoved")
  eq(#inline_marks(buf), 1)
end

T["cases"]["detach clears diagnostics and autocmds"] = function()
  local buf = setup_buf({ "$\\frac{$" })
  core.attach(buf, { sync = true })
  vim.wait(90000, function() return #vim.diagnostic.get(buf, { namespace = core.ns_err }) == 1 end, 50)
  core.detach(buf)
  eq(#vim.diagnostic.get(buf, { namespace = core.ns_err }), 0)
  eq(#vim.api.nvim_get_autocmds({ group = "inkmath", buffer = buf }), 0)
  eq(core.is_attached(buf), false)
end

T["cases"]["markdown macro blocks feed ctx"] = function()
  local buf = setup_buf({ "$$\\newcommand{\\R}{\\mathbb{R}}$$", "", "a $\\R$ b" })
  config.setup({ macros = { foo = "bar" } })
  local ctx = core.ctx(buf)
  eq(ctx.macros.R ~= nil, true)
  eq(ctx.macros.foo, "bar")
  eq(ctx.color:match("^#%x%x%x%x%x%x$") ~= nil, true)
  eq(ctx.cell_w, 10)
end

T["cases"]["duplicate inline formulas each render"] = function()
  local buf = setup_buf({ "$x$ and $x$" })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 2 end, 20)
  eq(#inline_marks(buf), 2)
end

T["cases"]["revealing one duplicate keeps the other"] = function()
  local buf = setup_buf({ "$x$", "$x$", "z" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- outside both formulas
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 2 end, 20)
  eq(#inline_marks(buf), 2)
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  vim.cmd("doautocmd CursorMoved")
  local m = inline_marks(buf)
  eq(#m, 1)
  eq(m[1][2], 1) -- the second occurrence (row 1) stays placed
  eq(vim.tbl_count(state.get(buf).revealed), 1)
end

T["cases"]["stale render after ColorScheme is dropped"] = function()
  local render = require("inkmath.render")
  local cache = require("inkmath.render.cache")
  orig.render = render.render
  local calls = 0
  render.render = function(n, ctx, cb)
    calls = calls + 1
    local img = { key = cache.key(n, ctx, "mathjax"), cols = 1, rows = 1, ratio = 0.5 }
    if calls == 1 then
      img.path = "/old.png"
      vim.defer_fn(function() cb(img) end, 100)
    else
      img.path = "/new.png"
      cb(img)
    end
  end
  local buf = setup_buf({ "a $s$ b" })
  core.attach(buf, { sync = true })
  eq(calls, 1)
  vim.cmd("doautocmd ColorScheme")
  eq(calls, 2)
  vim.wait(300)
  local e = state.get(buf).nodes[next(state.get(buf).nodes)]
  eq(e.img.path, "/new.png")
  eq(#inline_marks(buf), 1)
end

T["cases"]["window options do not leak to other buffers"] = function()
  local buf = setup_buf({ "a $x$ b" })
  core.attach(buf, { sync = true })
  eq(vim.wo.conceallevel, 2)
  vim.cmd("enew")
  eq(vim.wo.conceallevel, 0)
  vim.api.nvim_win_set_buf(0, buf)
  eq(vim.wo.conceallevel, 2)
  core.detach(buf)
  eq(vim.wo.conceallevel, 0) -- previous value restored
end

--- C1: a parse error must not make formulas below it vanish
local function doc_buf()
  local lines = vim.fn.readfile("dev/samples/document.tex")
  vim.o.lines = math.max(vim.o.lines, 60)
  local buf = setup_buf(lines, "tex")
  core.attach(buf, { sync = true })
  vim.wait(30000, function() return vim.tbl_count(state.get(buf).nodes) == 11 end, 20)
  eq(vim.tbl_count(state.get(buf).nodes), 11)
  return buf
end

local function rows_below(buf, row)
  local n = 0
  for _, m in ipairs(marks(buf)) do
    if m[2] > row then n = n + 1 end
  end
  return n
end

local function edit_refresh(buf, row, col, text)
  vim.api.nvim_buf_set_text(buf, row, col, row, col, { text })
  core.refresh(buf)
  vim.wait(200)
end

T["cases"]["unclosed brace keeps formulas below"] = function()
  local buf = doc_buf()
  local before = rows_below(buf, 10)
  assert(before > 0)
  edit_refresh(buf, 10, 22, "\\frac{")
  eq(rows_below(buf, 10), before)
end

T["cases"]["lone dollar keeps formulas below"] = function()
  local buf = doc_buf()
  local before = rows_below(buf, 10)
  edit_refresh(buf, 10, 7, "$")
  eq(rows_below(buf, 10), before)
end

T["cases"]["closing the brace resumes refresh"] = function()
  local buf = doc_buf()
  local before = rows_below(buf, 10)
  edit_refresh(buf, 10, 22, "\\frac{")
  edit_refresh(buf, 10, 28, "a}{b}")
  local function has_frac()
    for _, e in pairs(state.get(buf).nodes) do
      if e.node.src:find("\\frac{a}{b}", 1, true) then return true end
    end
  end
  vim.wait(15000, has_frac, 20)
  eq(has_frac(), true)
  eq(rows_below(buf, 10), before)
  -- unseen clearing works again: removing a formula below drops its marks
  vim.api.nvim_buf_set_lines(buf, 13, 14, false, { "" })
  core.refresh(buf)
  eq(rows_below(buf, 10) < before, true)
end

T["cases"]["cursor reveal works while frozen"] = function()
  local buf = doc_buf()
  local function at(row)
    return vim.tbl_filter(function(m) return m[2] == row end, inline_marks(buf))
  end
  eq(#at(38), 1) -- `$\$5 + x$`
  vim.api.nvim_buf_set_lines(buf, 9, 9, false, { "a lone $ here" }) -- everything shifts down
  core.refresh(buf)
  eq(#at(39), 1)
  vim.api.nvim_win_set_cursor(0, { 40, 37 })
  vim.cmd("doautocmd CursorMoved")
  eq(#at(39), 0) -- revealed at its moved position
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("doautocmd CursorMoved")
  eq(#at(39), 1) -- restored there
end

T["cases"]["buffer broken since attach still refreshes"] = function()
  local buf = setup_buf({ "$\\frac{$ a", "", "$y$" }, "tex")
  core.attach(buf, { sync = true })
  vim.wait(300)
  -- never had a clean parse: unseen nodes are still cleared (no freeze)
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "" })
  core.refresh(buf)
  eq(#inline_marks(buf), 0)
end

T["cases"]["bdelete then edit renders again"] = function()
  local f = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "a $x$ b" }, f)
  require("inkmath").setup({})
  vim.cmd("filetype on")
  vim.cmd("edit " .. vim.fn.fnameescape(f))
  local buf = vim.api.nvim_get_current_buf()
  bufs[#bufs + 1] = buf
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  eq(#inline_marks(buf), 1)
  vim.cmd("bdelete")
  vim.cmd("edit " .. vim.fn.fnameescape(f))
  eq(vim.api.nvim_get_current_buf(), buf)
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  pcall(vim.api.nvim_del_augroup_by_name, "inkmath_filetype")
  eq(#inline_marks(buf), 1)
end

T["cases"]["dd then undo re-places the formula"] = function()
  local buf = setup_buf({ "a", "b $x$ c", "d" })
  vim.bo[buf].undolevels = 100
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("normal! dd")
  vim.cmd("silent normal! u")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  core.refresh(buf)
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  local m = inline_marks(buf)
  eq(#m, 1)
  eq(m[1][2], 1)
  eq(m[1][4].invalid, nil)
end

T["cases"]["insert mode: refresh skips the node under the cursor"] = function()
  local render = require("inkmath.render")
  local cache = require("inkmath.render.cache")
  orig.render, orig.mode, orig.cached = render.render, core._mode, render.cached
  local mode = "i"
  core._mode = function() return mode end
  render.cached = function() end -- an earlier case may have cached "q"
  local rendered = {}
  render.render = function(n, ctx, cb)
    rendered[n.src] = (rendered[n.src] or 0) + 1
    cb({ key = cache.key(n, ctx, "mathjax"), path = "/x.png", cols = 1, rows = 1, ratio = 0.5 })
  end
  local buf = setup_buf({ "a $q$ b $r$" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  core.attach(buf, { sync = true })
  eq(rendered, { r = 1 })
  -- leaving insert mode renders it
  mode = "n"
  vim.cmd("doautocmd ModeChanged")
  vim.wait(1000, function() return rendered.q ~= nil end, 10)
  eq(rendered.q, 1)
end

T["cases"]["preview disabled without mathjax"] = function()
  local mathjax = require("inkmath.render.mathjax")
  local cursor = require("inkmath.view.cursor")
  orig.mode, orig.start, orig.preview = core._mode, mathjax.start, cursor.preview
  core._mode = function() return "i" end
  local started, previews = false, 0
  mathjax.start = function() return started end
  cursor.preview = function() previews = previews + 1 end
  local buf = setup_buf({ "a $x$ b" })
  core.attach(buf, { sync = true })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  vim.cmd("doautocmd CursorMovedI")
  vim.wait(300)
  eq(previews, 0)
  started = true
  vim.cmd("doautocmd CursorMovedI")
  vim.wait(300)
  eq(previews, 1)
end

T["cases"]["conceal options apply to the window"] = function()
  config.setup({ conceal = { level = 3, cursor = "" } })
  local buf = setup_buf({ "a $x$ b" })
  vim.wo.concealcursor = "n"
  core.attach(buf, { sync = true })
  eq(vim.wo.conceallevel, 3)
  eq(vim.wo.concealcursor, "")
end

T["cases"]["warns once without termguicolors"] = function()
  vim.o.termguicolors = false
  local buf = setup_buf({ "a $x$ b" })
  eq(core.attach(buf, { sync = true }), true)
  local b2 = setup_buf({ "c $y$ d" })
  core.attach(b2, { sync = true })
  vim.o.termguicolors = true
  local warns = vim.tbl_filter(function(m) return m:find("termguicolors", 1, true) ~= nil end, notes)
  eq(#warns, 1)
end

T["cases"]["eviction keeps the preview image"] = function()
  local cursor = require("inkmath.view.cursor")
  local render = require("inkmath.render")
  orig.render = render.render
  local png = vim.fn.tempname() .. ".png"
  vim.fn.writefile({ "x" }, png)
  render.render = function(_, _, cb) cb({ key = "preview-key", path = png, cols = 2, rows = 1, ratio = 0.5 }) end
  local buf = setup_buf({ "plain text", "more" })
  core.attach(buf, { sync = true })
  cursor.preview(
    buf,
    vim.api.nvim_get_current_win(),
    { id = "p", kind = "inline", src = "p", range = { srow = 0, scol = 0, erow = 0, ecol = 2 } },
    {}
  )
  local id = require("inkmath.term.images").id("preview-key")
  assert(id)
  config.setup({ max_images = 1 })
  require("inkmath.term.images").ensure({ key = "other-key", path = png, cols = 1, rows = 1, ratio = 0.5 })
  sent = {}
  core.refresh(buf)
  cursor.close_preview(buf)
  local deleted = vim.tbl_filter(function(s) return s:find("a=d", 1, true) ~= nil end, sent)
  eq(#deleted, 1)
  eq(deleted[1]:match("i=(%d+)") ~= tostring(id), true)
end

T["cases"]["clear-cache drops placements and resident images"] = function()
  local buf = setup_buf({ "a $c_1$ b" })
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  vim.cmd("InkMath clear-cache")
  sent = {}
  require("inkmath.term.images").retransmit_all()
  eq(#transmits(), 0) -- nothing left that points at a deleted file
  vim.wait(15000, function() return #inline_marks(buf) == 1 and #transmits() == 1 end, 20)
  eq(#inline_marks(buf), 1)
  local e = state.get(buf).nodes[next(state.get(buf).nodes)]
  eq(vim.uv.fs_stat(e.img.path) ~= nil, true)
end

-- final review #6: a cache hit is read once (render.cached), not again by render()
T["cases"]["a cached formula is read from the cache once per refresh"] = function()
  local buf = setup_buf({ "a $once_1$ b" })
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 1 end, 20)
  local cache = require("inkmath.render.cache")
  placer.clear_all(buf) -- placed again from the cache by the next refresh
  local get, n = cache.get, 0
  cache.get = function(...)
    n = n + 1
    return get(...)
  end
  local ok, e = pcall(core.refresh, buf)
  local hits = n
  cache.get = get
  if not ok then error(e) end
  eq(#inline_marks(buf), 1)
  eq(hits, 1) -- before: cached() and render() each read it
end

-- final review #4: a placed image whose PNG was deleted (prune, outside clear-cache)
-- is not retransmitted to blank cells: its placement is cleared and it renders again
T["cases"]["retransmit with the PNG gone renders the formula again"] = function()
  local render = require("inkmath.render")
  local cache = require("inkmath.render.cache")
  orig.render, orig.cached = render.render, render.cached
  render.cached = function() end
  local png, calls = vim.fn.tempname() .. ".png", 0
  render.render = function(n, ctx, cb)
    calls = calls + 1
    vim.fn.writefile({ "x" }, png)
    cb({ key = cache.key(n, ctx, "mathjax"), path = png, cols = 1, rows = 1, ratio = 0.5 })
  end
  local buf = setup_buf({ "a $gone_1$ b" })
  core.attach(buf, { sync = true })
  eq(#inline_marks(buf), 1)
  eq(calls, 1)
  os.remove(png)
  require("inkmath.term.images").retransmit_all()
  eq(#inline_marks(buf), 0) -- no placeholder left pointing at a deleted image
  vim.wait(2000, function() return #inline_marks(buf) == 1 end, 10)
  eq(#inline_marks(buf), 1)
  eq(calls, 2)
end

-- final review #5: an edit that changes (not deletes) a placed formula's text keeps
-- its extmark valid; the old image is cleared at once, not after the debounce
T["cases"]["an edited formula's old image is cleared before the debounced refresh"] = function()
  local buf = setup_buf({ "a $x$ b", "c $w$ d" })
  core.attach(buf, { sync = true })
  vim.wait(15000, function() return #inline_marks(buf) == 2 end, 20)
  vim.api.nvim_buf_set_text(buf, 0, 3, 0, 4, { "y" })
  vim.cmd("doautocmd TextChanged")
  eq(#inline_marks(buf), 1) -- only the unchanged formula stays placed
  vim.wait(15000, function() return #inline_marks(buf) == 2 end, 20)
  eq(#inline_marks(buf), 2)
end

-- a preview image whose PNG is gone at retransmit closes its float (not left blank)
T["cases"]["retransmit with the preview PNG gone closes the preview"] = function()
  local cursor = require("inkmath.view.cursor")
  local render = require("inkmath.render")
  orig.render = render.render
  local png = vim.fn.tempname() .. ".png"
  vim.fn.writefile({ "x" }, png)
  render.render = function(_, _, cb) cb({ key = "gone-preview", path = png, cols = 2, rows = 1, ratio = 0.5 }) end
  local buf = setup_buf({ "plain text", "more" })
  core.attach(buf, { sync = true })
  cursor.preview(
    buf,
    vim.api.nvim_get_current_win(),
    { id = "p", kind = "inline", src = "p", range = { srow = 0, scol = 0, erow = 0, ecol = 2 } },
    {}
  )
  eq(cursor.preview_keys(), { "gone-preview" })
  os.remove(png)
  require("inkmath.term.images").retransmit_all()
  eq(cursor.preview_keys(), {})
  vim.wait(50, function() return false end, 10) -- the scheduled re-preview runs cleanly
  cursor.close_preview(buf)
end

--- render stub: records each rendered node's src, delivers a 1x1 image at once
local function stub_render(srcs)
  local render = require("inkmath.render")
  local cache = require("inkmath.render.cache")
  orig.render = render.render
  render.render = function(n, ctx, cb)
    srcs[#srcs + 1] = n.src
    cb({ key = cache.key(n, ctx, "mathjax"), path = "/stub.png", cols = 1, rows = 1, ratio = 0.5 })
  end
end

T["cases"]["stale nodes not rendered"] = function()
  local srcs = {}
  stub_render(srcs)
  local lines = { "\\documentclass{article}", "\\begin{document}", "a $x$ b $y$", "" }
  for i = 1, 4000 do
    lines[#lines + 1] = ("Prose %d with $q_{%d}$ in it."):format(i, i)
  end
  lines[#lines + 1] = "\\end{document}"
  local buf = setup_buf(lines, "tex")
  core.attach(buf, { sync = true })
  eq(#inline_marks(buf) > 2, true)
  local before = #srcs
  local n0 = #inline_marks(buf)
  vim.api.nvim_buf_set_text(buf, 2, 4, 2, 4, { "z" }) -- "a $xz$ b $y$"
  local p0 = require("inkmath.detect.incr").stats.pending
  core.refresh(buf)
  if require("inkmath.detect.incr").stats.pending == p0 then return end -- the parse finished at once
  eq(#srcs, before) -- pending: y's row is stale, no render (and x was dropped)
  eq(#inline_marks(buf), n0) -- nothing cleared on stale rows
  vim.wait(2000, function() return vim.tbl_contains(srcs, "xz") end, 10)
  eq(vim.tbl_contains(srcs, "xz"), true)
end

local function aux_project(num)
  local d = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(d .. "/build", "p")
  d = vim.uv.fs_realpath(d)
  vim.fn.writefile({ "\\newlabel{eq:a}{{" .. num .. "}{1}}" }, d .. "/build/main.aux")
  return d
end

local function tagged(srcs, num)
  return vim.tbl_contains(srcs, "\\begin{equation}\\tag{" .. num .. "}\n  a \\label{eq:a}\n\\end{equation}")
end

local function rewrite_aux(d, num, secs)
  local p = d .. "/build/main.aux"
  vim.fn.writefile({ "\\newlabel{eq:a}{{" .. num .. "}{1}}" }, p)
  local st = vim.uv.fs_stat(p)
  vim.uv.fs_utime(p, st.atime.sec, st.mtime.sec + secs)
end

local EQ_DOC =
  { "x", "\\begin{equation}", "  a \\label{eq:a}", "\\end{equation}", "\\begin{equation}", "  b", "\\end{equation}" }

T["cases"]["vimtex: labeled equation renders with its aux number"] = function()
  local srcs = {}
  stub_render(srcs)
  local d = aux_project("3.2")
  local buf = setup_buf(EQ_DOC, "tex")
  vim.b[buf].vimtex = { tex = d .. "/main.tex", root = d, name = "main", compiler = { out_dir = "build" } }
  core.attach(buf, { sync = true })
  eq(tagged(srcs, "3.2"), true)
  eq(vim.tbl_contains(srcs, "\\begin{equation}\n  b\n\\end{equation}"), true) -- unlabeled: unchanged
end

T["cases"]["vimtex: compile success re-reads the aux file"] = function()
  local srcs = {}
  stub_render(srcs)
  local d = aux_project("3.2")
  local buf = setup_buf(EQ_DOC, "tex")
  vim.b[buf].vimtex = { tex = d .. "/main.tex", root = d, name = "main", compiler = { out_dir = "build" } }
  core.attach(buf, { sync = true })
  rewrite_aux(d, "4.1", 5)
  vim.cmd("doautocmd User VimtexEventCompileSuccess")
  vim.wait(1000, function() return tagged(srcs, "4.1") end, 10)
  eq(tagged(srcs, "4.1"), true)
end

T["cases"]["vimtex: BufEnter refreshes only when the aux mtime changed"] = function()
  local srcs = {}
  stub_render(srcs)
  local d = aux_project("1")
  local buf = setup_buf(EQ_DOC, "tex")
  vim.b[buf].vimtex = { tex = d .. "/main.tex", root = d, name = "main", compiler = { out_dir = "build" } }
  core.attach(buf, { sync = true })
  local n = #srcs
  vim.cmd("doautocmd BufEnter")
  vim.wait(300)
  eq(#srcs, n) -- unchanged aux: nothing re-rendered
  rewrite_aux(d, "2", 5)
  vim.cmd("doautocmd BufEnter")
  vim.wait(1000, function() return tagged(srcs, "2") end, 10)
  eq(tagged(srcs, "2"), true)
end

-- without an .aux file the equation gets its document-order number (equation_numbers
-- = "document"); "formula" leaves it alone (MathJax numbers each formula from 1)
T["cases"]["without vimtex labels equations are numbered in document order"] = function()
  local srcs = {}
  stub_render(srcs)
  local buf = setup_buf(EQ_DOC, "tex")
  core.attach(buf, { sync = true })
  eq(vim.tbl_contains(srcs, "\\begin{equation}\\tag{1}\n  a \\label{eq:a}\n\\end{equation}"), true)
end

T["cases"]["equation_numbers = formula leaves equations alone"] = function()
  local srcs = {}
  stub_render(srcs)
  config.setup({ equation_numbers = "formula" })
  local buf = setup_buf(EQ_DOC, "tex")
  core.attach(buf, { sync = true })
  eq(vim.tbl_contains(srcs, "\\begin{equation}\n  a \\label{eq:a}\n\\end{equation}"), true)
end

T["cases"]["conceallevel 0 hides the images, back above 0 re-places them"] = function()
  local srcs = {}
  stub_render(srcs)
  local buf = setup_buf({ "a $x$ b", "", "$$y$$", "", "z" }, "markdown")
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  core.attach(buf, { sync = true })
  local n = #marks(buf)
  eq(n > 1, true)
  vim.wo.conceallevel = 0
  eq(#marks(buf), 0)
  vim.cmd("doautocmd TextChanged")
  vim.wait(300)
  eq(#marks(buf), 0) -- refresh while hidden places nothing
  vim.wo.conceallevel = 2
  eq(#marks(buf), n)
  -- :set (vim.o, as in a global toggle keymap) works the same
  vim.o.conceallevel = 0
  eq(#marks(buf), 0)
  vim.o.conceallevel = 2
  eq(#marks(buf), n)
end

T["cases"]["conceal.level = 0 in setup still places images"] = function()
  config.setup({ conceal = { level = 0, cursor = "" } })
  local srcs = {}
  stub_render(srcs)
  local buf = setup_buf({ "a $x$ b" }, "markdown")
  core.attach(buf, { sync = true })
  eq(#inline_marks(buf), 1)
end

T["cases"]["vimtex math conceal is cleared on attach and after Syntax"] = function()
  local srcs = {}
  stub_render(srcs)
  local vimtex = require("inkmath.vimtex")
  local calls = 0
  orig.clear_conceal = vimtex.clear_math_conceal
  vimtex.clear_math_conceal = function()
    calls = calls + 1
    return true
  end
  local ok, err = pcall(function()
    local buf = setup_buf({ "a $x$ b" }, "tex")
    core.attach(buf, { sync = true })
    eq(calls, 1)
    vim.cmd("doautocmd Syntax")
    vim.wait(200, function() return calls == 2 end, 10)
    eq(calls, 2)
    vimtex._reloading[buf] = true -- our own reload fires Syntax: must not loop
    vim.cmd("doautocmd Syntax")
    vimtex._reloading[buf] = nil
    vim.wait(100)
    eq(calls, 2)
    vim.cmd("doautocmd User VimtexEventInitPost")
    vim.wait(200, function() return calls == 3 end, 10)
    eq(calls, 3)
    calls = 2
    config.setup({ vimtex = { math_conceal = true } })
    local b2 = setup_buf({ "c $y$ d" }, "tex")
    core.attach(b2, { sync = true })
    eq(calls, 2) -- opted out
  end)
  vimtex.clear_math_conceal = orig.clear_conceal
  assert(ok, err)
end

local PH = "\u{10EEEE}" -- kitty unicode placeholder: an image cell on screen

--- screen text of buffer line `lnum` after a redraw: image cells as "#", trailing blanks cut
local function screen_line(lnum)
  vim.cmd("redraw!")
  local p = vim.fn.screenpos(0, lnum, 1)
  local out = {}
  for c = p.col, vim.o.columns do
    local s = vim.fn.screenstring(p.row, c)
    out[#out + 1] = s:find(PH, 1, true) and "#" or s
  end
  return (table.concat(out):gsub("%s+$", ""))
end

-- Vim's own syntax/tex.vim conceals math with replacement characters (^i -> ⁱ, \le -> ≤,
-- \in -> ∈). A syntax item's cchar is drawn even under our conceal = "" extmark, so it
-- stood next to the image and made the line longer (wrapped earlier than it should).
T["cases"]["inline image: no conceal characters of Vim's tex syntax next to it"] = function()
  local render = require("inkmath.render")
  local cache = require("inkmath.render.cache")
  orig.render = render.render
  render.render = function(n, ctx, cb)
    cb({ key = cache.key(n, ctx, "mathjax"), path = "/stub.png", cols = 2, rows = 1, ratio = 0.5 })
  end
  local had_syntax = vim.g.syntax_on ~= nil
  vim.cmd("syntax on")
  local ok, err = pcall(function()
    local line = [[a $e^{i\pi} + 1 \le \alpha$ b \(x \in A\) c $x^2$ d]]
    local buf = setup_buf({ "top", line }, "tex")
    vim.bo[buf].syntax = "tex"
    eq(vim.b[buf].current_syntax, "tex")
    core.attach(buf, { sync = true })
    vim.wait(2000, function() return #inline_marks(buf) == 3 end, 10)
    eq(#inline_marks(buf), 3)
    eq(screen_line(2), "a ## b ## c ## d")
    -- detach gives the user's syntax conceal back (and their 'conceallevel', here 0)
    core.detach(buf)
    vim.wo.conceallevel = 2
    eq(screen_line(2):find("≤", 1, true) ~= nil, true)
  end)
  if not had_syntax then vim.cmd("syntax off") end
  assert(ok, err)
end

--- folds: screen checks via screenstring()/screenpos() after :redraw (headless
--- Neovim keeps a screen grid). The stub image is 2 cols x 3 rows.
local FOLD_DOC = { "x", "\\begin{equation}", "  a", "\\end{equation}", "y", "z" }

-- a normal-mode edit after a quiet spell refreshes at once (no debounce wait); a
-- second edit right after it is debounced (bursts coalesce)
T["cases"]["a quiet normal-mode edit refreshes at once, a burst is debounced"] = function()
  local srcs = {}
  stub_render(srcs)
  config.setup({ debounce_ms = 400 })
  local buf = setup_buf({ "a $q_1$ b" })
  core.attach(buf, { sync = true })
  vim.wait(2000, function() return #inline_marks(buf) == 1 end, 10)
  vim.wait(450, function() return false end, 10) -- quiet for a debounce
  local function edit(to)
    vim.api.nvim_buf_set_text(buf, 0, 3, 0, 6, { to })
    vim.cmd("doautocmd TextChanged")
  end
  edit("q_2")
  eq(vim.wait(150, function() return vim.tbl_contains(srcs, "q_2") end, 5), true)
  edit("q_3") -- within the debounce of the previous edit
  eq(vim.wait(150, function() return vim.tbl_contains(srcs, "q_3") end, 5), false)
  eq(vim.wait(1000, function() return vim.tbl_contains(srcs, "q_3") end, 5), true)
end

local function stub_render_rows(rows)
  local render = require("inkmath.render")
  local cache = require("inkmath.render.cache")
  orig.render = render.render
  render.render = function(n, ctx, cb)
    cb({
      key = cache.key(n, ctx, "mathjax"),
      path = "/stub.png",
      cols = 2,
      rows = n.kind == "inline" and 1 or rows,
      ratio = 0.5,
    })
  end
end

--- screen row (1-based, in the window) of buffer line `lnum`, after a redraw
local function srow(lnum)
  vim.cmd("redraw!")
  return vim.fn.screenpos(0, lnum, 1).row - vim.fn.win_screenpos(0)[1] + 1
end

local function row_has_image(r)
  vim.cmd("redraw!")
  local top = vim.fn.win_screenpos(0)[1]
  for c = 1, vim.o.columns do
    -- the cell holds the placeholder plus its row/column diacritics
    if vim.fn.screenstring(top + r - 1, c):find(PH, 1, true) then return true end
  end
  return false
end

local function fold_buf()
  stub_render_rows(3)
  local buf = setup_buf(FOLD_DOC, "tex")
  vim.wo.foldmethod = "manual"
  vim.wo.foldenable = true
  core.attach(buf, { sync = true })
  vim.cmd("redraw!")
  eq(srow(5), 5) -- open: x, image rows 1..3 (first over \begin, 2 virt_lines), y
  eq(row_has_image(2), true)
  return buf
end

T["cases"]["folds: a closed fold over a display block takes one screen row"] = function()
  local buf = fold_buf()
  vim.cmd("2,4fold")
  vim.wait(500, function() return not row_has_image(2) end, 20)
  eq(vim.fn.foldclosed(2), 2)
  eq(srow(5), 3) -- x, fold line, y: virt_lines are not drawn inside the closed fold
  eq(row_has_image(2), false) -- no image row on the fold line
  eq(row_has_image(3), false)
  eq(vim.api.nvim_buf_is_valid(buf), true)
end

T["cases"]["folds: opening the fold places the image again"] = function()
  local buf = fold_buf()
  vim.cmd("2,4fold")
  vim.wait(500, function() return not row_has_image(2) end, 20)
  vim.cmd("normal! zR")
  vim.wait(1000, function() return row_has_image(2) end, 20)
  eq(row_has_image(2), true)
  eq(srow(5), 5)
  eq(vim.tbl_count(state.get(buf).nodes), 1)
end

T["cases"]["folds: fold starting above the block hides it entirely"] = function()
  fold_buf()
  vim.cmd("1,5fold")
  vim.wait(500, function() return not row_has_image(1) end, 20)
  eq(srow(6), 2) -- fold line, z
  eq(row_has_image(1), false)
end

T["cases"]["folds: a fold inside the block changes nothing"] = function()
  fold_buf()
  vim.cmd("3,4fold") -- rows hidden by conceal_lines anyway
  vim.wait(200)
  eq(srow(5), 5)
  eq(row_has_image(2), true)
end

T["cases"]["folds: inline images on a folded line are not drawn"] = function()
  stub_render_rows(1)
  local buf = setup_buf({ "a $x$ b", "c", "d" }, "tex")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.wo.foldmethod = "manual"
  core.attach(buf, { sync = true })
  eq(row_has_image(1), true)
  vim.cmd("1,2fold")
  vim.wait(200)
  eq(row_has_image(1), false) -- default foldtext: fold line shows no virt_text
  eq(srow(3), 2)
end

T["cases"]["M4: no live preview while images are hidden"] = function()
  local mathjax = require("inkmath.render.mathjax")
  local cursor = require("inkmath.view.cursor")
  orig.mode, orig.start, orig.preview = core._mode, mathjax.start, cursor.preview
  core._mode = function() return "i" end
  mathjax.start = function() return true end
  local previews = 0
  cursor.preview = function() previews = previews + 1 end
  local buf = setup_buf({ "a $x$ b" })
  core.attach(buf, { sync = true })
  vim.wo.conceallevel = 0
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  vim.cmd("doautocmd CursorMovedI")
  vim.wait(300)
  eq(previews, 0)
  vim.wo.conceallevel = 2
  vim.cmd("doautocmd CursorMovedI")
  vim.wait(300)
  eq(previews, 1)
end

T["cases"]["M5: conceallevel set on another buffer's window is noticed"] = function()
  local srcs = {}
  stub_render(srcs)
  local buf = setup_buf({ "a $x$ b", "", "z" }, "markdown")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  core.attach(buf, { sync = true })
  local w1 = vim.api.nvim_get_current_win()
  eq(#inline_marks(buf), 1)
  vim.cmd("new") -- current window shows another buffer
  local w2 = vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value("conceallevel", 0, { scope = "local", win = w1 })
  eq(#inline_marks(buf), 0)
  vim.api.nvim_set_option_value("conceallevel", 2, { scope = "local", win = w1 })
  eq(#inline_marks(buf), 1)
  vim.api.nvim_win_close(w2, true)
end

T["cases"]["M6: fold signatures are dropped when the window closes"] = function()
  local srcs = {}
  stub_render_rows(3)
  local buf = setup_buf(FOLD_DOC, "tex")
  core.attach(buf, { sync = true })
  vim.cmd("split")
  local w = vim.api.nvim_get_current_win()
  vim.cmd("redraw!")
  eq(core._fold_sig[w .. ":" .. buf] ~= nil, true)
  vim.api.nvim_win_close(w, true)
  eq(core._fold_sig[w .. ":" .. buf], nil)
  eq(srcs, {})
end

T["cases"]["M10: a user's conceallevel 0 survives switching buffers"] = function()
  local srcs = {}
  stub_render(srcs)
  local buf = setup_buf({ "a $x$ b", "", "z" }, "markdown")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  core.attach(buf, { sync = true })
  -- typed, as the user's toggle is (view/conceal: only typed writes stick)
  vim.api.nvim_feedkeys(vim.keycode(":setlocal conceallevel=0<CR>"), "xt", false)
  eq(#inline_marks(buf), 0)
  vim.cmd("enew")
  vim.api.nvim_win_set_buf(0, buf)
  eq(vim.wo.conceallevel, 0) -- BufWinEnter no longer forces the configured level
  core.refresh(buf)
  eq(#inline_marks(buf), 0)
  vim.wo.conceallevel = 2
  eq(#inline_marks(buf), 1)
  vim.cmd("enew")
  vim.api.nvim_win_set_buf(0, buf)
  eq(vim.wo.conceallevel, 2)
  eq(#inline_marks(buf), 1)
  -- off in this buffer, back on while the window shows another one: on again here
  vim.o.conceallevel = 0
  vim.cmd("enew")
  vim.o.conceallevel = 2
  vim.api.nvim_win_set_buf(0, buf)
  eq(vim.wo.conceallevel, 2)
  vim.wait(1000, function() return #inline_marks(buf) == 1 end, 10) -- BufWinEnter refresh
  eq(#inline_marks(buf), 1)
end

T["health parser check rejects unknown language"] = function()
  local health = require("inkmath.health")
  local ok, err = health._parser_ok("inkmath_no_such_lang")
  eq(ok, false)
  eq(type(err), "string")
  eq(health._parser_ok("markdown"), true)
end

T["cases"]["render.inline = false places no inline"] = function()
  config.setup({ render = { inline = false } })
  local srcs = {}
  stub_render(srcs)
  local buf = setup_buf({ "a $x$ b", "", "$$y$$", "" })
  core.attach(buf, { sync = true })
  eq(srcs, { "y" })
  eq(#inline_marks(buf), 0)
end

T["cases"]["render.display = false places no display"] = function()
  local srcs = {}
  stub_render(srcs)
  local buf = setup_buf({ "a $x$ b", "", "$$y$$", "" })
  core.attach(buf, { sync = true })
  eq(#marks(buf) > 1, true)
  config.setup({ render = { display = false } })
  core.refresh(buf)
  eq(#marks(buf), #inline_marks(buf))
  eq(#inline_marks(buf), 1)
end

T["cases"]["max_formula_len"] = function()
  config.setup({ max_formula_len = 5 })
  local buf = setup_buf({ "a $abcdefgh$ b" })
  core.attach(buf, { sync = true })
  local d = vim.diagnostic.get(buf, { namespace = core.ns_err })
  eq(#d, 1)
  require("tests.expect").match(d[1].message, "too long")
end

-- With 'conceallevel' > 0 the TS highlighter parses once per screen row in the redraw
-- after an edit (conceal_lines queries); TextChanged* run before it and parse the
-- windows' rows in one call, so those per-row parses find a valid tree.
T["cases"]["edit with TS highlighter and conceal: view parsed before the redraw"] = function()
  local lines = {}
  for i = 1, 600 do
    lines[#lines + 1] = i % 2 == 0 and ("Para %d has $a_{%d}$ math."):format(i, i) or "Plain text."
  end
  local buf = setup_buf(lines)
  vim.treesitter.start(buf, "markdown")
  local hl = vim.treesitter.highlighter.active[buf]
  if not (hl and hl._conceal_line) then MiniTest.skip("highlighter without conceal_lines") end
  core.attach(buf, { sync = true })
  eq(vim.wo.conceallevel > 0, true)
  vim.api.nvim_win_set_cursor(0, { 300, 0 })
  vim.cmd("normal! zz")
  vim.cmd("redraw")
  local top = vim.fn.line("w0") - 1
  local view = { { top, vim.fn.line("w$") - 1 } }
  local parser = vim.treesitter.get_parser(buf)
  local function edit()
    vim.api.nvim_buf_set_text(buf, 299, 0, 299, 0, { "$y$ " })
    eq(parser:is_valid(false, view), false)
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf, modeline = false })
  end
  edit()
  eq(parser:is_valid(false, view), true)
  -- the redraw's per-row parses: no reparse left (each returns at once)
  local LT = getmetatable(parser).__index
  local p, slow = LT.parse, 0
  LT.parse = function(self, ...)
    local valid = self:is_valid(false, (...))
    if not valid then slow = slow + 1 end
    return p(self, ...)
  end
  local ok, err = pcall(vim.cmd, "redraw")
  LT.parse = p
  assert(ok, err)
  eq(slow, 0)
  -- conceal off in the window: the highlighter parses async, nothing done here
  vim.wo.conceallevel = 0
  edit()
  eq(parser:is_valid(false, view), false)
end

-- the view parse is an optimisation on private highlighter API: when it throws (another
-- Neovim version), the edit's refresh still comes
T["cases"]["edit with TS highlighter and conceal: a failing view parse still refreshes"] = function()
  local lines = {}
  for i = 1, 200 do
    lines[#lines + 1] = ("Para %d has $a_{%d}$ math."):format(i, i)
  end
  local buf = setup_buf(lines)
  vim.treesitter.start(buf, "markdown")
  local hl = vim.treesitter.highlighter.active[buf]
  if not (hl and hl._conceal_line) then MiniTest.skip("highlighter without conceal_lines") end
  core.attach(buf, { sync = true })
  local tree = hl.tree
  local refreshed = 0
  local orig_refresh = core.refresh
  core.refresh = function(...)
    refreshed = refreshed + 1
    return orig_refresh(...)
  end
  tree.parse = function() error("parse API changed") end -- instance field shadows the method
  local ok, err = pcall(function()
    for _, ev in ipairs({ "TextChanged", "TextChangedI" }) do
      refreshed = 0
      vim.api.nvim_buf_set_text(buf, 10, 0, 10, 0, { "x" })
      vim.api.nvim_exec_autocmds(ev, { buffer = buf, modeline = false })
      -- the debounced refresh (TextChangedI: after debounce_ms) runs
      eq(vim.wait(5000, function() return refreshed > 0 end, 5), true)
    end
  end)
  tree.parse = nil
  core.refresh = orig_refresh
  if not ok then error(err, 0) end
end

return T
