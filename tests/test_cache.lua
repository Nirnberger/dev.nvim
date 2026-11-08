vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local cache = require("inkmath.render.cache")

local node = { id = "1", kind = "inline", src = "x^2", range = { 0, 0, 0, 3 } }
local function ctx(o)
  return vim.tbl_extend(
    "force",
    { color = "#c0caf5", cell_w = 10, cell_h = 20, container_px = 800, macros = { R = "\\mathbb{R}" } },
    o or {}
  )
end

T["same inputs same key"] = function() eq(cache.key(node, ctx(), "mathjax"), cache.key(node, ctx(), "mathjax")) end

T["key changes"] = function()
  local base = cache.key(node, ctx(), "mathjax")
  assert(base ~= cache.key(node, ctx({ color = "#ffffff" }), "mathjax"))
  assert(base ~= cache.key(node, ctx({ cell_h = 21 }), "mathjax"))
  assert(base ~= cache.key(node, ctx({ macros = { R = "\\mathbb{Q}" } }), "mathjax"))
  assert(base ~= cache.key(node, ctx(), "tectonic"))
end

T["macro order is irrelevant"] = function()
  local a = cache.key(node, ctx({ macros = { A = "a", B = { "b#1", 1 } } }), "mathjax")
  local b = cache.key(node, ctx({ macros = { B = { "b#1", 1 }, A = "a" } }), "mathjax")
  eq(a, b)
end

T["container_px only matters for non-inline"] = function()
  eq(cache.key(node, ctx(), "mathjax"), cache.key(node, ctx({ container_px = 400 }), "mathjax"))
  local d = { id = "2", kind = "display", src = "x", range = { 0, 0, 0, 1 } }
  assert(cache.key(d, ctx(), "mathjax") ~= cache.key(d, ctx({ container_px = 400 }), "mathjax"))
end

T["inline x_height and baseline are in the key"] = function()
  local config = require("inkmath.config")
  local base = cache.key(node, ctx(), "mathjax")
  config.setup({ inline = { baseline = 0.7 } })
  local b = cache.key(node, ctx(), "mathjax")
  config.setup({ inline = { x_height = 0.5 } })
  local x = cache.key(node, ctx(), "mathjax")
  config.setup({})
  assert(base ~= b, "baseline not in key")
  assert(base ~= x, "x_height not in key")
end

T["preamble only matters for tectonic"] = function()
  local p1 = ctx({ preamble = { "\\documentclass{article}" } })
  local p2 = ctx({ preamble = { "\\documentclass{article}", "\\usepackage{bm}" } })
  eq(cache.key(node, p1, "mathjax"), cache.key(node, p2, "mathjax"))
  assert(cache.key(node, p1, "tectonic") ~= cache.key(node, p2, "tectonic"))
end

local PNG = "\137PNG\r\n\26\n" .. "rest of the file"
local function write_png(path, bytes)
  local f = assert(io.open(path, "wb"))
  f:write(bytes or PNG)
  f:close()
end

T["put then get round-trips"] = function()
  local key = cache.key(node, ctx(), "mathjax")
  eq(cache.get(key), nil)
  vim.fn.mkdir(vim.fs.dirname(cache.path(key)), "p")
  write_png(cache.path(key))
  local img = cache.put(key, 3, 1, 0.5)
  eq(img, { key = key, path = cache.path(key), cols = 3, rows = 1, ratio = 0.5 })
  eq(cache.get(key), img)
end

T["get without png is nil"] = function()
  local key = cache.key(node, ctx({ cell_w = 11 }), "mathjax")
  cache.put(key, 1, 1, 1)
  eq(cache.get(key), nil)
end

T["empty, truncated or non-PNG image is a miss"] = function()
  local key = cache.key(node, ctx({ cell_w = 14 }), "mathjax")
  vim.fn.mkdir(vim.fs.dirname(cache.path(key)), "p")
  cache.put(key, 1, 1, 1)
  for _, bytes in ipairs({ "", "\137PNG", "GIF89a-not-a-png-file" }) do
    write_png(cache.path(key), bytes)
    eq(cache.get(key), nil)
  end
  write_png(cache.path(key))
  eq(cache.get(key) ~= nil, true)
end

T["sidecar without ratio is a miss"] = function()
  local key = cache.key(node, ctx({ cell_w = 13 }), "mathjax")
  vim.fn.mkdir(vim.fs.dirname(cache.path(key)), "p")
  write_png(cache.path(key))
  vim.fn.writefile({ vim.json.encode({ cols = 1, rows = 1 }) }, (cache.path(key):gsub("%.png$", ".json")))
  eq(cache.get(key), nil)
end

T["clear removes files"] = function()
  local key = cache.key(node, ctx({ cell_w = 12 }), "mathjax")
  vim.fn.mkdir(vim.fs.dirname(cache.path(key)), "p")
  vim.fn.writefile({ "png" }, cache.path(key))
  cache.put(key, 1, 1, 1)
  cache.clear()
  eq(vim.uv.fs_stat(cache.path(key)), nil)
  eq(cache.get(key), nil)
end

T["cache_dir"] = function()
  local config = require("inkmath.config")
  local tmp = vim.fn.tempname()
  config.setup({ cache_dir = tmp })
  eq(cache.dir(), tmp)
  eq(vim.startswith(cache.path("k"), tmp .. "/"), true)
  config.setup({ cache_dir = "~/x-inkmath" })
  eq(cache.dir(), vim.fs.normalize("~") .. "/x-inkmath")
  config.setup({})
  eq(cache.dir(), vim.fn.stdpath("cache") .. "/inkmath")
