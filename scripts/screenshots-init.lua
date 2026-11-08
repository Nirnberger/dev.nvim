-- Child Neovim for scripts/screenshots.sh: inkmath with a fixed UI. Once rendering has settled
-- (an InkMathRender event, every formula placed or marked as error, render queue and workers
-- idle for 0.5 s) it writes
-- $INKMATH_SHOT_READY: { formulas, placed, errors, cell = {w, h}, columns, lines, backend, mode, paints }.
-- Also the child of tests/test_terminals_real.lua. Overlay backends (iTerm2, Sixel, kitty overlay):
-- every paint is recorded (`paints`: { id, row, col, cols, rows }, 1-based screen cells, last one per
-- image), and the ready file waits until there is one and none came for 0.5 s.
-- $INKMATH_SHOT_BACKEND forces term.backend; $INKMATH_SHOT_BREAK=1 sends the paints without their
-- image (cursor moves only): the negative control of the pixel checks.
local root = assert(vim.env.INKMATH_ROOT, "INKMATH_ROOT not set")
local ready_file = assert(vim.env.INKMATH_SHOT_READY, "INKMATH_SHOT_READY not set")
vim.opt.runtimepath:prepend(root)

vim.o.termguicolors = true
vim.cmd.colorscheme("habamax")
vim.o.shortmess = vim.o.shortmess .. "IF"
vim.o.number = true
vim.o.ruler = false
vim.o.showmode = false
vim.o.showcmd = false
vim.o.swapfile = false
vim.o.laststatus = 2
vim.o.cmdheight = 1
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "tex", "markdown" },
  callback = function(ev) pcall(vim.treesitter.start, ev.buf) end,
})
require("inkmath").setup({ term = { backend = vim.env.INKMATH_SHOT_BACKEND or "auto" } })

local paints, last_paint = {}, 0 ---@type table<integer, table>, integer
for _, mod in ipairs({
  "inkmath.term.backends.iterm2",
  "inkmath.term.backends.kitty_overlay",
  "inkmath.term.backends.sixel",
}) do
  local b = require(mod)
  local paint = b.paint
  b.paint = function(img, row, col)
    local seqs = paint(img, row, col)
    if #seqs > 0 then
      paints[img.id] = { id = img.id, row = row, col = col, cols = img.cols, rows = img.rows }
      last_paint = vim.uv.now()
      if vim.env.INKMATH_SHOT_BREAK == "1" then return { ("\0277\27[%d;%dH\0278"):format(row, col) } end
    end
    return seqs
  end
end

local seen = false
vim.api.nvim_create_autocmd("User", { pattern = "InkMathRender", callback = function() seen = true end })

local function idle(st)
  for _, q in pairs(st.queue) do
    if q.queued > 0 or q.inflight > 0 then return false end
  end
  for _, w in ipairs(st.workers) do
    if w.pending > 0 then return false end
  end
  return true
end

local quiet = 0
local timer = assert(vim.uv.new_timer())
timer:start(
  200,
  100,
  vim.schedule_wrap(function()
    if timer:is_closing() then return end
    local st = require("inkmath.status").collect()
    local a = st.attached[1]
    -- every formula resolved: placed or marked as error (after the tectonic fallback)
    local resolved = a and a.formulas > 0 and a.placed + a.errors >= a.formulas
    local b = require("inkmath.term.backend").current()
    local painted = b.mode ~= "overlay" or (next(paints) ~= nil and vim.uv.now() - last_paint > 500)
    quiet = (seen and resolved and painted and idle(st)) and quiet + 1 or 0
    if quiet < 5 then return end
    timer:close()
    vim.cmd("echo ''")
    vim.cmd("redraw!")
    if b.mode == "overlay" then
      -- :redraw! cleared the terminal and with it every overlay image: paint them all again
      require("inkmath.view.overlay")._reset()
      require("inkmath.view.overlay").repaint()
    end
    vim.schedule(function() -- after the repaint
      vim.fn.writefile({
        vim.json.encode({
          formulas = a.formulas,
          placed = a.placed,
          errors = a.errors,
          cell = require("inkmath.term.cells").cell_size() or vim.NIL,
          columns = vim.o.columns,
          lines = vim.o.lines,
          backend = b.name,
          mode = b.mode,
          paints = vim.tbl_values(paints),
        }),
      }, ready_file)
    end)
  end)
)
