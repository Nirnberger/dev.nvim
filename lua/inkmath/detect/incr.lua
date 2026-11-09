-- Incremental whole-buffer detection.
--
-- Keeps the previous detection of each buffer and re-detects only the dirty rows:
-- * rows touched by edits (nvim_buf_attach on_bytes; the previous nodes are shifted
--   like extmarks, nodes touched by an edit are dropped),
-- * rows whose syntax tree changed (the LanguageTree's on_changedtree ranges, e.g.
--   a new `$` re-pairing the rest of the paragraph, a new comment or environment),
-- * expanded until no node crosses the boundary (old nodes overlapping the range and
--   re-detected nodes extending past it pull it wider), and in markdown to the
--   surrounding blank lines (inline math never crosses a paragraph).
--
-- Keystroke fast paths (see detect(); `want` = the rows refresh scans):
-- * precheck skip: edited rows whose text has no trigger (detect/precheck), on which
--   no known formula or `$$` line lies, and no tree change outside them: the previous
--   nodes are only shifted; no parse, no query. In markdown the trigger scan covers
--   the edited rows' whole paragraphs (blank-line bounded): removing a block marker
--   (`# `, `> `) or filling a blank line joins paragraphs, and their `$` re-pair.
--   Only pure insertions skip: the scan cannot see removed text (a deleted
--   `\begin{comment}` line, a `\` or a fence), so an edit that removed any is detected.
-- * parse-free: a valid tree is not parsed again. With `want`, an invalid tree is not
--   parsed synchronously: in markdown with the treesitter highlighter active, its own
--   parse comes (on_changedtree then calls the on_ready handler once); otherwise an
--   async parse (3 ms slices) runs and calls it when done. Meanwhile the
--   previous nodes are returned and the dirty rows are reported stale.
-- * with `want`, the "large" and markdown "dollar" fallbacks re-detect only the
--   wanted rows (plus whole changed `$$` pairs they intersect); the rest stays stale
--   (old nodes kept, flagged `stale`) until a later detect wants it.
-- Falls back to a full detect when there is no previous result, the tree has errors
-- (now or before), the edit list is large, or the buffer was reloaded; without
-- `want` also on a large dirty range or a re-paired `$$` (full equivalence).
local detect = require("inkmath.detect")
local precheck = require("inkmath.detect.precheck")
local rows = require("inkmath.detect.rows")

local M = {}

local MAX_EDITS = 64
local MAX_TOUCHED = 64 -- edited rows the precheck looks at; more: no skip
local MAX_PARAGRAPH = 300 -- markdown precheck: rows of the edited paragraphs
local FALLBACK_MS = 200 -- pending on the highlighter: parse ourselves after this

---@class inkmath.IncrState
---@field nodes inkmath.MathNode[]|nil pristine nodes of the last detection
---@field pairs integer[][] markdown: `$$` block row pairs (markdown.block_pairs), shifted
---@field has_error boolean the parse tree was broken at the last detection (tree_error): no incremental work
---@field freeze boolean the last detection could not recover (info.has_error)
---@field tick integer
---@field edits table[]
---@field dirty {[1]: integer, [2]: integer}|nil row range, current coordinates
---@field tree {[1]: integer, [2]: integer}|nil rows of on_changedtree ranges (part of dirty)
---@field touched table<integer, true>|false rows edited since the last detect (false: too many)
---@field dropped boolean an edit touched a known node or `$$` line
---@field removed boolean an edit since the last detect removed text (never skipped)
---@field pair_hit boolean an edit touched a `$$` line
---@field stale {[1]: integer, [2]: integer}[] rows not re-detected since they changed
---@field pending boolean waiting for a parse (highlighter or async)
---@field force_sync boolean the highlighter did not parse in time: parse ourselves
---@field full boolean
---@field dead boolean
---@field parser table|nil parser whose on_changedtree feeds `dirty`
local states = {} ---@type table<integer, inkmath.IncrState>

-- counters (tests, bench)
M.stats = { full = 0, incr = 0, reuse = 0, skip = 0, pending = 0 }

local ready = function(_) end
--- fn(buf) runs (scheduled) once a parse a pending detect waited for has finished:
--- detect again (core refreshes).
---@param fn fun(buf: integer)
function M.on_ready(fn) ready = fn end

local function notify_ready(buf, st)
  if not st.pending then return end
  st.pending = false
  if st.timer then
    st.timer:stop()
    st.timer:close()
    st.timer = nil
  end
  vim.schedule(function()
    if states[buf] == st and not st.dead then pcall(ready, buf) end
  end)
end

local function lang_of(buf)
  local spec = require("inkmath.detect.registry").of(buf)
  return spec and spec.lang
end

local function hull(r, a, b)
  if a > b then
    a, b = b, a
  end
  if r then return { math.min(r[1], a), math.max(r[2], b) } end
  return { a, b }
end

local function add_dirty(st, a, b) st.dirty = hull(st.dirty, a, b) end

--- position (row, col) after an edit, for a position at or after the old end
local function shift_pos(row, col, e)
  if row == e.oer then return e.ner, e.nec + (col - e.oec) end
  return row + (e.ner - e.oer), col
end

local function before(r1, c1, r2, c2) return r1 < r2 or (r1 == r2 and c1 < c2) end

local function shift_hull(r, e)
  if not r then return nil end
  local s = rows.shift({ r }, e)[1]
  return s and { s[1], s[2] }
end

--- apply one edit to the previous nodes, the `$$` rows, the touched rows and the
--- dirty/tree/stale ranges
local function apply_edit(st, e)
  local keep = {}
  for _, n in ipairs(st.nodes) do
    local r = n.range
    if before(r.erow, r.ecol, e.sr, e.sc) then
      keep[#keep + 1] = n
    elseif before(e.oer, e.oec, r.srow, r.scol) then
      local sr, sc = shift_pos(r.srow, r.scol, e)
      local er, ec = shift_pos(r.erow, r.ecol, e)
      n.range = { srow = sr, scol = sc, erow = er, ecol = ec }
      keep[#keep + 1] = n
    else
      -- touched: drop it and re-detect its rows (mapped into new coordinates)
      local er = r.erow > e.oer and (r.erow + e.ner - e.oer) or e.ner
      add_dirty(st, math.min(r.srow, e.sr), er)
      st.dropped = true
    end
  end
  st.nodes = keep
  local pairs_ = {}
  for _, p in ipairs(st.pairs) do
    local q = {}
    for k, row in ipairs(p) do
      if row < e.sr then
        q[k] = row
      elseif row > e.oer then
        q[k] = row + e.ner - e.oer
      else
        q[k] = e.sr -- a `$$` line was edited: the pairs differ now (see "dollar")
        st.dropped, st.pair_hit = true, true
      end
    end
    pairs_[#pairs_ + 1] = q
  end
  st.pairs = pairs_
  st.dirty, st.tree = shift_hull(st.dirty, e), shift_hull(st.tree, e)
  st.stale = rows.shift(st.stale, e)
  if st.touched then
    local t = {}
    local n = 0
    for row in pairs(st.touched) do
      local r = row < e.sr and row or row > e.oer and row + e.ner - e.oer or nil
      if r then
        t[r] = true
        n = n + 1
      end
    end
    for row = e.sr, e.ner do
      t[row] = true
      n = n + 1
    end
    st.touched = n <= MAX_TOUCHED and t
  end
  add_dirty(st, e.sr, e.ner)
end

--- apply queued edits (before anything in current coordinates is added)
local function flush(st)
  if not st.nodes or st.full then
    st.edits = {}
    return
  end
  local edits = st.edits
  st.edits = {}
  for _, e in ipairs(edits) do
    apply_edit(st, e)
  end
end

--- on_bytes for the state `st` it was attached for: a later state of the buffer
--- (forget + re-detect, or a language change) has its own attachment, so this one
--- detaches itself instead of feeding the new state a second copy of every edit.
local function bytes_cb(st)
  return function(_, buf, _, sr, sc, _, oer, oec, _, ner, nec)
    if states[buf] ~= st or st.dead then return true end
    if st.full or not st.nodes then return end
    if #st.edits >= MAX_EDITS then
      st.full = true
      st.edits = {}
      return
    end
    -- the trigger scan sees only the text after the edit: one that removed text (maybe
    -- a `\begin{comment}` or a `\\`) is never skipped (can_skip)
    if oer > 0 or oec > 0 then st.removed = true end
    st.edits[#st.edits + 1] = {
      sr = sr,
      sc = sc,
      oer = sr + oer,
      oec = oer == 0 and sc + oec or oec,
      ner = sr + ner,
      nec = ner == 0 and sc + nec or nec,
    }
  end
end

local function ensure_attached(buf, st)
  if st.attached then return end
  st.attached = vim.api.nvim_buf_attach(buf, false, {
    on_bytes = bytes_cb(st),
    on_reload = function()
      if states[buf] ~= st or st.dead then return true end
      st.full = true
    end,
    on_detach = function() st.attached = false end,
  })
end

-- one on_changedtree registration per parser (callbacks cannot be removed): it feeds
-- whichever live state of the buffer uses that parser
local registered = setmetatable({}, { __mode = "k" }) ---@type table<table, true>

local function ensure_cbs(buf, st, parser)
  if st.parser == parser then return end
  -- another parser instance (filetype or parser reset): its tree is not the one the
  -- previous detection came from
  if st.parser then st.full = true end
  st.parser = parser
  if registered[parser] then return end
  registered[parser] = true
  -- recursive: changed injected trees (markdown_inline) mark their rows dirty too
  parser:register_cbs({
    on_changedtree = function(changes)
      local s = states[buf]
      if not s or s.dead or s.parser ~= parser then return end
      flush(s) -- the ranges are in current coordinates
      for _, c in ipairs(changes) do
        -- Range4 {srow, scol, erow, ecol} or Range6 {srow, scol, sbyte, erow, ecol, ebyte}
        local a, b = c[1], #c >= 6 and c[4] or c[3]
        add_dirty(s, a, b)
        s.tree = hull(s.tree, a, b)
      end
      notify_ready(buf, s) -- the highlighter parsed for a pending detect
    end,
  }, true)
end

local function copy(nodes, stale)
  local out = {}
  for i, n in ipairs(nodes) do
    local r = n.range
    out[i] = {
      id = n.id,
      kind = n.kind,
      src = n.src,
      env = n.env,
      range = { srow = r.srow, scol = r.scol, erow = r.erow, ecol = r.ecol },
    }
    if stale and #stale > 0 and rows.hits(stale, r.srow, r.erow) then out[i].stale = true end
  end
  return out
end

--- the result: fresh tables (callers may mutate them), stale ones flagged
local function result(st, has_error, extra)
  local stale = st.stale
  if extra then stale = rows.add(vim.deepcopy(stale), extra[1], extra[2]) end
  return copy(st.nodes, stale),
    { has_error = has_error == true, tree_error = st.has_error == true },
    vim.deepcopy(stale)
end

local function has_dollar(buf, lo, hi)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, lo, hi + 1, false)) do
    if l:find("$", 1, true) then return true end
  end
  return false
end

local function blank(buf, row)
  local l = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  return l == nil or l:match("^%s*$") ~= nil
end

local function reset_marks(st)
  st.touched, st.dropped, st.pair_hit, st.tree, st.force_sync, st.removed = {}, false, false, nil, false, false
end

--- markdown: can the `$$` pairs differ from the shifted ones? Only through an edited
--- `$$` line, a new one, or a code block (fence or indentation) appearing or going:
--- block_pairs walks the whole tree, so it is skipped otherwise.
local function pairs_may_change(buf, st)
  if st.pair_hit or not st.touched then return true end
  local function indented(l) return l and (l:find("^    ") or l:find("^\t")) ~= nil end
  for row in pairs(st.touched) do
    local l, nxt = unpack(vim.api.nvim_buf_get_lines(buf, row, row + 2, false))
    -- a $$ line, a fence or indented code here; or indented code below (it becomes
    -- code when this line turns blank)
    if l and (l:find("$$", 1, true) or l:find("^%s*[`~][`~][`~]")) or indented(l) or indented(nxt) then return true end
  end
  return false
