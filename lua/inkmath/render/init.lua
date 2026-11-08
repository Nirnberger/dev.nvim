-- Render pipeline: cache -> MathJax worker -> (fallback) tectonic.
local cache = require("inkmath.render.cache")
local config = require("inkmath.config")
local mathjax = require("inkmath.render.mathjax")
local tectonic = require("inkmath.render.tectonic")

local M = {}

---@alias inkmath.RenderCallback fun(img: inkmath.Image|nil, err: inkmath.RenderError|nil)

---@type table<string, inkmath.RenderCallback[]>
local inflight = {}

--- argv for a configured command (`node_cmd`, ...): its first word resolved with
--- exepath, then `...`. nil when the command is not executable.
---@param cmd string|string[]
---@return string[]|nil
function M.argv(cmd, ...)
  local list = type(cmd) == "string" and { cmd } or vim.deepcopy(cmd)
  local exe = vim.fn.exepath(list[1])
  if exe == "" then return nil end
  list[1] = exe
  return vim.list_extend(list, { ... })
end

---@return {mathjax: boolean, tectonic: boolean}
function M.available() return { mathjax = mathjax.available(), tectonic = tectonic.available() } end

function M.shutdown() mathjax.shutdown() end

-- mathjax errors that mean "could not run" rather than "TeX is invalid"
local UNAVAILABLE = {
  ["worker unavailable"] = true,
  ["worker shut down"] = true,
  ["worker exited"] = true,
  ["worker timeout"] = true,
}

local function mathjax_render(node, ctx, key, cb, retried)
  local cfg = config.of(ctx)
  vim.fn.mkdir(vim.fs.dirname(cache.path(key)), "p")
  mathjax.request({
    tex = node.src,
    display = node.kind ~= "inline",
    macros = ctx.macros or {},
    color = ctx.color,
    cell_w = ctx.cell_w,
    cell_h = ctx.cell_h,
    container_px = ctx.container_px,
    x_height = cfg.inline.x_height,
    baseline = cfg.inline.baseline,
    scale = cfg.scale,
    out = cache.path(key),
  }, function(res, err)
    if res then
      local ok, img = pcall(cache.put, key, res.cols, res.rows, res.ratio)
      if ok then
        cb(img, nil)
      else
        cb(nil, { message = "cache write failed: " .. tostring(img), backend = "mathjax" })
      end
    elseif err == "worker exited" and not retried then
      mathjax_render(node, ctx, key, cb, true) -- worker restarts on next request
    else
      cb(nil, { message = err or "render failed", backend = "mathjax", unavailable = UNAVAILABLE[err] or nil })
    end
  end)
end

-- MathJax stage shared by every flow (normal and live preview "nofallback:") that
-- needs the same mathjax key: one worker request per PNG path, never two workers
-- writing the same file. key -> callbacks waiting for the stage result.
local mj_inflight = {} ---@type table<string, fun(img: inkmath.Image|nil, err: inkmath.RenderError|nil)[]>

local function mathjax_stage(node, ctx, key, cb)
  local slot = cache.epoch .. ":" .. key -- see M.render: flows of a cleared cache are not joined
  local waiters = mj_inflight[slot]
  if waiters then
    waiters[#waiters + 1] = cb
    return
  end
  mj_inflight[slot] = { cb }
  local function finish(img, err)
    local list = mj_inflight[slot]
    mj_inflight[slot] = nil
    for _, w in ipairs(list or {}) do
      pcall(w, img, err)
    end
  end
  local ok, e = pcall(mathjax_render, node, ctx, key, finish)
  if not ok then finish(nil, { message = tostring(e), backend = "mathjax" }) end
end

local function tectonic_render(node, ctx, key, cb) tectonic.submit({ node = node, ctx = ctx, key = key }, cb) end

--- The cached image of `node` (either backend), or nil.
---@param node inkmath.MathNode
---@param ctx inkmath.RenderCtx
---@return inkmath.Image|nil
function M.cached(node, ctx)
  return cache.get(cache.key(node, ctx, "mathjax")) or cache.get(cache.key(node, ctx, "tectonic"))
end

--- Render `node`. `cb` is called exactly once: synchronously on a cache hit, otherwise
--- from vim.schedule.
--- opts.no_fallback: MathJax only, never tectonic (live preview while typing).
--- opts.on_stage: called once (possibly synchronously) as soon as this request no
--- longer waits for a MathJax worker: the MathJax stage finished (even when tectonic
--- follows), was not needed (cache hit, tectonic backend), or the request joined
--- one already in flight. The render queue frees its worker slot there.
---@param node inkmath.MathNode
---@param ctx inkmath.RenderCtx
---@param cb inkmath.RenderCallback
---@param opts? {no_fallback?: boolean, on_stage?: fun()}
function M.render(node, ctx, cb, opts)
  local no_fallback = opts and opts.no_fallback or false
  local stage_cb = opts and opts.on_stage
  local function stage()
    if stage_cb then
      local f = stage_cb
      stage_cb = nil
      pcall(f)
    end
  end
  local cfg = config.of(ctx)
  local len = #node.src > cfg.max_formula_len and vim.fn.strchars(node.src) -- bytes >= chars
  if len and len > cfg.max_formula_len then
    stage()
    return cb(nil, { message = ("formula too long (%d > %d)"):format(len, cfg.max_formula_len), backend = "none" })
  end
  local mkey = cache.key(node, ctx, "mathjax")
  local tkey = cache.key(node, ctx, "tectonic")
  local hit = cache.get(mkey) or cache.get(tkey)
  if hit then
    stage()
    return cb(hit, nil)
  end

  local flow = (cfg.backend == "tectonic" and not no_fallback) and tkey or mkey
  if no_fallback then flow = "nofallback:" .. flow end
  -- a flow started before :InkMath clear-cache may fail writing into the deleted
  -- directory: later requests start their own instead of joining it
  flow = cache.epoch .. ":" .. flow
  if inflight[flow] then
    table.insert(inflight[flow], cb)
    stage()
    return
  end
  inflight[flow] = { cb }

  local function done(img, err)
    stage()
    local waiters = inflight[flow]
    if not waiters then
      return -- already completed
    end
    inflight[flow] = nil
    vim.schedule(function()
      for _, w in ipairs(waiters) do
        pcall(w, img, err)
      end
    end)
  end

  local function with_tectonic(prev_err)
    if tectonic.available() then
      tectonic_render(node, ctx, tkey, function(img, err)
        if img then
          done(img, nil)
        else
          -- keep the mathjax error only when mathjax really rejected the TeX
          if prev_err and not prev_err.unavailable then
            done(nil, prev_err)
          else
            done(nil, err)
          end
        end
      end)
    else
      done(nil, prev_err or { message = "no render backend available", backend = "none" })
    end
  end

  local function start()
    if no_fallback then return mathjax_stage(node, ctx, mkey, done) end
    if cfg.backend == "tectonic" then
      stage()
      return with_tectonic(nil)
    end
    mathjax_stage(node, ctx, mkey, function(img, err)
      stage()
      if img then
        done(img, nil)
      elseif cfg.fallback then
        local ok, e = pcall(with_tectonic, err)
        if not ok then done(nil, { message = tostring(e), backend = "tectonic" }) end
      else
        done(nil, err)
      end
    end)
  end
  local ok, e = pcall(start)
  if not ok then done(nil, { message = tostring(e), backend = "render" }) end
end

return M
