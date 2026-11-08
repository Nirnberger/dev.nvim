-- Lists of row ranges: sorted, disjoint, inclusive {lo, hi} pairs (0-based rows).
-- Every function returns a new list and leaves its argument alone.
local M = {}

---@alias inkmath.Rows {[1]: integer, [2]: integer}[]

--- list plus [a, b] (adjacent ranges merge)
---@param list inkmath.Rows
---@return inkmath.Rows
function M.add(list, a, b)
  if a > b then a, b = b, a end
  local out, placed = {}, false
  for _, r in ipairs(list) do
    if r[2] < a - 1 then
      out[#out + 1] = r
    elseif r[1] > b + 1 then
      if not placed then
        out[#out + 1] = { a, b }
        placed = true
      end
      out[#out + 1] = r
    else
      a, b = math.min(a, r[1]), math.max(b, r[2])
    end
  end
  if not placed then out[#out + 1] = { a, b } end
  return out
end

--- list minus [a, b]
---@param list inkmath.Rows
---@return inkmath.Rows
function M.sub(list, a, b)
  local out = {}
  for _, r in ipairs(list) do
    if r[2] < a or r[1] > b then
      out[#out + 1] = r
    else
      if r[1] < a then out[#out + 1] = { r[1], a - 1 } end
      if r[2] > b then out[#out + 1] = { b + 1, r[2] } end
    end
  end
  return out
end

--- the parts of list inside [a, b]
---@param list inkmath.Rows
---@return inkmath.Rows
function M.clip(list, a, b)
  local out = {}
  for _, r in ipairs(list) do
    local lo, hi = math.max(r[1], a), math.min(r[2], b)
    if lo <= hi then out[#out + 1] = { lo, hi } end
  end
  return out
end

--- some range of list intersects [a, b]
---@param list inkmath.Rows
---@return boolean
function M.hits(list, a, b)
  for _, r in ipairs(list) do
    if r[1] <= b and r[2] >= a then return true end
  end
  return false
end

--- number of rows in list
---@param list inkmath.Rows
---@return integer
function M.count(list)
  local n = 0
  for _, r in ipairs(list) do n = n + r[2] - r[1] + 1 end
  return n
end

--- Map the ranges through an edit of rows [e.sr, e.oer] into [e.sr, e.ner] (rows in
--- the edited span widen to the whole new span).
---@param list inkmath.Rows
---@param e {sr: integer, oer: integer, ner: integer}
---@return inkmath.Rows
function M.shift(list, e)
  local d = e.ner - e.oer
  local out = {}
  for _, r in ipairs(list) do
    local a = r[1] < e.sr and r[1] or (r[1] > e.oer and r[1] + d or e.sr)
    local b = r[2] < e.sr and r[2] or (r[2] > e.oer and r[2] + d or e.ner)
    out = M.add(out, a, math.max(a, b))
  end
  return out
end

return M
