-- Enable policy: may this buffer be attached? core.attach is the mechanism and
-- checks none of this.
local config = require("inkmath.config")
local log = require("inkmath.log")
local registry = require("inkmath.detect.registry")

local M = {}

--- buf -> "off" (:InkMath disable) | "on" (:InkMath enable: the guards are waived).
--- Survives :e! and :set ft=, cleared when the buffer is wiped out.
local sticky = {} ---@type table<integer, "on"|"off">
local group = vim.api.nvim_create_augroup("inkmath_enable", { clear = true })

local function float_only(buf)
  local wins = vim.fn.win_findbuf(buf)
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_get_config(w).relative == "" then return false end
  end
  return #wins > 0
end

local function predicate_ok(buf, enabled)
  if type(enabled) ~= "function" then return enabled ~= false end
  local ok, res = pcall(enabled, buf)
  if not ok then log.once("enabled", "inkmath: `enabled` function failed: " .. tostring(res), vim.log.levels.ERROR) end
  return ok and res == true
end

---@param buf integer
---@param opts? {force?: boolean} explicit enable: skip the `filetypes` list and the buftype, size and float guards
---@return boolean allowed
---@return string|nil reason "global"|"buffer"|"sticky"|"filetype"|"enabled"|"buftype"|"size"|"float"
function M.allowed(buf, opts)
  if not vim.api.nvim_buf_is_valid(buf) then return false, "invalid" end
  local force = opts and opts.force
  -- remembered :InkMath enable: waives the guards below, not the `filetypes` list
  local waive = force or sticky[buf] == "on"
  if vim.g.inkmath_disable == true then return false, "global" end
  if vim.b[buf].inkmath_disable == true then return false, "buffer" end
  if sticky[buf] == "off" then return false, "sticky" end
  local cfg = config.get(buf)
  local ft = vim.bo[buf].filetype
  -- an explicit enable needs a detector, not an entry in `filetypes`
  if not registry.get(ft) or not (force or vim.tbl_contains(cfg.filetypes, ft)) then return false, "filetype" end
  if not predicate_ok(buf, cfg.enabled) then return false, "enabled" end
  if waive then return true end
  if vim.bo[buf].buftype ~= "" then return false, "buftype" end
  if vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf)) > cfg.max_file_size * 2 ^ 20 then
    return false, "size"
  end
  if float_only(buf) then return false, "float" end
  return true
end

--- Remember an explicit :InkMath disable (true) or enable (false) for this buffer.
---@param buf integer
---@param disabled boolean
function M.set_sticky(buf, disabled)
  if not sticky[buf] then
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = buf,
      once = true,
      callback = function() sticky[buf] = nil end,
    })
  end
  sticky[buf] = disabled and "off" or "on"
end

--- Set (on = true/false) or read the global switch (g:inkmath_disable).
---@param on? boolean
---@return boolean enabled
function M.global(on)
  if on ~= nil then vim.g.inkmath_disable = (not on) or nil end
  return vim.g.inkmath_disable ~= true
end

--- (tests) forget sticky state
function M._reset() sticky = {} end

return M
