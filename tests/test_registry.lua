local registry = require("inkmath.detect.registry")
local detect = require("inkmath.detect")
local incr = require("inkmath.detect.incr")
local h = require("tests.helpers")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["built-ins"] = function()
  eq(registry.get("tex").lang, "latex")
  eq(registry.get("markdown").detector, "inkmath.detect.markdown")
  -- other test files register more filetypes (mdx, ...)
  for _, ft in ipairs({ "markdown", "tex" }) do
    eq(vim.list_contains(registry.filetypes(), ft), true)
  end
end
T["register validates the spec"] = function()
  eq(pcall(registry.register, "x", { lang = "markdown" }), false)
  eq(pcall(registry.register, "x", { lang = "markdown", detector = "m", ctx = "rst" }), false)
end
T["unregistered ft yields no nodes"] = function()
  local b = h.buf({ "$x$" }, "text")
  eq(#detect.detect(b), 0)
  vim.api.nvim_buf_delete(b, { force = true })
end
T["registered ft is detected"] = function()
  registry.register("mdx", { lang = "markdown", detector = "inkmath.detect.markdown", ctx = "markdown" })
  local b = h.buf({ "$x$" }, "mdx")
  eq(#detect.detect(b), 1)
  vim.api.nvim_buf_delete(b, { force = true })
end
T["incr uses registry lang"] = function()
  registry.register("mdx", { lang = "markdown", detector = "inkmath.detect.markdown", ctx = "markdown" })
  local b = h.buf({ "$x$", "", "$y$" }, "mdx")
  eq(#incr.detect(b), 2)
  local before = incr.stats.incr
  vim.api.nvim_buf_set_lines(b, 2, 3, false, { "$y + 1$" })
  eq(#incr.detect(b), 2)
  eq(incr.stats.incr > before, true)
  incr.forget(b)
  vim.api.nvim_buf_delete(b, { force = true })
end
T["registered ctx kind gives macros"] = function()
  registry.register("mdx", { lang = "markdown", detector = "inkmath.detect.markdown", ctx = "markdown" })
  local cells = require("inkmath.term.cells")
  local orig = cells.cell_size
  cells.cell_size = function() return { w = 10, h = 20 } end
  local b = h.buf({ "$$\\newcommand{\\R}{\\mathbb{R}}$$", "", "$\\R$" }, "mdx")
  eq(require("inkmath.ctx").build(b).macros.R ~= nil, true)
  registry.register("custom", {
    lang = "markdown",
    detector = "inkmath.detect.markdown",
    ctx = function() return { macros = { Q = "\\mathbb{Q}" } } end,
  })
  vim.bo[b].filetype = "custom"
  eq(require("inkmath.ctx").build(b).macros.Q, "\\mathbb{Q}")
  cells.cell_size = orig
  vim.api.nvim_buf_delete(b, { force = true })
end

-- The detector from README.md / doc/inkmath.txt ("Custom detectors"), verbatim.
local EXAMPLE = [==[
-- lua/rst_math.lua
local M = {}

function M.detect(buf, srow, erow)
  local nodes = {}
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row, line in ipairs(lines) do
    local init = 1
    while true do
      local s, e, src = line:find(":math:`([^`]+)`", init)
      if not s then break end
      nodes[#nodes + 1] = {
        id = require("inkmath.detect").node_id("inline", nil, src),
        kind = "inline",
        src = src,
        range = { srow = row - 1, scol = s - 1, erow = row - 1, ecol = e },
      }
      init = e + 1
    end
  end
  return nodes, false -- nodes, has_error
end

return M
]==]

T["documented custom detector"] = function()
  package.loaded.rst_math = assert(load(EXAMPLE, "=rst_math"))()
  local api = require("inkmath")
  api.register_filetype("rst", { lang = "rst", detector = "rst_math" })
  local b = h.buf({ "Euler: :math:`e^{i\\pi}+1=0` and :math:`x^2`.", "none here" }, "rst")
  local nodes, info = detect.detect(b)
  eq(#nodes, 2)
  eq(nodes[1].src, "e^{i\\pi}+1=0")
  eq(nodes[1].kind, "inline")
  eq(info.has_error, false)
  eq(vim.api.nvim_buf_get_text(b, 0, nodes[2].range.scol, 0, nodes[2].range.ecol, {})[1], ":math:`x^2`")
  eq(#detect.detect(b, 1, 1), 0) -- row filter applied by detect.detect
  vim.api.nvim_buf_delete(b, { force = true })
  package.loaded.rst_math = nil
end

return T
