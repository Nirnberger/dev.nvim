-- Render errors of a buffer: one vim.diagnostic per failed formula plus an
-- InkMathError highlight over its source. Keyed by placement id.
local M = {}

M.ns = vim.api.nvim_create_namespace("inkmath_err")
local ns_mark = vim.api.nvim_create_namespace("inkmath_errmark")

---@class inkmath.RenderError
---@field range {srow: integer, scol: integer, erow: integer, ecol: integer}
---@field keys string[] cache keys the failed render was made for
---@field diag vim.Diagnostic
---@field mark? integer
local errs = {} ---@type table<integer, table<string, inkmath.RenderError>>

---@param buf integer
---@param id string
---@return inkmath.RenderError|nil
function M.get(buf, id) return errs[buf] and errs[buf][id] end

--- id -> error of a buffer (live table: do not modify)
---@param buf integer
---@return table<string, inkmath.RenderError>
function M.all(buf) return errs[buf] or {} end

--- Push the buffer's errors to vim.diagnostic.
---@param buf integer
function M.publish(buf)
  local list = {}
  for _, e in pairs(errs[buf] or {}) do list[#list + 1] = e.diag end
  if vim.api.nvim_buf_is_valid(buf) then vim.diagnostic.set(M.ns, buf, list) end
end

--- Forget one error (publish() shows the change).
---@return boolean removed
function M.clear(buf, id)
  local e = M.get(buf, id)
  if not e then return false end
  if e.mark then pcall(vim.api.nvim_buf_del_extmark, buf, ns_mark, e.mark) end
  errs[buf][id] = nil
  return true
end

---@param buf integer
---@param node inkmath.MathNode
---@param keys string[]
---@param err? {message?: string}
function M.set(buf, node, keys, err)
  M.clear(buf, node.id)
  local r = node.range
  local ok, mark = pcall(vim.api.nvim_buf_set_extmark, buf, ns_mark, r.srow, r.scol,
    { end_row = r.erow, end_col = r.ecol, hl_group = "InkMathError" })
  errs[buf] = errs[buf] or {}
  errs[buf][node.id] = {
    range = r,
    keys = keys,
    mark = ok and mark or nil,
    diag = { lnum = r.srow, col = r.scol, end_lnum = r.erow, end_col = r.ecol,
      severity = vim.diagnostic.severity.ERROR, source = "inkmath", message = (err and err.message) or "render failed" },
  }
end

--- Drop every error of the buffer, its highlights and diagnostics.
---@param buf integer
function M.reset(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns_mark, 0, -1)
    vim.diagnostic.reset(M.ns, buf)
  end
  errs[buf] = nil
end

return M
