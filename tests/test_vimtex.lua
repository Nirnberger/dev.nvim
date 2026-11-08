-- vimtex adapter. vimtex itself is not installed in the test env: b:vimtex is stubbed
-- with a plain dict shaped like vimtex's state (tex, root, name, compiler.out_dir,
-- compiler.file_info.jobname).
local function V() return require("inkmath.vimtex") end -- lazy: a load error must fail cases, not the file

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return vim.uv.fs_realpath(d)
end

local function touch(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ "\\relax" }, path)
end

local function tex_buf(name)
  local b = vim.api.nvim_create_buf(true, false)
  if name then vim.api.nvim_buf_set_name(b, name) end
  vim.bo[b].filetype = "tex"
  return b
end

T["absent vimtex"] = function()
  local b = tex_buf()
  eq(V().available(b), false)
  eq(V().root_file(b), nil)
  eq(V().aux_file(b), nil)
end

T["invalid buffer never raises"] = function()
  eq(V().available(99999), false)
  eq(V().root_file(99999), nil)
  eq(V().aux_file(99999), nil)
end

T["malformed b:vimtex"] = function()
  local b = tex_buf()
  vim.b[b].vimtex = { foo = 1 }
  eq(V().available(b), false)
  vim.b[b].vimtex = "x"
  eq(V().available(b), false)
  eq(V().aux_file(b), nil)
end

T["root file"] = function()
  local d = tmpdir()
  local b = tex_buf(d .. "/chap/one.tex")
  vim.b[b].vimtex = { tex = d .. "/main.tex", root = d, name = "main" }
  eq(V().available(b), true)
  eq(V().root_file(b), d .. "/main.tex")
end

T["aux next to the root file"] = function()
  local d = tmpdir()
  touch(d .. "/main.aux")
  local b = tex_buf(d .. "/main.tex")
  vim.b[b].vimtex = { tex = d .. "/main.tex", root = d, name = "main", compiler = { out_dir = "" } }
  eq(V().aux_file(b), d .. "/main.aux")
end

T["aux in relative out_dir with jobname"] = function()
  local d = tmpdir()
  touch(d .. "/build/thesis.aux")
  touch(d .. "/main.aux") -- stale copy next to the root: out_dir has precedence
  local b = tex_buf(d .. "/main.tex")
  vim.b[b].vimtex = {
    tex = d .. "/main.tex",
    root = d,
    name = "main",
    compiler = { out_dir = "build", file_info = { jobname = "thesis", root = d } },
  }
  eq(V().aux_file(b), d .. "/build/thesis.aux")
end

T["aux in absolute out_dir"] = function()
  local d, o = tmpdir(), tmpdir()
  touch(o .. "/main.aux")
  local b = tex_buf(d .. "/main.tex")
  vim.b[b].vimtex = { tex = d .. "/main.tex", root = d, name = "main", compiler = { out_dir = o } }
  eq(V().aux_file(b), o .. "/main.aux")
end

T["aux not built yet: expected path"] = function()
  local d = tmpdir()
  local b = tex_buf(d .. "/main.tex")
  vim.b[b].vimtex = { tex = d .. "/main.tex", root = d, name = "main", compiler = { out_dir = "build" } }
  eq(V().aux_file(b), d .. "/build/main.aux")
  vim.b[b].vimtex = { tex = d .. "/main.tex" }
  eq(V().aux_file(b), d .. "/main.aux")
end

T["aux uses vimtex's own get_file when it works"] = function()
  local d = tmpdir()
  touch(d .. "/elsewhere/x.aux")
  local b = tex_buf(d .. "/main.tex")
  vim.b[b].vimtex = { tex = d .. "/main.tex", root = d, name = "main" }
  local orig = V()._vim_get_file
  V()._vim_get_file = function(buf, ext)
    eq(buf, b)
    eq(ext, "aux")
    return d .. "/elsewhere/x.aux"
  end
  local ok, res = pcall(V().aux_file, b)
  V()._vim_get_file = orig
  eq(ok, true)
  eq(res, d .. "/elsewhere/x.aux")
end

T["get_file on a stub dict fails quietly"] = function()
  local b = tex_buf()
  vim.b[b].vimtex = { tex = "/x/main.tex", compiler = { out_dir = "" } }
  eq(V()._vim_get_file(b, "aux"), nil)
end

--- A fake vimtex syntax file: like vimtex's syntax/tex.vim it sets b:vimtex_syntax
--- and adds conceal items only for the g:vimtex_syntax_conceal keys that are on.
local FAKE_SYNTAX = {
  "if exists('b:current_syntax') | finish | endif",
  "let b:vimtex_syntax = {}",
  "let g:inkmath_seen_conceal = deepcopy(g:vimtex_syntax_conceal)",
  [[if g:vimtex_syntax_conceal.math_symbols | syntax match texMathSymbol "\\alpha" conceal cchar=α | endif]],
  [[if g:vimtex_syntax_conceal.styles | syntax match texMathCmdStyleBold "\\mathbf" conceal | endif]],
  [[if g:vimtex_syntax_conceal.accents | syntax match texCmdAccent "\\'a" conceal cchar=á | endif]],
  "let b:current_syntax = 'inkmathfake'",
}

