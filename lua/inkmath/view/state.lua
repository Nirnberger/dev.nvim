local M = {}

---@class inkmath.BufState
---@field nodes table<string, {node: inkmath.MathNode, img: inkmath.Image, marks: integer[], anchor: integer}> anchor: row of marks[1] when placed
---@field revealed table<string, true>

local bufs = {} ---@type table<integer, inkmath.BufState>

---@param buf integer
---@return inkmath.BufState
function M.get(buf)
  local s = bufs[buf]
  if not s then
    s = { nodes = {}, revealed = {} }
    bufs[buf] = s
  end
  return s
end

---@param buf integer
function M.reset(buf) bufs[buf] = nil end

return M
