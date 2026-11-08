-- Notifications: filtered by the `log.level` option; `once` remembers its cause
-- until `rearm`.
local M = {}

local LEVELS =
  { error = vim.log.levels.ERROR, warn = vim.log.levels.WARN, info = vim.log.levels.INFO, debug = vim.log.levels.DEBUG }
M.LEVEL_NAMES = vim.tbl_keys(LEVELS)
table.sort(M.LEVEL_NAMES)

local fired = {} ---@type table<string, true> causes notified by `once`

local function threshold()
  local ok, lvl = pcall(function() return require("inkmath.config").get().log.level end)
  return LEVELS[ok and lvl or "warn"] or LEVELS.warn
end

---@param msg string
---@param level? integer vim.log.levels (default INFO)
function M.notify(msg, level)
  level = level or vim.log.levels.INFO
  if level < threshold() then return end
  if vim.v.vim_did_enter == 0 then
    -- during startup (a file given on the command line): after the first screen is
    -- drawn, so the message does not stop startup at a "Press ENTER" prompt
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function()
        vim.schedule(function() vim.notify(msg, level) end)
      end,
    })
    return
  end
  vim.notify(msg, level)
end

--- Notify once per `cause` (until rearmed).
---@param cause string
---@param msg string
---@param level? integer default WARN
function M.once(cause, msg, level)
  if fired[cause] then return end
  fired[cause] = true
  M.notify(msg, level or vim.log.levels.WARN)
end

--- Forget the causes starting with `prefix` (all when nil), so they notify again.
---@param prefix? string
function M.rearm(prefix)
  if not prefix then
    fired = {}
    return
  end
  for cause in pairs(fired) do
    if vim.startswith(cause, prefix) then fired[cause] = nil end
  end
end

--- Run fn(...) without ever raising into the editing flow: an error is notified once
--- per `cause` (ERROR).
---@param cause string
---@param fn function
function M.guard(cause, fn, ...)
  local ok, e = pcall(fn, ...)
  if not ok then M.once("error:" .. cause, "inkmath: " .. cause .. ": " .. tostring(e), vim.log.levels.ERROR) end
end

---@param fmt string
function M.debug(fmt, ...)
  if vim.log.levels.DEBUG < threshold() then return end
  M.notify("inkmath: " .. fmt:format(...), vim.log.levels.DEBUG)
end

return M
