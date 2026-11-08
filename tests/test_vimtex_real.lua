-- inkmath against the real vimtex (pack/deps/opt/vimtex, cloned by tests/minit.lua).
-- Runs in a child Neovim: vimtex installs global autocmds and options that must not leak
-- into the other test files. Skipped when vimtex was not cloned.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local vimtex_dir = vim.fn.stdpath("data") .. "/site/pack/deps/opt/vimtex"

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not vim.uv.fs_stat(vimtex_dir) then MiniTest.skip("vimtex not cloned") end
      child.restart({ "--headless", "--noplugin" }) -- mini.test adds --clean: no init file
      child.lua(("vim.opt.runtimepath:prepend(%q)"):format(root))
      -- --clean has no packpath; vimtex must precede the runtime, whose ftplugin/tex.vim sets
      -- b:did_ftplugin and would make vimtex's own ftplugin bail out
      child.lua(("vim.opt.runtimepath:prepend(%q)"):format(vimtex_dir))
      child.lua([[
        vim.g.tex_flavor = "latex" -- vimtex's own advice: a subfile has no \documentclass
        vim.cmd("filetype plugin indent on | syntax on")
        vim.cmd("runtime! plugin/vimtex.vim")
        vim.g.vimtex_compiler_enabled = 0 -- no latexmk in tests
        vim.g.vimtex_view_enabled = 0
        vim.g.vimtex_quickfix_enabled = 0
        function _G.open_tex(path)
          vim.cmd("edit " .. vim.fn.fnameescape(path))
          vim.wo.conceallevel = 2 -- synconcealed() reports nothing at 0
          vim.wait(5000, function() return vim.b.vimtex ~= nil end, 20)
          return vim.api.nvim_get_current_buf()
        end
      ]])
    end,
    post_once = function() child.stop() end,
  },
})

local function project()
  local dir = vim.uv.fs_realpath(vim.fn.tempname() .. "") or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  vim.fn.writefile({
    "\\documentclass{article}",
    "\\begin{document}",
    "$\\alpha^2$",
    "\\input{sub}",
    "\\end{document}",
  }, dir .. "/main.tex")
  vim.fn.writefile({ "%! TEX root = main.tex", "$\\beta$" }, dir .. "/sub.tex")
  return dir
end

T["vimtex sets b:vimtex and the adapter sees it"] = function()
  local dir = project()
  child.lua(("_G.buf = open_tex(%q)"):format(dir .. "/main.tex"))
  eq(child.lua_get([[vim.b[_G.buf].vimtex ~= nil]]), true)
  eq(child.lua_get([[require("inkmath.vimtex").available(_G.buf)]]), true)
  eq(child.lua_get([[require("inkmath.vimtex").root_file(_G.buf)]]), dir .. "/main.tex")
end

T["subfile resolves its root through vimtex"] = function()
  local dir = project()
  child.lua(("_G.buf = open_tex(%q)"):format(dir .. "/sub.tex"))
  eq(child.lua_get([[require("inkmath.vimtex").available(_G.buf)]]), true)
  eq(child.lua_get([[require("inkmath.vimtex").root_file(_G.buf)]]), dir .. "/main.tex")
end

T["clear_math_conceal removes vimtex math conceal and restores the global"] = function()
  local dir = project()
  child.lua(("_G.buf = open_tex(%q)"):format(dir .. "/main.tex"))
  -- line 3 is `$\alpha^2$`; column 2 is the backslash of \alpha
  local probe =
    [[(function() vim.cmd("redraw"); return vim.api.nvim_buf_call(_G.buf, function() return vim.fn.synconcealed(3, 2)[1] end) end)()]]
  eq(child.lua_get("vim.b[_G.buf].vimtex_syntax ~= nil"), true)
  eq(child.lua_get(probe), 1) -- vimtex conceals \alpha by default
  local before = child.lua_get("vim.g.vimtex_syntax_conceal")
  eq(child.lua_get([[require("inkmath.vimtex").clear_math_conceal(_G.buf)]]), true)
  eq(child.lua_get(probe), 0)
  eq(child.lua_get("vim.g.vimtex_syntax_conceal"), before)
  child.lua([[require("inkmath.vimtex").reload_syntax(_G.buf)]])
  eq(child.lua_get(probe), 1)
end

return T
