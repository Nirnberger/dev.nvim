local c = require("inkmath.config")
local images = require("inkmath.term.images")
local kitty = require("inkmath.term.kitty")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local match = require("tests.expect").match

local orig = {}
local sent = {}
local n = 0
local function img(key)
  n = n + 1
  return { key = "ids-test-" .. key .. "-" .. n, path = "/tmp/x.png", cols = 1, rows = 1, ratio = 1 }
end

T["ids"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      orig.send, orig.pid, orig.notify = kitty.send, images._getpid, vim.notify
      sent = {}
      kitty.send = function(s) sent[#sent + 1] = s end
      vim.notify = function() end
      c.reset()
    end,
    post_case = function()
      images.delete_all()
      kitty.send, images._getpid, vim.notify = orig.send, orig.pid, orig.notify
      c.reset()
      images._reset()
    end,
  },
})
local I = T["ids"]

I["ids start at base"] = function()
  c.setup({ image_ids = { base = 0x300000, span = 2048, per_instance = false } })
  images._reset()
  eq(images.ensure(img("a")), 0x300000)
  eq(images.ensure(img("b")), 0x300001)
  eq({ images.range() }, { 0x300000, 0x300000 + 2048 })
end
I["ids stay in range and are reused"] = function()
  c.setup({ image_ids = { base = 0x300000, span = 1024, per_instance = false } }) -- max_images = 512
  images._reset()
  local start, stop = images.range()
  local seen = {}
  for i = 1, 3000 do
    local id = images.ensure(img(i))
    eq(id >= start and id < stop, true)
    seen[id] = true
    images.evict(512, {})
  end
  eq(vim.tbl_count(seen), 1024) -- every id used, none outside the range
end
I["exhausted range evicts the oldest unpinned resident"] = function()
  c.setup({ max_images = 1, image_ids = { base = 0x300000, span = 2, per_instance = false } })
  images._reset()
  local a = images.ensure(img("a"))
  local b = images.ensure(img("b"))
  sent = {}
  local d = images.ensure(img("d")) -- no free id: a (oldest) is deleted and its id reused
  eq(d, a)
  eq(sent[1], kitty.delete_seq(a))
  images.pin(b)
  local e = images.ensure(img("e"))
  eq(e, d) -- b is pinned
  images.unpin(b)
