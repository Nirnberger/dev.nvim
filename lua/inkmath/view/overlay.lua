-- Overlay view for backends that paint at screen cells (iTerm2, Sixel, kitty without
-- placeholders). The placer reserves blank cells; this module paints the images over them
-- and deletes them again when the anchor leaves the screen, folds, or the buffer goes.
local backend = require("inkmath.term.backend")
local images = require("inkmath.term.images")
local state = require("inkmath.view.state")

local M = {}

local painted = {} ---@type table<string, {id: integer, buf: integer, row: integer, col: integer}>
local scheduled = false
local group ---@type integer?
local own_ids, next_own = {}, 0 ---@type table<string, integer>, integer ids for backends that need no transmit

--- Id of an image for painting: the kitty id when the backend transmits (needs the image resident),
--- otherwise a private counter (iTerm2, Sixel send the pixels with every paint).
local function id_for(b, img)
  if b.transmit ~= false then return images.id(img.key) or images.ensure(img) end
  if not own_ids[img.key] then
    next_own = next_own + 1
    own_ids[img.key] = next_own
  end
  return own_ids[img.key]
end

---@return inkmath.Backend|nil b the active backend when it paints at cells
function M.active()
  local b = backend.get()
  if b and b.mode == "overlay" and b.paint then return b end
end

--- 1-based screen cell of buffer position (lnum, col) in `win`.
---@return {row: integer, col: integer}|nil nil: not visible, in a closed fold, or outside the window
function M.cell(win, lnum, col)
  if not vim.api.nvim_win_is_valid(win) then return nil end
  local hidden = vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(lnum) ~= -1 end)
  if hidden then return nil end
  local p = vim.fn.screenpos(win, lnum, col)
  if p.row == 0 or p.col == 0 then return nil end
  return { row = p.row, col = p.col }
end

--- what should be on screen now: key -> {img, buf, row, col}
local function wanted()
  local want = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    for node_id, e in pairs(state.get(buf).nodes) do
      local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, require("inkmath.view.placer").ns, e.marks[1], {})
      if ok and pos[1] then
        local c = M.cell(win, pos[1] + 1, pos[2] + 1)
        if c then
          want[("%d:%d:%s"):format(win, buf, node_id)] = { img = e.img, buf = buf, row = c.row, col = c.col }
        end
      end
    end
  end
  return want
end

local function paint_now()
  scheduled = false
  local b = M.active()
  if not b then return end
  local want = wanted()
  local dirty = {} ---@type table<integer, true> ids deleted: every placement of them is repainted
  for key, p in pairs(painted) do
    local w = want[key]
    if not w or w.row ~= p.row or w.col ~= p.col then
      if not dirty[p.id] then b.send(b.delete(p.id)) end
      dirty[p.id] = true
      painted[key] = nil
    end
  end
  for key, p in pairs(painted) do
    if dirty[p.id] then painted[key] = nil end
  end
  -- backends that cannot delete single images redraw the screen once, which wipes every
  -- image: all of them are painted again after it
  if b.flush and b.flush() then painted = {} end
  for key, w in pairs(want) do
    if not painted[key] then
      local id = id_for(b, w.img)
      if id then
        local seqs = b.paint({ path = w.img.path, cols = w.img.cols, rows = w.img.rows, id = id }, w.row, w.col)
        for _, seq in ipairs(seqs) do
          b.send(seq)
        end
        -- nothing to paint yet (file missing, being converted): try again on the next repaint
        if #seqs > 0 then painted[key] = { id = id, buf = w.buf, row = w.row, col = w.col } end
      end
    end
  end
end

--- Repaint at the end of the tick; any number of calls in one tick cost one pass.
function M.repaint()
  if scheduled or not M.active() then return end
  scheduled = true
  vim.schedule(paint_now)
end

--- Remove painted images of `buf` (default: all).
---@param buf? integer
function M.clear(buf)
  local b = backend.get()
  local gone = {}
  for key, p in pairs(painted) do
    if not buf or p.buf == buf then
      if b and not gone[p.id] then b.send(b.delete(p.id)) end
      gone[p.id] = true
      painted[key] = nil
    end
  end
  if b and b.flush then b.flush() end
end

--- Autocmds that keep the paint in sync; idempotent.
function M.enable()
  if group then return end
  group = vim.api.nvim_create_augroup("inkmath_overlay", { clear = true })
  vim.api.nvim_create_autocmd(
    { "WinScrolled", "VimResized", "CursorHold", "TextChanged", "ModeChanged", "WinEnter", "BufEnter" },
    { group = group, callback = M.repaint }
  )
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev) M.clear(ev.buf) end,
  })
end

--- (tests) forget everything without sending
function M._reset()
  painted, scheduled = {}, false
end

return M
