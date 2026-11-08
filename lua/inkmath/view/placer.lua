local images = require("inkmath.term.images")
local diacritics = require("inkmath.term.diacritics")
local state = require("inkmath.view.state")

local M = {}

M.ns = vim.api.nvim_create_namespace("inkmath")

local PH = vim.fn.nr2char(0x10EEEE)
local marks_ch = {} ---@type table<integer, string> row/column diacritic i -> its UTF-8 text

local function dia(i)
  local c = marks_ch[i]
  if not c then
    c = vim.fn.nr2char(diacritics[i])
    marks_ch[i] = c
  end
  return c
end

---@param id integer
---@param cols integer
---@param rows integer
---@return string[]
function M.placeholder_rows(id, cols, rows)
  local _ = id
  local out = {}
  if require("inkmath.view.overlay").active() then
    -- overlay backends paint the image themselves: just reserve the cells
    for r = 1, rows do
      out[r] = string.rep(" ", cols)
    end
    return out
  end
  for r = 0, rows - 1 do
    local parts, rd = {}, dia(r + 1)
    for c = 0, cols - 1 do
      parts[#parts + 1] = PH .. rd .. dia(c + 1)
    end
    out[#out + 1] = table.concat(parts)
  end
  return out
end

---@param buf integer
---@param node_id string
function M.clear(buf, node_id)
  local s = state.get(buf)
  local entry = s.nodes[node_id]
  if not entry then return end
  if vim.api.nvim_buf_is_valid(buf) then
    for _, m in ipairs(entry.marks) do
      pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, m)
    end
  end
  s.nodes[node_id] = nil
  require("inkmath.view.overlay").repaint()
end

---@param buf integer
function M.clear_all(buf)
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1) end
  state.get(buf).nodes = {}
  require("inkmath.view.overlay").clear(buf)
end

---@param buf integer
---@param node inkmath.MathNode
---@return boolean
--- all of the entry's extmarks still exist and none was invalidated (deleted text;
--- undo does not restore them since they are set with undo_restore = false)
function M.marks_ok(buf, entry)
  for _, id in ipairs(entry.marks) do
    local ok, p = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, M.ns, id, { details = true })
    if not ok or not p[1] or (p[3] and p[3].invalid) then return false end
  end
  return true
end

--- While the parse is frozen (see core.refresh), placed entries keep their last-detected
--- ranges although their extmarks moved with the text. Re-derive the ranges from the
--- marks so cursor reveal hit-tests and restores at the right place.
---@param buf integer
function M.sync_ranges(buf)
  for _, e in pairs(state.get(buf).nodes) do
    local ok, p = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, M.ns, e.marks[1], { details = true })
    if ok and p[1] and not (p[3] and p[3].invalid) then
      local r = e.node.range
      if e.node.kind == "inline" then
        e.node.range = { srow = p[1], scol = p[2], erow = p[3].end_row or p[1], ecol = p[3].end_col or p[2] }
      elseif e.anchor and p[1] ~= e.anchor then
        local d = p[1] - e.anchor
        e.node.range = { srow = r.srow + d, scol = r.scol, erow = r.erow + d, ecol = r.ecol }
      end
      e.anchor = p[1]
    end
  end
end

--- the buffer text a placement covers at range `r` (inline/promoted: the node's own
--- characters; display/block: its whole rows); nil when the range is out of bounds
local function text_at(buf, kind, r)
  if kind == "inline" or kind == "promoted" then
    local ok, t = pcall(vim.api.nvim_buf_get_text, buf, r.srow, r.scol, r.erow, r.ecol, {})
    return ok and table.concat(t, "\n") or nil
  end
  if r.erow >= vim.api.nvim_buf_line_count(buf) then return nil end
  return table.concat(vim.api.nvim_buf_get_lines(buf, r.srow, r.erow + 1, false), "\n")
end

