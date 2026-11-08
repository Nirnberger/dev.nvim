-- Pipeline: autocmds -> detect -> render -> place, plus cursor reveal/preview.
local cache = require("inkmath.render.cache")
local cells = require("inkmath.term.cells")
local conceal = require("inkmath.view.conceal")
local config = require("inkmath.config")
local ctxmod = require("inkmath.ctx")
local cursor = require("inkmath.view.cursor")
local detect = require("inkmath.detect")
local diags = require("inkmath.view.diagnostics")
local incr = require("inkmath.detect.incr")
local rows = require("inkmath.detect.rows")
local folds = require("inkmath.view.folds")
local images = require("inkmath.term.images")
local labels = require("inkmath.labels")
local log = require("inkmath.log")
local mathjax = require("inkmath.render.mathjax")
local placer = require("inkmath.view.placer")
local queue = require("inkmath.render.queue")
local fill = require("inkmath.fill")
local env = require("inkmath.env")
local events = require("inkmath.events")
local registry = require("inkmath.detect.registry")
local render = require("inkmath.render")
local residency = require("inkmath.view.residency")
local state = require("inkmath.view.state")
local vimtex = require("inkmath.vimtex")

local M = {}

M.ns_err = diags.ns
local group = vim.api.nvim_create_augroup("inkmath", { clear = true })

local attached = {} ---@type table<integer, true>
local timers = {} ---@type table<integer, table<string, uv.uv_timer_t>>
local gen = {} ---@type table<integer, integer> bumped when in-flight renders become stale
local last_ctx = {} ---@type table<integer, inkmath.RenderCtx> ctx of the latest refresh
local skipped = {} ---@type table<integer, table> range of the node refresh skipped under the cursor
local parsed_clean = {} ---@type table<integer, true> buffer has had an error-free parse since attach
local folded = {} ---@type table<integer, table<string, integer>> node id -> row, not placed: in a closed fold
local cleared_conceal = {} ---@type table<integer, true> vimtex math conceal cleared (reload on detach)
local globals_done = false
local last_top = {} ---@type table<string, integer> "win:buf" -> topline (0-based) at the last refresh
local last_dir = {} ---@type table<string, integer> "win:buf" -> last scroll direction (1 down, -1 up)
local outstanding = {} ---@type table<integer, integer> buf -> render_node calls not finished
local drain = {} ---@type table<integer, table[]> buf -> scanned row ranges of the refresh awaiting its Render event

M._reset_notified = function() log.rearm() end

--- mode() indirection so tests can simulate insert mode
function M._mode() return vim.fn.mode() end

local function insert_mode() return M._mode():sub(1, 1) == "i" end

--- refresh renders this node at all: its kind is on, and in markdown a display block
--- that only defines macros is not drawn
local function wanted(n, md, kinds)
  return kinds[n.kind == "inline" and "inline" or "display"] and not (md and n.kind ~= "inline" and ctxmod.macro_only(n.src))
end

local guard = log.guard -- never raise into the editing flow

local function same_range(a, b)
  return a.srow == b.srow and a.scol == b.scol and a.erow == b.erow and a.ecol == b.ecol
end

local function keys_for(node, ctx)
  return { cache.key(node, ctx, "mathjax"), cache.key(node, ctx, "tectonic") }
end

--- entry exists at the node's last-detected range, was rendered with this ctx and its
--- marks are intact
local function fresh(buf, entry, node, rnode, ctx)
  if not (entry and same_range(entry.node.range, node.range)) then return false end
  local k = keys_for(rnode, ctx)
  return (entry.img.key == k[1] or entry.img.key == k[2]) and placer.marks_ok(buf, entry)
end

--- Detect the whole buffer (incrementally, see detect/incr; bounded to the scanned
--- rows `want`), ids unique per occurrence; stale: rows whose nodes are old.
local function detect_all(buf, want)
  local nodes, info, stale = incr.detect(buf, want)
  return detect.number(nodes), info, stale or {}
