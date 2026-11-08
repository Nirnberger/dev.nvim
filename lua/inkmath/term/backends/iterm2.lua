-- iTerm2 inline images (OSC 1337). Overlay mode: the image is painted at screen cells and
-- cannot be deleted individually, so a repaint batch ends in one `:redraw!`.
local kitty = require("inkmath.term.kitty")

local M = {}

M.name = "iterm2"
M.mode = "overlay"
M.transmit = false -- the pixels travel with every paint; no resident kitty image
M.send = kitty.send -- same raw write, tmux-wrapped when needed

local redraw_pending = false

---@param env? table
---@return boolean
function M.probe(env)
  env = env or vim.env
  return env.TERM_PROGRAM == "iTerm.app" or env.LC_TERMINAL == "iTerm2"
end

--- No per-image delete in OSC 1337: stale pixels vanish when Neovim repaints the cells.
---@return string
function M.delete()
  if not redraw_pending then
    redraw_pending = true
    vim.schedule(function()
      redraw_pending = false
      pcall(vim.cmd, "redraw!")
    end)
  end
  return ""
end

---@param img {path: string, cols: integer, rows: integer, id: integer}
---@param row integer
---@param col integer
---@return string[]
function M.paint(img, row, col)
  local f = io.open(img.path, "rb")
  if not f then return {} end
  local bytes = f:read("*a")
  f:close()
  if not bytes or #bytes == 0 then return {} end
  local file = ("\27]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1:%s\7"):format(
    img.cols,
    img.rows,
    vim.base64.encode(bytes)
  )
  return { ("\0277\27[%d;%dH%s\0278"):format(row, col, file) }
end

return M
