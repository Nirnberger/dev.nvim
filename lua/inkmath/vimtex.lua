-- Adapter for vimtex (https://github.com/lervag/vimtex). Everything here is optional:
-- without vimtex every function returns false/nil and never raises.
--
-- vimtex facts relied on (vimtex 3f96503, 2026-10-30):
-- * b:vimtex is the project state dict: .tex (absolute path of the root/main file),
--   .root (its directory), .name (its basename without extension), .compiler (the
--   compiler dict). (autoload/vimtex/state.vim, autoload/vimtex/state/class.vim)
-- * b:vimtex.compiler.get_file(ext) returns the first readable output file among the
--   roots $VIMTEX_OUTPUT_DIRECTORY, [compiler.aux_dir (latexmk),] compiler.out_dir,
--   file_info.root, each joined
--   with file_info.jobname (relative roots are taken relative to file_info.root), or
--   '' if none exists. (autoload/vimtex/compiler/_template.vim, _output_roots,
--   _get_file_candidates, get_file)
local M = {}

local function abs(path, base)
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then return vim.fs.normalize(path) end
  return vim.fs.normalize(base .. "/" .. path)
end

--- b:vimtex when it looks like vimtex's state dict, else nil.
---@param buf integer
---@return table|nil
function M.state(buf)
  local ok, st = pcall(function() return vim.b[buf].vimtex end)
  if not ok or type(st) ~= "table" or type(st.tex) ~= "string" or st.tex == "" then return nil end
  return st
end

---@param buf integer
---@return boolean
function M.available(buf) return M.state(buf) ~= nil end

--- Absolute path of vimtex's root (main) file for this buffer.
---@param buf integer
---@return string|nil
function M.root_file(buf)
  local st = M.state(buf)
  if not st then return nil end
  local ok, p = pcall(abs, st.tex, vim.fn.getcwd())
  return ok and p or nil
end

--- vimtex's own lookup: b:vimtex.compiler.get_file(ext), nil when it fails or finds
--- nothing (e.g. a stubbed b:vimtex without funcrefs). Overridable for tests.
---@param buf integer
---@param ext string
---@return string|nil
function M._vim_get_file(buf, ext)
  local ok, res = pcall(
    vim.api.nvim_buf_call,
    buf,
    function() return vim.fn.eval(("b:vimtex.compiler.get_file('%s')"):format(ext)) end
  )
  if ok and type(res) == "string" and res ~= "" then return res end
  return nil
end

--- b:vimtex.compiler.get_output_signature(ext): the path the compiler is expected to
--- write (newer vimtex); nil when unavailable. Overridable for tests.
---@param buf integer
---@param ext string
---@return string|nil
function M._vim_signature(buf, ext)
  local ok, res = pcall(vim.api.nvim_buf_call, buf, function()
    if vim.fn.eval("has_key(get(b:vimtex, 'compiler', {}), 'get_output_signature')") ~= 1 then return nil end
    return vim.fn.eval(("b:vimtex.compiler.get_output_signature('%s')"):format(ext))
  end)
  if ok and type(res) == "string" and res ~= "" then return res end
  return nil
end

--- Output file candidates in vimtex's order of precedence (see the header).
local function candidates(st, ext)
  local comp = type(st.compiler) == "table" and st.compiler or {}
  local info = type(comp.file_info) == "table" and comp.file_info or {}
  local root = (type(info.root) == "string" and info.root ~= "" and info.root)
    or (type(st.root) == "string" and st.root ~= "" and st.root)
    or vim.fs.dirname(st.tex)
  local job = (type(info.jobname) == "string" and info.jobname ~= "" and info.jobname)
    or (type(st.name) == "string" and st.name ~= "" and st.name)
    or vim.fn.fnamemodify(st.tex, ":t:r")
  local out = {}
  -- latexmk's _output_roots: env, aux_dir, out_dir, root (no nil holes for ipairs)
  local dirs = { vim.env.VIMTEX_OUTPUT_DIRECTORY or "", comp.aux_dir or "", comp.out_dir or "", root }
  for _, dir in ipairs(dirs) do
    if type(dir) == "string" and dir ~= "" then out[#out + 1] = abs(dir .. "/" .. job .. "." .. ext, root) end
  end
  return out
end

--- The project's .aux file: vimtex's get_file('aux'), else the first existing
--- candidate, else the path the compiler is expected to write (so a later compile
--- can be noticed by its mtime).
---@param buf integer
---@return string|nil
function M.aux_file(buf)
  local ok, res = pcall(function()
    local st = M.state(buf)
    if not st then return nil end
    local f = M._vim_get_file(buf, "aux")
    if f then return vim.fs.normalize(f) end
    local cands = candidates(st, "aux")
    for _, c in ipairs(cands) do
      if vim.uv.fs_stat(c) then return c end
    end
    local sig = M._vim_signature(buf, "aux")
    if sig then return vim.fs.normalize(sig) end
    return cands[1]
  end)
  return ok and res or nil
end

-- Math conceal. g:vimtex_syntax_conceal is global and vimtex reads it while it
-- defines the syntax rules (autoload/vimtex/syntax/core.vim, e.g. s:match_math_symbols:
-- `if !g:vimtex_syntax_conceal.math_symbols | return | endif`; styles ~1804-1888,
-- math_delimiters ~2299, spacing; package files such as p/unicode_math.vim and
-- p/amsmath.vim read it too). Syntax items are buffer-local, so the buffer's syntax
-- is reloaded with a temporarily patched global (these keys 0, the user's other keys
-- unchanged) and the global is restored right after.
-- `styles` and `spacing` also cover text mode (\textbf, \quad): vimtex has one key
-- for both.
M.MATH_CONCEAL_KEYS =
  { "math_bounds", "math_delimiters", "math_fracs", "math_super_sub", "math_symbols", "greek", "styles", "spacing" }

M._reloading = {} ---@type table<integer, true> buffers whose syntax inkmath is reloading

--- Reload this buffer's vimtex syntax without math conceal. Returns whether vimtex
--- syntax is active (b:vimtex_syntax, set by vimtex's syntax/tex.vim) and was reloaded.
---@param buf integer
---@return boolean
function M.clear_math_conceal(buf)
  local ok, res = pcall(function()
    if vim.b[buf].vimtex_syntax == nil or vim.bo[buf].syntax == "" then return false end
    local orig = vim.g.vimtex_syntax_conceal
    if type(orig) ~= "table" then return false end
    local patched = vim.deepcopy(orig)
    for _, k in ipairs(M.MATH_CONCEAL_KEYS) do
      patched[k] = 0
    end
    M._reloading[buf] = true
    vim.g.vimtex_syntax_conceal = patched
    local rok, rerr = pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("let &l:syntax = &l:syntax") end)
    vim.g.vimtex_syntax_conceal = orig
    M._reloading[buf] = nil
    if not rok then error(rerr) end
    return true
  end)
  M._reloading[buf] = nil
  return ok and res == true
end

--- Reload the buffer's syntax (undoes clear_math_conceal).
---@param buf integer
function M.reload_syntax(buf)
  pcall(vim.api.nvim_buf_call, buf, function()
    if vim.bo.syntax ~= "" then vim.cmd("let &l:syntax = &l:syntax") end
  end)
end

return M