end

---@param buf integer
---@return inkmath.RenderCtx|nil
function M.ctx(buf) return ctxmod.build(buf, log.once) end

local function evict() residency.evict(vim.tbl_keys(attached)) end

local function cur_win(buf)
  local w = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(w) == buf then return w end
  local id = vim.fn.bufwinid(buf)
  return id ~= -1 and id or nil
end

--- A finished render is current when no ColorScheme/resize/detach happened since the
--- request, the buffer is unchanged and the image matches the latest ctx.
local function current(buf, tick, g, rnode, img)
  if not attached[buf] or not vim.api.nvim_buf_is_valid(buf) then return false end
  if vim.b[buf].changedtick ~= tick or gen[buf] ~= g then return false end
  local c = last_ctx[buf]
  if img and c then
    local k = keys_for(rnode, c)
    if img.key ~= k[1] and img.key ~= k[2] then return false end
  end
  return true
end

--- Place (or, when revealed, just remember) a finished render.
local function deliver(buf, node, img)
  if conceal.is_hidden(buf) or folds.hidden(buf, node) then return end
  local s = state.get(buf)
  local rev = s.revealed[node.id]
  if rev then
    rev.node, rev.img = node, img
  else
    placer.place(buf, node, img)
  end
end

local function promote(buf, node, img, ctx, tick)
  local pkey = node.id .. ":promoted"
  local cfg = config.of(ctx)
  if not (cfg.inline.promote and node.kind == "inline" and img.ratio > cfg.inline.promote_ratio) then
    placer.clear(buf, pkey)
    return
  end
  local s = state.get(buf)
  local pnode = { id = pkey, kind = "promoted", src = node.src, range = node.range }
  local dnode = { id = pkey, kind = "display", src = node.src, range = node.range }
  if s.revealed[pkey] or fresh(buf, s.nodes[pkey], pnode, dnode, ctx) then return end
  local g = gen[buf]
  render.render(dnode, ctx, function(pimg)
    guard("promote", function()
      if not pimg or not current(buf, tick, g, dnode, pimg) then return end
      deliver(buf, pnode, pimg)
    end)
  end)
end

-- Per-delivery bookkeeping, coalesced: after a batch of finished renders (one
-- scheduled tick), update the cursor reveal once per buffer and evict once, instead of
-- per render callback (both walk every placed node / resident image).
local tick_bufs = {} ---@type table<integer, true>
local tick_scheduled = false
local function after_deliveries(buf)
  tick_bufs[buf] = true
  if tick_scheduled then return end
  tick_scheduled = true
  vim.schedule(function()
    tick_scheduled = false
    local bs = tick_bufs
    tick_bufs = {}
    for b in pairs(bs) do
      if attached[b] and vim.api.nvim_buf_is_valid(b) then
        local w = cur_win(b)
        if w then guard("cursor", cursor.update, b, w) end
      end
    end
    guard("evict", evict)
  end)
end

