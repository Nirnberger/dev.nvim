local config = require("inkmath.config")
local kitty = require("inkmath.term.kitty")
local tmux = require("inkmath.term.tmux")

local M = {}

local cached ---@type {w:integer,h:integer}|false|nil false: every source failed

--- Forget the cached size (or failure); core calls this on VimResized/FocusGained.
function M.refresh()
  cached = nil
end

---@return integer rc, table|nil ws
function M._ioctl()
  local ok, rc, ws = pcall(function()
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
      typedef struct { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; } inkmath_winsize;
      int ioctl(int fd, unsigned long request, ...);
    ]])
    local req = (vim.uv.os_uname().sysname == "Darwin") and 0x40087468 or 0x5413
    local arr = ffi.new("inkmath_winsize[1]")
    local r = ffi.C.ioctl(1, req, ffi.cast("void*", arr))
    local w = arr[0] -- copy out of the cdata: arr is garbage-collected with this frame
    return r, { ws_row = w.ws_row, ws_col = w.ws_col, ws_xpixel = w.ws_xpixel, ws_ypixel = w.ws_ypixel }
  end)
  if not ok then return -1, nil end
  return rc, ws
end

local function from_ioctl()
  local rc, ws = M._ioctl()
  if rc ~= 0 or not ws then return nil end
  if ws.ws_col > 0 and ws.ws_row > 0 and ws.ws_xpixel > 0 and ws.ws_ypixel > 0 then
    return { w = math.floor(ws.ws_xpixel / ws.ws_col), h = math.floor(ws.ws_ypixel / ws.ws_row) }
  end
end

local function from_csi()
  local result
  local group = vim.api.nvim_create_augroup("inkmath_cellquery", { clear = true })
  vim.api.nvim_create_autocmd("TermResponse", {
    group = group,
    callback = function(ev)
      local seq = (type(ev.data) == "table" and ev.data.sequence) or vim.v.termresponse or ""
      local h, w = seq:match("\27%[6;(%d+);(%d+)t")
      if h and w then
        result = { w = tonumber(w), h = tonumber(h) }
        return true
      end
    end,
  })
  kitty.send("\27[16t")
  vim.wait(200, function() return result ~= nil end, 10)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  return result
end

function M._from_tmux()
  if not tmux.in_tmux() or vim.fn.executable("tmux") ~= 1 then return nil end
  local out = vim.fn.system({ "tmux", "display", "-p", "#{client_cell_width} #{client_cell_height}" })
  if vim.v.shell_error ~= 0 then return nil end
  local w, h = out:match("(%d+)%s+(%d+)")
  w, h = tonumber(w), tonumber(h)
  if w and h and w > 0 and h > 0 then return { w = w, h = h } end
end

---@return {w:integer,h:integer}|nil
function M.cell_size()
  local c = config.get().cell_size
  if c then
    return { w = c.w, h = c.h }
  end
  if cached == nil then
    -- inside tmux the CSI 16t reply goes to tmux, not the pane: ask tmux first.
    -- A failure is cached too (CSI waits up to 200 ms), until M.refresh().
    cached = from_ioctl() or M._from_tmux() or from_csi() or false
  end
  return cached or nil
end

return M
