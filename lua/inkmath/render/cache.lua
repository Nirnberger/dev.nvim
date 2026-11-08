---@class inkmath.Image
---@field key string
---@field path string
---@field cols integer
---@field rows integer
---@field ratio number natural image height / cell height

---@class inkmath.RenderCtx
---@field color string "#rrggbb"
---@field cell_w integer
---@field cell_h integer
---@field container_px integer
---@field macros table
---@field preamble string[]|nil
---@field labels table<string, string>|nil label -> number from the .aux file (vimtex)
---@field aux string|nil
---@field aux_stamp string|nil
---@field opts? table resolved config of the buffer (inkmath.config.get(buf))

local M = {}

--- Bumped when the image format or the key's inputs change: old files no longer match.
M.VERSION = 2

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
local mj_version ---@type string|nil

--- mathjax-full version of the worker (worker/package-lock.json, read once): a new
--- MathJax renders differently, so it is part of every key.
---@return string
function M._mathjax_version()
  if not mj_version then
    local ok, v = pcall(function()
      local lock = vim.json.decode(table.concat(vim.fn.readfile(root .. "/worker/package-lock.json"), "\n"))
      return vim.tbl_get(lock, "packages", "node_modules/mathjax-full", "version")
    end)
    mj_version = ok and type(v) == "string" and v or "?"
  end
  return mj_version
end

--- the image cache directory (`cache_dir`, default stdpath("cache")/inkmath)
---@return string
function M.dir()
  local d = require("inkmath.config").get().cache_dir
  return d and vim.fs.normalize(d) or vim.fn.stdpath("cache") .. "/inkmath"
end
local dir = M.dir
local PRUNE_EVERY = 200
local puts = 0

-- JSON with sorted keys, so equal macro tables always hash equally. Memoized per
-- macros table (ctx.build makes a new one whenever the macros change).
local encoded = setmetatable({}, { __mode = "k" }) ---@type table<table, string>
local function encode_macros(macros)
  if macros and encoded[macros] then return encoded[macros] end
  local keys = vim.tbl_keys(macros or {})
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = vim.json.encode(k) .. ":" .. vim.json.encode(macros[k])
  end
  local out = "{" .. table.concat(parts, ",") .. "}"
  if macros then encoded[macros] = out end
  return out
end

-- sha256 of key inputs already seen: a refresh asks for the key of every node in
-- the views (twice per node and backend), and vim.fn.sha256 dominates that cost
local hashed, nhashed = {}, 0
local MAX_HASHED = 20000
local function sha(s)
  local h = hashed[s]
  if h then return h end
  h = vim.fn.sha256(s)
  if nhashed >= MAX_HASHED then hashed, nhashed = {}, 0 end
  hashed[s], nhashed = h, nhashed + 1
  return h
end

---@param node inkmath.MathNode
---@param ctx inkmath.RenderCtx
---@param backend string
---@return string
function M.key(node, ctx, backend)
  local cfg = require("inkmath.config").of(ctx)
  local parts = {
    "v" .. M.VERSION,
    M._mathjax_version(),
    backend,
    node.kind,
    node.src,
    encode_macros(ctx.macros),
    ctx.color,
    tostring(ctx.cell_w),
    tostring(ctx.cell_h),
    tostring(node.kind ~= "inline" and ctx.container_px or 0),
    tostring(cfg.scale),
    tostring(cfg.inline.x_height),
    tostring(cfg.inline.baseline),
    -- tectonic compiles with the document's preamble; MathJax only sees the macros
    backend == "tectonic" and sha(table.concat(ctx.preamble or {}, "\n")) or "",
  }
  return sha(table.concat(parts, "\31")) -- not "\0": vim.fn.sha256 turns a NUL-containing string into a Blob
end

---@param key string
---@return string
function M.path(key)
  return dir() .. "/" .. key .. ".png"
end

local function meta_path(key)
  return dir() .. "/" .. key .. ".json"
end

local PNG_SIG = "\137PNG\r\n\26\n"

--- the file is at least a PNG signature (a truncated or foreign file is a miss)
local function png_ok(path)
  local st = vim.uv.fs_stat(path)
  if not st or st.size <= 8 then
    return false
  end
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  local head = f:read(8)
  f:close()
  return head == PNG_SIG
end

-- key -> metadata already read and checked: a later hit only stats the PNG (scrolling
-- back to formulas placed before, from the cache, is a few dozen hits at once)
local metas = {} ---@type table<string, {cols: integer, rows: integer, ratio: number}>

---@param key string
---@return inkmath.Image|nil
function M.get(key)
  local png = M.path(key)
  local data = metas[key]
  if data then
    local st = vim.uv.fs_stat(png)
    if not st or st.size <= 8 then
      metas[key] = nil
      return nil
    end
  else
    local meta = meta_path(key)
    if not (vim.uv.fs_stat(meta) and png_ok(png)) then
      return nil
    end
    local ok
    ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(meta), "\n"))
    end)
    if not ok or type(data) ~= "table" or not data.cols or not data.rows or type(data.ratio) ~= "number" then
      return nil
    end
    metas[key] = { cols = data.cols, rows = data.rows, ratio = data.ratio }
  end
  -- recently used: prune deletes the oldest files first
  local now = os.time()
  pcall(vim.uv.fs_utime, png, now, now, function() end)
  return { key = key, path = png, cols = data.cols, rows = data.rows, ratio = data.ratio }
end

