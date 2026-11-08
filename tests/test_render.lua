vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      require("inkmath.config").setup({})
    end,
  },
})
local eq = MiniTest.expect.equality
local cache = require("inkmath.render.cache")
local render = require("inkmath.render")
local mathjax = require("inkmath.render.mathjax")

local function ctx(o)
  return vim.tbl_extend("force", { color = "#c0caf5", cell_w = 10, cell_h = 20, container_px = 800, macros = {} }, o or {})
end
local function node(src, kind, id)
  return { id = id or src, kind = kind or "inline", src = src, range = { 0, 0, 0, #src } }
end
local function render_sync(n, c, timeout)
  local done, img, err
  render.render(n, c, function(i, e)
    done, img, err = true, i, e
  end)
  vim.wait(timeout or 15000, function() return done end, 20)
  assert(done, "render callback not called")
  return img, err
end

T["mathjax renders and caches"] = function()
  local n, c = node("x^2"), ctx()
  local img, err = render_sync(n, c)
  eq(err, nil)
  eq(img.rows, 1)
  eq(img.key, cache.key(n, c, "mathjax"))
  assert(vim.uv.fs_stat(img.path))
  local sync = false
  render.render(n, c, function() sync = true end)
  eq(sync, true)
end

T["fallback to tectonic on mathjax error"] = function()
  local n = node("\\mycustom{x}")
  local c = ctx({ preamble = { "\\documentclass{article}", "\\newcommand{\\mycustom}[1]{#1}" } })
  local img, err = render_sync(n, c, 90000)
  eq(err, nil)
  eq(img.key, cache.key(n, c, "tectonic"))
  assert(vim.uv.fs_stat(img.path))
  eq(img.rows, 1)
  assert(img.cols >= 1 and img.ratio > 0)
end

local function size_of(path)
  local w, h = vim.fn.system({ "magick", "identify", "-format", "%w %h", path }):match("(%d+) (%d+)")
  return tonumber(w), tonumber(h)
end

T["tectonic display fills container cols"] = function()
  local n = node("\\int_0^1 f", "display")
  require("inkmath.config").setup({ backend = "tectonic" })
  local img, err = render_sync(n, ctx(), 90000)
  eq(err, nil)
  eq(img.key, cache.key(n, ctx(), "tectonic"))
  eq(img.cols, 80)
  assert(img.rows >= 1)
  local w, h = size_of(img.path)
  eq({ w, h }, { img.cols * 10, img.rows * 20 })
end

T["tectonic display shrinks to narrow container"] = function()
  local n = node("\\int_0^1 f", "display")
  local c = ctx({ container_px = 400 })
  require("inkmath.config").setup({ backend = "tectonic" })
  local img, err = render_sync(n, c, 90000)
  eq(err, nil)
  eq(img.cols, 40)
  local w, h = size_of(img.path)
  eq({ w, h }, { 400, img.rows * 20 })
end

T["tectonic wide block shrinks, not cropped"] = function()
  local n = node("\\begin{align}" .. string.rep("a+", 120) .. "b&=c\\end{align}", "block")
  local c = ctx({ container_px = 300 })
  require("inkmath.config").setup({ backend = "tectonic" })
  local img, err = render_sync(n, c, 90000)
  eq(err, nil)
  eq(img.cols, 30)
  local w, h = size_of(img.path)
  eq({ w, h }, { 300, img.rows * 20 })
end

T["thrown error does not wedge in-flight"] = function()
  require("inkmath.config").setup({ fallback = false })
  local orig = cache.put
  cache.put = function() error("boom") end
  local n, c = node("q^7"), ctx()
  local calls, img1, err1 = 0, nil, nil
  render.render(n, c, function(i, e) calls = calls + 1; img1, err1 = i, e end)
  vim.wait(15000, function() return calls > 0 end, 20)
  cache.put = orig
  vim.wait(200)
  eq(calls, 1)
  eq(img1, nil)
  assert(err1 and err1.message ~= "")
  local img, err = render_sync(n, c)
  eq(err, nil)
  assert(img)
end

T["tectonic error when mathjax unavailable"] = function()
  local orig = mathjax.start
  mathjax.start = function() return false end
  local img, err = render_sync(node("\\frac{"), ctx(), 90000)
  mathjax.start = orig
  eq(img, nil)
  eq(err.backend, "tectonic")
end

T["mathjax error kept when TeX invalid"] = function()
  local img, err = render_sync(node("\\frac{ "), ctx(), 90000)
  eq(img, nil)
  eq(err.backend, "mathjax")
end

T["request timeout kills worker and recovers"] = function()
  mathjax.shutdown()
  local orig = mathjax.timeout_ms
  mathjax.timeout_ms = 1
  local done, res, err
  mathjax.request({ tex = "x", display = false, macros = {}, color = "#ffffff", cell_w = 10, cell_h = 20, container_px = 800,
    x_height = 0.45, baseline = 0.78, scale = 1, out = vim.fn.tempname() .. ".png" }, function(r, e)
    done, res, err = true, r, e
  end)
  vim.wait(5000, function() return done end, 5)
  mathjax.timeout_ms = orig
  eq(res, nil)
  eq(err, "worker timeout")
  local n, c = node("t+u"), ctx()
  local img, e2 = render_sync(n, c)
  eq(e2, nil)
  eq(img.key, cache.key(n, c, "mathjax"))
  mathjax.shutdown()
end

T["error from both"] = function()
  local img, err = render_sync(node("\\frac{"), ctx(), 90000)
  eq(img, nil)
  assert(type(err.message) == "string" and err.message ~= "")
end

T["worker missing"] = function()
  local orig = mathjax.start
  mathjax.start = function() return false end
  local n, c = node("y^3"), ctx()
  local img, err = render_sync(n, c, 90000)
  mathjax.start = orig
  eq(err, nil)
  eq(img.key, cache.key(n, c, "tectonic"))
end

T["worker crash restarts"] = function()
  render_sync(node("a+b"), ctx())
  local pid = mathjax.pid()
  assert(pid)
  vim.uv.kill(pid, "sigkill")
  local n, c = node("c+d"), ctx()
  local img, err = render_sync(n, c)
  eq(err, nil)
  eq(img.key, cache.key(n, c, "mathjax"))
  assert(mathjax.pid() ~= pid)
end

T["dedupe in flight"] = function()
  local orig, count = mathjax.request, 0
  mathjax.request = function(...)
    count = count + 1
    return orig(...)
  end
  local n, c = node("z^5"), ctx()
  local calls = 0
  local function cb(img) if img then calls = calls + 1 end end
  render.render(n, c, cb)
  render.render(n, c, cb)
  vim.wait(15000, function() return calls == 2 end, 20)
  mathjax.request = orig
  eq(count, 1)
  eq(calls, 2)
end

T["no_fallback never calls tectonic"] = function()
  local tectonic = require("inkmath.render.tectonic")
  local orig_batch, orig_submit, calls = tectonic.batch, tectonic.submit, 0
  tectonic.batch = function(...) calls = calls + 1 return orig_batch(...) end
  if orig_submit then tectonic.submit = function(...) calls = calls + 1 return orig_submit(...) end end
  local done, img, err
  render.render(node("\\nomacro{q}"), ctx(), function(i, e) done, img, err = true, i, e end, { no_fallback = true })
  vim.wait(15000, function() return done end, 20)
  vim.wait(300)
  tectonic.batch, tectonic.submit = orig_batch, orig_submit
  eq(calls, 0)
  eq(img, nil)
  eq(err.backend, "mathjax")
end

T["concurrent tectonic requests are batched"] = function()
  local tectonic = require("inkmath.render.tectonic")
  require("inkmath.config").setup({ backend = "tectonic" })
  local orig_run, spawns = tectonic._run, 0
  assert(orig_run, "tectonic._run missing")
  tectonic._run = function(cmd, cb)
    if cmd[1]:find("tectonic", 1, true) then spawns = spawns + 1 end
    return orig_run(cmd, cb)
  end
  local c, done, ok = ctx(), 0, 0
  for i = 1, 4 do
    render.render(node("b_" .. i .. "+q"), c, function(img)
      done = done + 1
      if img then ok = ok + 1 end
    end)
  end
  vim.wait(120000, function() return done == 4 end, 50)
  tectonic._run = orig_run
  eq(done, 4)
  eq(ok, 4)
  assert(spawns <= 2, "tectonic spawned " .. spawns .. " times")
end

T["available reports both"] = function()
  local a = render.available()
  eq(a.mathjax, true)
  eq(a.tectonic, true)
end

-- v2 knobs
T["max_formula_len: too long is an error, no render"] = function()
  require("inkmath.config").setup({ max_formula_len = 5 })
  local img, err = render_sync(node("abcdefgh"), ctx())
  eq(img, nil)
  require("tests.expect").match(err.message, "formula too long %(8 > 5%)")
end
T["max_formula_len counts characters"] = function()
  require("inkmath.config").setup({ max_formula_len = 3 })
  local _, err = render_sync(node("ααα"), ctx())
  eq(err == nil or not err.message:find("too long"), true)
end
T["max_formula_len from the ctx's buffer config"] = function()
  local img, err = render_sync(node("abcdefgh"), ctx({ opts = vim.tbl_extend("force", require("inkmath.config").get(), { max_formula_len = 3 }) }))
  eq(img, nil)
  require("tests.expect").match(err.message, "too long")
end
T["render.argv resolves the first word"] = function()
  eq(render.argv({ "env", "node" }, "x"), { vim.fn.exepath("env"), "node", "x" })
  eq(render.argv("no-such-command-inkmath"), nil)
end
T["node_cmd list used"] = function()
  require("inkmath.config").setup({ node_cmd = { "env", "node" } })
  local argv = mathjax._argv()
  eq(argv[1], vim.fn.exepath("env"))
  eq(argv[2], "node")
end
T["node_cmd missing: mathjax unavailable"] = function()
  require("inkmath.config").setup({ node_cmd = "no-such-command-inkmath" })
  eq(mathjax.available(), false)
end
T["tectonic_cmd / magick_cmd missing: tectonic unavailable"] = function()
  local tectonic = require("inkmath.render.tectonic")
  require("inkmath.config").setup({ magick_cmd = "no-such-command-inkmath" })
  eq(tectonic.available(), false)
  require("inkmath.config").setup({ tectonic_cmd = { "no-such-command-inkmath" } })
  eq(tectonic.available(), false)
end
T["timeouts.mathjax_ms"] = function()
  mathjax.shutdown()
  eq(mathjax.timeout_ms, nil)
  require("inkmath.config").setup({ timeouts = { mathjax_ms = 1 } })
  local done, err
  mathjax.request({ tex = "x", display = false, macros = {}, color = "#ffffff", cell_w = 10, cell_h = 20, container_px = 800,
    x_height = 0.45, baseline = 0.78, scale = 1, out = vim.fn.tempname() .. ".png" }, function(_, e)
    done, err = true, e
  end)
  vim.wait(5000, function() return done end, 5)
  eq(err, "worker timeout")
  mathjax.shutdown()
end

-- final review #3: a render in flight when the cache is cleared must not hand its
-- (possibly ENOENT) result to a request made after the clear
T["clear-cache: later requests do not join a flow started before it"] = function()
  require("inkmath.config").setup({ fallback = false })
  local orig, held = mathjax.request, {}
  mathjax.request = function(req, cb) held[#held + 1] = { req = req, cb = cb } end
  local ok, e = pcall(function()
    local n, c = node("epoch_x"), ctx()
    local r1, r2
    render.render(n, c, function(img, err) r1 = { img = img, err = err } end)
    eq(#held, 1)
    cache.clear()
    render.render(n, c, function(img, err) r2 = { img = img, err = err } end)
    eq(#held, 2) -- a new worker request, not a join
    held[1].cb(nil, "ENOENT: no such file or directory")
    vim.wait(100, function() return r1 ~= nil end)
    eq(r1.err ~= nil, true)
    eq(r2, nil)
    held[2].cb({ cols = 1, rows = 1, ratio = 0.5 })
    vim.wait(100, function() return r2 ~= nil end)
    eq(r2.err, nil)
    eq(r2.img.rows, 1)
  end)
  mathjax.request = orig
  if not ok then error(e, 0) end
end
T["clear-cache returns at once and removes the files"] = function()
  cache.clear()
  local d = cache.dir()
  vim.fn.mkdir(d, "p")
  for i = 1, 20 do vim.fn.writefile({ "x" }, d .. "/f" .. i .. ".json") end
  eq(cache.clear(), 20)
  eq(vim.uv.fs_stat(d .. "/f1.json"), nil)
end

return T
