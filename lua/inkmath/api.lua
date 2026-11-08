-- Public API (re-exported by require("inkmath")); :InkMath and the <Plug> maps call
-- only these. For enable/disable/toggle/is_enabled, `buf` nil means the global switch
-- and 0 the current buffer. Documented in doc/inkmath.txt (|inkmath-api|).
local enable = require("inkmath.enable")
local events = require("inkmath.events")

local M = {}

local function core() return require("inkmath.core") end

local function resolve(buf)
  return buf == 0 and vim.api.nvim_get_current_buf() or buf
end

local pending = vim.api.nvim_create_augroup("inkmath_pending", { clear = true })
--- buffers this module detached (policy, global disable): re-applying may attach
--- them again. Others that were detached (core.detach by hand) are left alone.
local released = {} ---@type table<integer, true>

local function release(b)
  released[b] = true
  core().detach(b)
end

--- Attach buffers newly allowed (hidden ones when next shown), detach those no
--- longer allowed and re-apply the config to the rest (after setup(), a global enable).
--- Attaching is deferred like a FileType attach (setup() may run inside FileType, e.g.
--- lazy.nvim `ft =`, before an ftplugin sets b:inkmath_disable) unless `now`.
---@param now? boolean attach visible buffers synchronously (explicit :InkMath! enable)
function M._reapply(now)
  for b in pairs(released) do
    if not vim.api.nvim_buf_is_valid(b) then released[b] = nil end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local ok = enable.allowed(b)
      if core().is_attached(b) then
        if ok then core().reconfigure(b) else release(b) end
      elseif ok and (released[b] or core()._generation(b) == 0) then
        released[b] = nil
        if #vim.fn.win_findbuf(b) == 0 then
          vim.api.nvim_clear_autocmds({ group = pending, buffer = b })
          vim.api.nvim_create_autocmd("BufWinEnter", { group = pending, buffer = b, once = true, callback = function() M._auto(b) end })
        elseif now then
          core().attach(b)
        else
          M._auto(b)
        end
      end
    end
  end
end

---@param buf integer|nil
---@param enabled boolean
local function toggled(buf, enabled)
  events.emit("Toggle", { buf = buf, enabled = enabled, scope = buf and "buffer" or "global" })
end

---@param buf? integer
function M.enable(buf)
  buf = resolve(buf)
  if not buf then
    enable.global(true)
    M._reapply(true)
    return toggled(nil, true)
  end
  enable.set_sticky(buf, false)
  local ok, why = enable.allowed(buf, { force = true })
  if not ok then
    vim.notify(("inkmath: not enabled in buffer %d (%s)"):format(buf, why), vim.log.levels.WARN)
    return
  end
  toggled(buf, core().attach(buf))
end

---@param buf? integer
function M.disable(buf)
  buf = resolve(buf)
  if not buf then
    enable.global(false)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if core().is_attached(b) then release(b) end
    end
    return toggled(nil, false)
  end
  enable.set_sticky(buf, true)
  core().detach(buf)
  toggled(buf, false)
end

---@param buf? integer
function M.toggle(buf)
  buf = resolve(buf)
  local on = buf and core().is_attached(buf) or (not buf and enable.global())
  if on then M.disable(buf) else M.enable(buf) end
end

---@param buf? integer
---@return boolean
function M.is_enabled(buf)
  if buf == nil then return enable.global() end
  return core().is_attached(resolve(buf))
end

---@param buf? integer
function M.refresh(buf)
  core().rearm_env() -- the user may have fixed the terminal, tmux or the backend
  core().refresh(resolve(buf or 0))
end

--- Delete the image cache and render every attached buffer again.
---@return integer files deleted
function M.clear_cache() return core().clear_cache() end

---@class inkmath.Formula
---@field id string placement id (content hash .. "#" .. occurrence)
---@field kind "inline"|"display"|"block"
---@field src string TeX source without delimiters
---@field env? string environment name (blocks)
---@field range {srow: integer, scol: integer, erow: integer, ecol: integer} 0-based, end exclusive
---@field rendered boolean an image is placed (or revealed under the cursor)
---@field error? string render error

--- Formulas of a buffer in source order, optionally only those overlapping the rows
--- range.srow..range.erow (0-based, inclusive). Attached buffers reuse the last
--- detection when unchanged.
---@param buf? integer default: current
---@param range? {srow: integer, erow: integer}
---@return inkmath.Formula[]
function M.get_formulas(buf, range)
  buf = resolve(buf or 0)
  local detect = require("inkmath.detect")
  local attached = core().is_attached(buf)
  local nodes = detect.number(attached and require("inkmath.detect.incr").detect(buf) or (detect.detect(buf)))
  local out = {}
  for _, n in ipairs(nodes) do
    local r = n.range
    if not range or (r.srow <= range.erow and r.erow >= range.srow) then
      local rendered, err = false, nil
      if attached then rendered, err = core()._formula_info(buf, n.id) end
      out[#out + 1] = { id = n.id, kind = n.kind, src = n.src, env = n.env, rendered = rendered, error = err,
        range = { srow = r.srow, scol = r.scol, erow = r.erow, ecol = r.ecol } }
    end
  end
  return out
