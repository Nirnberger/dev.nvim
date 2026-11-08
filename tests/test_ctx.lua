-- Render ctx: preamble/macros source for multi-file vimtex projects (b:vimtex stubbed).
local cells = require("inkmath.term.cells")
local config = require("inkmath.config")

local function C() return require("inkmath.ctx") end -- lazy: a load error must fail cases, not the file
local function F() return require("inkmath.fcache") end

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local orig_cs
local bufs = {}

T["cases"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      orig_cs = cells.cell_size
      cells.cell_size = function() return { w = 10, h = 20 } end
      config.setup({})
    end,
    post_case = function()
      cells.cell_size = orig_cs
      for _, b in ipairs(bufs) do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
      bufs = {}
    end,
  },
})

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return vim.uv.fs_realpath(d)
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

--- bump the mtime so a rewrite within the same clock tick is still noticed
local function bump_mtime(path, secs)
  local st = vim.uv.fs_stat(path)
  vim.uv.fs_utime(path, st.atime.sec, st.mtime.sec + secs)
end

local MAIN = {
  "\\documentclass{article}",
  "\\usepackage{amsmath}",
  "\\input{macros}",
  "\\newcommand{\\R}{\\mathbb{R}}",
  "\\begin{document}",
  "\\include{chap/one}",
  "\\end{document}",
}

local function project()
  local d = tmpdir()
  write(d .. "/main.tex", MAIN)
  write(d .. "/macros.tex", { "\\newcommand{\\N}{\\mathbb{N}}" })
  write(d .. "/chap/one.tex", { "%! TEX root = ../main.tex", "\\begin{equation} \\R \\end{equation}" })
  return d
end

