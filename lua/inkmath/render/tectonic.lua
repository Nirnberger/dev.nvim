-- Tectonic backend: compile formulas with LaTeX (preview package), rasterize pages with
-- ImageMagick and pad them onto the cell grid. Slower than MathJax; used for fallback.
local cache = require("inkmath.render.cache")
local config = require("inkmath.config")

local M = {}

local DEFAULT_PREAMBLE = { "\\documentclass{article}", "\\usepackage{amsmath,amssymb}" }
local XHEIGHT_PT = 4.305 -- x-height of cmr10, in TeX points
local PT_PER_IN = 72.27
local SP_PER_PT = 65536

---@class inkmath.RenderError
---@field message string
---@field backend string

--- argv of the configured `tectonic_cmd` / `magick_cmd` (nil: not executable)
---@param which "tectonic"|"magick"
---@return string[]|nil
local function argv(which, ...)
  return require("inkmath.render").argv(config.get()[which .. "_cmd"], ...)
end

--- Static check: both tectonic and magick must be installed.
---@return boolean
function M.available()
  return argv("tectonic") ~= nil and argv("magick") ~= nil
end

function M._run(cmd, cb)
  local ok, err = pcall(vim.system, cmd, { text = true }, function(res)
    vim.schedule(function()
      cb(res)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ code = -1, stdout = "", stderr = tostring(err) })
    end)
  end
end

local function run(cmd, cb) return M._run(cmd, cb) end

local function wrap_math(node)
  if node.kind == "inline" then
    return "$" .. node.src .. "$"
  elseif node.kind == "display" then
    return "\\[" .. node.src .. "\\]"
  end
  return node.src -- block: full \begin..\end
end