local USER_CONCEAL = {
  accents = 1,
  ligatures = 1,
  cites = 1,
  fancy = 1,
  texTabularChar = 1,
  spacing = 1,
  greek = 1,
  math_bounds = 1,
  math_delimiters = 1,
  math_fracs = 1,
  math_super_sub = 1,
  math_symbols = 1,
  sections = 0,
  styles = 1,
}

local function fake_buf()
  local rtp = vim.fn.tempname()
  vim.fn.mkdir(rtp .. "/syntax", "p")
  vim.fn.writefile(FAKE_SYNTAX, rtp .. "/syntax/inkmathfake.vim")
  vim.opt.runtimepath:append(rtp)
  if vim.g.syntax_on == nil then
    vim.cmd("syntax enable")
    vim.schedule(function() vim.cmd("syntax off") end) -- do not leak into other test files
  end
  vim.g.vimtex_syntax_conceal = USER_CONCEAL
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, b)
  vim.wo.conceallevel = 2
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "\\alpha \\mathbf \\'a" })
  vim.bo[b].syntax = "inkmathfake"
  return b,
    function()
      vim.api.nvim_buf_delete(b, { force = true })
      vim.opt.runtimepath:remove(rtp)
      vim.g.vimtex_syntax_conceal = nil
      vim.g.inkmath_seen_conceal = nil
    end
end

T["math conceal: syntax reloaded with math keys off, global restored"] = function()
  local b, done = fake_buf()
  local ok, err = pcall(function()
    eq(vim.fn.synconcealed(1, 1)[1], 1)
    eq(vim.fn.synconcealed(1, 8)[1], 1)
    eq(V().clear_math_conceal(b), true)
    eq(vim.fn.synconcealed(1, 1)[1], 0) -- \alpha (math_symbols)
    eq(vim.fn.synconcealed(1, 8)[1], 0) -- \mathbf (styles)
    eq(vim.fn.synconcealed(1, 16)[1], 1) -- accents: not math, kept
    local seen = vim.g.inkmath_seen_conceal
    for _, k in ipairs({
      "math_bounds",
      "math_delimiters",
      "math_fracs",
      "math_super_sub",
      "math_symbols",
      "greek",
      "styles",
      "spacing",
    }) do
      eq({ k, seen[k] }, { k, 0 })
    end
    eq(seen.accents, 1)
    eq(seen.cites, 1)
    eq(vim.g.vimtex_syntax_conceal, USER_CONCEAL) -- the user's global is back
    eq(V()._reloading[b], nil)
  end)
  done()
  assert(ok, err)
end

T["math conceal: left alone without vimtex syntax"] = function()
  local b = vim.api.nvim_create_buf(false, true)
  vim.g.vimtex_syntax_conceal = USER_CONCEAL
  eq(V().clear_math_conceal(b), false)
  vim.g.vimtex_syntax_conceal = nil
  vim.api.nvim_buf_delete(b, { force = true })
  eq(V().clear_math_conceal(b), false) -- invalid buffer: no error
end

T["M1: latexmk aux_dir has precedence over out_dir"] = function()
  local d = tmpdir()
  touch(d .. "/aux/main.aux")
  touch(d .. "/build/main.aux")
  local b = tex_buf(d .. "/main.tex")
  vim.b[b].vimtex =
    { tex = d .. "/main.tex", root = d, name = "main", compiler = { aux_dir = "aux", out_dir = "build" } }
  eq(V().aux_file(b), d .. "/aux/main.aux")
  vim.b[b].vimtex =
    { tex = d .. "/main.tex", root = d, name = "main", compiler = { aux_dir = "aux2", out_dir = "out2" } }
  eq(V().aux_file(b), d .. "/aux2/main.aux") -- nothing built: highest-precedence path
end

T["M1: get_output_signature is the expected path when nothing exists"] = function()
  local d = tmpdir()
  local b = tex_buf(d .. "/main.tex")
  vim.b[b].vimtex = { tex = d .. "/main.tex", root = d, name = "main", compiler = { out_dir = "build" } }
  local orig = V()._vim_signature
  V()._vim_signature = function(_, ext) return d .. "/sig/main." .. ext end
  local ok, res = pcall(V().aux_file, b)
  V()._vim_signature = orig
  eq(ok, true)
  eq(res, d .. "/sig/main.aux")
  eq(V()._vim_signature(b, "aux"), nil) -- stub dict: no funcref, quietly nil
end

return T
