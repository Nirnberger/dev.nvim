-- kitty graphics protocol without Unicode placeholders (WezTerm, Konsole): the image is
-- transmitted once by images.ensure (`a=t`, no virtual placement) and placed at the cursor
-- cell with `a=p`. Deleting removes the placements only; the image data stays resident.
local kitty = require("inkmath.term.kitty")

local M = {}

M.name = "kitty"
M.mode = "overlay"
M.send = kitty.send

---@param env? table
---@return boolean
function M.probe(env)
  env = env or vim.env
  return env.TERM_PROGRAM == "WezTerm" or (env.KONSOLE_VERSION or "") ~= ""
end

---@param id integer
---@return string
function M.delete(id) return string.format("\27_Ga=d,d=i,i=%d,q=2\27\\", id) end

---@param img {path: string, cols: integer, rows: integer, id: integer}
---@param row integer
---@param col integer
---@return string[]
function M.paint(img, row, col)
  return { ("\0277\27[%d;%dH\27_Ga=p,i=%d,c=%d,r=%d,C=1,q=2\27\\\0278"):format(row, col, img.id, img.cols, img.rows) }
end

return M