--- Clear placements anchored in rows [top, bot] (default: all) whose text changed since they were
--- placed (an edit that changed, not deleted, the text keeps the extmarks valid), so
--- an edited formula never shows its old image until the next refresh replaces it.
---@param buf integer
---@param top? integer
---@param bot? integer
---@return integer cleared
function M.verify(buf, top, bot)
  top, bot = top or 0, bot or math.huge
  local s, n = state.get(buf), 0
  for id, e in pairs(s.nodes) do
    if e.text then
      local ok, p = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, M.ns, e.marks[1], { details = true })
      local pos = ok and p[1]
      if pos and pos >= top and pos <= bot then
        local r = e.node.range
        local cur
        if p[3] and p[3].invalid then
          cur = nil
        elseif e.node.kind == "inline" then
          cur = { srow = pos, scol = p[2], erow = p[3].end_row or pos, ecol = p[3].end_col or p[2] }
        else
          local d = pos - (e.anchor or pos)
          cur = { srow = r.srow + d, scol = r.scol, erow = r.erow + d, ecol = r.ecol }
        end
        if not cur or text_at(buf, e.node.kind, cur) ~= e.text then
          M.clear(buf, id)
          n = n + 1
        end
      end
    end
  end
  return n
end

local function in_bounds(buf, node)
  local r = node.range
  local n = vim.api.nvim_buf_line_count(buf)
  if r.srow < 0 or r.erow < r.srow or r.erow >= n then return false end
  if node.kind == "inline" then
    if r.srow ~= r.erow or r.scol < 0 or r.ecol < r.scol then return false end
    local line = vim.api.nvim_buf_get_lines(buf, r.srow, r.srow + 1, false)[1] or ""
    if r.ecol > #line then return false end
  end
  return true
end

local function try_mark(buf, row, col, opts, out)
  opts.invalidate = true
  opts.undo_restore = false
  local ok, m = pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, col, opts)
  if ok then out[#out + 1] = m end
  return ok
end

---@param buf integer
---@param node inkmath.MathNode
---@param img inkmath.Image
function M.place(buf, node, img)
  local ok = pcall(function()
    if not vim.api.nvim_buf_is_valid(buf) or not in_bounds(buf, node) then return end
    local ov = require("inkmath.view.overlay")
    local hl
    if ov.active() then
      ov.enable()
      ov.repaint()
    else
      local id = images.ensure(img)
      if not id then return end
      images.touch(id)
      hl = images.hl(id)
    end
    local rows = M.placeholder_rows(id, img.cols, img.rows)
    local r = node.range
    local marks = {}

    if node.kind == "inline" then
      try_mark(buf, r.srow, r.scol, {
        end_row = r.erow,
        end_col = r.ecol,
        conceal = "",
        virt_text = { { rows[1], hl } },
        virt_text_pos = "inline",
      }, marks)
    elseif node.kind == "promoted" then
      -- display copy of a tall inline node, drawn below its line
      local vl = {}
      for i = 1, #rows do
        vl[i] = { { rows[i], hl } }
      end
      try_mark(buf, r.erow, 0, { virt_lines = vl }, marks)
    else
      -- display/block: everything is anchored on the node's own rows, so neighbouring
      -- blocks cannot hide each other's image (virt_lines on a row hidden by
      -- conceal_lines are not drawn). The first row's text is concealed and the first
      -- image row is drawn over it (overlay: clipped at the window edge, never wraps);
      -- the other image rows are virt_lines below it; the remaining rows are hidden.
      local line = vim.api.nvim_buf_get_lines(buf, r.srow, r.srow + 1, false)[1] or ""
      local vl = {}
      for i = 2, #rows do
        vl[#vl + 1] = { { rows[i], hl } }
      end
      try_mark(buf, r.srow, 0, {
        end_row = r.srow,
        end_col = #line,
        conceal = "",
        virt_text = { { rows[1], hl } },
        virt_text_pos = "overlay",
        virt_lines = #vl > 0 and vl or nil,
      }, marks)
      for row = r.srow + 1, r.erow do
        try_mark(buf, row, 0, { conceal_lines = "" }, marks)
      end
    end

    M.clear(buf, node.id)
    if #marks > 0 then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, marks[1], {})
      state.get(buf).nodes[node.id] =
        { node = node, img = img, marks = marks, anchor = pos[1], text = text_at(buf, node.kind, r) }
    end
  end)
  return ok
end

return M
