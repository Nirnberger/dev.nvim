-- Closed folds vs. image extmarks (checked headless, Neovim 0.11, tests/test_core.lua
-- "folds: ..."):
-- * virt_lines and conceal_lines of rows inside a closed fold are not drawn: a folded
--   display block takes exactly the fold's one screen row;
-- * but the overlay virt_text of a display block's first row IS drawn over the fold
--   line when that row starts the fold (whatever 'foldtext' is), i.e. the image's
--   first row would cover the fold text;
-- * inline virt_text is drawn on the fold line only with 'foldtext' = "" (the line
--   is shown as is), where the inline image is correct.
-- So display/block nodes whose first row is inside a closed fold are not placed.
-- Folds are per window, extmarks per buffer: a node is hidden when its row is folded
-- in any window showing the buffer.
local M = {}

---@param node inkmath.MathNode
local function overlay(node) return node.kind == "display" or node.kind == "block" end

---@param win integer
---@param row integer 0-based
---@return boolean
function M.closed(win, row)
  local ok, res = pcall(vim.api.nvim_win_call, win, function() return vim.fn.foldclosed(row + 1) end)
  return ok and res ~= -1
end

--- The node's first row is inside a closed fold in some window showing buf.
---@param buf integer
---@param node inkmath.MathNode
---@return boolean
function M.hidden(buf, node)
  if not overlay(node) then return false end
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if M.closed(w, node.range.srow) then return true end
  end
  return false
end

--- Folded rows among `rows` within [top, bot], for the CURRENT window (called from a
--- decoration provider's on_win, where only the current window can be queried
--- without switching windows). A change means folds opened/closed over images.
---@param rows integer[] 0-based
---@param top integer
---@param bot integer
---@return string
function M.signature(rows, top, bot)
  local out = {}
  for _, r in ipairs(rows) do
    if r >= top and r <= bot and vim.fn.foldclosed(r + 1) ~= -1 then out[#out + 1] = r end
  end
  table.sort(out)
  return table.concat(out, ",")
end

M.overlay = overlay

M._sig = {} ---@type table<string, string> "win:buf" -> signature at the last redraw of the window

--- No event fires when folds open or close (zc, zo, zM, zR, ...), but the window is
--- redrawn: at each redraw of the current window, compare the folded rows among
--- rows_of(buf) (nil: not watched) and call changed(buf) (scheduled) when they differ.
---@param rows_of fun(buf: integer): integer[]|nil
---@param changed fun(buf: integer)
function M.watch(rows_of, changed)
  vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace("inkmath_folds"), {
    on_win = function(_, win, b, top, bot)
      if win ~= vim.api.nvim_get_current_win() then return false end
      local ok, sig = pcall(function()
        local rows = rows_of(b)
        return rows and M.signature(rows, top, bot)
      end)
      if not (ok and sig) then return false end
      local k = win .. ":" .. b
      if M._sig[k] ~= sig then
        local first = M._sig[k] == nil
        M._sig[k] = sig
        if not first then vim.schedule(function() pcall(changed, b) end) end
      end
      return false
    end,
  })
end

return M
