-- Render ctx: color, cell size, container width, macros and the TeX preamble.
--
-- tex preamble source:
-- * without vimtex: the buffer's own lines before \begin{document} (unchanged);
-- * with vimtex: the preamble of vimtex's root file (b:vimtex.tex). The root's loaded
--   buffer is used when there is one (unsaved edits count), else the file on disk
--   (cached by mtime). `\input{f}`/`\include{f}` lines in that preamble are replaced
--   by the contents of f (one level, relative to the root's directory), so their
--   macros reach MathJax and tectonic (which compiles in a temp dir) sees them inline.
local cells = require("inkmath.term.cells")
local config = require("inkmath.config")
local fcache = require("inkmath.fcache")
local labels = require("inkmath.labels")
local latex = require("inkmath.detect.latex")
local macros = require("inkmath.render.macros")
local registry = require("inkmath.detect.registry")
local vimtex = require("inkmath.vimtex")

local M = {}

local MACRO_LINE = { "^%s*$", "^%s*\\newcommand", "^%s*\\renewcommand", "^%s*\\def", "^%s*\\DeclareMathOperator", "^%s*\\let" }

--- text consists only of macro definitions (and blank lines)
---@param text string
---@return boolean
function M.macro_only(text)
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local ok = false
    for _, p in ipairs(MACRO_LINE) do
      if line:match(p) then ok = true break end
    end
    if not ok then return false end
  end
  return vim.trim(text) ~= ""
end

--- `$$...$$` blocks of only macro definitions at the top of a markdown file.
local function markdown_macro_lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(200, vim.api.nvim_buf_line_count(buf)), false)
  local out, i = {}, 1
  while i <= #lines do
    local l = lines[i]
    if l:match("^%s*$") then
      i = i + 1
    elseif l:match("^%s*%$%$") then
      local body, j = l:gsub("^%s*%$%$", "", 1), i
      local closed = body:find("%$%$%s*$")
      if closed then body = body:gsub("%$%$%s*$", "") end
      local parts = { body }
      while not closed do
        j = j + 1
        if j > #lines then return out end
        local s = lines[j]
        if s:find("%$%$%s*$") then closed = true s = s:gsub("%$%$%s*$", "") end
        parts[#parts + 1] = s
      end
      local text = table.concat(parts, "\n")
      if not M.macro_only(text) then return out end
      vim.list_extend(out, parts)
      i = j + 1
    else
      return out
    end
  end
  return out
end

--- lines before \begin{document} ({} if there is none), as latex.preamble does
local function slice(lines)
  for i, l in ipairs(lines) do
    if l:match("^%s*\\begin%s*{document}") then return vim.list_slice(lines, 1, i - 1) end
  end
  return {}
end

local function realpath(p)
  if not p or p == "" then return nil end
  return vim.uv.fs_realpath(p) or vim.fs.normalize(p)
end

--- file named by \input{name} / \include{name}: name.tex first (as TeX does), then name
local function resolve(name, dir)
  local base = name:sub(1, 1) == "/" and name or (dir .. "/" .. name)
  for _, p in ipairs({ base .. ".tex", base }) do
    if fcache.stamp(p) then return p end
  end
end

local function input_name(line)
  local code = line:gsub("%%.*$", "")
  return code:match("^%s*\\input%s*{%s*([^}]-)%s*}%s*$")
    or code:match("^%s*\\include%s*{%s*([^}]-)%s*}%s*$")
    or code:match("^%s*\\input%s+([^%s{}\\]+)%s*$")
end

--- splice \input/\include lines; deps collects the stamps of the files read
local function splice(lines, dir, deps)
  local out = {}
  for _, l in ipairs(lines) do
    local name = input_name(l)
    local file = name and name ~= "" and resolve(name, dir)
    local body = file and fcache.lines(file)
    if body then
      deps[file] = fcache.stamp(file)
      vim.list_extend(out, body)
    else
      out[#out + 1] = l
    end
  end
  return out
end

--- Loaded buffer whose file is `path` (a realpath), compared by realpath over all
--- buffers, not bufnr(pattern). Realpaths are memoized per buffer name.
local real_names = {} ---@type table<string, string|false>
local function loaded_buf(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        if real_names[name] == nil then real_names[name] = realpath(name) or false end
        if real_names[name] == path then return b end
      end
    end
  end
end

--- root -> { key = "buf:<n>:<tick>" | "file:<stamp>", deps = {path = stamp}, lines }
local pre_cache = {} ---@type table<string, {key: string, deps: table<string, string>, lines: string[]}>

local function deps_ok(deps)
  for p, st in pairs(deps) do
    if fcache.stamp(p) ~= st then return false end
  end
  return true
end

--- The TeX preamble for a tex buffer (see the header). The result is cached per
--- root (by the root buffer's changedtick or the file's stamp, plus the stamps of
--- spliced files); treat it as read-only.
---@param buf integer
---@return string[]
function M.tex_preamble(buf)
  local root = vimtex.available(buf) and realpath(vimtex.root_file(buf))
  if not root then return latex.preamble(buf) end
  local own = realpath(vim.api.nvim_buf_get_name(buf))
  local rb = own == root and buf or loaded_buf(root)
  local key
  if rb then
    key = ("buf:%d:%d"):format(rb, vim.b[rb].changedtick)
  else
    local st = fcache.stamp(root)
    if not st then return latex.preamble(buf) end -- root unreadable
    key = "file:" .. st
  end
  local c = pre_cache[root]
  if c and c.key == key and deps_ok(c.deps) then return c.lines end
  local pre = rb and latex.preamble(rb) or fcache.derive(root, "preamble", slice)
  if not pre then return latex.preamble(buf) end
  local deps = {}
  local lines = splice(pre, vim.fs.dirname(root), deps)
  pre_cache[root] = { key = key, deps = deps, lines = lines }
  return lines
end

M.NO_CELL_SIZE = "inkmath: could not detect the terminal cell size (set `cell_size` in setup) (:checkhealth inkmath)"

--- foreground of a highlight group as #rrggbb (black/white by 'background' if unset)
local function fg_color(group)
  local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
  return string.format("#%06x", hl.fg or (vim.o.background == "light" and 0x000000 or 0xffffff))
end

--- A buffer-free ctx (api.render): the global config with `opts` on top. Always has
--- `opts` (the config it was built with). nil when the cell size is unknown.
---@param opts? {color?: string, scale?: number, width?: integer, macros?: table}
---@return inkmath.RenderCtx|nil
function M.for_string(opts)
  opts = opts or {}
  local cs = cells.cell_size()
  if not cs then return nil end
  local cfg = config.get()
  if opts.scale then cfg = vim.tbl_extend("force", cfg, { scale = opts.scale }) end
  return {
    color = opts.color or fg_color(cfg.highlight),
    cell_w = cs.w,
    cell_h = cs.h,
    container_px = (opts.width or vim.o.columns) * cs.w,
    macros = vim.tbl_extend("force", cfg.macros or {}, opts.macros or {}),
    opts = cfg,
  }
end

---@param buf integer
---@param notify? fun(cause: string, msg: string)
---@return inkmath.RenderCtx|nil
function M.build(buf, notify)
  local cfg = config.get(buf)
  local cs = cells.cell_size()
  if not cs then
    if notify then notify("cell_size", M.NO_CELL_SIZE) end
    return nil
  end
  local spec = registry.of(buf)
  local kind = spec and spec.ctx
  local m, preamble = {}, nil
  if kind == "tex" then
    preamble = M.tex_preamble(buf)
    m = macros.from_tex_preamble(preamble)
  elseif kind == "markdown" then
    m = macros.from_tex_preamble(markdown_macro_lines(buf))
  elseif type(kind) == "function" then
    local own = kind(buf) or {}
    m, preamble = own.macros or {}, own.preamble
  end
  local win = vim.fn.bufwinid(buf)
  -- the text area: the window minus its number/sign/fold columns (a display image as
  -- wide as the whole window is clipped at the right, where equation numbers sit)
  local width = vim.o.columns
  if win ~= -1 then
    local info = vim.fn.getwininfo(win)[1]
    width = math.max(1, vim.api.nvim_win_get_width(win) - (info and info.textoff or 0))
  end
  local tw = math.min(vim.bo[buf].textwidth, width)
  local out = {
    color = fg_color(cfg.highlight),
    cell_w = cs.w,
    cell_h = cs.h,
    container_px = (tw > 0 and tw or width) * cs.w,
    macros = vim.tbl_extend("force", m, cfg.macros or {}),
    preamble = preamble,
    opts = cfg, -- resolved config of this buffer (overrides applied)
  }
  if kind == "tex" and vimtex.available(buf) then
    -- equation numbers of the last compile (see inkmath.labels)
    local aux = vimtex.aux_file(buf)
    out.aux, out.aux_stamp, out.labels = aux, aux and fcache.stamp(aux), labels.read(aux)
  end
  return out
end

--- The aux file's stamp changed since `ctx` was built (BufEnter check).
---@param buf integer
---@param ctx inkmath.RenderCtx|nil
---@return boolean
function M.aux_changed(buf, ctx)
  if vim.bo[buf].filetype ~= "tex" or not vimtex.available(buf) then return false end
  local aux = vimtex.aux_file(buf)
  if not ctx then return aux ~= nil end
  return aux ~= ctx.aux or (aux and fcache.stamp(aux)) ~= ctx.aux_stamp
end

return M
