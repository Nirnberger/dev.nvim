local helpers = require("tests.helpers")
local images = require("inkmath.term.images")
local placer = require("inkmath.view.placer")
local state = require("inkmath.view.state")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local orig_ensure
local function setup_buf(lines)
  local buf = helpers.buf(lines, "tex")
  vim.api.nvim_win_set_buf(0, buf)
  state.reset(buf)
  return buf
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, placer.ns, 0, -1, { details = true })
end

local function node(kind, r)
  return { id = "n1", kind = kind, src = "x", range = { srow = r[1], scol = r[2], erow = r[3], ecol = r[4] } }
end

T["placeholder row"] = function()
  eq(placer.placeholder_rows(5, 2, 1)[1], "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}")
end

T["cases"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      orig_ensure = images.ensure
      images.ensure = function() return 5 end
    end,
    post_case = function() images.ensure = orig_ensure end,
  },
})

T["cases"]["inline extmark"] = function()
  local buf = setup_buf({ "a $x$ b" })
  placer.place(buf, node("inline", { 0, 2, 0, 5 }), { cols = 2, rows = 1 })
  local m = marks(buf)
  eq(#m, 1)
  eq(m[1][4].conceal, "")
  eq(m[1][4].virt_text_pos, "inline")
  eq(m[1][4].end_col, 5)
end

T["cases"]["display at row 0"] = function()
  local buf = setup_buf({ "$$", "a", "$$", "after" })
  placer.place(buf, node("display", { 0, 0, 2, 2 }), { cols = 2, rows = 2 })
  local m = marks(buf)
  eq(#m, 3)
  local c, v = {}, nil
  for _, e in ipairs(m) do
    if e[4].conceal_lines then c[#c + 1] = e[2] end
    if e[4].virt_lines then v = e end
  end
  eq(c, { 1, 2 })
  eq(v[2], 0) -- anchored on the node's own first row
  eq(v[4].conceal, "")
  eq(v[4].end_col, 2)
  eq(v[4].virt_text_pos, "overlay")
  eq(#v[4].virt_lines, 1) -- image row 1 is the overlay, row 2 a virt_line
  eq(v[4].virt_lines_above or false, false)
end

T["cases"]["display middle"] = function()
  local buf = setup_buf({ "x", "$$", "a", "$$" })
  placer.place(buf, node("display", { 1, 0, 3, 2 }), { cols = 2, rows = 2 })
  local v
  for _, e in ipairs(marks(buf)) do
    if e[4].virt_lines then v = e end
  end
  eq(v[2], 1)
  eq(v[4].virt_lines_above or false, false)
end

T["cases"]["one-row display has no virt_lines"] = function()
  local buf = setup_buf({ "x", "\\[a\\]", "y" })
  placer.place(buf, node("display", { 1, 0, 1, 5 }), { cols = 2, rows = 1 })
  local m = marks(buf)
  eq(#m, 1)
  eq(m[1][4].virt_text_pos, "overlay")
  eq(m[1][4].virt_lines, nil)
end

T["cases"]["whole buffer"] = function()
  local buf = setup_buf({ "$$", "a", "$$" })
  placer.place(buf, node("display", { 0, 0, 2, 2 }), { cols = 2, rows = 2 })
  local v
  for _, e in ipairs(marks(buf)) do
    if e[2] == 0 then
      eq(e[4].conceal_lines, nil)
    end
    if e[4].virt_lines then v = e end
  end
  eq(v[2], 0)
  eq(v[4].virt_lines_above or false, false)
end

T["cases"]["replace"] = function()
  local buf = setup_buf({ "a $x$ b" })
  local n = node("inline", { 0, 2, 0, 5 })
  placer.place(buf, n, { cols = 2, rows = 1 })
  placer.place(buf, n, { cols = 2, rows = 1 })
  eq(#marks(buf), 1)
  eq(#state.get(buf).nodes["n1"].marks, 1)
end

T["cases"]["clear"] = function()
  local buf = setup_buf({ "a $x$ b" })
  local n = node("inline", { 0, 2, 0, 5 })
  placer.place(buf, n, { cols = 2, rows = 1 })
  placer.clear(buf, n.id)
  eq(#marks(buf), 0)
  eq(state.get(buf).nodes["n1"], nil)
end

--- Screen rows drawn for each placed node: image rows on rows not hidden by any
--- conceal_lines mark (an overlay virt_text counts as one row, each virt_line as one).
local function drawn_rows(buf)
  local hidden = {}
  for _, m in ipairs(marks(buf)) do
    if m[4].conceal_lines then hidden[m[2]] = true end
  end
  local out = {}
  for id, e in pairs(state.get(buf).nodes) do
    local n = 0
    for _, mid in ipairs(e.marks) do
      local p = vim.api.nvim_buf_get_extmark_by_id(buf, placer.ns, mid, { details = true })
      if not hidden[p[1]] then
        if p[3].virt_text and p[3].virt_text_pos == "overlay" then n = n + 1 end
        n = n + #(p[3].virt_lines or {})
      end
    end
    out[id] = n
  end
  return out
end

local function blk(id, kind, r)
  return { id = id, kind = kind, src = id, range = { srow = r[1], scol = r[2], erow = r[3], ecol = r[4] } }
end

local ADJ_TEX = { "\\begin{equation}", "a", "\\end{equation}", "\\begin{equation}", "b", "\\end{equation}", "x" }
local ADJ_MD = { "$$", "a", "$$", "$$", "b", "$$", "x" }

for _, case in ipairs({
  { "adjacent equation blocks", ADJ_TEX, "block", false },
  { "adjacent equation blocks reversed", ADJ_TEX, "block", true },
  { "adjacent $$ blocks", ADJ_MD, "display", false },
  { "adjacent $$ blocks reversed", ADJ_MD, "display", true },
}) do
  T["cases"][case[1]] = function()
    local buf = setup_buf(case[2])
    local a = blk("a", case[3], { 0, 0, 2, #case[2][3] })
    local b = blk("b", case[3], { 3, 0, 5, #case[2][6] })
    local order = case[4] and { b, a } or { a, b }
    for _, n in ipairs(order) do placer.place(buf, n, { cols = 2, rows = 3 }) end
    eq(drawn_rows(buf), { a = 3, b = 3 })
  end
end

T["cases"]["out of range is skipped"] = function()
  local buf = setup_buf({ "a" })
  placer.place(buf, node("inline", { 0, 2, 0, 50 }), { cols = 2, rows = 1 })
  placer.place(buf, node("display", { 3, 0, 5, 2 }), { cols = 2, rows = 2 })
  eq(#marks(buf), 0)
  eq(next(state.get(buf).nodes), nil)
end

-- final review #5: a formula whose text changed (marks stay valid) is cleared at
-- once instead of showing its old image until the debounced refresh
T["cases"]["verify clears an inline placement whose text changed"] = function()
  local buf = setup_buf({ "a $x$ b", "c $y$ d" })
  local n2 = node("inline", { 1, 2, 1, 5 })
  n2.id = "n2"
  placer.place(buf, node("inline", { 0, 2, 0, 5 }), { key = "k1", cols = 1, rows = 1 })
  placer.place(buf, n2, { key = "k2", cols = 1, rows = 1 })
  eq(placer.verify(buf, 0, 1), 0)
  vim.api.nvim_buf_set_text(buf, 0, 3, 0, 4, { "z" }) -- $x$ -> $z$
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new" }) -- unchanged one moves down
  eq(placer.verify(buf, 0, 2), 1)
  eq(state.get(buf).nodes.n1, nil)
  eq(state.get(buf).nodes.n2 ~= nil, true)
end

T["cases"]["verify clears an edited display block, keeps moved and out-of-view ones"] = function()
  local buf = setup_buf({ "$$", "a", "$$", "", "$$", "b", "$$" })
  local n2 = node("display", { 4, 0, 6, 2 })
  n2.id = "n2"
  placer.place(buf, node("display", { 0, 0, 2, 2 }), { key = "k1", cols = 1, rows = 1 })
  placer.place(buf, n2, { key = "k2", cols = 1, rows = 1 })
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "top" })
  eq(placer.verify(buf, 0, 7), 0) -- both moved, text unchanged
  vim.api.nvim_buf_set_text(buf, 2, 0, 2, 1, { "q" }) -- a -> q in the first block
  vim.api.nvim_buf_set_text(buf, 6, 0, 6, 1, { "r" }) -- b -> r in the second
  eq(placer.verify(buf, 0, 3), 1) -- only the first is in view
  eq(state.get(buf).nodes.n1, nil)
  eq(state.get(buf).nodes.n2 ~= nil, true)
  eq(placer.verify(buf, 4, 7), 1)
  eq(state.get(buf).nodes.n2, nil)
end

return T
