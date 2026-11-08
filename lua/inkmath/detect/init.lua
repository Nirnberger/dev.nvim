local M = {}

---@class inkmath.MathNode
---@field id string
---@field kind "inline"|"display"|"block"
---@field src string
---@field env? string
---@field range {srow:integer, scol:integer, erow:integer, ecol:integer}

local registry = require("inkmath.detect.registry")

---@param kind "inline"|"display"|"block"
---@param env string|nil
---@param src string
---@return string
function M.node_id(kind, env, src)
  return vim.fn.sha256(kind .. "\0" .. (env or "") .. "\0" .. src):sub(1, 16)
end

--- Make ids unique per occurrence (in place): content id .. "#" .. n, n counting the
--- nodes with the same content id in source order. These are the ids of placements.
---@param nodes inkmath.MathNode[] in source order
---@return inkmath.MathNode[] nodes
function M.number(nodes)
  local count = {}
  for _, n in ipairs(nodes) do
    count[n.id] = (count[n.id] or 0) + 1
    n.id = n.id .. "#" .. count[n.id]
  end
  return nodes
end

--- Source order (total, so equal starts sort the same in every detection).
---@param a inkmath.MathNode
---@param b inkmath.MathNode
function M.before(a, b)
  local x, y = a.range, b.range
  if x.srow ~= y.srow then return x.srow < y.srow end
  if x.scol ~= y.scol then return x.scol < y.scol end
  if x.erow ~= y.erow then return x.erow < y.erow end
  if x.ecol ~= y.ecol then return x.ecol < y.ecol end
  return a.kind < b.kind
end

---@param bufnr integer
---@param srow? integer inclusive
---@param erow? integer inclusive
---@return inkmath.MathNode[] nodes
---@return {has_error: boolean} info has_error: the parse tree has syntax errors
function M.detect(bufnr, srow, erow)
  local spec = registry.of(bufnr)
  local modname = spec and spec.detector -- a missing module yields no nodes
  if not modname then return {}, { has_error = false } end
  local ok, mod = pcall(require, modname)
  if not ok then
    if type(mod) == "string" and mod:find("module '" .. modname .. "' not found", 1, true) then return {}, { has_error = false } end
    error(mod)
  end
  local nodes, has_error = mod.detect(bufnr, srow, erow)
  if srow or erow then
    local lo, hi = srow or 0, erow or math.huge
    nodes = vim.tbl_filter(function(n) return n.range.srow <= hi and n.range.erow >= lo end, nodes)
  end
  table.sort(nodes, M.before)
  return nodes, { has_error = has_error == true }
end

return M
