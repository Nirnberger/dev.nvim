local config = require("inkmath.config")
local images = require("inkmath.term.images")
local placer = require("inkmath.view.placer")
local render = require("inkmath.render")
local state = require("inkmath.view.state")

local M = {}

local pns = vim.api.nvim_create_namespace("inkmath_preview")

---@class inkmath.PreviewState
---@field fbuf integer? scratch buffer (kept for the life of the source buffer)
---@field win integer? float window
---@field seq integer request sequence; bumped per request and on close
---@field img_key string? key of the image currently shown
local previews = {} ---@type table<integer, inkmath.PreviewState>

---@param r table
---@param row integer
---@param col integer
---@param inclusive boolean
function M.contains(r, row, col, inclusive)
  if row < r.srow or row > r.erow then return false end
  if row == r.srow and col < r.scol then return false end
  if row == r.erow then
    if inclusive then return col <= r.ecol end
    return col < r.ecol
  end
  return true
end

---@param buf integer
---@param win integer
function M.update(buf, win)
  pcall(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local s = state.get(buf)
    local mode = vim.fn.mode()
    local first = mode:sub(1, 1)
    local visual = first == "v" or first == "V" or first == "\22"
    local row, col, vrow
    if visual then
      local a = vim.fn.getpos("v")[2] - 1
      local b = vim.fn.getpos(".")[2] - 1
      row, vrow = math.min(a, b), math.max(a, b)
    else
      local pos = vim.api.nvim_win_get_cursor(win)
      row, col = pos[1] - 1, pos[2]
    end
    local inclusive = first == "i"

    local function hit(node)
      local r = node.range
      if visual then return r.srow <= vrow and r.erow >= row end
      return M.contains(r, row, col, inclusive)
    end

    -- Rule: a revealed entry whose buffer changedtick differs from the tick
    -- recorded at reveal time is STALE (its range/img may be wrong after an
    -- edit). Stale entries are left alone here: not hit-tested, not restored.
    -- Task 9's refresh must call M.forget_stale(buf) (before re-detecting and
    -- re-placing) so they are dropped and rebuilt from fresh detection.
    local tick = vim.b[buf].changedtick
    local to_reveal, to_restore = {}, {}
    for id, e in pairs(s.nodes) do
      if hit(e.node) then to_reveal[id] = e end
    end
    for id, e in pairs(s.revealed) do
      if e.tick == tick and not hit(e.node) then to_restore[id] = e end
    end

    for id, e in pairs(to_reveal) do
      placer.clear(buf, id)
      s.revealed[id] = { node = e.node, img = e.img, tick = tick }
    end
    for id, e in pairs(to_restore) do
      s.revealed[id] = nil
      pcall(placer.place, buf, e.node, e.img)
    end
  end)
end

--- Drop revealed entries recorded at an older changedtick (see update()).
---@param buf integer
function M.forget_stale(buf)
  local s = state.get(buf)
  local ok, tick = pcall(function() return vim.b[buf].changedtick end)
  if not ok then return end
  for id, e in pairs(s.revealed) do
    if e.tick ~= tick then s.revealed[id] = nil end
  end
end

