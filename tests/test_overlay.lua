local helpers = require("tests.helpers")
local backend = require("inkmath.term.backend")
local images = require("inkmath.term.images")
local overlay = require("inkmath.view.overlay")
local placer = require("inkmath.view.placer")
local state = require("inkmath.view.state")

local eq = MiniTest.expect.equality

local sent, fake, orig_get, orig_ensure
local function flush()
  vim.wait(50, function() return false end)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      sent = {}
      fake = {
        name = "iterm2",
        mode = "overlay",
        send = function(s) sent[#sent + 1] = s end,
        delete = function(id) return "del" .. id end,
        paint = function(img, row, col) return { ("paint%d@%d,%d"):format(img.id, row, col) } end,
      }
      orig_get, orig_ensure = backend.get, images.ensure
      backend.get = function() return fake end
      images.ensure = function() return 7 end
      overlay._reset()
    end,
    post_case = function()
      backend.get, images.ensure = orig_get, orig_ensure
      overlay.clear()
      vim.cmd("silent! only | enew!")
    end,
  },
})

local function setup(lines)
  local buf = helpers.buf(lines, "tex")
  vim.api.nvim_win_set_buf(0, buf)
  state.reset(buf)
  return buf
end

local function node(id, row)
  return { id = id, kind = "inline", src = "x", range = { srow = row, scol = 0, erow = row, ecol = 3 } }
end

local function place(buf, id, row) placer.place(buf, node(id, row), { key = id, path = "/x.png", cols = 2, rows = 1 }) end

local function count(prefix)
  local n = 0
  for _, s in ipairs(sent) do
    if s:sub(1, #prefix) == prefix then n = n + 1 end
  end
  return n
end

T["cell is nil for a line scrolled off the window"] = function()
  local lines = {}
  for i = 1, 200 do
    lines[i] = "line " .. i
  end
  local buf = setup(lines)
  local win = vim.api.nvim_get_current_win()
  vim.cmd("normal! G")
  vim.cmd("redraw")
  eq(overlay.cell(win, 1, 1), nil)
  eq(type(overlay.cell(win, 200, 1)), "table")
  eq(buf ~= nil, true)
end

T["cell is nil inside a closed fold"] = function()
  setup({ "a", "b", "c", "d" })
  local win = vim.api.nvim_get_current_win()
  vim.cmd("2,3fold")
  eq(overlay.cell(win, 3, 1), nil)
  eq(type(overlay.cell(win, 1, 1)), "table")
end

T["placeholder text is plain cells in overlay mode"] = function()
  local buf = setup({ "a $x$ b" })
  place(buf, "n1", 0)
  local m = vim.api.nvim_buf_get_extmarks(buf, placer.ns, 0, -1, { details = true })
  eq(m[1][4].virt_text[1][1], "  ")
end

T["five repaints in one tick paint each image once"] = function()
  local buf = setup({ "a $x$ b", "c $y$ d" })
  place(buf, "n1", 0)
  place(buf, "n2", 1)
  flush()
  sent = {}
  overlay.clear()
  sent = {}
  for _ = 1, 5 do
    overlay.repaint()
  end
  flush()
  eq(count("paint"), 2)
end

T["an image scrolled off-screen is deleted on the next repaint"] = function()
  local lines = {}
  for i = 1, 200 do
    lines[i] = "line " .. i
  end
  lines[1] = "a $x$ b"
  local buf = setup(lines)
  place(buf, "n1", 0)
  overlay.repaint()
  flush()
  eq(count("paint"), 1)
  vim.cmd("normal! G")
  vim.cmd("redraw")
  overlay.repaint()
  flush()
  eq(count("del"), 1)
end

T["clear(buf) deletes the buffer's images and wipeout clears"] = function()
  local buf = setup({ "a $x$ b" })
  place(buf, "n1", 0)
  overlay.repaint()
  flush()
  sent = {}
  overlay.clear(buf)
  eq(count("del"), 1)
  place(buf, "n1", 0)
  overlay.repaint()
  flush()
  sent = {}
  vim.cmd("enew")
  vim.api.nvim_buf_delete(buf, { force = true })
  flush()
  eq(count("del"), 1)
end

T["backend without transmit never touches kitty images"] = function()
  fake.transmit = false
  local called = false
  images.ensure = function()
    called = true
    return 7
  end
  local buf = setup({ "a $x$ b" })
  place(buf, "n1", 0)
  overlay.repaint()
  flush()
  eq(called, false)
  eq(count("paint"), 1)
end

T["flush that redrew makes every image paint again"] = function()
  fake.transmit = false
  local redrew = false
  fake.flush = function()
    local r = redrew
    redrew = false
    return r
  end
  local buf = setup({ "a $x$ b", "c $y$ d" })
  place(buf, "n1", 0)
  place(buf, "n2", 1)
  overlay.repaint()
  flush()
  eq(count("paint"), 2)
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new line" }) -- n1 and n2 move down one row
  redrew = true
  overlay.repaint()
  flush()
  eq(count("del") >= 1, true)
  eq(count("paint"), 4) -- both painted again after the redraw
end

T["an empty paint is retried on the next repaint"] = function()
  fake.transmit = false
  local ready = false
  fake.paint = function(img, row, col) return ready and { ("paint%d@%d,%d"):format(img.id, row, col) } or {} end
  local buf = setup({ "a $x$ b" })
  place(buf, "n1", 0)
  overlay.repaint()
  flush()
  eq(count("paint"), 0)
  ready = true
  overlay.repaint()
  flush()
  eq(count("paint"), 1)
end

T["inline images after concealed formulas on the same line sit on their reserved cells"] = function()
  -- found in real terminals (scripts/screenshots.sh, inline.md): screenpos() counts concealed
  -- text, so every image after the first one on a line was painted too far right
  local buf = setup({ "ab $x$, $yy$, $z$ end" })
  vim.wo.conceallevel = 2
  vim.wo.number = false
  local function put(id, s, e, cols)
    placer.place(
      buf,
      { id = id, kind = "inline", src = "x", range = { srow = 0, scol = s, erow = 0, ecol = e } },
      { key = id, path = "/x.png", cols = cols, rows = 1 }
    )
  end
  put("a", 3, 6, 2)
  put("b", 8, 12, 3)
  put("c", 14, 17, 1)
  vim.cmd("redraw")
  sent = {}
  overlay._reset()
  overlay.repaint()
  flush()
  -- screen: "ab " .. 2 cells .. ", " .. 3 cells .. ", " .. 1 cell .. " end"
  local cols = {}
  for _, s in ipairs(sent) do
    local c = s:match("^paint%d+@1,(%d+)$")
    if c then cols[#cols + 1] = tonumber(c) end
  end
  table.sort(cols)
  eq(cols, { 4, 8, 13 })
end

return T