end
I["exhausted range never steals an id in use on screen"] = function()
  c.setup({ max_images = 1, image_ids = { base = 0x300000, span = 2, per_instance = false } })
  images._reset()
  local a = images.ensure(img("a"))
  local b = images.ensure(img("b"))
  images.evict(1, { [a] = true, [b] = true }) -- both placed (core's pinned set)
  sent = {}
  eq(images.ensure(img("c")), nil) -- soft failure: the placement is skipped
  eq(sent, {}) -- nothing deleted
  images.evict(1, { [b] = true }) -- a scrolled away: deleted by eviction
  local d = images.ensure(img("d"))
  eq(d, a)
end
I["failed transmit does not leak its id"] = function()
  c.setup({ max_images = 1, image_ids = { base = 0x300000, span = 4, per_instance = false } })
  images._reset()
  local orig_seq = kitty.transmit_seq
  kitty.transmit_seq = function() return {} end -- remote, unreadable PNG
  local ok, err = pcall(function()
    for i = 1, 40 do
      eq(images.ensure(img("f" .. i)) ~= nil, true)
      images.evict(1, {})
    end
  end)
  kitty.transmit_seq = orig_seq
  eq(ok, true, err)
  local x = img("ok")
  local id = images.ensure(x) -- range still usable
  eq(id ~= nil, true)
  eq(sent[#sent]:find("a=T", 1, true) ~= nil, true)
end
I["failed transmit is retried by ensure"] = function()
  c.setup({ image_ids = { base = 0x300000, span = 2048, per_instance = false } })
  images._reset()
  local orig_seq = kitty.transmit_seq
  kitty.transmit_seq = function() return {} end
  local x = img("r")
  local id = images.ensure(x)
  kitty.transmit_seq = orig_seq
  sent = {}
  eq(images.ensure(x), id)
  eq(#sent, 1)
end
I["evicted key gets a new id, hl kept"] = function()
  c.setup({ image_ids = { base = 0x300000, span = 2048, per_instance = false } })
  images._reset()
  local a = img("a")
  local ia = images.ensure(a)
  local hl = images.hl(ia)
  images.evict(0, {})
  eq(images.id(a.key), nil)
  eq(vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = hl })), false)
end
I["per_instance offset"] = function()
  images._getpid = function() return 5 end
  images._reset()
  eq(images.range(), 0x200000 + 5 * 0x10000)
  images._getpid = function() return 224 + 3 end
  images._reset()
  eq(images.range(), 0x200000 + 3 * 0x10000)
end
I["validation rejects overflow"] = function()
  eq(require("inkmath").setup({ image_ids = { base = 0xFFFF00, span = 0x1000, per_instance = false } }), false)
  eq(require("inkmath").setup({ image_ids = { base = 0x200000, span = 0x10001 } }), false) -- 224 instances overflow
  eq(require("inkmath").setup({ image_ids = { span = 100 } }), false) -- span < 2 * max_images
  eq(require("inkmath").setup({ image_ids = { base = 0 } }), false)
  eq(c.get().image_ids, { base = 0x200000, span = 0x10000, per_instance = true })
  local ok, err = pcall(c.setup, { image_ids = { base = 0xFFFF00, span = 0x1000, per_instance = false } })
  eq(ok, false)
  match(err, "image_ids.*0xffffff")
end
I["delete_all deletes only resident ids"] = function()
  c.setup({ image_ids = { base = 0x300000, span = 2048, per_instance = false } })
  images._reset()
  local a, b = img("a"), img("b")
  images.ensure(a)
  local ib = images.ensure(b)
  images.evict(1, { [ib] = true }) -- a deleted
  local ia_old = sent[#sent]
  sent = {}
  images.delete_all()
  eq(sent, { kitty.delete_seq(ib) })
  eq(ia_old:find("a=d,d=I", 1, true) ~= nil, true)
  for _, s in ipairs(sent) do eq(s:find("d=a", 1, true), nil) end
end
I["VimLeavePre deletes images"] = function()
  local core = require("inkmath.core")
  local stubs = {
    { kitty, "supported", function() return true end },
    { require("inkmath.term.tmux"), "in_tmux", function() return false end },
    { require("inkmath.term.cells"), "cell_size", function() return { w = 10, h = 20 } end },
    { require("inkmath.render"), "available", function() return { mathjax = false, tectonic = true } end },
    { require("inkmath.render"), "shutdown", function() end },
    { require("inkmath.render"), "render", function(nd, ctx, cb)
      cb({ key = require("inkmath.render.cache").key(nd, ctx, "mathjax"), path = "/stub.png", cols = 1, rows = 1, ratio = 0.5 })
    end },
  }
  local saved = {}
  for i, s in ipairs(stubs) do saved[i] = s[1][s[2]]; s[1][s[2]] = s[3] end
  local b = require("tests.helpers").buf({ "$a$ $b$" }, "markdown")
  vim.api.nvim_win_set_buf(0, b)
  core.attach(b, { sync = true })
  local ids = {}
  for _, s in ipairs(sent) do
    if s:find("a=T", 1, true) then ids[#ids + 1] = s:match("i=(%d+)") end
  end
  sent = {}
  vim.api.nvim_exec_autocmds("VimLeavePre", {})
  core.detach(b)
  vim.api.nvim_buf_delete(b, { force = true })
  for i, s in ipairs(stubs) do s[1][s[2]] = saved[i] end
  eq(#ids, 2)
  for _, id in ipairs(ids) do eq(vim.tbl_contains(sent, kitty.delete_seq(tonumber(id))), true) end
end

return T
