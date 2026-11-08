-- Sixel (foot, mlterm, xterm -ti vt340, Windows Terminal, ...). Overlay mode like iTerm2:
-- the worker writes `<key>.six` next to the cached PNG (request flag `sixel`), `paint` sends it.
local kitty = require("inkmath.term.kitty")
local tmux = require("inkmath.term.tmux")

local M = {}

M.name = "sixel"
M.mode = "overlay"
M.transmit = false
M.send = kitty.send

local redraw_pending = false

--- Sixel cannot be deleted either: repaint the cells (see iterm2.lua).
---@return string
function M.delete()
  redraw_pending = true
  return ""
end

--- Called by the overlay between deleting and painting: one `:redraw!` for all deletions.
---@return boolean redrew every image on screen is gone now
function M.flush()
  if not redraw_pending then return false end
  redraw_pending = false
  pcall(vim.cmd, "redraw!")
  return true
end

--- Does a primary device attributes reply (`CSI ? 62 ; 4 ; c`) list attribute 4 (Sixel)?
---@param seq string
---@return boolean
function M.da1_has_sixel(seq)
  local attrs = seq:match("\27%[%?([%d;]+)c")
  if not attrs then return false end
  for a in attrs:gmatch("%d+") do
    if a == "4" then return true end
  end
  return false
end

--- Ask the terminal (DA1), wait at most 200 ms. Memoized by backend.get() through detect().
---@return boolean
local da1 ---@type boolean|nil memoized for the session: a reset must not cost 200 ms again
local function query_da1()
  if da1 ~= nil then return da1 end
  if #vim.api.nvim_list_uis() == 0 then return false end
  local answered, sixel = false, false
  local group = vim.api.nvim_create_augroup("inkmath_da1", { clear = true })
  vim.api.nvim_create_autocmd("TermResponse", {
    group = group,
    callback = function(ev)
      local seq = (type(ev.data) == "table" and ev.data.sequence) or vim.v.termresponse or ""
      if seq:match("\27%[%?[%d;]+c") then
        answered, sixel = true, M.da1_has_sixel(seq)
        return true
      end
    end,
  })
  kitty.send("\27[c")
  vim.wait(200, function() return answered end, 10)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  if answered then da1 = sixel end -- no answer may just be slowness (ssh): ask again next time
  return sixel
end

---@param env? table
---@return boolean
function M.probe(env)
  local real = env == nil or env == vim.env
  env = env or vim.env
  if tmux.in_tmux() and real and not tmux.passthrough_enabled() then return false end
  local term = env.TERM or ""
  if term:match("foot") or term:match("mlterm") or term:match("^xterm.*sixel") or (env.WT_SESSION or "") ~= "" then
    return true
  end
  return real and query_da1()
end

---@param path string
---@return string|nil
local function six_path(path) return (path:gsub("%.png$", "") .. ".six") end

local converting = {} ---@type table<string, true>

--- `.six` for images the worker did not encode (cache entries from before, tectonic fallback):
--- magick runs in the background and the overlay repaints when the file is there.
local function convert(png, six)
  if converting[six] or vim.fn.executable("magick") ~= 1 then return end
  converting[six] = true
  local tmp = ("%s.tmp.%d.six"):format(six:gsub("%.six$", ""), vim.uv.os_getpid())
  vim.system({ "magick", png, "-background", "none", "sixel:" .. tmp }, {}, function(r)
    if r.code == 0 then
      os.rename(tmp, six)
    else
      os.remove(tmp)
    end
    vim.schedule(function()
      converting[six] = nil
      require("inkmath.view.overlay").repaint()
    end)
  end)
end

---@param img {path: string, cols: integer, rows: integer, id: integer}
---@param row integer
---@param col integer
---@return string[]
function M.paint(img, row, col)
  local six = six_path(img.path)
  if not vim.uv.fs_stat(six) then
    convert(img.path, six)
    return {}
  end
  local f = io.open(six, "rb")
  if not f then return {} end
  local data = f:read("*a")
  f:close()
  if not data or #data == 0 then return {} end
  return { ("\0277\27[%d;%dH%s\0278"):format(row, col, data) }
end

return M