--- a loaded buffer for `path` (read from disk), with a stubbed b:vimtex pointing at `root`
local function open(path, root)
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  vim.bo[b].filetype = "tex"
  if root then vim.b[b].vimtex = { tex = root, root = vim.fs.dirname(root), name = "main" } end
  bufs[#bufs + 1] = b
  return b
end

-- seen in a real config with 'number' on: display images were as wide as the whole
-- window, so the number column pushed their right edge (equation numbers) out of view
T["cases"]["container width is the text area, not the whole window"] = function()
  local b = vim.api.nvim_create_buf(false, true)
  bufs[#bufs + 1] = b
  vim.api.nvim_win_set_buf(0, b)
  vim.bo[b].filetype = "tex"
  local win = vim.api.nvim_get_current_win()
  local saved = { vim.wo[win].number, vim.wo[win].signcolumn, vim.bo[b].textwidth }
  vim.wo[win].number, vim.wo[win].signcolumn = true, "yes"
  local textoff = vim.fn.getwininfo(win)[1].textoff
  local width = vim.api.nvim_win_get_width(win)
  eq(textoff > 0, true)
  eq(C().build(b).container_px, (width - textoff) * 10)
  vim.bo[b].textwidth = 10000 -- wider than the window: capped at the text area
  eq(C().build(b).container_px, (width - textoff) * 10)
  vim.bo[b].textwidth = 20
  eq(C().build(b).container_px, 200)
  vim.wo[win].number, vim.wo[win].signcolumn, vim.bo[b].textwidth = unpack(saved)
end

T["cases"]["without vimtex a subfile keeps its own (empty) preamble"] = function()
  local d = project()
  local b = open(d .. "/chap/one.tex")
  eq(C().tex_preamble(b), {})
  eq(C().build(b).macros.R, nil)
end

T["cases"]["subfile takes the root file's preamble from disk"] = function()
  local d = project()
  local b = open(d .. "/chap/one.tex", d .. "/main.tex")
  local pre = C().tex_preamble(b)
  eq(pre[1], "\\documentclass{article}")
  eq(vim.tbl_contains(pre, "\\begin{document}"), false)
  local ctx = C().build(b)
  eq(ctx.macros.R, "\\mathbb{R}")
  eq(ctx.preamble, pre)
end

T["cases"]["\\input in the root preamble is spliced in one level deep"] = function()
  local d = project()
  local b = open(d .. "/chap/one.tex", d .. "/main.tex")
  local pre = C().tex_preamble(b)
  eq(vim.tbl_contains(pre, "\\input{macros}"), false)
  eq(vim.tbl_contains(pre, "\\newcommand{\\N}{\\mathbb{N}}"), true)
  eq(C().build(b).macros.N, "\\mathbb{N}")
end

T["cases"]["\\input forms: no braces, explicit extension, missing file"] = function()
  local d = tmpdir()
  write(d .. "/a.tex", { "\\newcommand{\\A}{a}" })
  write(d .. "/b.sty.tex", { "\\newcommand{\\B}{b}" })
  write(d .. "/main.tex", {
    "\\documentclass{article}",
    "\\input a",
    "\\include{b.sty.tex} % comment",
    "\\input{missing}",
    "\\begin{document}",
    "\\end{document}",
  })
  write(d .. "/sub.tex", { "x" })
  local b = open(d .. "/sub.tex", d .. "/main.tex")
  local m = C().build(b).macros
  eq(m.A, "a")
  eq(m.B, "b")
  eq(vim.tbl_contains(C().tex_preamble(b), "\\input{missing}"), true) -- unresolvable: kept
end

T["cases"]["a loaded root buffer wins over the file on disk"] = function()
  local d = project()
  local rb = open(d .. "/main.tex")
  vim.api.nvim_buf_set_lines(rb, 3, 4, false, { "\\newcommand{\\R}{\\mathbf{R}}" }) -- unsaved
  local b = open(d .. "/chap/one.tex", d .. "/main.tex")
  eq(C().build(b).macros.R, "\\mathbf{R}")
end

T["cases"]["the root file is cached by mtime"] = function()
  local d = project()
  local b = open(d .. "/chap/one.tex", d .. "/main.tex")
  C().tex_preamble(b)
  local reads = F()._reads
  C().tex_preamble(b)
  eq(F()._reads, reads) -- no re-read while the mtime is unchanged
  local m2 = vim.deepcopy(MAIN)
  m2[4] = "\\newcommand{\\R}{X}"
  write(d .. "/main.tex", m2)
  bump_mtime(d .. "/main.tex", 5)
  eq(C().build(b).macros.R, "X")
  eq(F()._reads > reads, true)
end

T["cases"]["the root buffer itself (vimtex) uses its own lines"] = function()
  local d = project()
  local b = open(d .. "/main.tex", d .. "/main.tex")
  vim.api.nvim_buf_set_lines(b, 3, 4, false, { "\\newcommand{\\R}{Y}" })
  local m = C().build(b).macros
  eq(m.R, "Y")
  eq(m.N, "\\mathbb{N}") -- \input spliced for the root file too
end

T["cases"]["unreadable root falls back to the buffer's preamble"] = function()
  local d = project()
  write(d .. "/solo.tex", { "\\newcommand{\\S}{s}", "\\begin{document}", "\\end{document}" })
  local b = open(d .. "/solo.tex", d .. "/nope.tex")
  eq(C().build(b).macros.S, "s")
end

T["cases"]["M2: root buffer opened under a symlinked path is found"] = function()
  local d = project()
  local link = vim.fn.tempname()
  vim.uv.fs_symlink(d, link)
  local rb = open(link .. "/main.tex") -- same file, other name
  vim.api.nvim_buf_set_lines(rb, 3, 4, false, { "\\newcommand{\\R}{L}" }) -- unsaved
  local b = open(d .. "/chap/one.tex", d .. "/main.tex")
  eq(C().build(b).macros.R, "L")
end

T["cases"]["M3: preamble cached by changedtick / stamps"] = function()
  local d = project()
  local rb = open(d .. "/main.tex")
  local b = open(d .. "/chap/one.tex", d .. "/main.tex")
  local p1 = C().tex_preamble(b)
  eq(rawequal(C().tex_preamble(b), p1), true) -- unchanged: same table, no rebuild
  vim.api.nvim_buf_set_lines(rb, 3, 4, false, { "\\newcommand{\\R}{T}" })
  local p2 = C().tex_preamble(b)
  eq(rawequal(p2, p1), false)
  eq(vim.tbl_contains(p2, "\\newcommand{\\R}{T}"), true)
  -- an \input file changing on disk invalidates too
  write(d .. "/macros.tex", { "\\newcommand{\\N}{M}" })
  bump_mtime(d .. "/macros.tex", 5)
  eq(vim.tbl_contains(C().tex_preamble(b), "\\newcommand{\\N}{M}"), true)
end

return T