---@param key string
---@param cols integer
---@param rows integer
---@param ratio number
---@return inkmath.Image
function M.put(key, cols, rows, ratio)
  vim.fn.mkdir(dir(), "p")
  -- "S": no fsync. It blocked the main loop ~2.5 ms per render (macOS); a metadata file
  -- lost in a crash is just a cache miss (get validates it)
  vim.fn.writefile({ vim.json.encode({ cols = cols, rows = rows, ratio = ratio }) }, meta_path(key), "S")
  metas[key] = { cols = cols, rows = rows, ratio = ratio }
  puts = puts + 1
  if puts % PRUNE_EVERY == 0 then M.auto_prune(0) end
  return { key = key, path = M.path(key), cols = cols, rows = rows, ratio = ratio }
end

--- Bumped by clear(): renders started before it belong to the deleted directory
--- (render/init keeps them apart from later requests of the same key).
M.epoch = 0

--- Delete the cache directory: renamed away at once (the files are gone for get()),
--- then removed in the background.
---@return integer files that were in it
function M.clear()
  local d, n = dir(), 0
  for _ in vim.fs.dir(d) do n = n + 1 end
  M.epoch = M.epoch + 1
  metas = {}
  local trash = ("%s.deleted.%d.%d"):format(d, vim.uv.os_getpid(), vim.uv.hrtime())
  if vim.uv.fs_rename(d, trash) then
    vim.system({ "rm", "-rf", trash }, {}, function() end)
  else
    vim.fn.delete(d, "rf")
  end
  return n
end

---@class inkmath.CacheFile
---@field name string
---@field size integer
---@field mtime number

--- Async walk of the cache directory: cb(files) with size and mtime of every entry.
---@param cb fun(files: inkmath.CacheFile[])
local function walk(cb)
  local d = dir()
  vim.uv.fs_scandir(d, function(err, handle)
    if err or not handle then return vim.schedule(function() cb({}) end) end
    local names = {}
    while true do
      local name, typ = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if typ == "file" then names[#names + 1] = name end
    end
    if #names == 0 then return vim.schedule(function() cb({}) end) end
    local files, left = {}, #names
    for _, name in ipairs(names) do
      vim.uv.fs_stat(d .. "/" .. name, function(_, st)
        if st then files[#files + 1] = { name = name, size = st.size, mtime = st.mtime.sec + st.mtime.nsec / 1e9 } end
        left = left - 1
        if left == 0 then vim.schedule(function() cb(files) end) end
      end)
    end
  end)
end

---@return integer bytes the cache may hold (`cache.max_size_mb`)
function M.max_bytes() return math.floor(require("inkmath.config").get().cache.max_size_mb * 1024 * 1024) end
local max_bytes = M.max_bytes

--- cb({dir, files, bytes, max_bytes}) after an async walk of the directory.
---@param cb fun(st: {dir: string, files: integer, bytes: integer, max_bytes: integer})
function M.stats(cb)
  walk(function(files)
    local bytes = 0
    for _, f in ipairs(files) do bytes = bytes + f.size end
    cb({ dir = dir(), files = #files, bytes = bytes, max_bytes = max_bytes() })
  end)
end

local ORPHAN_AGE = 60 -- s: older temp files and metadata without a PNG are abandoned

--- Delete the least recently used images (PNG and metadata, by the PNG's mtime: get()
--- touches it) until the cache holds at most 90% of max_bytes; images resident in
--- the terminal (maybe placed: a retransmit re-reads the file) are kept. Abandoned
--- worker temp files and metadata without a PNG are deleted too. Async; cb(deleted)
--- once every deletion finished.
---@param max integer bytes
---@param cb? fun(deleted: integer)
function M.prune(max, cb)
  local keep = require("inkmath.term.images").keys()
  walk(function(files)
    local d = dir()
    local total, pngs, size, old = 0, {}, {}, os.time() - ORPHAN_AGE
    local deleted, pending, walked = 0, 0, false
    local function finished()
      if walked and pending == 0 and cb then
        local f = cb
        cb = nil
        vim.schedule(function() f(deleted) end)
      end
    end
    local function unlink(name, bytes)
      pending = pending + 1
      vim.uv.fs_unlink(d .. "/" .. name, function()
        pending = pending - 1
        finished()
      end)
      total = total - bytes
    end
    for _, f in ipairs(files) do
      total = total + f.size
      size[f.name] = f.size
    end
    for _, f in ipairs(files) do
      local name = f.name
      if name:find(".tmp.", 1, true) then
        if f.mtime < old then unlink(name, f.size) end
      elseif name:sub(-4) == ".png" then
        if not keep[name:sub(1, -5)] then pngs[#pngs + 1] = f end
      elseif name:sub(-5) == ".json" and not size[name:sub(1, -6) .. ".png"] and f.mtime < old then
        unlink(name, f.size)
      end
    end
    table.sort(pngs, function(a, b) return a.mtime < b.mtime end)
    local limit = max * 0.9
    for _, f in ipairs(pngs) do
      if total <= limit then break end
      local key = f.name:sub(1, -5)
      unlink(f.name, f.size)
      metas[key] = nil
      if size[key .. ".json"] then unlink(key .. ".json", size[key .. ".json"]) end
      deleted = deleted + 1
    end
    walked = true
    finished()
  end)
end

--- Prune to `cache.max_size_mb` when idle, `delay_ms` from now (10 s after the first
--- attach; every PRUNE_EVERY puts).
---@param delay_ms integer
function M.auto_prune(delay_ms)
  vim.defer_fn(function()
    require("inkmath.idle").run("cache-prune", function()
      pcall(M.prune, max_bytes())
      return false
    end)
  end, delay_ms)
end

return M
