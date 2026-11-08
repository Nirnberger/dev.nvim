-- Client for the persistent node MathJax worker (worker/mathjax.mjs).
local M = {}

local MAX_RESTARTS = 3
M.timeout_ms = nil ---@type integer|nil per-request timeout; nil: config timeouts.mathjax_ms (tests set it)

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
local worker_path = root .. "/worker/mathjax.mjs"

---@class inkmath.WorkerState
---@field proc vim.SystemObj
---@field pending table<integer, {cb: fun(res: table|nil, err: string|nil), timer: uv.uv_timer_t|nil}>
---@field buf string
---@field slot inkmath.WorkerSlot

-- A pool of workers (config `workers`, default 2): MathJax is CPU-bound, so several
-- processes render in parallel. Each slot has its own restart cap.
---@class inkmath.WorkerSlot
---@field cur inkmath.WorkerState|nil
---@field spawns integer
local slots = {} ---@type inkmath.WorkerSlot[]
local next_id = 0

local function pool_size()
  local ok, n = pcall(function() return require("inkmath.config").get().workers end)
  n = ok and tonumber(n) or 1
  return math.max(1, math.floor(n or 1))
end

--- the worker's argv from `node_cmd` (nil: node not executable)
---@return string[]|nil
function M._argv() return require("inkmath.render").argv(require("inkmath.config").get().node_cmd, worker_path) end

local avail ---@type {cmd: string, ok: boolean}|nil memoized (exepath, fs_stat per attach)

--- Static check: node is executable and worker deps are installed. Memoized per
--- `node_cmd`; _reset_available() checks again (after :InkMath build).
---@return boolean
function M.available()
  local cmd = vim.inspect(require("inkmath.config").get().node_cmd)
  if not (avail and avail.cmd == cmd) then
    avail = { cmd = cmd, ok = M._argv() ~= nil and vim.uv.fs_stat(root .. "/worker/node_modules") ~= nil }
  end
  return avail.ok
end

function M._reset_available() avail = nil end

local function stop_timer(entry)
  if entry.timer then
    entry.timer:stop()
    if not entry.timer:is_closing() then entry.timer:close() end
    entry.timer = nil
  end
end

local function fail_all(state, msg)
  local pending = state.pending
  state.pending = {}
  for _, entry in pairs(pending) do
    stop_timer(entry)
    vim.schedule(function() pcall(entry.cb, nil, msg) end)
  end
end

local function dispatch(state, line)
  if line:match("^%s*$") then return end
  local ok, res = pcall(vim.json.decode, line)
  if not ok or type(res) ~= "table" then return end
  local entry = state.pending[res.id]
  if not entry then return end
  state.pending[res.id] = nil
  stop_timer(entry)
  if res.ok then
    pcall(entry.cb, res, nil)
  else
    pcall(entry.cb, nil, type(res.error) == "string" and res.error or "render failed")
  end
end

