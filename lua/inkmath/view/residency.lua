-- Which images stay in the terminal. Placements live near the windows: after a
-- refresh, when idle, those farther than `keep_screens` window heights from every
-- window showing the buffer are cleared (1 while more than max_images would stay),
-- and scrolling back places them again from the disk cache. Placed images are
-- pinned; evict() deletes the least recently used of the others above max_images.
-- So the resident images stay near max_images however long the document, and ids
-- (image_ids.span >= 2 * max_images) do not run out.
local config = require("inkmath.config")
local cursor = require("inkmath.view.cursor")
local idle = require("inkmath.idle")
local images = require("inkmath.term.images")
local placer = require("inkmath.view.placer")
local state = require("inkmath.view.state")

local M = {}

--- Clear the buffer's placements outside every window's keep band (now).
---@param buf integer
function M.trim(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local views = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    views[#views + 1] = { top = info.topline - 1, bot = info.botline - 1, h = vim.api.nvim_win_get_height(win) }
  end
  if #views == 0 then return end
  local s = state.get(buf)
  local cfg = config.get()
  local function trim_to(k)
    local n = 0
    for id, e in pairs(s.nodes) do
      local r, keep = e.node.range, false
      for _, v in ipairs(views) do
        if r.srow <= v.bot + k * v.h and r.erow >= v.top - k * v.h then
          keep = true
          break
        end
      end
      if keep then
        n = n + 1
      else
        placer.clear(buf, id)
      end
    end
    return n
  end
  if trim_to(cfg.keep_screens) > cfg.max_images and cfg.keep_screens > 1 then trim_to(1) end
end

--- trim() when idle: deleting many extmarks costs a few ms, kept off the scroll path
---@param buf integer
---@param after? fun() runs after the trim (evict the images it unpinned)
function M.trim_later(buf, after)
  idle.run("trim:" .. buf, function()
    M.trim(buf)
    if after then after() end
    return false
  end)
end

---@param buf integer
function M.cancel(buf) idle.cancel("trim:" .. buf) end

--- Clear the placements (any of `bufs`) showing the image `key`.
---@param bufs integer[]
---@param key string
---@return integer[] buffers that lost a placement
function M.forget_key(bufs, key)
  local hit = {}
  for _, b in ipairs(bufs) do
    local s, found = state.get(b), false
    for id, e in pairs(s.nodes) do
      if e.img and e.img.key == key then
        placer.clear(b, id)
        found = true
      end
    end
    if found then hit[#hit + 1] = b end
  end
  return hit
end

--- Delete least recently used images above max_images; placed, revealed and preview
--- images of `bufs` are kept.
---@param bufs integer[]
function M.evict(bufs)
  local pinned = {}
  for _, b in ipairs(bufs) do
    local s = state.get(b)
    for _, tbl in ipairs({ s.nodes, s.revealed }) do
      for _, e in pairs(tbl) do
        local id = e.img and images.id(e.img.key)
        if id then pinned[id] = true end
      end
    end
  end
  for _, key in ipairs(cursor.preview_keys()) do
    local id = images.id(key)
    if id then pinned[id] = true end
  end
  images.evict(config.get().max_images, pinned)
end

return M
