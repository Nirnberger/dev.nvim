-- Idle-sliced task runner: run(key, step) calls step() in slices of at most
-- `slice_ms`, one slice every `delay_ms`, and only while the user has not typed,
-- moved the cursor or scrolled (TextChanged*, CursorMoved*, WinScrolled) in the last
-- `delay_ms`. step() returns true while there is more to do. One task per key: run()
-- replaces it.
local M = {}

local tasks = {} ---@type table<string, {step: fun(): boolean, slice: number, delay: integer, timer: uv.uv_timer_t}>
local last_input = 0

local function now() return vim.uv.hrtime() / 1e6 end

vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "CursorMoved", "CursorMovedI", "WinScrolled" }, {
  group = vim.api.nvim_create_augroup("inkmath_idle", { clear = true }),
  callback = function() last_input = now() end,
})

local function stop(t)
  if t.timer and not t.timer:is_closing() then
    t.timer:stop()
    t.timer:close()
  end
end

---@param key string
function M.cancel(key)
  local t = tasks[key]
  if t then
    tasks[key] = nil
    stop(t)
  end
end

---@param key string
---@return boolean
function M.running(key) return tasks[key] ~= nil end

local function tick(key, t)
  if tasks[key] ~= t then return end
  local quiet = now() - last_input
  if quiet < t.delay then
    t.timer:start(math.max(1, math.ceil(t.delay - quiet)), 0, vim.schedule_wrap(function() tick(key, t) end))
    return
  end
  local start = now()
  local more = true
  repeat
    local ok, res = pcall(t.step)
    more = ok and res == true
  until not more or tasks[key] ~= t or now() - start >= t.slice
  if tasks[key] ~= t then return end
  if not more then return M.cancel(key) end
  t.timer:start(t.delay, 0, vim.schedule_wrap(function() tick(key, t) end))
end

--- Run the task's next slice now instead of after its delay (its work in flight
--- finished), when the user is still idle; else it waits as usual.
---@param key string
function M.poke(key)
  local t = tasks[key]
  if not t or t.poked then return end
  t.poked = true
  vim.schedule(function()
    t.poked = nil
    if tasks[key] ~= t or now() - last_input < t.delay then return end
    t.timer:stop()
    tick(key, t)
  end)
end

--- Run step() when idle until it returns a non-true value (or errors), or cancel(key).
---@param key string
---@param step fun(): boolean true: more to do
---@param opts? {slice_ms?: integer, delay_ms?: integer}
function M.run(key, step, opts)
  M.cancel(key)
  opts = opts or {}
  local t = { step = step, slice = opts.slice_ms or 4, delay = opts.delay_ms or 50, timer = vim.uv.new_timer() }
  tasks[key] = t
  t.timer:start(t.delay, 0, vim.schedule_wrap(function() tick(key, t) end))
end

return M
