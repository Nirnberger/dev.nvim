vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local tmux = require("inkmath.term.tmux")
local kitty = require("inkmath.term.kitty")
local images = require("inkmath.term.images")
local cells = require("inkmath.term.cells")
local config = require("inkmath.config")

--- a file at `p` (retransmit_all skips images whose file is gone)
local function touch(p)
  vim.fn.writefile({ "x" }, p)
  return p
end
local A, B = touch(vim.fn.tempname() .. "-a.png"), touch(vim.fn.tempname() .. "-b.png")

T["tmux.wrap doubles escapes"] = function() eq(tmux.wrap("\27_Gx\27\\"), "\27Ptmux;\27\27_Gx\27\27\\\27\\") end

T["transmit_seq local"] = function()
  eq(
    kitty.transmit_seq(7, "/tmp/a.png", 3, 1, true),
    { "\27_Ga=T,U=1,f=100,t=f,q=2,i=7,c=3,r=1;" .. vim.base64.encode("/tmp/a.png") .. "\27\\" }
  )
end

T["transmit_seq remote chunks"] = function()
  local p = vim.fn.tempname()
  local f = assert(io.open(p, "wb"))
  f:write(string.rep("a", 10000))
  f:close()
  local seqs = kitty.transmit_seq(7, p, 3, 1, false)
  eq(#seqs, 4)
  assert(seqs[1]:find("m=1;", 1, true))
  local head = "\27_Ga=T,U=1,f=100,t=d,q=2,i=7,c=3,r=1,m=1;"
  eq(seqs[1]:sub(1, #head), head)
  eq(seqs[4]:sub(1, 7), "\27_Gm=0;")
  eq(seqs[2]:sub(1, 7), "\27_Gm=1;")
  os.remove(p)
end

T["transmit_seq remote single chunk uses m=0"] = function()
  local p = vim.fn.tempname()
  local f = assert(io.open(p, "wb"))
  f:write("abc")
  f:close()
  local seqs = kitty.transmit_seq(1, p, 1, 1, false)
  eq(seqs, { "\27_Ga=T,U=1,f=100,t=d,q=2,i=1,c=1,r=1,m=0;" .. vim.base64.encode("abc") .. "\27\\" })
  os.remove(p)
end

T["delete_seq"] = function() eq(kitty.delete_seq(7), "\27_Ga=d,d=I,i=7,q=2\27\\") end

T["diacritics"] = function()
  local d = require("inkmath.term.diacritics")
  eq(#d, 297)
  eq(d[1], 0x0305)
  eq(d[2], 0x030D)
end

T["images registry"] = function()
  local sent = {}
  local orig = kitty.send
  kitty.send = function(s) sent[#sent + 1] = s end
  local ok, err = pcall(function()
    local a = { key = "ka", path = A, cols = 1, rows = 1, ratio = 1 }
    local b = { key = "kb", path = B, cols = 2, rows = 1, ratio = 2 }
    local ia = images.ensure(a)
    eq(images.ensure(a), ia)
    eq(#sent, 1)
    local ib = images.ensure(b)
    eq(ib, ia + 1)
    eq(#sent, 2)
    sent = {}
    images.touch(ib)
    images.evict(1, {})
    eq(sent, { kitty.delete_seq(ia) })
    sent = {}
    images.retransmit_all()
    eq(#sent, 1)
    images.evict(0, { [ib] = true })
    eq(#sent, 1) -- pinned: nothing deleted
    sent = {}
    images.ensure(a) -- retransmit after eviction, same id
    eq(#sent, 1)
  end)
  kitty.send = orig
  assert(ok, err)
end

T["ensure with missing remote file does not raise"] = function()
  local old = vim.env.SSH_CONNECTION
  vim.env.SSH_CONNECTION = "1 2 3 4"
  local orig = kitty.send
  local sent = {}
  kitty.send = function(x) sent[#sent + 1] = x end
  local ok, err = pcall(images.ensure, { key = "missing", path = "/nonexistent/x.png", cols = 1, rows = 1, ratio = 1 })
  kitty.send = orig
  vim.env.SSH_CONNECTION = old
  assert(ok, err)
  eq(#sent, 0)
end

T["retransmit_all preserves LRU order"] = function()
  local sent = {}
  local orig = kitty.send
  kitty.send = function(x) sent[#sent + 1] = x end
  local ok, err = pcall(function()
    local ia = images.ensure({ key = "lru-a", path = A, cols = 1, rows = 1, ratio = 1 })
    local ib = images.ensure({ key = "lru-b", path = B, cols = 1, rows = 1, ratio = 1 })
    images.touch(ia)
    images.touch(ib)
    images.retransmit_all()
    sent = {}
    -- keep only newest (ib) among these; others resident from earlier tests are older
    images.evict(1, {})
    local deleted_a, deleted_b = false, false
    for _, s in ipairs(sent) do
      if s == kitty.delete_seq(ia) then deleted_a = true end
      if s == kitty.delete_seq(ib) then deleted_b = true end
    end
    assert(deleted_a and not deleted_b)
  end)
  kitty.send = orig
  assert(ok, err)
end

-- final review #4: a PNG deleted under a resident image (cache prune or clear) is
-- not retransmitted; the image is dropped and the on_drop handler clears placements
T["retransmit_all drops images whose file is gone"] = function()
  local sent, dropped = {}, {}
  local orig = kitty.send
  kitty.send = function(x) sent[#sent + 1] = x end
  local prev = images.on_drop(function(key) dropped[#dropped + 1] = key end)
  local ok, err = pcall(function()
    local p = touch(vim.fn.tempname() .. ".png")
    local id = images.ensure({ key = "gone-key", path = p, cols = 1, rows = 1, ratio = 1 })
    os.remove(p)
    sent = {}
    images.retransmit_all()
    eq(vim.tbl_contains(sent, kitty.delete_seq(id)), true)
    for _, x in ipairs(sent) do
      eq(x:find("_Ga=T,", 1, true) ~= nil and x:find("i=" .. id .. ",", 1, true) ~= nil, false)
    end
    eq(dropped, { "gone-key" })
    eq(images.id("gone-key"), nil)
  end)
  images.on_drop(prev)
  kitty.send = orig
  assert(ok, err)
end

T["on_drop returns the handler it replaces"] = function()
  local a, b = function() end, function() end
  local orig = images.on_drop(a)
  eq(type(orig), "function")
  eq(images.on_drop(b), a)
  eq(images.on_drop(orig), b)
end

T["keys lists the resident image keys"] = function()
  local orig = kitty.send
  kitty.send = function() end
  images.ensure({ key = "listed-key", path = A, cols = 1, rows = 1, ratio = 1 })
  kitty.send = orig
  eq(images.keys()["listed-key"], true)
end

T["images.hl"] = function()
  local name = images.hl(0x0a0b0c)
  eq(name, "InkMathImg" .. 0x0a0b0c)
  eq(vim.api.nvim_get_hl(0, { name = name }).fg, 0x0a0b0c)
end

T["cells override"] = function()
  config.setup({ cell_size = { w = 9, h = 18 } })
  cells.refresh()
  eq(cells.cell_size(), { w = 9, h = 18 })
  config.setup({})
  cells.refresh()
end

--- run fn with the cell-size sources stubbed; returns the number of CSI 16t queries
local function with_sources(o, fn)
  local saved = { cells._ioctl, cells._from_tmux, kitty.send, tmux.in_tmux }
  local csi = 0
  config.setup({})
  cells.refresh()
  cells._ioctl = function() return -1, nil end
  cells._from_tmux = function() return o.tmux end
  tmux.in_tmux = function() return o.in_tmux or false end
  kitty.send = function(seq)
    if seq == "\27[16t" then csi = csi + 1 end
  end
  local ok, e = pcall(fn)
  cells._ioctl, cells._from_tmux, kitty.send, tmux.in_tmux = unpack(saved)
  cells.refresh()
  assert(ok, e)
  return csi
end

T["cell size failure is cached until refresh"] = function()
  local csi = with_sources({}, function()
    eq(cells.cell_size(), nil)
    eq(cells.cell_size(), nil)
  end)
  eq(csi, 1)
  csi = with_sources({}, function()
    cells.cell_size()
    cells.refresh()
    cells.cell_size()
  end)
  eq(csi, 2)
end

T["tmux cell size is asked before CSI"] = function()
  local csi = with_sources(
    { in_tmux = true, tmux = { w = 8, h = 16 } },
    function() eq(cells.cell_size(), { w = 8, h = 16 }) end
  )
  eq(csi, 0)
end

T["ioctl returns a plain table"] = function()
  local _, ws = cells._ioctl()
  eq(ws == nil or type(ws) == "table", true)
end

T["passthrough counts pane and window options"] = function()
  local orig, orig_exec = tmux._show, vim.fn.executable
  assert(orig, "tmux._show missing")
  local vals = {}
  tmux._show = function(scope) return vals[scope] end
  vim.fn.executable = function() return 1 end
  local res = {}
  vals = { g = "off", w = "", p = "on" }
  tmux.forget() -- memoized per session
  res[1] = tmux.passthrough_enabled()
  vals = { g = "off", w = "all" }
  tmux.forget() -- memoized per session
  res[2] = tmux.passthrough_enabled()
  vals = { g = "on" }
  tmux.forget() -- memoized per session
  res[3] = tmux.passthrough_enabled()
  vals = { g = "off", w = "off", p = "off" }
  tmux.forget() -- memoized per session
  res[4] = tmux.passthrough_enabled()
  tmux.forget()
  tmux._show, vim.fn.executable = orig, orig_exec
  eq(res, { true, true, true, false })
end

T["supported detects ghostty via tmux client_termtype"] = function()
  local kitty = require("inkmath.term.kitty")
  local tmux = require("inkmath.term.tmux")
  local saved = {
    in_tmux = tmux.in_tmux,
    system = vim.fn.system,
    exec = vim.fn.executable,
    TERM = vim.env.TERM,
    TERM_PROGRAM = vim.env.TERM_PROGRAM,
    G = vim.env.GHOSTTY_RESOURCES_DIR,
    K = vim.env.KITTY_WINDOW_ID,
  }
  vim.env.TERM, vim.env.TERM_PROGRAM = "tmux-256color", "tmux"
  vim.env.GHOSTTY_RESOURCES_DIR, vim.env.KITTY_WINDOW_ID = nil, nil
  tmux.in_tmux = function() return true end
  vim.fn.executable = function() return 1 end
  -- Ghostty with TERM=xterm-256color: termname is generic, termtype names ghostty.
  local termtype
  vim.fn.system = function(argv)
    local fmt = type(argv) == "table" and argv[#argv] or ""
    local out = fmt:gsub("#{client_termname}", "xterm-256color"):gsub("#{client_termtype}", termtype)
    return out .. "\n"
  end
  termtype = "ghostty 1.4.0"
  kitty.forget()
  local ok_ghostty = kitty.supported()
  termtype = ""
  local memo = kitty.supported() -- memoized: no second shell-out
  kitty.forget()
  local ok_unknown = kitty.supported()
  kitty.forget()
  eq(memo, true)
  tmux.in_tmux, vim.fn.system, vim.fn.executable = saved.in_tmux, saved.system, saved.exec
  vim.env.TERM, vim.env.TERM_PROGRAM = saved.TERM, saved.TERM_PROGRAM
  vim.env.GHOSTTY_RESOURCES_DIR, vim.env.KITTY_WINDOW_ID = saved.G, saved.K
  eq({ ok_ghostty, ok_unknown }, { true, false })
end

return T
