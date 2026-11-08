-- Smoke test: attach the plugin to every dev/samples file with a stubbed terminal.
vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local config = require("inkmath.config")
local core = require("inkmath.core")
require("inkmath")
local cells = require("inkmath.term.cells")
local kitty = require("inkmath.term.kitty")
local tmux = require("inkmath.term.tmux")
local placer = require("inkmath.view.placer")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local orig = {}
local errors = {}

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, placer.ns, 0, -1, { details = true })
end

--- open dev/samples/<name> in the current window and return buf, lines
local function open(name, ft)
  local path = vim.fn.getcwd() .. "/dev/samples/" .. name
  local lines = vim.fn.readfile(path)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if ok and parser then parser:parse(true) end
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return buf, lines
end

local function find_row(lines, pat)
  for i, l in ipairs(lines) do
    if l:find(pat, 1, true) then return i - 1 end
  end
  error("pattern not found: " .. pat)
end

T["samples"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      orig.send, orig.supported, orig.in_tmux, orig.cell_size, orig.notify =
        kitty.send, kitty.supported, tmux.in_tmux, cells.cell_size, vim.notify
      errors = {}
      kitty.send = function() end
      kitty.supported = function() return true end
      tmux.in_tmux = function() return false end
      cells.cell_size = function() return { w = 10, h = 20 } end
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then errors[#errors + 1] = msg end
      end
      config.setup({})
      vim.o.conceallevel, vim.o.concealcursor = 0, ""
    end,
    post_case = function()
      pcall(core.detach, vim.api.nvim_get_current_buf())
      require("inkmath.term.images").evict(0, {})
      kitty.send, kitty.supported, tmux.in_tmux, cells.cell_size, vim.notify =
        orig.send, orig.supported, orig.in_tmux, orig.cell_size, orig.notify
      config.setup({})
      core._reset_notified()
    end,
  },
})

local function attach_and_wait(buf, n)
  eq(core.attach(buf, { sync = true }), true)
  vim.wait(60000, function() return #marks(buf) >= n end, 50)
end

T["samples"]["document.tex renders and keeps \\$5 as text"] = function()
  local buf, lines = open("document.tex", "tex")
  attach_and_wait(buf, 10)
  eq(#marks(buf) >= 10, true)
  eq(errors, {})
  -- the escaped dollar sits before the real `$\$5 + x$` formula on that row
  local row = find_row(lines, "price is")
  local first_math_col = lines[row + 1]:find("$\\$5", 1, true) - 1
  for _, m in ipairs(marks(buf)) do
    if m[2] == row then eq(m[3] >= first_math_col, true) end
  end
end

T["samples"]["inline.md renders and keeps \\$5 as text"] = function()
  local buf, lines = open("inline.md", "markdown")
  attach_and_wait(buf, 7)
  eq(#marks(buf) >= 7, true)
  eq(errors, {})
  local row = find_row(lines, "Cost is")
  for _, m in ipairs(marks(buf)) do eq(m[2] ~= row, true) end
end

T["samples"]["display.md renders"] = function()
  local buf = open("display.md", "markdown")
  attach_and_wait(buf, 2)
  eq(#marks(buf) >= 2, true)
  eq(errors, {})
end

T["samples"]["multiline.md renders and ignores code"] = function()
  local buf, lines = open("multiline.md", "markdown")
  attach_and_wait(buf, 2)
  eq(#marks(buf) >= 2, true)
  eq(errors, {})
  local fence = find_row(lines, "this $x$ stays text")
  local code = find_row(lines, "Inline code")
  for _, m in ipairs(marks(buf)) do
    eq(m[2] ~= fence, true)
    eq(m[2] ~= code, true)
  end
end

T["samples"]["broken.tex yields diagnostics"] = function()
  local buf = open("broken.tex", "tex")
  eq(core.attach(buf, { sync = true }), true)
  vim.wait(120000, function() return #vim.diagnostic.get(buf, { namespace = core.ns_err }) >= 2 end, 50)
  eq(#vim.diagnostic.get(buf, { namespace = core.ns_err }) >= 2, true)
  eq(errors, {})
end

return T
