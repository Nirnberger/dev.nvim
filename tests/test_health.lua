local h = require("tests.helpers")
local c = require("inkmath.config")
local core = require("inkmath.core")
local detect = require("inkmath.detect")
local health = require("inkmath.health")
require("inkmath")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local match = require("tests.expect").match

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
local FAKE = {
  "render-markdown",
  "render-markdown.state",
  "render-markdown.core.manager",
  "markview",
  "markview.spec",
  "markview.state",
  "image",
}
local saved, bufs = {}, {}

local function find(list, pat)
  for _, r in ipairs(list) do
    if r.msg:find(pat) then return r end
  end
  error("no interop line matching " .. pat .. " in " .. vim.inspect(list))
end
local function warns(list)
  return vim.tbl_filter(function(x) return x.level == "warn" end, list)
end

local function buf(lines, ft)
  local b = h.buf(lines or { "$x$" }, ft or "markdown")
  bufs[#bufs + 1] = b
  return b
end

T["interop"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for i, s in ipairs(stubs) do
        saved[i] = s[1][s[2]]
        s[1][s[2]] = s[3]
      end
      c.reset()
    end,
    post_case = function()
      vim.wait(20, function() return false end)
      for _, m in ipairs(FAKE) do
        package.loaded[m] = nil
      end
      _G.Snacks = nil
      for _, b in ipairs(bufs) do
        pcall(core.detach, b)
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
      bufs = {}
      require("inkmath.term.images").evict(0, {})
      for i, s in ipairs(stubs) do
        s[1][s[2]] = saved[i]
      end
      c.reset()
    end,
  },
})
local I = T["interop"]

I["render-markdown latex warns with snippet"] = function()
  package.loaded["render-markdown"] = {}
  package.loaded["render-markdown.state"] = { config = { latex = { enabled = true } } }
  local r = find(health._interop(), "render%-markdown")
  eq(r.level, "warn")
  match(r.fix, "latex = { enabled = false }")
end
I["render-markdown with latex off is ok"] = function()
  package.loaded["render-markdown"] = {}
  package.loaded["render-markdown.state"] = { config = { latex = { enabled = false } } }
  eq(find(health._interop(), "render%-markdown").level, "ok")
end
I["render-markdown config unreadable"] = function()
  package.loaded["render-markdown"] = {}
  package.loaded["render-markdown.state"] = { config = {} }
  local r = find(health._interop(), "render%-markdown")
  eq(r.level, "warn")
  match(r.msg, "make sure latex is off")
end
I["markview latex warns"] = function()
  package.loaded["markview"] = {}
  package.loaded["markview.spec"] = { config = { latex = { enable = true } } }
  local r = find(health._interop(), "markview")
  eq(r.level, "warn")
  match(r.fix, "latex = { enable = false }")
  match(r.fix, "opts")
end
I["markview without setup(): detected, latex on by default"] = function()
  -- plugin/markview.lua loads markview.autocmds -> markview.spec, never "markview";
  -- spec.config has no latex key until markview's own spec.get() merges its defaults
  package.loaded["markview.spec"] = { config = { preview = {} } }
  eq(find(health._interop(), "markview").msg:find("renders LaTeX", 1, true) ~= nil, true)
  package.loaded["markview.spec"] = { config = { latex = { inline = {} } } } -- setup({latex = {...}}) without enable
  eq(find(health._interop(), "markview").level, "warn")
  package.loaded["markview.spec"] = { config = { latex = { enable = false } } }
  eq(find(health._interop(), "markview").level, "ok")
  eq(package.loaded["markview.config.latex"], nil) -- never loaded by the check
end
I["render-markdown: check loads nothing"] = function()
  package.loaded["render-markdown"] = {}
  local r = find(health._interop(), "render%-markdown")
  eq(r.level, "warn")
  match(r.msg, "make sure latex is off")
  eq(package.loaded["render-markdown.state"], nil)