end

-- Task 14: versioned keys, LRU prune, touch on hit, stats
T["key changes with VERSION"] = function()
  local k1 = cache.key(node, ctx(), "mathjax")
  local v = cache.VERSION
  cache.VERSION = v + 1
  local k2 = cache.key(node, ctx(), "mathjax")
  cache.VERSION = v
  eq(k2 ~= k1, true)
  eq(cache.key(node, ctx(), "mathjax"), k1)
end
T["key carries the worker's mathjax-full version"] = function()
  eq(cache._mathjax_version():match("^%d+%.%d+") ~= nil, true)
end

local PNG = "\137PNG\r\n\26\n" .. ("x"):rep(100 * 1024 - 8)
local function write_files(n)
  local d = cache.dir()
  vim.fn.mkdir(d, "p")
  local keys = {}
  for i = 1, n do
    local key = ("prune%02d"):format(i)
    keys[i] = key
    local f = assert(io.open(d .. "/" .. key .. ".png", "wb"))
    f:write(PNG)
    f:close()
    vim.fn.writefile({ '{"cols":1,"rows":1,"ratio":1}' }, d .. "/" .. key .. ".json")
    local t = 1000000 + i * 100 -- increasing mtime
    vim.uv.fs_utime(d .. "/" .. key .. ".png", t, t)
    vim.uv.fs_utime(d .. "/" .. key .. ".json", t, t)
  end
  return keys
end
local function remaining()
  local out = {}
  for name in vim.fs.dir(cache.dir()) do
    if name:match("^prune%d+%.png$") then out[#out + 1] = name:sub(1, -5) end
  end
  table.sort(out)
  return out
end

T["prune keeps newest"] = function()
  cache.clear()
  write_files(10)
  local done
  cache.prune(500 * 1024, function() done = true end)
  vim.wait(2000, function() return done end)
  eq(done, true)
  eq(remaining(), { "prune07", "prune08", "prune09", "prune10" }) -- <= 90% of 500 KiB
  for _, k in ipairs({ "prune01", "prune06" }) do
    eq(vim.uv.fs_stat(cache.dir() .. "/" .. k .. ".json"), nil)
  end
  cache.clear()
end
-- final review #4: an image still in the terminal (it may be placed) keeps its PNG:
-- a retransmit (FocusGained, VimResized) re-reads it
T["prune skips images resident in the terminal"] = function()
  local images, kitty = require("inkmath.term.images"), require("inkmath.term.kitty")
  cache.clear()
  write_files(10)
  local orig = kitty.send
  kitty.send = function() end
  images.ensure({ key = "prune01", path = cache.dir() .. "/prune01.png", cols = 1, rows = 1, ratio = 1 })
  local done
  cache.prune(500 * 1024, function() done = true end)
  vim.wait(2000, function() return done end)
  images.evict(0, {})
  kitty.send = orig
  eq(remaining(), { "prune01", "prune08", "prune09", "prune10" })
  eq(vim.uv.fs_stat(cache.dir() .. "/prune01.json") ~= nil, true)
  cache.clear()
end
-- final review #7: orphan metadata and abandoned worker temp files are removed
T["prune removes orphan json and old temp files"] = function()
  cache.clear()
  local d = cache.dir()
  vim.fn.mkdir(d, "p")
  vim.fn.writefile({ "{}" }, d .. "/orphan.json")
  vim.fn.writefile({ "x" }, d .. "/k.png.tmp.123.4")
  vim.fn.writefile({ "x" }, d .. "/fresh.png.tmp.123.5")
  vim.uv.fs_utime(d .. "/k.png.tmp.123.4", 1000000, 1000000)
  vim.uv.fs_utime(d .. "/orphan.json", 1000000, 1000000)
  local done
  cache.prune(500 * 1024 * 1024, function() done = true end)
  vim.wait(2000, function() return done end)
  vim.wait(200, function() return vim.uv.fs_stat(d .. "/orphan.json") == nil end)
  eq(vim.uv.fs_stat(d .. "/orphan.json"), nil)
  eq(vim.uv.fs_stat(d .. "/k.png.tmp.123.4"), nil)
  eq(vim.uv.fs_stat(d .. "/fresh.png.tmp.123.5") ~= nil, true) -- a worker may still write it
  cache.clear()
end
T["hit touches mtime"] = function()
  cache.clear()
  write_files(1)
  local p = cache.dir() .. "/prune01.png"
  local before = vim.uv.fs_stat(p).mtime.sec
  eq(cache.get("prune01") ~= nil, true)
  vim.wait(1000, function() return vim.uv.fs_stat(p).mtime.sec > before end)
  eq(vim.uv.fs_stat(p).mtime.sec > before, true)
  cache.clear()
end
T["stats counts files and bytes"] = function()
  cache.clear()
  write_files(3)
  local got
  cache.stats(function(st) got = st end)
  vim.wait(2000, function() return got ~= nil end)
  eq(got.files, 6)
  eq(got.bytes >= 3 * 100 * 1024, true)
  eq(got.dir, cache.dir())
  eq(got.max_bytes, 200 * 1024 * 1024)
  eq(cache.clear(), 6)
end

return T
