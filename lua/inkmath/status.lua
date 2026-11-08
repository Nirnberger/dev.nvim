-- :InkMath status: what inkmath is doing right now (backends, workers, render queue,
-- cache, kitty ids and resident images, attached buffers with placements and fill). collect() is synchronous; the cache's file count
-- and size come from an async directory walk (show() waits up to 500 ms for it).
local M = {}

---@class inkmath.Status
---@field backend {mathjax: boolean, tectonic: boolean}
---@field workers {pid: integer, pending: integer}[]
---@field queue table<integer, {queued: integer, inflight: integer}>
---@field cache {dir: string, files?: integer, bytes?: integer, max_bytes: integer}
---@field attached {buf: integer, name: string, ft: string, formulas: integer, errors: integer, placed: integer, fill: string}[]
---@field ids {start: integer, stop: integer, resident: integer, max_images: integer}

---@return inkmath.Status
function M.collect()
  local core = require("inkmath.core")
  local images = require("inkmath.term.images")
  local cfg = require("inkmath.config").get()
  local fill = require("inkmath.fill")
  local state = require("inkmath.view.state")
  local cache = require("inkmath.render.cache")
  local attached = {}
  for _, b in ipairs(core.attached_bufs()) do
    local ok, fs = pcall(require("inkmath.api").get_formulas, b)
    local errors = 0
    for _, f in ipairs(ok and fs or {}) do
      if f.error then errors = errors + 1 end
    end
    attached[#attached + 1] = { buf = b, name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":~:."),
      ft = vim.bo[b].filetype, formulas = ok and #fs or 0, errors = errors,
      placed = vim.tbl_count(state.get(b).nodes), fill = fill.state(b) }
  end
  local start, stop = images.range()
  return {
    backend = require("inkmath.render").available(),
    workers = require("inkmath.render.mathjax").stats(),
    queue = require("inkmath.render.queue").stats(),
    cache = { dir = cache.dir(), max_bytes = cache.max_bytes() },
    attached = attached,
    ids = { start = start, stop = stop, resident = images.resident_count(), max_images = cfg.max_images },
  }
end

local function mb(bytes) return ("%.1f MB"):format(bytes / 1024 / 1024) end

---@param t inkmath.Status
---@return string[]
function M.format(t)
  local yes = function(v) return v and "yes" or "no" end
  local out = { "inkmath status",
    ("backend: mathjax %s, tectonic %s"):format(yes(t.backend.mathjax), yes(t.backend.tectonic)) }
  local ws = {}
  for _, w in ipairs(t.workers) do ws[#ws + 1] = ("pid %d (%d pending)"):format(w.pid, w.pending) end
  out[#out + 1] = ("workers: %d running%s"):format(#t.workers, #ws > 0 and ": " .. table.concat(ws, ", ") or "")
  local qs = {}
  for b, q in pairs(t.queue) do qs[#qs + 1] = ("buffer %d: %d queued, %d in flight"):format(b, q.queued, q.inflight) end
  table.sort(qs)
  out[#out + 1] = "queue: " .. (#qs > 0 and table.concat(qs, "; ") or "empty")
  local c = t.cache
  out[#out + 1] = ("cache: %s, %s of %s"):format(c.dir,
    c.files and ("%d files, %s"):format(c.files, mb(c.bytes)) or "…", mb(c.max_bytes))
  out[#out + 1] = ("kitty ids: %d..%d, %d resident / max_images %d"):format(t.ids.start, t.ids.stop - 1,
    t.ids.resident, t.ids.max_images)
  if #t.attached == 0 then out[#out + 1] = "attached: none" end
  for _, a in ipairs(t.attached) do
    out[#out + 1] = ("attached: buffer %d %s (%s): %d formulas, %d placed, %d errors, fill %s"):format(a.buf,
      a.name ~= "" and a.name or "[No Name]", a.ft, a.formulas, a.placed, a.errors, a.fill)
  end
  return out
end

--- :InkMath status: print through nvim_echo once the cache walk is done, or after
--- `timeout_ms` (500) with "…" for the cache.
---@param timeout_ms? integer
function M.show(timeout_ms)
  local t = M.collect()
  local printed = false
  local function print_it()
    if printed then return end
    printed = true
    local chunks = {}
    for i, l in ipairs(M.format(t)) do chunks[#chunks + 1] = { (i > 1 and "\n" or "") .. l } end
    vim.api.nvim_echo(chunks, true, {})
  end
  require("inkmath.render.cache").stats(function(st)
    t.cache = st
    print_it()
  end)
  vim.defer_fn(print_it, timeout_ms or 500)
end

return M
