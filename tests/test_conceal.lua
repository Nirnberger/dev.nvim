local h = require("tests.helpers")
local c = require("inkmath.config")
local core = require("inkmath.core")
local conceal = require("inkmath.view.conceal")
require("inkmath")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local stubs = {
  { require("inkmath.term.kitty"), "supported", function() return true end },
  { require("inkmath.term.kitty"), "send", function() end },
  { require("inkmath.term.tmux"), "in_tmux", function() return false end },
  { require("inkmath.term.cells"), "cell_size", function() return { w = 10, h = 20 } end },
  { require("inkmath.render"), "available", function() return { mathjax = false, tectonic = true } end },
  {
    require("inkmath.render"),
    "render",
    function(n, ctx, cb)
      cb({
        key = require("inkmath.render.cache").key(n, ctx, "mathjax"),
        path = "/stub.png",
        cols = 1,
        rows = 1,
        ratio = 0.5,
      })
    end,
  },
  { vim, "notify", function() end },
}
local saved, bufs, b, w, groups = {}, {}, nil, nil, {}

local function new_buf(lines)
  local x = h.buf(lines or { "a $x$ b" }, "markdown")
  bufs[#bufs + 1] = x
  return x
end

--- show another buffer in `win`, then `buf` again (BufWinEnter)
local function reshow(buf, win)
  vim.api.nvim_win_set_buf(win, new_buf({ "" }))
  vim.api.nvim_win_set_buf(win, buf)
end

--- keys as if typed (vim.on_key sees them), executed now
local function type_keys(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false) end

local function au(ev, fn, nested)
  local g = vim.api.nvim_create_augroup("inkmath_test_conceal" .. #groups, { clear = true })
  groups[#groups + 1] = g
  vim.api.nvim_create_autocmd(ev, { group = g, nested = nested, callback = fn })
end

T["conceal"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for i, s in ipairs(stubs) do
        saved[i] = s[1][s[2]]
        s[1][s[2]] = s[3]
      end
      c.reset()
      vim.cmd("only")
      w = vim.api.nvim_get_current_win()
      vim.wo[w].conceallevel, vim.wo[w].concealcursor = 0, ""
      b = new_buf()
      vim.api.nvim_win_set_buf(w, b)
    end,
    post_case = function()
      for _, g in ipairs(groups) do
        vim.api.nvim_del_augroup_by_id(g)
      end
      groups = {}
      vim.cmd("only")
      for _, x in ipairs(bufs) do
        pcall(core.detach, x)
        pcall(vim.api.nvim_buf_delete, x, { force = true })
      end
      bufs = {}
      require("inkmath.term.images").evict(0, {}) -- leave no resident image for other files
      for i, s in ipairs(stubs) do
        s[1][s[2]] = saved[i]
      end
      c.reset()
    end,
  },
})
local C = T["conceal"]

C["conceal=false leaves options alone"] = function()
  c.setup({ conceal = false })
  vim.wo[w].conceallevel = 3
  core.attach(b, { sync = true })
  eq(vim.wo[w].conceallevel, 3)
  reshow(b, w)
  eq(vim.wo[w].conceallevel, 3)
  core.detach(b)
  eq(vim.wo[w].conceallevel, 3)
end
C["conceal=false: level 0 hides, 2 shows"] = function()
  c.setup({ conceal = false })
  vim.wo[w].conceallevel = 2
  core.attach(b, { sync = true })
  eq(conceal.hidden(b), false)
  vim.wo[w].conceallevel = 0 -- OptionSet
  eq(conceal.is_hidden(b), true)
  eq(conceal._sticky(b, w), false) -- never recorded with conceal = false
  vim.wo[w].conceallevel = 2
  eq(conceal.is_hidden(b), false)
end
C["conceal=false: a floating window does not hide"] = function()
  c.setup({ conceal = false })
  vim.wo[w].conceallevel = 2
  core.attach(b, { sync = true })
  local f = vim.api.nvim_open_win(b, false, { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
  vim.wo[f].conceallevel = 0
  eq(conceal.hidden(b), false)
  vim.api.nvim_win_close(f, true)
end
C["switching to conceal=false restores the window options"] = function()
  vim.wo[w].conceallevel = 1
  core.attach(b, { sync = true })
  eq(vim.wo[w].conceallevel, 2)
  require("inkmath").setup({ conceal = false })
  eq(vim.wo[w].conceallevel, 1)
end
C["user :setlocal cl=0 is sticky"] = function()
  core.attach(b, { sync = true })
  type_keys(":setlocal conceallevel=0<CR>")
  eq(conceal._sticky(b, w), true)
  reshow(b, w)
  eq(vim.wo[w].conceallevel, 0)
  vim.cmd("setlocal conceallevel=2") -- non-zero clears it
  eq(conceal._sticky(b, w), false)
end
C["the same :setlocal from code, not typed, is not sticky"] = function()
  core.attach(b, { sync = true })
  vim.cmd("setlocal conceallevel=0")
  eq(conceal.is_hidden(b), true)
  eq(conceal._sticky(b, w), false)
end
C["a typed toggle mapping is sticky"] = function()
  core.attach(b, { sync = true })
  vim.keymap.set("n", "<F7>", function() vim.wo.conceallevel = vim.wo.conceallevel == 0 and 2 or 0 end)
  type_keys("<F7>")
  vim.keymap.del("n", "<F7>")
  eq(vim.wo[w].conceallevel, 0)
  eq(conceal._sticky(b, w), true)
  reshow(b, w)
  eq(vim.wo[w].conceallevel, 0)
end
C["render-markdown's write (vim.schedule, scope=local, win=w) is not sticky"] = function()
  core.attach(b, { sync = true })
  -- lib/decorator.lua Decorator:schedule -> core/ui.lua Updater:run: win_options
  -- written with nvim_set_option_value(name, v, { scope = "local", win = win })
  type_keys("i<Esc>") -- a key queues it (ModeChanged), as entering insert mode does
  vim.schedule(function() vim.api.nvim_set_option_value("conceallevel", 0, { scope = "local", win = w }) end)
  vim.wait(50, function() return vim.wo[w].conceallevel == 0 end)
  eq(vim.wo[w].conceallevel, 0)
  eq(conceal.is_hidden(b), true) -- hidden while it lasts
  eq(conceal._sticky(b, w), false)
  reshow(b, w)
  eq(vim.wo[w].conceallevel, 2)
end
C["a timer write right after a key is not sticky"] = function()
  core.attach(b, { sync = true })
  type_keys("l")
  local done = false
  vim.defer_fn(function()
    vim.wo[w].conceallevel = 0
    done = true
  end, 0)
  vim.wait(200, function() return done end)
  eq(conceal._sticky(b, w), false)
end
C["no sticky inference in a buffer render-markdown manages"] = function()
  core.attach(b, { sync = true })
  package.loaded["render-markdown"] = {}
  package.loaded["render-markdown.core.manager"] = { attached = function(x) return x == b end }
  type_keys(":setlocal conceallevel=0<CR>") -- e.g. :RenderMarkdown disable writes it synchronously
  package.loaded["render-markdown"], package.loaded["render-markdown.core.manager"] = nil, nil
  eq(conceal.is_hidden(b), true)
  eq(conceal._sticky(b, w), false)
end
C["no sticky inference in a buffer markview manages"] = function()
  core.attach(b, { sync = true })
  package.loaded["markview.spec"] = { config = {} }
  package.loaded["markview.state"] = { buf_attached = function(x) return x == b end }
  type_keys(":setlocal conceallevel=0<CR>")
  package.loaded["markview.spec"], package.loaded["markview.state"] = nil, nil
  eq(conceal._sticky(b, w), false)
end
C["plugin write from other window is not sticky"] = function()
  core.attach(b, { sync = true })
  vim.cmd("new")
  vim.api.nvim_set_option_value("conceallevel", 0, { win = w, scope = "local" })
  eq(conceal.is_hidden(b), true) -- hidden while it lasts
  eq(conceal._sticky(b, w), false)
  reshow(b, w)
  eq(vim.wo[w].conceallevel, 2)
end
C["write inside BufWinEnter is not sticky"] = function()
  core.attach(b, { sync = true })
  au("BufWinEnter", function() vim.wo.conceallevel = 0 end, true) -- nested: OptionSet fires
  reshow(b, w)
  vim.wait(20)
  eq(conceal._sticky(b, w), false)
  reshow(b, w)
  eq(conceal._sticky(b, w), false)
end
C["write inside ModeChanged / FileType / WinEnter is not sticky"] = function()
  core.attach(b, { sync = true })
  for _, ev in ipairs({ "ModeChanged", "FileType", "WinEnter" }) do
    eq(
      conceal._user_initiated({
        buf = b,
        win = w,
        command = "setlocal",
        typed = true,
        managers = {},
        stack = "nvim_exec2()[1].." .. ev .. ' Autocommands for "*"..OptionSet Autocommands for "conceallevel"',
      }),
      false
    )
  end
end
C["modeline and setglobal not sticky"] = function()
  core.attach(b, { sync = true })
  local function ui(cmd, typed)
    return conceal._user_initiated({ buf = b, win = w, command = cmd, stack = "", typed = typed, managers = {} })
  end
  eq(ui("setlocal", true), true)
  eq(ui("set", true), true)
  eq(ui("modeline", true), false)
  eq(ui("setglobal", true), false)
  eq(ui("setlocal", false), false) -- not while a typed key is handled
  eq(
    conceal._user_initiated({
      buf = b,
      win = w,
      command = "setlocal",
      stack = "",
      typed = true,
      managers = { "markview" },
    }),
    false
  )
end
C["conceal=false: never user-initiated"] = function()
  c.setup({ conceal = false })
  core.attach(b, { sync = true })
  eq(
    conceal._user_initiated({ buf = b, win = w, command = "setlocal", stack = "", typed = true, managers = {} }),
    false
  )
end
C["a non-nested FileType write (no OptionSet) is seen after FileType"] = function()
  core.attach(b, { sync = true })
  eq(conceal.is_hidden(b), false)
  au("FileType", function() vim.wo.conceallevel = 0 end) -- not nested: no OptionSet
  require("inkmath.api")._auto(b) -- what plugin/'s FileType handler runs
  vim.bo[b].filetype = "markdown"
  eq(conceal.is_hidden(b), false) -- missed so far
  vim.wait(20, function() return false end)
  eq(conceal.is_hidden(b), true)
end
C["old table form unchanged"] = function()
  c.setup({ conceal = { level = 3, cursor = "" } })
  vim.wo[w].concealcursor = "n"
  core.attach(b, { sync = true })
  eq({ vim.wo[w].conceallevel, vim.wo[w].concealcursor }, { 3, "" })
end

return T
