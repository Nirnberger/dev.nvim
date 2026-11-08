-- Entry point: :InkMath, auto-attach on FileType, <Plug> maps, highlight defaults.
-- Loading must stay cheap: every require happens inside a callback.
if vim.g.loaded_inkmath then return end
vim.g.loaded_inkmath = 1

vim.api.nvim_create_user_command("InkMath", function(opts) require("inkmath.commands").run(opts) end, {
  nargs = "*",
  bang = true,
  desc = "inkmath: render LaTeX math as images (! = all buffers)",
  complete = function(lead, line) return require("inkmath.commands").complete(lead, line) end,
})

--- the configured filetypes; before inkmath.config is loaded only vim.g.inkmath is
--- read, with the schema default (config/schema.lua `filetypes`) inline: no require
--- here (tests/test_plugin.lua keeps them equal)
local function filetypes()
  local config = package.loaded["inkmath.config"]
  if config then return config.get().filetypes end
  local g = vim.g.inkmath
  return type(g) == "table" and type(g.filetypes) == "table" and g.filetypes or { "tex", "markdown", "quarto", "rmd" }
end

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("inkmath_filetype", { clear = true }),
  pattern = "*",
  callback = function(ev)
    if vim.g.inkmath_disable == true or not vim.tbl_contains(filetypes(), ev.match) then return end
    require("inkmath.api")._auto(ev.buf)
  end,
})

local function plug(name, desc, fn)
  vim.keymap.set("n", "<Plug>(inkmath-" .. name .. ")", fn, { desc = "inkmath: " .. desc })
end
plug("toggle", "toggle rendering in this buffer", function() require("inkmath.api").toggle(0) end)
plug("toggle-global", "toggle rendering everywhere", function() require("inkmath.api").toggle() end)
plug("enable", "render math in this buffer", function() require("inkmath.api").enable(0) end)
plug("disable", "stop rendering in this buffer", function() require("inkmath.api").disable(0) end)
plug("refresh", "re-render this buffer", function() require("inkmath.api").refresh(0) end)

-- user-facing groups are defaults (a colorscheme or the user may set them first);
-- InkMathImg<id> groups encode image ids and are managed by the placer
local function highlights()
  vim.api.nvim_set_hl(0, "InkMathError", { link = "DiagnosticUnderlineError", default = true })
  vim.api.nvim_set_hl(0, "InkMathPreviewBorder", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "InkMathPreviewError", { link = "DiagnosticError", default = true })
end
highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("inkmath_highlights", { clear = true }),
  callback = highlights,
})
