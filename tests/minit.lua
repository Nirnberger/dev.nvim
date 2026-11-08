-- Test/bootstrap init; run with NVIM_APPNAME=inkmath-dev
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
-- Several test files point XDG_CACHE_HOME at an empty dir (isolated render cache). Tectonic
-- follows it on Linux and would re-download its whole bundle each time, so pin its cache first.
if vim.fn.has("linux") == 1 and not vim.env.TECTONIC_CACHE_DIR then
  vim.env.TECTONIC_CACHE_DIR = (vim.env.XDG_CACHE_HOME or (vim.env.HOME .. "/.cache")) .. "/tectonic"
end
-- opt/: loaded on demand (tests/test_vimtex_real.lua packadds it in a child Neovim)
local function ensure_opt(name, url)
  local dir = vim.fn.stdpath("data") .. "/site/pack/deps/opt/" .. name
  if vim.uv.fs_stat(dir) then return end
  vim.fn.mkdir(vim.fs.dirname(dir), "p")
  local out = vim.fn.system({ "git", "clone", "--depth=1", url, dir })
  if vim.v.shell_error ~= 0 then vim.notify("could not clone " .. name .. ": " .. out, vim.log.levels.WARN) end
end
ensure_opt("vimtex", "https://github.com/lervag/vimtex")
-- tests/test_plugins_real.lua: other LaTeX-math / conceal plugins, probed by interop.lua
ensure_opt("render-markdown.nvim", "https://github.com/MeanderingProgrammer/render-markdown.nvim")
ensure_opt("markview.nvim", "https://github.com/OXY2DEV/markview.nvim")
ensure_opt("snacks.nvim", "https://github.com/folke/snacks.nvim")
vim.cmd("packloadall")
for _, d in ipairs({ "/usr/local/bin", "/opt/homebrew/bin" }) do
  if not vim.env.PATH:find(d, 1, true) then vim.env.PATH = d .. ":" .. vim.env.PATH end
end
if vim.fn.exepath("node") == "" then
  local nodes = vim.fn.glob(vim.env.HOME .. "/.nvm/versions/node/*/bin", false, true)
  if #nodes > 0 then vim.env.PATH = nodes[#nodes] .. ":" .. vim.env.PATH end
end
require("nvim-treesitter").install({ "latex", "markdown", "markdown_inline" }):wait(300000)
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. package.path
require("mini.test").setup()