end

--- The formula under the cursor of `win` (same hit-test as the cursor reveal: the
--- closing delimiter counts in insert mode).
---@param win? integer default: current
---@return inkmath.Formula|nil
function M.formula_at_cursor(win)
  local cur = vim.api.nvim_get_current_win()
  win = (win == nil or win == 0) and cur or win
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  row = row - 1
  local inclusive = win == cur and vim.fn.mode():sub(1, 1) == "i"
  local contains = require("inkmath.view.cursor").contains
  for _, f in ipairs(M.get_formulas(vim.api.nvim_win_get_buf(win), { srow = row, erow = row })) do
    if contains(f.range, row, col, inclusive) then return f end
  end
end

---@class inkmath.RenderResult
---@field path string PNG file
---@field cols integer
---@field rows integer
---@field width integer pixels (cols * cell width)
---@field height integer pixels (rows * cell height)
---@field key string cache key (api.placeholder uses it)

--- Render a TeX string outside any buffer. cb runs once: at once on a cache hit,
--- else from the main loop.
---@param tex string
---@param opts? {kind?: "inline"|"display", color?: string, scale?: number, width?: integer, macros?: table}
---@param cb fun(res: inkmath.RenderResult|nil, err: string|nil)
function M.render(tex, opts, cb)
  vim.validate("tex", tex, "string")
  vim.validate("cb", cb, "function")
  opts = opts or {}
  local user_cb = cb
  -- one behaviour on both paths (sync cache hit, async render): an error in cb is
  -- reported, never raised into the caller nor swallowed
  cb = function(...) require("inkmath.log").guard("render cb", user_cb, ...) end
  local ctxmod = require("inkmath.ctx")
  local ctx = ctxmod.for_string(opts)
  if not ctx then return cb(nil, ctxmod.NO_CELL_SIZE) end
  local kind = opts.kind or "inline"
  local node = { id = require("inkmath.detect").node_id(kind, nil, tex), kind = kind, src = tex,
    range = { srow = 0, scol = 0, erow = 0, ecol = #tex } }
  require("inkmath.render").render(node, ctx, function(img, err)
    if not img then return cb(nil, (err and err.message) or "render failed") end
    cb({ path = img.path, cols = img.cols, rows = img.rows, key = img.key,
      width = img.cols * ctx.cell_w, height = img.rows * ctx.cell_h }, nil)
  end)
end

--- Transmit a render result to the terminal and return the placeholder text that
--- shows it (e.g. in a float: set `lines` and highlight them with `hl`). The image
--- stays resident until release(id).
---@param res inkmath.RenderResult
---@return {lines: string[], hl: string, id: integer}
function M.placeholder(res)
  local images = require("inkmath.term.images")
  local id = images.ensure(res)
  if not id then error("inkmath: no free image id (raise image_ids.span)") end
  images.pin(id)
  return { lines = require("inkmath.view.placer").placeholder_rows(id, res.cols, res.rows), hl = images.hl(id), id = id }
end

--- Let the terminal image of a placeholder() be evicted again.
---@param id integer
function M.release(id) require("inkmath.term.images").unpin(id) end

--- Detect math in another filetype (see inkmath.detect.registry) and add it to
--- `filetypes`.
---@param ft string
---@param spec inkmath.FiletypeSpec
function M.register_filetype(ft, spec)
  require("inkmath.detect.registry").register(ft, spec)
  local config = require("inkmath.config")
  local fts = config.get().filetypes
  if not vim.tbl_contains(fts, ft) then config.set({ filetypes = vim.list_extend(vim.deepcopy(fts), { ft }) }, true) end
  M._reapply()
end

--- (plugin/) FileType of a configured filetype: attach after the other FileType
--- handlers ran (an ftplugin may set b:inkmath_disable), unless the buffer was
--- detached in between.
---@param buf integer
function M._auto(buf)
  local g = core()._generation(buf)
  vim.schedule(function()
    if core().is_attached(buf) then
      -- FileType again (:set ft=, :e): its ftplugin may have set 'conceallevel' without
      -- an OptionSet (handlers are not nested)
      return pcall(require("inkmath.view.conceal").recheck, buf)
    end
    if core()._generation(buf) == g and enable.allowed(buf) then pcall(core().attach, buf) end
  end)
end

return M
