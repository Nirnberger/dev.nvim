-- Isolated dev config; run with NVIM_APPNAME=inkmath-dev
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local base = vim.fn.stdpath("data") .. "/site/pack/deps/start/"
local function ensure(name, url, branch)
  local dir = base .. name
  if vim.uv.fs_stat(dir) then return end
  vim.fn.mkdir(base, "p")
  local cmd = { "git", "clone", "--depth=1" }
  if branch then vim.list_extend(cmd, { "--branch", branch }) end
  vim.list_extend(cmd, { url, dir })
  local out = vim.fn.system(cmd)
  assert(vim.v.shell_error == 0, out)
end
ensure("mini.nvim", "https://github.com/echasnovski/mini.nvim")
ensure("nvim-treesitter", "https://github.com/nvim-treesitter/nvim-treesitter", "main")
vim.cmd("packloadall")
vim.env.PATH = "/opt/homebrew/bin:" .. vim.env.PATH
require("nvim-treesitter").install({ "latex", "markdown", "markdown_inline" }):wait(300000)
vim.opt.runtimepath:prepend(root)

vim.o.termguicolors = true
vim.cmd.colorscheme("habamax")
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "tex", "markdown" },
  callback = function(ev) pcall(vim.treesitter.start, ev.buf) end,
})
require("inkmath").setup({})