local function build_doc(items)
  local lines = {}
  vim.list_extend(lines, items[1].ctx.preamble or DEFAULT_PREAMBLE)
  vim.list_extend(lines, {
    "\\usepackage{xcolor}",
    -- `auctex` makes preview log the exact box size of every snippet
    "\\usepackage[auctex,active,tightpage]{preview}",
    "\\setlength\\PreviewBorder{0pt}",
    "\\begin{document}",
  })
  for _, it in ipairs(items) do
    local hex = it.ctx.color:gsub("^#", ""):upper()
    lines[#lines + 1] = ("\\begin{preview}\\color[HTML]{%s}%s\\end{preview}"):format(hex, wrap_math(it.node))
  end
  lines[#lines + 1] = "\\end{document}"
  return lines
end

--- Parse the log: snippet sizes (sp) by page number and the first real TeX error.
local function parse_log(path)
  local snippets, first_err = {}, nil
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return snippets, nil
  end
  for _, l in ipairs(lines) do
    local n, h, d, w = l:match("Preview: Snippet (%d+) ended%.%((%-?%d+)%+(%-?%d+)x(%-?%d+)%)")
    if n then
      snippets[tonumber(n)] = { h = tonumber(h), d = tonumber(d), w = tonumber(w) }
    elseif not first_err and l:sub(1, 2) == "! " and not l:find("^! Preview:") then
      first_err = l:sub(3)
    end
  end
  return snippets, first_err
end

local function round(x)
  return math.floor(x + 0.5)
end

--- Compute the magick pad command for one rasterized page.
local function layout(item, png_w, png_h, snip, pps)
  local ctx, node = item.ctx, item.node
  local cfg = config.of(ctx)
  local cw, ch = ctx.cell_w, ctx.cell_h
  local total = snip and (snip.h + snip.d) * pps or png_h
  local ratio = total / ch
  if node.kind == "inline" then
    local s = png_h > ch and ch / png_h or 1
    local ws, hs = math.max(1, round(png_w * s)), math.max(1, round(png_h * s))
    local cols = math.max(1, math.ceil(png_w * s / cw - 1e-6))
    local ty
    if snip then
      ty = cfg.inline.baseline * ch - s * (png_h - snip.d * pps)
    else
      ty = (ch - hs) / 2 -- no depth known: center vertically
    end
    ty = math.min(math.max(ty, 0), ch - hs)
    -- magick's -extent offset moves the image opposite to its sign, hence the negation
    local oy = -round(ty - (ch - hs) / 2)
    return {
      cols = cols,
      rows = 1,
      ratio = ratio,
      args = {
        s < 1 and "-resize" or nil,
        s < 1 and ("%dx%d!"):format(ws, hs) or nil,
        "-background", "none", "-gravity", "West",
        "-extent", ("%dx%d%+d%+d"):format(cols * cw, ch, 0, oy),
      },
    }
  end
  -- display/block: png is already trimmed to its content. Width is the container in whole
  -- cells (or the content width without a container); wider content shrinks to fit.
  local cols
  if (ctx.container_px or 0) > 0 then
    cols = math.max(1, math.ceil(ctx.container_px / cw - 1e-6))
  else
    cols = math.max(1, math.ceil(png_w / cw - 1e-6))
  end
  local W = cols * cw
  local s = png_w > W and W / png_w or 1
  local hs = math.max(1, round(png_h * s))
  local rows = math.max(1, math.ceil(hs / ch - 1e-6))
  return {
    cols = cols,
    rows = rows,
    ratio = hs / ch,
    args = {
      s < 1 and "-resize" or nil,
      s < 1 and ("%dx%d!"):format(W, hs) or nil,
      "-background", "none", "-gravity", "Center", "-extent", ("%dx%d"):format(W, rows * ch),
    },
  }
end

local function compact(list)
  local out = {}
  for i = 1, table.maxn(list) do
    if list[i] ~= nil then
      out[#out + 1] = list[i]
    end
  end
  return out
end

---@param items {node: inkmath.MathNode, ctx: inkmath.RenderCtx, key: string}[]
---@param cb_each fun(i: integer, img: inkmath.Image|nil, err: inkmath.RenderError|nil)
function M.batch(items, cb_each)
  if #items == 0 then
    return
  end
  local called = {}
  local function finish(i, img, err)
    if called[i] then
      return
    end
    called[i] = true
    vim.schedule(function()
      pcall(cb_each, i, img, err)
    end)
  end
  local function fail_all(msg)
    for i = 1, #items do
      finish(i, nil, { message = msg, backend = "tectonic" })
    end
  end
  local tmp
  local function cleanup()
    if tmp then
      pcall(vim.fn.delete, tmp, "rf")
    end
  end
  -- run fn under pcall; a thrown error fails every unfinished item and cleans up
  local function guarded(fn)
    return function(...)
      local ok, e = pcall(fn, ...)
      if not ok then
        pcall(fail_all, "tectonic backend error: " .. tostring(e))
        cleanup()
      end
    end
  end

  guarded(function()
    if not M.available() then
      return fail_all("tectonic or magick not installed")
    end
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    vim.fn.writefile(build_doc(items), tmp .. "/doc.tex")

    local first = items[1].ctx
    local cfg = config.of(first)
    local dpi = cfg.inline.x_height * first.cell_h * cfg.scale / (XHEIGHT_PT / PT_PER_IN)
    local pps = dpi / PT_PER_IN / SP_PER_PT -- pixels per sp
    local function magick(...) return argv("magick", ...) end

    -- -Z continue-on-errors: the auctex snippet markers are reported as TeX "errors", which
    -- tectonic would otherwise treat as fatal. Real errors are detected from the log below.
    run(argv("tectonic", "--untrusted", "-Z", "continue-on-errors", "--keep-logs", "--outdir", tmp, tmp .. "/doc.tex"), guarded(function(res)
      local snippets, first_err = parse_log(tmp .. "/doc.log")
      if res.code ~= 0 or first_err or not vim.uv.fs_stat(tmp .. "/doc.pdf") then
        local msg = first_err
        if not msg then
          local tail = vim.trim(res.stderr or "")
          msg = tail ~= "" and (tail:match("[^\n]*$")) or "tectonic failed"
        end
        cleanup()
        return fail_all(msg)
      end

      local step
      -- per-item guard: a thrown error fails only item i, then continues with the next
      local function item_guard(i, fn)
        return function(...)
          local ok, e = pcall(fn, ...)
          if not ok then
            finish(i, nil, { message = "tectonic backend error: " .. tostring(e), backend = "tectonic" })
            step(i + 1)
          end
        end
      end
      step = guarded(function(i)
        if i > #items then
          return cleanup()
        end
        local item = items[i]
        local png = ("%s/p%d.png"):format(tmp, i)
        local function bail(msg)
          finish(i, nil, { message = msg, backend = "tectonic" })
          step(i + 1)
        end
        local function identify_and_pad()
          run(magick("identify", "-format", "%w %h", png), item_guard(i, function(r2)
            local w, h = (r2.stdout or ""):match("(%d+) (%d+)")
            if r2.code ~= 0 or not w then
              return bail("magick identify failed")
            end
            local lay = layout(item, tonumber(w), tonumber(h), snippets[i], pps)
            local out = cache.path(item.key)
            vim.fn.mkdir(vim.fs.dirname(out), "p")
            -- write next to the target, then rename (atomic): a reader of `out` (the
            -- terminal, kitty transmit) never sees a half-written file
            local tmp_out = ("%s.tmp.%d.%d.png"):format(out:gsub("%.png$", ""), vim.uv.os_getpid(), vim.uv.hrtime())
            local cmd = magick(png)
            vim.list_extend(cmd, compact(lay.args))
            cmd[#cmd + 1] = tmp_out
            run(cmd, item_guard(i, function(r3)
              if r3.code ~= 0 then
                pcall(os.remove, tmp_out)
                return bail("magick pad failed: " .. vim.trim(r3.stderr or ""))
              end
              local renamed, rerr = os.rename(tmp_out, out)
              if not renamed then
                pcall(os.remove, tmp_out)
                return bail("could not move the image into the cache: " .. tostring(rerr))
              end
              finish(i, cache.put(item.key, lay.cols, lay.rows, lay.ratio), nil)
              step(i + 1)
            end))
          end))
        end
        run(magick("-density", ("%.3f"):format(dpi), "-background", "none", ("%s/doc.pdf[%d]"):format(tmp, i - 1), png), item_guard(i, function(r1)
          if r1.code ~= 0 then
            return bail("magick rasterize failed: " .. vim.trim(r1.stderr or ""))
          end
          if item.node.kind == "inline" then
            return identify_and_pad()
          end
          -- display/block: trim the page to its content first
          run(magick(png, "-trim", "+repage", png), item_guard(i, function(rt)
            if rt.code ~= 0 then
              return bail("magick trim failed: " .. vim.trim(rt.stderr or ""))
            end
            identify_and_pad()
          end))
        end))
      end)
      step(1)
    end))
  end)()
end

-- Single job queue: one tectonic document at a time. Requests that arrive while a job
-- runs wait and go into the next document together, grouped by everything the
-- document shares (preamble, color, cell size, container width).
local queue = {} ---@type {item: table, cb: fun(img: inkmath.Image|nil, err: inkmath.RenderError|nil)}[]
local running = false
local job_seq = 0
M.job_timeout_ms = nil ---@type integer|nil nil: config timeouts.tectonic_ms (tests set it)

local function group_key(ctx)
  return table.concat({
    table.concat(ctx.preamble or DEFAULT_PREAMBLE, "\n"),
    ctx.color or "", tostring(ctx.cell_w), tostring(ctx.cell_h), tostring(ctx.container_px),
    -- the document's dpi (batch) comes from these
    tostring(config.of(ctx).scale), tostring(config.of(ctx).inline.x_height),
  }, "\0")
end

local pump
pump = function()
  if running or #queue == 0 then return end
  local g = group_key(queue[1].item.ctx)
  local take, rest = {}, {}
  for _, q in ipairs(queue) do
    if group_key(q.item.ctx) == g then take[#take + 1] = q else rest[#rest + 1] = q end
  end
  queue = rest
  running = true
  job_seq = job_seq + 1
  local seq, left, called = job_seq, #take, {}
  local function deliver(i, img, err)
    if called[i] then return end
    called[i] = true
    pcall(take[i].cb, img, err)
    left = left - 1
    if left == 0 and job_seq == seq then
      running = false
      vim.schedule(pump)
    end
  end
  local function fail_rest(msg)
    for i = 1, #take do deliver(i, nil, { message = msg, backend = "tectonic" }) end
  end
  -- watchdog: a job that never reports back must not wedge the queue
  vim.defer_fn(function()
    if job_seq == seq and running then
      fail_rest("tectonic timed out")
    end
  end, M.job_timeout_ms or config.get().timeouts.tectonic_ms)
  local items = {}
  for i, q in ipairs(take) do items[i] = q.item end
  local ok, e = pcall(M.batch, items, deliver)
  if not ok then
    vim.schedule(function() fail_rest("tectonic backend error: " .. tostring(e)) end)
  end
end

--- Queue one formula; `cb` is called exactly once, asynchronously.
---@param item {node: inkmath.MathNode, ctx: inkmath.RenderCtx, key: string}
---@param cb fun(img: inkmath.Image|nil, err: inkmath.RenderError|nil)
function M.submit(item, cb)
  queue[#queue + 1] = { item = item, cb = cb }
  pump()
end

return M
