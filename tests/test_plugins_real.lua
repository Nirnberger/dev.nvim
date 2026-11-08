-- interop.lua against the real render-markdown, markview and snacks.image (cloned into
-- pack/deps/opt/ by tests/minit.lua). One child Neovim per case: these plugins install
-- global autocmds. A plugin that was not cloned skips its cases.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local opt = vim.fn.stdpath("data") .. "/site/pack/deps/opt/"

--- Start a child with `name` first on the runtimepath; skip when it is missing.
local function start(name)
  if not vim.uv.fs_stat(opt .. name) then MiniTest.skip(name .. " not cloned") end
  child.restart({ "--headless", "--noplugin" })
  child.lua(("vim.opt.runtimepath:prepend(%q)"):format(root))
  child.lua(("vim.opt.runtimepath:prepend(%q)"):format(opt .. name))
  child.lua("vim.cmd('filetype plugin indent on | syntax on')")
end

local function md_buf()
  local f = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "# Title", "", "Inline $x^2$ math.", "", "$$", "\\alpha", "$$" }, f)
  return f
end

local T = MiniTest.new_set({ hooks = { post_once = function() child.stop() end } })

T["render-markdown: latex_on follows setup and manages sees the attached buffer"] = function()
  start("render-markdown.nvim")
  child.lua([[vim.cmd("runtime! plugin/render-markdown.lua")]])
  child.lua([[require("render-markdown").setup({})]])
  eq(child.lua_get([[require("inkmath.interop").plugins[1].loaded()]]), true)
  eq(child.lua_get([[require("inkmath.interop").plugins[1].latex_on()]]), true)
  child.lua(("vim.cmd('edit %s')"):format(md_buf()))
  child.lua(
    [[vim.wait(3000, function() return #require("inkmath.interop").managers(vim.api.nvim_get_current_buf()) > 0 end, 20)]]
  )
  eq(child.lua_get([[require("inkmath.interop").managers(vim.api.nvim_get_current_buf())]]), { "render-markdown" })
  child.lua([[require("render-markdown").setup({ latex = { enabled = false } })]])
  eq(child.lua_get([[require("inkmath.interop").plugins[1].latex_on()]]), false)
end

T["markview: defaults mean latex on, disabling turns it off, manages sees the buffer"] = function()
  start("markview.nvim")
  child.lua([[vim.cmd("runtime! plugin/markview.lua")]])
  eq(child.lua_get([[require("inkmath.interop").plugins[2].latex_on()]]), true)
  child.lua(("vim.cmd('edit %s')"):format(md_buf()))
  child.lua(
    [[vim.wait(3000, function() return #require("inkmath.interop").managers(vim.api.nvim_get_current_buf()) > 0 end, 20)]]
  )
  eq(child.lua_get([[require("inkmath.interop").plugins[2].loaded()]]), true)
  eq(child.lua_get([[require("inkmath.interop").managers(vim.api.nvim_get_current_buf())]]), { "markview" })
  child.lua([[require("markview").setup({ latex = { enable = false } })]])
  eq(child.lua_get([[require("inkmath.interop").plugins[2].latex_on()]]), false)
end

T["snacks.image: off by default, on when image.enabled, off with math disabled"] = function()
  start("snacks.nvim")
  eq(child.lua_get([[require("inkmath.interop").plugins[3].latex_on()]]), false)
  child.lua([[require("snacks").setup({ image = { enabled = true } })]])
  eq(child.lua_get([[require("inkmath.interop").plugins[3].loaded()]]), true)
  eq(child.lua_get([[require("inkmath.interop").plugins[3].latex_on()]]), true)
  child.lua([[
    Snacks.config.image.math = { enabled = false }
    local img = rawget(Snacks, "image")
    if img and rawget(img, "config") then img.config.math = { enabled = false } end
  ]])
  eq(child.lua_get([[require("inkmath.interop").plugins[3].latex_on()]]), false)
end

return T