end
local function fake_snacks(cfg, image)
  local loads = {}
  local S = setmetatable({
    config = setmetatable({}, {
      __index = function(t, k)
        rawset(t, k, {})
        return t[k]
      end,
    }),
  }, {
    __index = function(t, k)
      loads[#loads + 1] = k
      rawset(t, k, { config = { enabled = true } })
      return rawget(t, k)
    end,
  })
  if cfg then rawset(S.config, "image", cfg) end
  if image then rawset(S, "image", image) end
  _G.Snacks = S
  return loads
end
I["snacks.image: off unless image.enabled, never loads snacks.image"] = function()
  local loads = fake_snacks(nil) -- snacks for the picker only
  eq(warns(health._interop()), {})
  eq(loads, {})
  loads = fake_snacks({ enabled = true }) -- image on, math/doc default on
  local r = find(health._interop(), "snacks")
  eq(r.level, "warn")
  match(r.fix, "image = { math = { enabled = false } }")
  eq(loads, {})
  fake_snacks({ enabled = true, math = { enabled = false } })
  eq(find(health._interop(), "snacks").level, "ok")
  fake_snacks({ enabled = true, doc = { enabled = false } })
  eq(find(health._interop(), "snacks").level, "ok")
end
I["snacks.image loaded: its resolved config"] = function()
  local loads = fake_snacks(nil, { config = { enabled = true, math = { enabled = true }, doc = { enabled = true } } })
  eq(find(health._interop(), "snacks").level, "warn")
  fake_snacks(nil, { config = { enabled = nil, math = { enabled = true }, doc = { enabled = true } } }) -- loaded by a picker preview
  eq(warns(health._interop()), {})
  eq(loads, {})
end
I["fix snippets go in the user's plugin spec"] = function()
  package.loaded["render-markdown"] = {}
  package.loaded["markview.spec"] = { config = {} }
  fake_snacks({ enabled = true })
  for _, r in ipairs(health._interop()) do
    if r.fix then eq(r.fix:find("setup(", 1, true), nil) end
  end
end
I["image.nvim info"] = function()
  package.loaded["image"] = {}
  local r = find(health._interop(), "image%.nvim")
  eq(r.level, "info")
end
I["conceal=false suggested next to render-markdown"] = function()
  package.loaded["render-markdown"] = {}
  package.loaded["render-markdown.state"] = { config = { latex = { enabled = false } } }
  match(find(health._interop(), "conceal = false").msg, "render%-markdown")
  c.setup({ conceal = false })
  for _, r in ipairs(health._interop()) do
    eq(r.msg:find("conceal = false", 1, true), nil)
  end
  -- the common form: only markdown-like filetypes leave conceal to the other plugin
  c.reset()
  c.setup({ overrides = { markdown = { conceal = false }, quarto = { conceal = false }, rmd = { conceal = false } } })
  for _, r in ipairs(health._interop()) do
    eq(r.msg:find("conceal = false", 1, true), nil)
  end
end
I["clean when nothing loaded"] = function() eq(warns(health._interop()), {}) end
I["conceallevel conflict"] = function()
  c.setup({ conceal = false })
  local b = buf()
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(w, b)
  core.attach(b, { sync = true })
  vim.wo[w].conceallevel = 1
  local r = find(health._interop(), "conceallevel")
  eq(r.level, "warn")
  match(r.msg, "< 2")
  match(r.msg, "does not manage it")
  vim.wo[w].conceallevel = 2
  eq(warns(health._interop()), {})
end
I["conceallevel below 2 from the table form"] = function()
  c.setup({ conceal = { level = 1 } })
  local b = buf()
  vim.api.nvim_win_set_buf(0, b)
  core.attach(b, { sync = true })
  local r = find(health._interop(), "conceallevel")
  match(r.msg, "conceal.level")
end
I["quarto detected as markdown"] = function()
  local b = buf({ "$x$" }, "quarto")
  eq(#detect.detect(b), 1)
  eq(vim.treesitter.language.get_lang("quarto"), "markdown")
end
I["rmd auto-attaches"] = function()
  vim.g.loaded_inkmath = nil -- (re)load plugin/: test_core deletes its FileType autocmd
  vim.cmd.source(vim.api.nvim_get_runtime_file("plugin/inkmath.lua", false)[1])
  local b = buf({ "$x$" }, "rmd")
  vim.api.nvim_win_set_buf(0, b)
  vim.wait(20, function() return false end) -- api._auto is scheduled
  eq(core.is_attached(b), true)
end
I["quarto and rmd in the default filetypes"] = function() eq(c.get().filetypes, { "tex", "markdown", "quarto", "rmd" }) end

-- WezTerm answers the kitty graphics query but has no Unicode placeholders: the
-- health error says so instead of "does not support kitty graphics"
T["health names WezTerm's missing Unicode placeholders"] = function()
  local kitty = require("inkmath.term.kitty")
  local errors = {}
  local saved_sup, saved_tp, saved_err = kitty.supported, vim.env.TERM_PROGRAM, vim.health.error
  kitty.supported = function() return false end
  vim.env.TERM_PROGRAM = "WezTerm"
  vim.health.error = function(msg) errors[#errors + 1] = msg end
  local ok, err = pcall(health.check)
  kitty.supported, vim.env.TERM_PROGRAM, vim.health.error = saved_sup, saved_tp, saved_err
  assert(ok, err)
  local hit = vim.tbl_filter(
    function(m) return m:find("WezTerm has kitty graphics but no Unicode placeholders", 1, true) end,
    errors
  )
  eq(#hit, 1)
end

return T