--- Image keys shown in open preview floats (pinned against eviction).
---@return string[]
function M.preview_keys()
  local out = {}
  for _, p in pairs(previews) do
    if p.img_key and p.win and vim.api.nvim_win_is_valid(p.win) then out[#out + 1] = p.img_key end
  end
  return out
end

--- An image was deleted from the terminal (its PNG is gone): close the previews that
--- showed it, so none stays blank on a deleted id.
---@param key string
---@return integer[] bufs whose preview was closed (show it again)
function M.drop_key(key)
  local out = {}
  for b, p in pairs(previews) do
    if p.img_key == key then
      M.close_preview(b)
      out[#out + 1] = b
    end
  end
  return out
end

---@param buf integer
function M.close_preview(buf)
  local p = previews[buf]
  if not p then return end
  p.seq = p.seq + 1 -- invalidate in-flight requests
  if p.win and vim.api.nvim_win_is_valid(p.win) then pcall(vim.api.nvim_win_close, p.win, true) end
  p.win = nil
  p.img_key = nil
  -- the scratch buffer is kept and reused for the next preview
end

---@param p inkmath.PreviewState
local function ensure_buf(p)
  if not (p.fbuf and vim.api.nvim_buf_is_valid(p.fbuf)) then p.fbuf = vim.api.nvim_create_buf(false, true) end
  return p.fbuf
end

--- Blank rows (only whitespace) directly above srow and below erow, counted within the
--- visible rows lo..hi (0-based, inclusive).
---@return integer above, integer below
function M._blank_rows(lines, first, srow, erow, lo, hi)
  local function blank(r)
    local l = lines[r - first + 1]
    return l ~= nil and l:match("^%s*$") ~= nil
  end
  local above, below = 0, 0
  local r = srow - 1
  while r >= math.max(lo, first) and blank(r) do
    above, r = above + 1, r - 1
  end
  r = erow + 1
  while r <= math.min(hi, first + #lines - 1) and blank(r) do
    below, r = below + 1, r + 1
  end
  return above, below
end

--- True: put the float above the node. The configured side wins when the float (height
--- plus its border rows) fits into the blank rows there, else the other side if it fits,
--- else the configured side (preview.avoid_text keeps text uncovered).
local function pick_above(buf, win, node, height, border, opts)
  local want_above = opts.position == "above"
  if not opts.avoid_text then return want_above end
  local ok, a, b = pcall(function()
    local vis = vim.api.nvim_win_call(win, function() return { vim.fn.line("w0") - 1, vim.fn.line("w$") - 1 } end)
    local lo, hi = vis[1], vis[2]
    local first = math.max(lo, node.range.srow - height - 3)
    local last = math.min(hi, node.range.erow + height + 3)
    local lines = vim.api.nvim_buf_get_lines(buf, first, last + 1, false)
    return M._blank_rows(lines, first, node.range.srow, node.range.erow, lo, hi)
  end)
  if not ok then return want_above end
  local need = height + ((border == "none") and 0 or 2)
  local fits = { above = a >= need, below = b >= need }
  local pref, other = want_above and "above" or "below", want_above and "below" or "above"
  if fits[pref] then return want_above end
  if fits[other] then return not want_above end
  return want_above
end

--- Open or move the preview float: width x height cells next to the node, with the
--- configured border/position; title only for the error view.
local function show_float(p, buf, win, node, width, height, title)
  local opts = config.get(buf).preview
  local border = opts.border or (vim.o.winborder == "" and "rounded" or nil)
  local above = pick_above(buf, win, node, height, border or vim.o.winborder, opts)
  local cfg = {
    relative = "win",
    win = win,
    -- below: under the formula's last row; above: the float's bottom edge on its first
    bufpos = above and { node.range.srow, node.range.scol } or { node.range.erow, node.range.scol },
    anchor = above and "SW" or "NW",
    row = above and 0 or 1,
    col = 0,
    width = math.max(1, width),
    height = math.max(1, height),
  }
  local open = p.win and vim.api.nvim_win_is_valid(p.win)
  -- a title needs a border; "" removes the error title again
  if border ~= "none" and (title or (open and p.titled)) then cfg.title = title or "" end
  p.titled = title ~= nil
  if open then
    vim.api.nvim_win_set_config(p.win, cfg)
  else
    cfg.style = "minimal"
    -- unset: nvim_open_win applies 'winborder' itself (custom comma lists included)
    if opts.border or vim.o.winborder == "" then cfg.border = border end
    cfg.focusable = false
    p.win = vim.api.nvim_open_win(p.fbuf, false, cfg)
    vim.wo[p.win].winhighlight = "FloatBorder:InkMathPreviewBorder"
  end
end

---@param buf integer
---@param win integer
---@param node inkmath.MathNode
---@param img inkmath.Image
local function apply(buf, win, node, img)
  local p = previews[buf]
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then return end
  local fbuf = ensure_buf(p)
  local id = images.ensure(img)
  if not id then return end
  images.touch(id)
  if p.img_key ~= img.key or not (p.win and vim.api.nvim_win_is_valid(p.win)) then
    local lines = placer.placeholder_rows(id, img.cols, img.rows)
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(fbuf, pns, 0, -1)
    local hl = images.hl(id)
    for i, l in ipairs(lines) do
      vim.api.nvim_buf_set_extmark(fbuf, pns, i - 1, 0, { end_col = #l, hl_group = hl })
    end
    p.img_key = img.key
  end
  show_float(p, buf, win, node, img.cols, img.rows, nil)
end

--- Word-wrap `text` to `width` columns, at most `max` lines (the last one cut with …).
---@return string[]
function M._wrap(text, width, max)
  local out, cur = {}, ""
  for word in tostring(text):gsub("%s+", " "):gmatch("%S+") do
    while vim.fn.strdisplaywidth(word) > width do -- a word longer than a line
      if cur ~= "" then
        out[#out + 1], cur = cur, ""
      end
      local part = vim.fn.strcharpart(word, 0, width)
      out[#out + 1], word = part, vim.fn.strcharpart(word, vim.fn.strchars(part))
    end
    if cur == "" then
      cur = word
    elseif vim.fn.strdisplaywidth(cur .. " " .. word) <= width then
      cur = cur .. " " .. word
    else
      out[#out + 1], cur = cur, word
    end
  end
  if cur ~= "" then out[#out + 1] = cur end
  if #out > max then
    out = vim.list_slice(out, 1, max)
    local last = out[max]
    if vim.fn.strdisplaywidth(last) >= width then last = vim.fn.strcharpart(last, 0, width - 1) end
    out[max] = last .. "…"
  end
  return out
end

--- The newest preview request failed: show its TeX error in the float instead of the
--- previous (now stale) image; preview.error_lines = 0 closes the float.
local function apply_error(buf, win, node, err)
  local p = previews[buf]
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then return end
  local n = config.get(buf).preview.error_lines
  if n == 0 then return M.close_preview(buf) end
  local msg = type(err) == "table" and err.message or err or "render failed"
  local lines = M._wrap(msg, math.max(10, math.min(80, vim.api.nvim_win_get_width(win) - 4)), n)
  if #lines == 0 then lines = { "render failed" } end
  local fbuf = ensure_buf(p)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(fbuf, pns, 0, -1)
  local width = 0
  for i, l in ipairs(lines) do
    vim.api.nvim_buf_set_extmark(fbuf, pns, i - 1, 0, { end_col = #l, hl_group = "InkMathPreviewError" })
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  p.img_key = nil -- the next valid render fills the float again
  show_float(p, buf, win, node, math.max(width, 11), #lines, " TeX error ")
end

---@param buf integer
---@param win integer
---@param node inkmath.MathNode
---@param ctx table
function M.preview(buf, win, node, ctx)
  local p0 = previews[buf] or { seq = 0 }
  previews[buf] = p0
  p0.seq = p0.seq + 1
  local seq = p0.seq -- only the newest request may apply
  -- MathJax only: intermediate states while typing must not spawn tectonic
  render.render(node, ctx, function(img, err)
    local p = previews[buf]
    if not p or p.seq ~= seq then return end
    if img then
      pcall(apply, buf, win, node, img)
    else
      pcall(apply_error, buf, win, node, err)
    end
  end, { no_fallback = true })
end

return M