end

local function full(buf, st, lang, why)
  M.stats.full = M.stats.full + 1
  M.stats[why or "?"] = (M.stats[why or "?"] or 0) + 1
  local nodes, info = detect.detect(buf)
  st.nodes = copy(nodes)
  st.has_error, st.freeze = info.tree_error == true, info.has_error == true
  st.pairs = lang == "markdown" and require("inkmath.detect.markdown").block_pairs(buf) or {}
  st.edits, st.dirty, st.full, st.stale = {}, nil, false, {}
  reset_marks(st)
  st.tick = vim.b[buf].changedtick
  return nodes, info, {}
end

--- The edits since the last detect only shift the previous nodes (see the header).
local function can_skip(buf, st, md)
  if not (st.dirty and st.touched and not st.dropped and not st.removed and not st.has_error) then return false end
  local lo, hi = math.huge, -1
  for row in pairs(st.touched) do
    lo, hi = math.min(lo, row), math.max(hi, row)
  end
  if hi < 0 then return false end
  if st.tree then -- tree changes inside the edited rows only
    for row = st.tree[1], st.tree[2] do
      if not st.touched[row] then return false end
    end
  end
  for _, n in ipairs(st.nodes) do
    local r = n.range
    if r.srow <= hi and r.erow >= lo then
      for row = math.max(lo, r.srow), math.min(hi, r.erow) do
        if st.touched[row] then return false end
      end
    end
  end
  if md then
    local last = vim.api.nvim_buf_line_count(buf) - 1
    while lo > 0 and not blank(buf, lo - 1) and hi - lo <= MAX_PARAGRAPH do
      lo = lo - 1
    end
    while hi < last and not blank(buf, hi + 1) and hi - lo <= MAX_PARAGRAPH do
      hi = hi + 1
    end
    if hi - lo > MAX_PARAGRAPH then return false end
    return not precheck.triggers(vim.api.nvim_buf_get_lines(buf, lo, hi + 1, false))
  end
  local lines = {}
  for row in pairs(st.touched) do
    lines[#lines + 1] = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  end
  return not precheck.triggers(lines)
end

--- Bring the tree up to date for a detect with `want`. Returns false while a parse
--- is pending (the previous nodes are returned meanwhile).
local function parse_for(buf, st, parser, lang, want)
  local md = lang == "markdown"
  local root_ok = parser:is_valid(true)
  if root_ok and not md then return true end
  if not root_ok and not st.force_sync then
    if md and vim.treesitter.highlighter.active[buf] then
      -- the highlighter parses on the next redraw; on_changedtree -> notify_ready
      st.pending = true
      if not st.timer then
        st.timer = vim.uv.new_timer()
        st.timer:start(
          FALLBACK_MS,
          0,
          vim.schedule_wrap(function()
            if st.pending then
              st.force_sync = true
              notify_ready(buf, st)
            end
          end)
        )
      end
      return false
    end
    if not vim.g._ts_force_sync_parsing then
      -- started from the event loop, not in this keystroke's refresh: the parse runs
      -- in 3 ms slices between input, and its callback refreshes again
      st.pending = true
      local range = md and want or nil
      vim.schedule(function()
        if states[buf] ~= st or st.dead or not vim.api.nvim_buf_is_valid(buf) then return end
        parser:parse(range, function(err)
          if err then st.force_sync = true end
          notify_ready(buf, st)
        end)
      end)
      return false
    end
  end
  -- markdown: the injections of the wanted rows (cheap when the highlighter parsed
  -- them); their changedtree marks reparsed rows dirty
  parser:parse(md and want or nil)
  return true
end

--- {a, b} spans of the `$$` pairs in only one of the two lists
local function changed_pairs(old, now)
  local function k(p) return (p[1] or -1) .. ":" .. (p[2] or -1) end
  local in_old, in_now = {}, {}
  for _, p in ipairs(old) do
    in_old[k(p)] = true
  end
  for _, p in ipairs(now) do
    in_now[k(p)] = true
  end
  local out = {}
  for _, p in ipairs(old) do
    if not in_now[k(p)] then
      out[#out + 1] = { math.min(p[1] or p[2], p[2] or p[1]), math.max(p[1] or p[2], p[2] or p[1]) }
    end
  end
  for _, p in ipairs(now) do
    if not in_old[k(p)] then out[#out + 1] = { p[1], p[2] } end
  end
  return out
end

--- Re-detect rows [lo, hi], expanded until no node crosses the boundary, and splice
--- the result into st.nodes. false: unstable or the tree has errors (detect fully).
--- With `want` an unstable expansion (e.g. a re-paired `$$` chains block after block)
--- stops after 32 rounds: the last detection is kept, far from its edges the wanted
--- rows are right; its other rows become stale.
local function redetect(buf, st, md, lo, hi, want)
  local last = vim.api.nvim_buf_line_count(buf) - 1
  lo, hi = math.max(0, lo), math.min(last, hi)
  local fresh, prev, plo, phi
  for _ = 1, 32 do
    if md then
      while lo > 0 and not blank(buf, lo - 1) do
        lo = lo - 1
      end
      while hi < last and not blank(buf, hi + 1) do
        hi = hi + 1
      end
    end
    local wlo, whi = lo, hi
    for _, n in ipairs(st.nodes) do
      if n.range.srow <= hi and n.range.erow >= lo then
        wlo, whi = math.min(wlo, n.range.srow), math.max(whi, n.range.erow)
      end
    end
    for _, p in ipairs(st.pairs) do -- `$$` blocks, also empty ones (no node)
      if p[1] <= hi and p[2] >= lo then
        wlo, whi = math.min(wlo, p[1]), math.max(whi, p[2])
      end
    end
    local info
    if md and not has_dollar(buf, wlo, whi) then
      -- no `$` in these rows (and no old node overlaps them, or wlo..whi would hold
      -- its `$`): nothing to find
      fresh, info = {}, { has_error = false, tree_error = false }
    else
      fresh, info = detect.detect(buf, wlo, whi)
    end
    if info.tree_error then return false end
    for _, n in ipairs(fresh) do
      wlo, whi = math.min(wlo, n.range.srow), math.max(whi, n.range.erow)
    end
    local stable = wlo == lo and whi == hi
    prev, plo, phi = fresh, lo, hi
    lo, hi = wlo, whi
    if stable then break end
    fresh = nil
  end
  local partial = false
  if not fresh then
    if not want then return false end
    fresh, lo, hi, partial = prev, plo, phi, true
  end
  local out = {}
  for _, n in ipairs(st.nodes) do
    if n.range.erow < lo or n.range.srow > hi then out[#out + 1] = n end
  end
  for _, n in ipairs(copy(fresh)) do
    out[#out + 1] = n
  end
  table.sort(out, detect.before)
  st.nodes = out
  if partial then
    st.stale = rows.add(st.stale, lo, hi)
    for _, w in ipairs(want) do
      st.stale = rows.sub(st.stale, w[1], w[2])
    end
  else
    st.stale = rows.sub(st.stale, lo, hi)
  end
  return true
end

--- Like detect.detect(buf) for the whole buffer, reusing the previous detection
--- outside the dirty rows. Returns fresh tables (callers may mutate them).
--- With `want` (the rows refresh scans) it may return before the tree is parsed and
--- bound its fallbacks to those rows; `stale` lists the rows whose nodes (flagged
--- n.stale) are old: not re-detected since they changed.
---@param buf integer
---@param want? {[1]: integer, [2]: integer}[]
---@return inkmath.MathNode[] nodes
---@return {has_error: boolean, tree_error: boolean, pending?: true} info has_error: unrecovered errors (freeze);
--- tree_error: the tree has errors (no incremental work); pending: waiting for a parse
---@return {[1]: integer, [2]: integer}[] stale
function M.detect(buf, want)
  local lang = lang_of(buf)
  if not lang then
    local n, i = detect.detect(buf)
    return n, i, {}
  end
  local st = states[buf]
  if not st or st.lang ~= lang then
    if st then M.forget(buf) end
    st = {
      pairs = {},
      edits = {},
      full = true,
      has_error = false,
      freeze = false,
      tick = -1,
      lang = lang,
      stale = {},
      touched = {},
      dropped = false,
      pending = false,
      force_sync = false,
    }
    states[buf] = st
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang, { error = false })
  if not ok or not parser then
    local n, i = detect.detect(buf)
    return n, i, {}
  end
  ensure_attached(buf, st)
  ensure_cbs(buf, st, parser)
  flush(st)
  local md = lang == "markdown"
  if st.nodes and not st.full and not st.has_error and can_skip(buf, st, md) then
    M.stats.skip = M.stats.skip + 1
    st.dirty = nil
    reset_marks(st)
    st.tick = vim.b[buf].changedtick
    return result(st, false)
  end
  if want then
    if not parse_for(buf, st, parser, lang, want) then
      M.stats.pending = M.stats.pending + 1
      local n, info, stale
      if st.nodes then
        n, info, stale = result(st, st.freeze, st.dirty)
      else -- first detection: nothing known yet
        n, info, stale = {}, { has_error = false, tree_error = false }, { { 0, vim.api.nvim_buf_line_count(buf) - 1 } }
      end
      info.pending = true
      return n, info, stale
    end
    if not st.nodes or st.full then
      -- first detection (or after a reload): only the wanted rows now, the rest is
      -- stale until wanted (background fill). A broken tree still detects fully.
      local tree = parser:trees()[1]
      if not st.attached or not tree or tree:root():has_error() then return full(buf, st, lang, "first") end
      M.stats.first_bounded = (M.stats.first_bounded or 0) + 1
      st.nodes, st.stale, st.has_error, st.freeze = {}, { { 0, vim.api.nvim_buf_line_count(buf) - 1 } }, false, false
      st.pairs = md and require("inkmath.detect.markdown").block_pairs(buf) or {}
      st.edits, st.dirty, st.full = {}, nil, false
      reset_marks(st)
    end
  else
    -- bring the whole tree up to date (fires on_changedtree for the edits). Markdown
    -- parses its injections too: a reparse of the markdown_inline trees can change
    -- results in rows nobody edited (tree-sitter keeps state between parses), and the
    -- recursive on_changedtree marks those rows dirty, so the result equals a full
    -- detect of the same LanguageTree. Cheap when the highlighter has just parsed.
    parser:parse(md or nil)
  end
  st.pending = false
  local trees = parser:trees()
  local tree = trees and trees[1]
  if not st.attached or not tree then
    local n, i = detect.detect(buf)
    return n, i, {}
  end
  if st.full or not st.nodes or st.has_error or tree:root():has_error() then
    return full(buf, st, lang, st.full and "flag" or not st.nodes and "first" or "error")
  end
  local tick = vim.b[buf].changedtick
  flush(st)
  if st.full then return full(buf, st, lang, "flag") end
  st.tick = tick
  local last = vim.api.nvim_buf_line_count(buf) - 1
  local dirty = st.dirty
  local check_pairs = md and pairs_may_change(buf, st)
  st.dirty = nil
  reset_marks(st)
  local need = {}
  if dirty then need = rows.add(need, math.max(0, dirty[1]), math.min(last, dirty[2])) end
  local large = dirty and dirty[2] - dirty[1] > math.max(400, last / 2)
  local changed
  if check_pairs then
    -- the paired `$$` lines must be the same ones (shifted): a new, removed, or
    -- (un)fenced one re-pairs every later block
    local now = require("inkmath.detect.markdown").block_pairs(buf)
    if not vim.deep_equal(now, st.pairs) then changed = changed_pairs(st.pairs, now) end
    st.pairs = now
  end
  if want then
    for _, w in ipairs(want) do -- stale rows that are wanted now
      for _, s in ipairs(rows.clip(st.stale, w[1], w[2])) do
        need = rows.add(need, s[1], s[2])
      end
    end
    if large or changed then
      -- bounded: the wanted rows of `need`, whole changed pairs that touch the view
      local bounded = {}
      for _, w in ipairs(want) do
        for _, s in ipairs(rows.clip(need, w[1], w[2])) do
          bounded = rows.add(bounded, s[1], s[2])
        end
      end
      for _, p in ipairs(changed or {}) do
        local seen = false
        for _, w in ipairs(want) do
          seen = seen or (p[1] <= w[2] and p[2] >= w[1])
        end
        if seen then
          bounded = rows.add(bounded, p[1], p[2])
        else
          need = rows.add(need, p[1], p[2])
        end
      end
      for _, s in ipairs(need) do
        st.stale = rows.add(st.stale, s[1], s[2])
      end
      need = bounded
      M.stats[large and "large" or "dollar"] = (M.stats[large and "large" or "dollar"] or 0) + 1
    end
  else
    if large then return full(buf, st, lang, "large") end
    if changed then return full(buf, st, lang, "dollar") end
    for _, s in ipairs(st.stale) do
      need = rows.add(need, s[1], s[2])
    end
    if rows.count(need) > math.max(400, last / 2) then return full(buf, st, lang, "large") end
  end
  if #need == 0 then
    M.stats.reuse = M.stats.reuse + 1
    return result(st, false)
  end
  for _, r in ipairs(need) do
    if not redetect(buf, st, md, r[1], r[2], want) then return full(buf, st, lang, "unstable") end
  end
  M.stats.incr = M.stats.incr + 1
  return result(st, false)
end

--- Stop tracking the buffer (detach).
---@param buf integer
function M.forget(buf)
  local st = states[buf]
  if st then
    st.dead = true
    if st.timer then
      st.timer:stop()
      st.timer:close()
      st.timer = nil
    end
  end
  states[buf] = nil
end

return M