local check_drain
--- Render `node` and place it (or, `warm`: only render it to the disk cache, the
--- background fill). `hit`: its cached image, already looked up (placed at once).
---@param done? fun() called once: when the request stops needing a MathJax worker
--- (render's on_stage, before any tectonic fallback) or at the latest when it finished
local function render_node(buf, node, ctx, tick, done, hit, warm)
  local g = gen[buf]
  outstanding[buf] = (outstanding[buf] or 0) + 1
  local function release()
    if done then
      local f = done
      done = nil
      pcall(f)
    end
  end
  local function finish(img, err)
    release()
    outstanding[buf] = math.max(0, (outstanding[buf] or 0) - 1)
    guard("render", function()
      if img and gen[buf] == g then fill.mark(buf, node) end
      if not current(buf, tick, g, node, img) then return end
      if img then
        if not warm then
          deliver(buf, node, img)
          promote(buf, node, img, ctx, tick)
          after_deliveries(buf)
        end
        if diags.clear(buf, node.id) then diags.publish(buf) end
      else
        placer.clear(buf, node.id)
        placer.clear(buf, node.id .. ":promoted")
        diags.set(buf, node, keys_for(node, ctx), err)
        diags.publish(buf)
      end
    end)
    if attached[buf] then
      guard("render", check_drain, buf)
      if warm and (outstanding[buf] or 0) == 0 and not queue.waiting(buf) then fill.kick(buf) end
    end
  end
  if hit then return finish(hit) end
  render.render(node, ctx, finish, done and { on_stage = release } or nil)
end

--- the job can still be placed: same text, generation and ctx as when queued
local function job_ok(buf, job)
  return attached[buf] and vim.api.nvim_buf_is_valid(buf) and gen[buf] == job.g
    and vim.b[buf].changedtick == job.tick and last_ctx[buf] == job.ctx
end
queue.setup({ ok = job_ok, run = function(b, job, done) render_node(b, job.node, job.ctx, job.tick, done, nil, job.warm) end })

--- User InkMathRender, once the latest refresh's queue is empty and its renders finished
function check_drain(buf)
  local scan = drain[buf]
  if not scan or (outstanding[buf] or 0) > 0 or queue.waiting(buf) then return end
  drain[buf] = nil
  local lo, hi = math.huge, -1
  for _, sc in ipairs(scan) do lo, hi = math.min(lo, sc[1]), math.max(hi, sc[2]) end
  events.emit("Render", { buf = buf, placed = vim.tbl_count(state.get(buf).nodes),
    errors = vim.tbl_count(diags.all(buf)), srow = lo, erow = hi })
end

--- Detect, place cached renders and queue the rest for the rows the windows show (plus
--- a screen of margin); clear placements far from them (view/residency). `range`: also
--- render rows [range[1], range[2]] to the disk cache at the lowest priority, at most
--- fill.max_jobs renders not cached (background fill; returns true when it left some
--- for the next step, and the number of renders it queued).
---@param buf integer
---@param range? {[1]: integer, [2]: integer}
---@return boolean|nil capped, integer|nil queued
function M.refresh(buf, range)
  if not attached[buf] or not vim.api.nvim_buf_is_valid(buf) then return end
  cursor.forget_stale(buf)
  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then return end
  if conceal.hidden(buf) then
    -- the user turned conceal off to see the source: hide every image (diagnostics
    -- and caches stay); refresh after 'conceallevel' goes above 0 places them again
    queue.drop(buf)
    placer.clear_all(buf)
    state.get(buf).revealed = {}
    cursor.close_preview(buf)
    return
  end
  local ctx = M.ctx(buf)
  if not ctx then return end
  last_ctx[buf] = ctx
  -- the key of a fixed probe covers every ctx input (macros, colour, cell size, preamble)
  fill.use_ctx(buf, cache.key({ kind = "display", src = "" }, ctx, "tectonic"))
  local s = state.get(buf)
  local tick = vim.b[buf].changedtick
  local last = vim.api.nvim_buf_line_count(buf) - 1
  local views, scanned = {}, {}
  for _, win in ipairs(wins) do
    local info = vim.fn.getwininfo(win)[1]
    local h = vim.api.nvim_win_get_height(win)
    local top, bot = info.topline - 1, info.botline - 1
    views[#views + 1] = { win = win, top = top, bot = bot, lo = math.max(0, top - h), hi = math.min(last, bot + h) }
    scanned[#scanned + 1] = { views[#views].lo, views[#views].hi }
  end
  if range then
    views[#views + 1] = { lo = range[1], hi = math.min(last, range[2]), fill = true }
    scanned[#scanned + 1] = { views[#views].lo, views[#views].hi }
  end
  local all, dinfo, stale = detect_all(buf, scanned)
  if ctx.labels and next(ctx.labels) then
    labels.apply(all, ctx.labels)
  elseif vim.bo[buf].filetype == "tex" and config.get(buf).equation_numbers == "document" then
    labels.number(buf, all)
  end
  -- An unclosed `$`/`{` turns the rest of the document into one ERROR node, so most
  -- formulas below it are not detected. After a clean parse, freeze instead: keep the
  -- existing placements (their extmarks follow the text) and start no renders until
  -- the parse is clean again. Buffers broken since attach never freeze.
  if not dinfo.has_error then parsed_clean[buf] = true end
  local frozen = dinfo.has_error and parsed_clean[buf] == true
  local seen = {}
  local md = (registry.of(buf) or {}).lang == "markdown"
  local kinds = config.get(buf).render -- kinds turned off are cleared like removed nodes
  -- insert mode: the node under the cursor is being typed and the live preview shows
  -- it, so refresh does not render it (on_cursor refreshes once the cursor leaves)
  local crow, ccol
  local cwin = vim.api.nvim_get_current_win()
  if insert_mode() and vim.api.nvim_win_get_buf(cwin) == buf then
    local pos = vim.api.nvim_win_get_cursor(cwin)
    crow, ccol = pos[1] - 1, pos[2]
  end
  skipped[buf] = nil
  folded[buf] = {}
  local jobs = {}
  for _, v in ipairs(views) do
    local win, top, bot, lo, hi = v.win, v.top, v.bot, v.lo, v.hi
    -- scroll direction from the last topline: the screen ahead is prefetched first
    local dir = 1
    if win then
      local wk = win .. ":" .. buf
      local prev = last_top[wk]
      dir = (prev and top < prev) and -1 or (prev and top == prev and last_dir[wk]) or 1
      last_top[wk], last_dir[wk] = top, dir
    end
    --- {class, distance}: 0 visible (top to bottom), 1 the screen ahead, 2 the rest
    --- of the margin, 3 background fill
    local function prio_of(r)
      if v.fill then return { 3, r.srow - lo } end
      if r.srow <= bot and r.erow >= top then return { 0, math.max(0, r.srow - top) } end
      local ahead = (dir > 0) == (r.srow > bot)
      local dist = r.srow > bot and (r.srow - bot) or (top - r.erow)
      return { ahead and 1 or 2, dist }
    end
    for _, node in ipairs(all) do
      if node.range.srow <= hi and node.range.erow >= lo and not seen[node.id] and wanted(node, md, kinds) then
        seen[node.id], seen[node.id .. ":promoted"] = true, true
        local e, er = s.nodes[node.id], diags.get(buf, node.id)
        if v.fill then
          -- background fill: render to the disk cache only (placed when scrolled to)
          if not (frozen or node.stale or er or fill.is_warm(buf, node)) then
            jobs[#jobs + 1] = { node = node, ctx = ctx, tick = tick, g = gen[buf], key = cache.key(node, ctx, "mathjax"),
              prio = prio_of(node.range), warm = true }
          end
        elseif folds.hidden(buf, node) then
          -- closed fold: its first image row would be drawn over the fold line
          placer.clear(buf, node.id)
          s.revealed[node.id] = nil
          folded[buf][node.id] = node.range.srow
        elseif s.revealed[node.id] then
          -- cursor is inside: never place
        elseif fresh(buf, e, node, node, ctx) then
          promote(buf, node, e.img, ctx, tick)
        elseif frozen or node.stale then
          -- no renders while the parse has errors, nor for old nodes of rows that
          -- changed and were not detected again yet
        elseif crow and cursor.contains(node.range, crow, ccol, true) then
          skipped[buf] = node.range
        else
          local mkey = cache.key(node, ctx, "mathjax")
          if not (er and same_range(er.range, node.range) and vim.tbl_contains(er.keys, mkey)) then
            jobs[#jobs + 1] = { node = node, ctx = ctx, tick = tick, g = gen[buf], key = mkey, prio = prio_of(node.range) }
          end
        end
      end
    end
  end
  -- cached renders are placed now, in priority order; the rest replace the queue
  table.sort(jobs, function(a, b)
    if a.prio[1] ~= b.prio[1] then return a.prio[1] < b.prio[1] end
    return a.prio[2] < b.prio[2]
  end)
  local pending, nfill, capped = {}, 0, false
  local max_fill = config.get().fill.max_jobs
  for _, job in ipairs(jobs) do
    local hit = render.cached(job.node, ctx)
    if hit and job.warm then
      fill.mark(buf, job.node)
    elseif hit then
      render_node(buf, job.node, ctx, tick, nil, hit)
    elseif not job.warm or nfill < max_fill then
      nfill = nfill + (job.warm and 1 or 0)
      pending[#pending + 1] = job
    else
      capped = true
    end
  end
  queue.push(buf, pending)
  local function in_scan(r)
    for _, sc in ipairs(scanned) do
      if r.srow <= sc[2] and r.erow >= sc[1] then return true end
    end
  end
  if frozen then
    placer.sync_ranges(buf)
  else
    -- placements and errors of rows still stale stay until those rows are detected
    local function gone(id, r) return not seen[id] and in_scan(r) and not rows.hits(stale, r.srow, r.erow) end
    for id, e in pairs(s.nodes) do
      if gone(id, e.node.range) then placer.clear(buf, id) end
    end
    local changed = false
    for id, e in pairs(diags.all(buf)) do
      if gone(id, e.range) then changed = diags.clear(buf, id) or changed end
    end
    if changed then diags.publish(buf) end
  end
  residency.trim_later(buf, evict)
  local w = cur_win(buf)
  if w then cursor.update(buf, w) end
  evict()
  if range then return capped or dinfo.pending, nfill end
  drain[buf] = scanned
  check_drain(buf)
  if frozen then return end
  -- off-screen work left (stale rows, formulas never rendered): fill in the background
  local left = #stale > 0
  for _, n in ipairs(all) do
    if left then break end
    left = not (s.nodes[n.id] or seen[n.id] or n.stale or fill.is_warm(buf, n) or diags.get(buf, n.id))
      and wanted(n, md, kinds)
  end
  if left then fill.start(buf, #stale > 0, M.refresh) else fill.settled(buf) end
end

local function debounce(buf, which, ms, fn)
  local t = timers[buf]
  if not t then return end
  local tm = t[which]
  if not tm then
    tm = vim.uv.new_timer()
    t[which] = tm
  end
  tm:stop()
  tm:start(ms, 0, vim.schedule_wrap(function() guard(which, fn) end))
end

--- clear the placements whose formula text changed (they would show the old image
--- until the debounced refresh). All of them, not only the windows' views: placements
--- are few (residency keeps them near the windows), and asking a window for its last
--- row (line("w$"), getwininfo) right after an edit computes line heights, which runs
--- the treesitter highlighter's parse synchronously.
local function verify_view(buf)
  placer.verify(buf)
end

local function schedule_refresh(buf, ms)
  debounce(buf, "refresh", ms or config.get(buf).debounce_ms, function() M.refresh(buf) end)
end
local last_event = {} ---@type table<integer, number> buf -> time (ms) of the last edit/scroll
--- An edit (normal mode) or scroll: refresh at once when the buffer was quiet for
--- `debounce_ms` (a jump, `x`, `u`, `p` show their images a debounce sooner), else
--- debounce (held keys, scrolling, typing coalesce into one refresh after the burst).
local function kick_refresh(buf)
  local t, ms = vim.uv.now(), config.get(buf).debounce_ms
  local quiet = t - (last_event[buf] or -math.huge) >= ms
  last_event[buf] = t
  schedule_refresh(buf, quiet and 0 or ms)
end

-- a parse a refresh's detection waited for finished: refresh at once
incr.on_ready(function(buf) if attached[buf] then schedule_refresh(buf, 0) end end)
local on_cursor ---@type fun(buf: integer)
-- an image still placed was deleted: clear it there and place it again; a preview
-- that showed it is rendered again
images.on_drop(function(key)
  for _, b in ipairs(residency.forget_key(vim.tbl_keys(attached), key)) do schedule_refresh(b, 0) end
  for _, b in ipairs(cursor.drop_key(key)) do
    vim.schedule(function()
      if attached[b] and vim.api.nvim_buf_is_valid(b) then guard("preview", on_cursor, b) end
    end)
  end
end)

local function each_attached(fn)
  for b in pairs(attached) do guard("refresh", fn, b) end
end
conceal.on_hidden_change(function(b) guard("refresh", M.refresh, b) end)

local function bump(buf) gen[buf] = (gen[buf] or 0) + 1 end
function M._generation(buf) return gen[buf] or 0 end -- changes when the buffer is detached

--- Run fn() once the syntax tree covers row `row`: right away when it is valid (or
--- the parse finishes within its first 3 ms slice), else when the async parse ends,
--- so a preview after an edit does not block on a full reparse (~10 ms in a large
--- file). Skipped when the text changed meanwhile (that keystroke asks again).
local function after_parse(buf, row, fn)
  local spec = require("inkmath.detect.registry").of(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, spec and spec.lang, { error = false })
  if not (ok and parser) or vim.g._ts_force_sync_parsing then return fn() end
  local tick = vim.b[buf].changedtick
  parser:parse({ row, row }, function()
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].changedtick == tick then guard("preview", fn) end
  end)
end

--- Insert mode inside a node: debounced preview of the freshly detected node.
function on_cursor(buf)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then return end
  cursor.update(buf, win)
  local sk = skipped[buf]
  if sk then
    local pos = vim.api.nvim_win_get_cursor(win)
    if not (insert_mode() and cursor.contains(sk, pos[1] - 1, pos[2], true)) then
      skipped[buf] = nil
      schedule_refresh(buf)
    end
  end
  local cfg = config.get(buf)
  if conceal.is_hidden(buf) or not (cfg.preview.enabled and insert_mode()) then
    return cursor.close_preview(buf)
  end
  debounce(buf, "preview", cfg.preview.debounce_ms, function()
    if not (attached[buf] and vim.api.nvim_win_is_valid(win) and insert_mode()) then return end
    if conceal.is_hidden(buf) then return cursor.close_preview(buf) end
    -- spec §8: no MathJax (node or worker deps missing, or crashed for good) -> no preview
    if not mathjax.start() then return cursor.close_preview(buf) end
    local pos = vim.api.nvim_win_get_cursor(win)
    local row, col = pos[1] - 1, pos[2]
    after_parse(buf, row, function()
      if not (attached[buf] and vim.api.nvim_win_is_valid(win) and insert_mode()) then return end
      if conceal.is_hidden(buf) then return cursor.close_preview(buf) end
      for _, n in ipairs(detect.detect(buf, row, row)) do
        local r = n.range
        local after = row > r.srow or col >= r.scol
        local before = row < r.erow or col <= r.ecol
        if after and before then
          local ctx = M.ctx(buf)
          if ctx then cursor.preview(buf, win, n, ctx) end
          return
        end
      end
      cursor.close_preview(buf)
    end)
  end)
end

M.rearm_env = env.rearm

local function setup_globals()
  if globals_done then return end
  globals_done = true
  cache.auto_prune(10000) -- 10 s after the first attach, when idle
  local function au(ev, fn)
    vim.api.nvim_create_autocmd(ev, { group = group, callback = function() guard(ev[1] or ev, fn) end })
  end
  au({ "ColorScheme" }, function()
    each_attached(function(b)
      -- :hi clear wiped the InkMathImg<id> groups; rebuild every placement
      bump(b)
      placer.clear_all(b)
      state.reset(b)
      M.refresh(b)
    end)
  end)
  au({ "FocusGained" }, function() M.rearm_env() end)
  au({ "VimResized", "FocusGained" }, function()
    cells.refresh()
    images.retransmit_all()
    each_attached(function(b)
      bump(b)
      schedule_refresh(b)
    end)
  end)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    -- CompileSuccess: new aux numbers; both events can load package syntax (vimtex
    -- calls vimtex#syntax#packages#init), which may add math conceal items again
    pattern = { "VimtexEventCompileSuccess", "VimtexEventInitPost" },
    callback = function(ev)
      guard("vimtex", each_attached, function(b)
        if vim.bo[b].filetype ~= "tex" then return end
        -- after vimtex's own handlers (init_post / packages#init) have run
        vim.schedule(function() guard("vimtex", M._vimtex_conceal, b) end)
        if ev.match == "VimtexEventCompileSuccess" then schedule_refresh(b) end
      end)
    end,
  })
  au({ "WinClosed" }, function()
    local w = tonumber(vim.fn.expand("<amatch>"))
    if not w then return end
    local prefix = w .. ":"
    for _, t in ipairs({ folds._sig, last_top, last_dir }) do
      for k in pairs(t) do
        if k:sub(1, #prefix) == prefix then t[k] = nil end
      end
    end
    conceal.forget_win(w)
  end)
  -- folds opened or closed (no event fires): refresh
  folds.watch(function(b)
    if not attached[b] or conceal.is_hidden(b) then return nil end
    local rows_ = {}
    for _, e in pairs(state.get(b).nodes) do
      if folds.overlay(e.node) then rows_[#rows_ + 1] = e.node.range.srow end
    end
    for _, r in pairs(folded[b] or {}) do rows_[#rows_ + 1] = r end
    return rows_
  end, function(b) schedule_refresh(b) end)
  au({ "VimResume" }, function() images.retransmit_all() end)
  au({ "VimLeavePre" }, function()
    images.delete_all() -- only our ids: other programs' images in the terminal stay
    render.shutdown()
  end)
end

--- Clear vimtex's math conceal in this tex buffer (unless configured to keep it).
---@param buf integer
function M._vimtex_conceal(buf)
  if not attached[buf] or vim.bo[buf].filetype ~= "tex" or config.get().vimtex.math_conceal then return end
  if vimtex.clear_math_conceal(buf) then cleared_conceal[buf] = true end
end

--- Attach: cheap checks, autocmds and conceal now; the first refresh is scheduled
--- (opts.sync: run it now, as v1 did; tests and bench).
---@param buf integer
---@param opts? {sync?: boolean}
---@return boolean
function M.attach(buf, opts)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if attached[buf] then return true end
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  if not env.check() then return false end
  setup_globals()
  attached[buf] = true
  timers[buf] = {}
  conceal.apply(buf)
  M._vimtex_conceal(buf)
  local function bau(ev, fn)
    vim.api.nvim_create_autocmd(ev, { group = group, buffer = buf, callback = function() guard(ev[1], fn) end })
  end
  bau({ "TextChanged" }, function()
    fill.cancel(buf)
    verify_view(buf)
    kick_refresh(buf)
  end)
  bau({ "TextChangedI" }, function()
    fill.cancel(buf)
    verify_view(buf)
    last_event[buf] = vim.uv.now()
    schedule_refresh(buf) -- typing: always debounced
  end)
  bau({ "WinScrolled" }, function()
    verify_view(buf)
    kick_refresh(buf)
  end)
  -- no worker runs after a warm open (queue.push starts one for the first render not
  -- cached): the first edit is the likely first miss, so warm one up on InsertEnter
  local warmed = false
  bau({ "InsertEnter" }, function()
    if warmed or config.get(buf).backend == "tectonic" or not mathjax.available() then return end
    warmed = true
    mathjax.warm()
  end)
  bau({ "BufWinEnter" }, function()
    conceal.apply(buf)
    schedule_refresh(buf)
  end)
  bau({ "Syntax" }, function()
    -- someone else (re)loaded the syntax with the user's g:vimtex_syntax_conceal;
    -- our own reload (inside _vimtex_conceal) is skipped, or it would loop
    if vimtex._reloading[buf] then return end
    vim.schedule(function() guard("vimtex", M._vimtex_conceal, buf) end)
  end)
  bau({ "BufEnter" }, function()
    -- the project was compiled outside this buffer (equation numbers may differ)
    if ctxmod.aux_changed(buf, last_ctx[buf]) then schedule_refresh(buf) end
  end)
  bau({ "CursorMoved", "CursorMovedI", "ModeChanged" }, function() on_cursor(buf) end)
  -- :bdelete unloads (extmarks gone, buffer number kept); detach so the FileType
  -- autocmd attaches afresh when the file is loaded again
  bau({ "BufUnload", "BufWipeout" }, function() M.detach(buf) end)
  events.emit("Attach", { buf = buf }) -- before the first Render
  if opts and opts.sync then
    guard("refresh", M.refresh, buf)
  else
    -- the first refresh after this attach returns (opening a file stays fast)
    local g = gen[buf]
    vim.schedule(function()
      if attached[buf] and gen[buf] == g then guard("refresh", M.refresh, buf) end
    end)
  end
  return true
end

---@param buf integer
function M.detach(buf)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local was = attached[buf]
  attached[buf] = nil
  bump(buf)
  last_ctx[buf] = nil
  labels.forget(buf)
  if vim.api.nvim_buf_is_valid(buf) then conceal.restore(buf) end
  conceal.forget_buf(buf)
  for _, tm in pairs(timers[buf] or {}) do
    tm:stop()
    if not tm:is_closing() then tm:close() end
  end
  timers[buf] = nil
  pcall(vim.api.nvim_clear_autocmds, { group = group, buffer = buf })
  if cleared_conceal[buf] and vim.api.nvim_buf_is_loaded(buf) then vimtex.reload_syntax(buf) end
  cleared_conceal[buf] = nil
  folded[buf] = nil
  for _, t in ipairs({ folds._sig, last_top, last_dir }) do
    for k in pairs(t) do
      if k:match(":(%d+)$") == tostring(buf) then t[k] = nil end
    end
  end
  cursor.close_preview(buf)
  placer.clear_all(buf)
  diags.reset(buf)
  queue.drop(buf)
  fill.forget(buf)
  residency.cancel(buf)
  incr.forget(buf)
  parsed_clean[buf] = nil
  skipped[buf], drain[buf], outstanding[buf], last_event[buf] = nil, nil, nil, nil
  state.reset(buf)
  if was then events.emit("Detach", { buf = buf }) end
end

M._fold_sig = folds._sig -- tests

--- (api) the formula with this placement id: placed or revealed, and its render error
---@return boolean rendered, string|nil err
function M._formula_info(buf, id)
  local s, e = state.get(buf), diags.get(buf, id)
  return (s.nodes[id] or s.revealed[id]) ~= nil, e and e.diag.message
end

---@return integer[] attached buffers, sorted
function M.attached_bufs()
  local out = vim.tbl_keys(attached)
  table.sort(out)
  return out
end

---@param buf integer
---@return boolean
function M.is_attached(buf) return attached[buf == 0 and vim.api.nvim_get_current_buf() or buf] == true end

--- Apply a changed config to an attached buffer (conceal options, render keys).
function M.reconfigure(buf)
  if not attached[buf] then return end
  bump(buf)
  conceal.apply(buf)
  guard("refresh", M.refresh, buf)
end

function M.refresh_all() each_attached(M.refresh) end

--- :InkMath clear-cache: delete the disk cache, drop every placement, diagnostic and
--- resident image (their files are gone, so retransmit_all must not send them), then
--- render again.
---@return integer files deleted
function M.clear_cache()
  local n = cache.clear()
  for b in pairs(attached) do
    bump(b)
    cursor.close_preview(b)
    placer.clear_all(b)
    state.reset(b)
    diags.reset(b)
  end
  images.evict(0, {})
  fill.reset_warm()
  M.refresh_all()
  return n
end

return M
