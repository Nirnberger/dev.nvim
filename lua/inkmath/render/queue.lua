-- Render queue. refresh() replaces a buffer's queue with the nodes that still need a
-- render, ordered visible first, then one screen in the scroll direction, then the
-- rest of the margin, then the background fill's off-screen ones; so requests for
-- nodes that scrolled out of the margin or were edited away are dropped before they
-- reach a worker. At most M.max_inflight distinct renders wait for a MathJax worker
-- at once (a cold open of 200 formulas does not queue a later visible request behind
-- all of them in the worker's stdin). A slot is freed when the MathJax stage ends:
-- tectonic work (the fallback, or backend = "tectonic") holds none, as tectonic has
-- its own queue that batches. The first queued job starts the MathJax worker (no
-- worker is spawned for an open whose formulas are all cached).
local mathjax = require("inkmath.render.mathjax")

local M = {}

M.max_inflight = 8

---@class inkmath.Job
---@field node inkmath.MathNode
---@field ctx inkmath.RenderCtx
---@field tick integer
---@field g integer
---@field key string
local queues = {} ---@type table<integer, {jobs: inkmath.Job[], i: integer}>
local running = {} ---@type table<string, true> render keys in flight (counted)
local inflight = {} ---@type table<integer, integer> buf -> counted renders in flight
local active = 0
local pumping, again = false, false

---@class inkmath.QueueHooks
---@field ok fun(buf: integer, job: inkmath.Job): boolean the job can still be placed
---@field run fun(buf: integer, job: inkmath.Job, done: fun()) start it; done() frees its slot
local hooks = { ok = function() return false end, run = function() end }

--- (core) how jobs are checked and started
---@param h inkmath.QueueHooks
function M.setup(h) hooks = h end

local function next_job()
  local cb = vim.api.nvim_get_current_buf()
  local order = { cb }
  for b in pairs(queues) do
    if b ~= cb then order[#order + 1] = b end
  end
  for _, b in ipairs(order) do
    local q = queues[b]
    while q and q.i <= #q.jobs do
      local job = q.jobs[q.i]
      q.i = q.i + 1
      if hooks.ok(b, job) then return b, job end
    end
    if q then queues[b] = nil end
  end
end

local function pump()
  if pumping then
    again = true
    return
  end
  pumping = true
  repeat
    again = false
    while active < M.max_inflight do
      local b, job = next_job()
      if not b then break end
      local key = job.key
      local counted = not running[key] -- else it joins the render in flight
      if counted then
        running[key] = true
        active = active + 1
        inflight[b] = (inflight[b] or 0) + 1
      end
      local freed = false
      local function free()
        if freed or not counted then return end
        freed = true
        running[key] = nil
        active = active - 1
        inflight[b] = math.max(0, (inflight[b] or 1) - 1)
      end
      local ok = pcall(hooks.run, b, job, function()
        if not counted or freed then return end
        free()
        again = true
        if not pumping then vim.schedule(function() pcall(pump) end) end
      end)
      if not ok then free() end
    end
  until not again
  pumping = false
end

--- Replace the queue of `buf` with `jobs` (priority order) and start what the cap
--- allows.
---@param buf integer
---@param jobs inkmath.Job[]
function M.push(buf, jobs)
  queues[buf] = { jobs = jobs, i = 1 }
  local j = jobs[1]
  if j and require("inkmath.config").of(j.ctx).backend ~= "tectonic" then mathjax.start() end
  pump()
end

---@param buf integer
function M.drop(buf) queues[buf] = nil end

--- jobs of `buf` not started yet
---@param buf integer
---@return boolean
function M.waiting(buf)
  local q = queues[buf]
  return q ~= nil and q.i <= #q.jobs
end

--- (tests) queued jobs of a buffer, in order, and the number of renders in flight
---@return inkmath.MathNode[] nodes, integer active
function M.list(buf)
  local q = queues[buf]
  local out = {}
  if q then
    for k = q.i, #q.jobs do out[#out + 1] = q.jobs[k].node end
  end
  return out, active
end

--- Queued and in-flight counts per buffer (all buffers, or just `buf`).
---@param buf? integer
---@return table<integer, {queued: integer, inflight: integer}>
function M.stats(buf)
  local out = {}
  local function add(b)
    local q = queues[b]
    out[b] = { queued = q and math.max(0, #q.jobs - q.i + 1) or 0, inflight = inflight[b] or 0 }
  end
  if buf then
    add(buf)
  else
    for b in pairs(queues) do add(b) end
    for b, n in pairs(inflight) do
      if n > 0 and not out[b] then add(b) end
    end
  end
  return out
end

--- (tests) forget every queued and in-flight render
function M.reset()
  queues, running, inflight, active = {}, {}, {}, 0
end

return M
