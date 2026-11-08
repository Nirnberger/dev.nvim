-- Terminal image registry: image key -> kitty image id, residency (LRU) and pins.
-- Ids live in [start, stop) (config `image_ids`, read at the first image): fresh ids
-- first, then ids freed by eviction (oldest first); when none is left, the least
-- recently used unpinned resident is deleted and its id reused.
local kitty = require("inkmath.term.kitty")
local backend = require("inkmath.term.backend")

local M = {}

local space = require("inkmath.term.idspace")
M.MAX_ID = space.MAX
M.INSTANCES = space.INSTANCES

local ids = {} ---@type table<string, integer> key -> id
local keys = {} ---@type table<integer, string> id -> key
local imgs = {} ---@type table<integer, inkmath.Image> id -> image
local resident = {} ---@type table<integer, integer> id -> last-touch tick
local pins = {} ---@type table<integer, integer> id -> pin count (api.placeholder): never evicted
local free = {} ---@type integer[] evicted ids, oldest first
local failed = {} ---@type table<integer, true> resident ids whose transmit sent nothing (retried on ensure)
local in_use = {} ---@type table<integer, true> the caller's in-use set at the last evict(): never stolen
local start, stop, next_id ---@type integer?, integer?, integer?
local tick = 0
local dropped_cb = function(_) end ---@type fun(key: string)

--- `fn(key)` runs when an image some placement may still show is deleted (its id was
--- taken for another image): the caller clears those placements, so a placeholder
--- never points at a deleted or reused id.
---@param fn fun(key: string)
---@return fun(key: string) prev the handler it replaces (restore it with on_drop(prev))
function M.on_drop(fn)
  local prev = dropped_cb
  dropped_cb = fn
  return prev
end

--- (tests) process id indirection
function M._getpid() return vim.uv.os_getpid() end

---@return integer start, integer stop ids are in [start, stop)
function M.range()
  if not start then
    local o = require("inkmath.config").get().image_ids
    start = o.base + (o.per_instance and (M._getpid() % M.INSTANCES) * o.span or 0)
    stop, next_id = start + o.span, start
  end
  return start, stop
end

--- (tests) forget every id and re-read `image_ids`
function M._reset()
  ids, keys, imgs, resident, pins, free, failed, in_use = {}, {}, {}, {}, {}, {}, {}, {}
  start, stop, next_id, tick = nil, nil, nil, 0
end

--- Delete a resident image from the terminal and give its id back. notify: tell the
--- on_drop handler (the image may still be placed).
local function drop(id, notify)
  local b = backend.current()
  b.send(b.delete(id))
  resident[id] = nil
  -- the InkMathImg<id> group stays: the id keeps meaning the same colour
  local key = keys[id]
  if key then ids[key] = nil end
  keys[id], imgs[id], failed[id] = nil, nil, nil
  free[#free + 1] = id
  if notify and key then pcall(dropped_cb, key) end
end

--- unpinned residents, least recently used first
local function lru(pinned)
  local list = {}
  for id, t in pairs(resident) do
    if not (pinned[id] or pins[id]) then list[#list + 1] = { id = id, t = t } end
  end
  table.sort(list, function(a, b) return a.t < b.t end)
  return list
end

--- a fresh id, else a freed one, else the least recently used resident that is
--- neither pinned nor in the last evict()'s in-use set (on screen); nil when none
local function alloc()
  M.range()
  if next_id < stop then
    next_id = next_id + 1
    return next_id - 1
  end
  if #free == 0 then
    local oldest = lru(in_use)[1]
    if not oldest then return nil end
    drop(oldest.id, true) -- maybe placed since that evict()
  end
  return table.remove(free, 1)
end

---@param keep integer|nil previous LRU stamp to preserve (retransmit)
local function transmit(id, img, keep)
  local seqs = kitty.transmit_seq(id, img.path, img.cols, img.rows, kitty.is_local())
  if #seqs == 0 then
    -- nothing sent (remote: unreadable or empty PNG): keep the id accounted for as the
    -- oldest resident, so eviction frees it (it never leaks from the range) but not
    -- while it is on screen; ensure() retries the transmit
    failed[id], resident[id] = true, 0
    return
  end
  local b = backend.current()
  for _, seq in ipairs(seqs) do
    b.send(seq)
  end
  failed[id] = nil
  resident[id] = keep or tick
end

---@param img inkmath.Image
---@return integer|nil id nil: every id of the range is in use (image_ids.span too small)
function M.ensure(img)
  tick = tick + 1
  local id = ids[img.key]
  if not id then
    id = alloc()
    if not id then
      require("inkmath.log").once("ids", "inkmath: no free image id: raise image_ids.span (:checkhealth inkmath)")
      return nil
    end
    ids[img.key], keys[id] = id, img.key
  end
  imgs[id] = img
  if resident[id] and not failed[id] then
    resident[id] = tick
  else
    transmit(id, img)
  end
  return id
end

---@param key string
---@return integer|nil id assigned to an image key (nil when never ensured or evicted)
function M.id(key) return ids[key] end

---@return integer images resident in the terminal
function M.resident_count() return vim.tbl_count(resident) end

---@param id integer
function M.touch(id)
  if resident[id] then
    tick = tick + 1
    resident[id] = tick
  end
end

--- Keep `id` resident (not evicted) until a matching unpin().
---@param id integer
function M.pin(id) pins[id] = (pins[id] or 0) + 1 end

---@param id integer
function M.unpin(id)
  local n = (pins[id] or 0) - 1
  pins[id] = n > 0 and n or nil
end

---Delete least-recently-touched resident ids (not pinned) until #resident <= max.
---@param max integer
---@param pinned table<integer, true> in use by the caller (pin() ids are kept too)
function M.evict(max, pinned)
  in_use = pinned
  local count = vim.tbl_count(resident)
  for _, e in ipairs(lru(pinned)) do
    if count <= max then break end
    drop(e.id)
    count = count - 1
  end
end

--- Delete every image of ours from the terminal (exit): only our ids, never `d=a`.
function M.delete_all()
  local list = vim.tbl_keys(resident)
  table.sort(list)
  for _, id in ipairs(list) do
    drop(id)
  end
end

--- Transmit every resident image again (the terminal may have dropped them). One
--- whose PNG is gone (cache pruned or cleared meanwhile) is deleted instead, and the
--- on_drop handler clears its placements so it renders again.
function M.retransmit_all()
  local list = vim.tbl_keys(resident)
  table.sort(list)
  for _, id in ipairs(list) do
    if vim.uv.fs_stat(imgs[id].path) then
      transmit(id, imgs[id], resident[id])
    else
      drop(id, true)
    end
  end
end

---@return table<string, true> keys of the images resident in the terminal
function M.keys()
  local out = {}
  for id in pairs(resident) do
    if keys[id] then out[keys[id]] = true end
  end
  return out
end

---@param id integer
---@return string
function M.hl(id)
  local name = "InkMathImg" .. id
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = name })) then
    vim.api.nvim_set_hl(0, name, { fg = string.format("#%06x", id), default = false })
  end
  return name
end

return M