--- (Re)start the worker of one slot (under its restart cap).
---@param slot inkmath.WorkerSlot
---@return boolean
local function spawn(slot)
  if slot.cur then return true end
  if slot.spawns > MAX_RESTARTS then -- first spawn + 3 restarts
    return false
  end
  local state = { pending = {}, buf = "" }
  local ok, proc = pcall(vim.system, M._argv(), {
    stdin = true,
    stdout = function(_, data)
      if not data then return end
      state.buf = state.buf .. data
      local lines = {}
      while true do
        local nl = state.buf:find("\n", 1, true)
        if not nl then break end
        lines[#lines + 1] = state.buf:sub(1, nl - 1)
        state.buf = state.buf:sub(nl + 1)
      end
      if #lines > 0 then
        vim.schedule(function()
          for _, l in ipairs(lines) do
            dispatch(state, l)
          end
        end)
      end
    end,
    stderr = false,
  }, function()
    vim.schedule(function()
      if slot.cur == state then slot.cur = nil end
      fail_all(state, "worker exited")
    end)
  end)
  if not ok then return false end
  state.proc = proc
  state.slot = slot
  slot.spawns = slot.spawns + 1
  slot.cur = state
  return true
end

local function ensure_slots()
  for i = 1, pool_size() do
    slots[i] = slots[i] or { spawns = 0 }
  end
end

--- Make sure one worker runs (the rest of the pool starts on demand, see pick).
---@return boolean any worker is running
function M.start()
  if not M.available() then return false end
  ensure_slots()
  for i = 1, pool_size() do
    if slots[i].cur then return true end
  end
  for i = 1, pool_size() do
    if spawn(slots[i]) then return true end
  end
  return false
end

--- Start every worker of the pool (those not running and under their restart cap).
---@return boolean any worker is running
function M.start_all()
  if not M.available() then return false end
  ensure_slots()
  local any = false
  for i = 1, pool_size() do
    if spawn(slots[i]) then any = true end
  end
  return any
end

local function load(st)
  local n = 0
  for _ in pairs(st.pending) do
    n = n + 1
  end
  return n
end

--- The running worker with the fewest pending requests. When even that one is busy,
--- the next slot's worker is started (on demand) and gets the request.
---@return inkmath.WorkerState|nil
local function pick()
  local best, best_load
  for i = 1, pool_size() do
    local st = slots[i] and slots[i].cur
    if st then
      local n = load(st)
      if not best or n < best_load then
        best, best_load = st, n
      end
    end
  end
  if not best or best_load > 0 then
    ensure_slots()
    for i = 1, pool_size() do
      if not slots[i].cur and spawn(slots[i]) then return slots[i].cur end
    end
  end
  return best
end

--- Send `req` (id assigned here) to `state`; `cb` is called exactly once, always
--- asynchronously, also on a timeout (which kills that worker).
local function send(state, req, cb)
  next_id = next_id + 1
  local id = next_id
  req = vim.tbl_extend("force", req, { id = id })
  local entry = { cb = cb }
  state.pending[id] = entry
  local timer = vim.uv.new_timer()
  entry.timer = timer
  timer:start(M.timeout_ms or require("inkmath.config").get().timeouts.mathjax_ms, 0, function()
    vim.schedule(function()
      if state.pending[id] ~= entry then return end
      state.pending[id] = nil
      stop_timer(entry)
      -- a hung worker is useless: kill it (counts toward the restart cap on next start)
      if state.slot.cur == state then state.slot.cur = nil end
      pcall(function() state.proc:kill("sigkill") end)
      pcall(cb, nil, "worker timeout")
    end)
  end)
  local ok = pcall(function() state.proc:write(vim.json.encode(req) .. "\n") end)
  if not ok and state.pending[id] then
    state.pending[id] = nil
    stop_timer(entry)
    vim.schedule(function() pcall(cb, nil, "worker exited") end)
  end
end

--- Start one worker and have it render a tiny formula, so node + MathJax start-up,
--- the input/output setup and the JIT are done before the first real request.
--- The other workers of the pool start when requests queue up. Idempotent.
function M.warm()
  if not M.start() then return end
  for i = 1, pool_size() do
    local st = slots[i] and slots[i].cur
    if st and not st.warmed then
      st.warmed = true
      local out = vim.fn.tempname() .. ".png"
      send(st, {
        tex = "x^2",
        display = false,
        macros = {},
        color = "#000000",
        cell_w = 10,
        cell_h = 20,
        container_px = 100,
        x_height = 0.45,
        baseline = 0.78,
        scale = 1,
        out = out,
      }, function() pcall(vim.uv.fs_unlink, out) end)
    end
  end
end

---@return integer|nil pid of the first running worker
function M.pid()
  for i = 1, #slots do
    if slots[i].cur then return slots[i].cur.proc.pid end
  end
  return nil
end

---@return {pid: integer, pending: integer}[] running workers and their pending requests
function M.stats()
  local out = {}
  for i = 1, #slots do
    local st = slots[i].cur
    if st then out[#out + 1] = { pid = st.proc.pid, pending = load(st) } end
  end
  return out
end

---@return integer[] pids of the running workers
function M.pids()
  local out = {}
  for i = 1, #slots do
    if slots[i].cur then out[#out + 1] = slots[i].cur.proc.pid end
  end
  return out
end

--- Send one request; `cb` is called exactly once, always asynchronously.
---@param req table  fields as the worker expects; `id` is assigned here
---@param cb fun(res: table|nil, err: string|nil)
function M.request(req, cb)
  local state = M.start() and pick()
  if not state then
    vim.schedule(function() pcall(cb, nil, "worker unavailable") end)
    return
  end
  send(state, req, cb)
end

function M.shutdown()
  local old = slots
  slots = {}
  for _, slot in ipairs(old) do
    local state = slot.cur
    slot.cur = nil
    if state then
      pcall(function() state.proc:write(nil) end)
      pcall(function() state.proc:kill("sigterm") end)
      fail_all(state, "worker shut down")
    end
  end
end

return M
