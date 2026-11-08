-- Background fill: while the user is idle (inkmath.idle), refresh a buffer in chunks
-- of fill.rows_per_step rows from the top, so rows a large edit left stale are
-- detected and formulas off-screen are rendered to the disk cache at the lowest
-- priority (at most fill.max_jobs renders not cached per step; core.refresh(buf,
-- range) does the work). Nothing is placed: scrolling places them from the cache.
-- An edit cancels it (cancel); the next refresh starts it again.
local config = require("inkmath.config")
local idle = require("inkmath.idle")

local M = {}

local done = {} ---@type table<integer, integer> buf -> changedtick a pass completed at
local started = {} ---@type table<integer, integer> buf -> changedtick of the running pass
--- buf -> {sig, [kind] = {[src] = true}}: formulas rendered to the cache for the ctx
--- with signature `sig` (a fill step skips them without a cache lookup)
local warm = {} ---@type table<integer, table>

local function key(buf) return "fill:" .. buf end

--- Start a pass unless one runs, or one completed for this text and no rows are stale.
---@param buf integer
---@param has_stale boolean
---@param refresh fun(buf: integer, range: {[1]: integer, [2]: integer}): boolean|nil, integer|nil
---  true: do the range again; and the number of renders queued
function M.start(buf, has_stale, refresh)
  local cfg = config.get().fill
  local tick0 = vim.b[buf].changedtick
  if not cfg.enabled or (done[buf] == tick0 and not has_stale) then return end
  if idle.running(key(buf)) and started[buf] == tick0 then return end -- a pass over this text runs
  started[buf] = tick0
  local row, busy = 0, false
  idle.run(key(buf), function()
    if not config.get().fill.enabled then return false end -- turned off while running
    if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].changedtick ~= tick0 then return false end
    if row >= vim.api.nvim_buf_line_count(buf) then
      -- a pass that queued renders: check again (a later refresh may have replaced
      -- the queue); done after a pass with nothing left to queue
      if not busy then
        done[buf] = tick0
        return false
      end
      row, busy = 0, false
    end
    local ok, again, queued = pcall(refresh, buf, { row, row + cfg.rows_per_step - 1 })
    if not ok then return false end
    busy = busy or again or (queued or 0) > 0
    if not again then row = row + cfg.rows_per_step end
    return true
  end)
end

--- Nothing is left to fill for the buffer's current text (refresh found no work).
---@param buf integer
function M.settled(buf)
  if not idle.running(key(buf)) then done[buf] = vim.b[buf].changedtick end
end

---@param buf integer
---@param sig string the render ctx's signature: another one forgets the warm set
function M.use_ctx(buf, sig)
  if not (warm[buf] and warm[buf].sig == sig) then warm[buf] = { sig = sig } end
end

--- `node` is in the disk cache (for the ctx of the last use_ctx).
---@param buf integer
---@param node inkmath.MathNode
function M.mark(buf, node)
  local w = warm[buf]
  if not w then return end
  local k = w[node.kind] or {}
  w[node.kind] = k
  k[node.src] = true
end

---@param buf integer
---@param node inkmath.MathNode
---@return boolean
function M.is_warm(buf, node)
  local w = warm[buf]
  local k = w and w[node.kind]
  return k ~= nil and k[node.src] == true
end

--- forget every warm set (the disk cache was cleared)
function M.reset_warm() warm = {} end

--- The renders a step queued finished: take the next step now (while idle) rather
--- than one idle delay later, so the fill runs at the workers' pace.
---@param buf integer
function M.kick(buf) idle.poke(key(buf)) end

---@param buf integer
function M.cancel(buf) idle.cancel(key(buf)) end

---@param buf integer
---@return boolean
function M.running(buf) return idle.running(key(buf)) end

---@param buf integer
---@return "off"|"running"|"done"|"pending" pending: not started, or stopped by an edit
function M.state(buf)
  if not config.get().fill.enabled then return "off" end
  if idle.running(key(buf)) then return "running" end
  return done[buf] == vim.b[buf].changedtick and "done" or "pending"
end

---@param buf integer
function M.forget(buf)
  M.cancel(buf)
  done[buf], started[buf], warm[buf] = nil, nil, nil
end

return M
