local M = {}

--- Multiplier for wall-clock limits in perf tests (INKMATH_PERF_FACTOR, default 1; shared CI runners are noisy).
M.perf_factor = tonumber(vim.env.INKMATH_PERF_FACTOR) or 1

---@param lines string[]
---@param ft string
---@return integer
function M.buf(lines, ft)
  local b = vim.api.nvim_create_buf(false, true)
  -- a normal buffer (not "nofile"), so the auto-attach guards treat it like a file;
  -- bufhidden stays "hide": "wipe" would refuse to abandon a modified buffer (E37)
  vim.bo[b].buftype, vim.bo[b].swapfile = "", false
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = ft
  local ok, parser = pcall(vim.treesitter.get_parser, b)
  if ok and parser then parser:parse(true) end
  return b
end

return M
