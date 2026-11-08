-- The option schema: the single source of truth for defaults, validation, unknown-key
-- warnings, per-filetype overrides and the options section of doc/inkmath.txt.
-- Adding an option is one entry in `M.options`.

---@class inkmath.Opt
---@field path string            dotted: "inline.x_height"
---@field default any            deep-copied; nil allowed (cell_size)
---@field check string|fun(v:any):boolean  type name or predicate
---@field expect? string         message for predicate failures
---@field doc string             one-line doc used by gendoc
---@field scope? "global"|"buffer"  "buffer" = allowed in overrides (default "global")
---@field free? boolean          table with arbitrary keys (macros, overrides)
---@field partial_configs? boolean  free table whose values are option tables (overrides)

local log = require("inkmath.log")

local M = {}

local function positive(v) return type(v) == "number" and v > 0 end
local function int_ge(min)
  return function(v) return type(v) == "number" and v >= min and v == math.floor(v) end
end
local function oneof(...)
  local set = {}
  for _, v in ipairs({ ... }) do
    set[v] = true
  end
  return function(v) return set[v] == true end
end
local function command(v)
  if type(v) == "string" then return v ~= "" end
  return type(v) == "table" and #v > 0 and vim.iter(v):all(function(x) return type(x) == "string" end)
end
-- nvim_open_win() border names; a list has 1, 2, 4 or 8 entries, each a char or {char, hl}
local BORDERS = { none = true, single = true, double = true, rounded = true, solid = true, shadow = true, bold = true }
local function border(v)
  if type(v) == "string" then return BORDERS[v] == true end
  if type(v) ~= "table" or not vim.list_contains({ 1, 2, 4, 8 }, #v) or #v ~= vim.tbl_count(v) then return false end
  return vim.iter(v):all(function(x) return type(x) == "string" or (type(x) == "table" and type(x[1]) == "string") end)
end
local function string_list(v)
  if type(v) ~= "table" then return false end
  for _, x in pairs(v) do
    if type(x) ~= "string" then return false end
  end
  return true
end

---@type inkmath.Opt[]
M.options = {
  {
    path = "filetypes",
    default = { "tex", "markdown", "quarto", "rmd" },
    check = string_list,
    expect = "list of filetype names",
    doc = "Filetypes attached automatically (each needs a detector registration).",
  },
  {
    path = "enabled",
    default = true,
    check = function(v) return type(v) == "boolean" or vim.is_callable(v) end,
    expect = "boolean or function(buf): boolean",
    scope = "buffer",
    doc = "Auto-attach switch; a function decides per buffer (errors count as false).",
  },
  {
    path = "max_file_size",
    default = 2.0,
    check = positive,
    expect = "number > 0",
    doc = "Buffers larger than this many MiB are not attached automatically.",
  },
  {
    path = "backend",
    default = "mathjax",
    check = oneof("mathjax", "tectonic"),
    expect = "'mathjax' or 'tectonic'",
    scope = "buffer",
    doc = "Renderer: MathJax worker (fast) or tectonic (full TeX).",
  },
  {
    path = "fallback",
    default = true,
    check = "boolean",
    scope = "buffer",
    doc = "Retry with tectonic when MathJax rejects a formula.",
  },
  {
    path = "highlight",
    default = "Normal",
    check = "string",
    scope = "buffer",
    doc = "Highlight group whose foreground colors the math.",
  },
  {
    path = "scale",
    default = 1.0,
    check = positive,
    expect = "number > 0",
    scope = "buffer",
    doc = "Size factor applied to every image.",
  },
  {
    path = "inline.x_height",
    default = 0.45,
    check = positive,
    expect = "number > 0",
    scope = "buffer",
    doc = "Height of an x in cell heights; sets the size of inline math.",
  },
  {
    path = "inline.baseline",
    default = 0.78,
    check = positive,
    expect = "number > 0",
    scope = "buffer",
    doc = "Text baseline position in the cell, from the top (fraction of the cell height).",
  },
  {
    path = "inline.promote",
    default = false,
    check = "boolean",
    scope = "buffer",
    doc = "Show tall inline formulas as an extra display image below the line.",
  },
  {
    path = "inline.promote_ratio",
    default = 1.6,
    check = positive,
    expect = "number > 0",
    scope = "buffer",
    doc = "Height (in cells) above which an inline formula is promoted.",
  },
  {
    path = "display.center",
    default = true,
    check = "boolean",
    scope = "buffer",
    doc = "Center display math in the text width (kept for compatibility: display math is always centered).",
  },
  {
    path = "preview.enabled",
    default = true,
    check = "boolean",
    scope = "buffer",
    doc = "Live preview float while typing inside a formula in insert mode.",
  },
  {
    path = "preview.debounce_ms",
    default = 50,
    check = positive,
    expect = "number > 0",
    scope = "buffer",
    doc = "Delay before the preview updates.",
  },
  {
    path = "preview.border",
    default = nil,
    scope = "buffer",
    check = border,
    expect = "nil, a border name (rounded, single, double, bold, solid, shadow, none) or a list of 1, 2, 4 or 8 chars",
    doc = "Preview float border (see 'winborder'); nil: 'winborder' if set, else \"rounded\".",
  },
  {
    path = "preview.position",
    default = "below",
    check = oneof("below", "above"),
    expect = "'below' or 'above'",
    scope = "buffer",
    doc = "Preview float below the formula or above it.",
  },
  {
    path = "preview.error_lines",
    default = 3,
    check = int_ge(0),
    expect = "integer >= 0",
    scope = "buffer",
    doc = "Lines of a TeX error the preview float shows instead of the image; 0 closes the float on an error.",
  },
  {
    path = "render.inline",
    default = true,
    check = "boolean",
    scope = "buffer",
    doc = "Render inline math ($...$, \\(...\\)).",
  },
  {
    path = "render.display",
    default = true,
    check = "boolean",
    scope = "buffer",
    doc = "Render display math and environments ($$...$$, \\[...\\], equation, ...).",
  },
  {
    path = "max_formula_len",
    default = 4000,
    check = positive,
    expect = "number > 0",
    scope = "buffer",
    doc = "Formulas with longer source are not rendered (shown as an error).",
  },
  {
    path = "debounce_ms",
    default = 80,
    check = positive,
    expect = "number > 0",
    scope = "buffer",
    doc = "Delay before images update while edits or scrolls keep coming (a single edit in normal mode, a jump or a scroll after a quiet spell updates at once; typing in insert mode always waits).",
  },
  {
    path = "fill.enabled",
    default = true,
    check = "boolean",
    doc = "Render formulas off-screen to the disk cache in the background while you are idle (and detect rows a large edit left stale); they are shown, from the cache, when scrolled to.",
  },
  {
    path = "fill.rows_per_step",
    default = 300,
    check = int_ge(1),
    expect = "integer >= 1",
    doc = "Rows the background fill handles per step.",
  },
  {
    path = "fill.max_jobs",
    default = 4,
    check = int_ge(1),
    expect = "integer >= 1",
    doc = "Renders (not cached) the background fill queues per step.",
  },
  {
    path = "keep_screens",
    default = 3,
    check = int_ge(1),
    expect = "integer >= 1",
    doc = "Images stay placed within this many window heights above and below each window showing the buffer; farther ones are cleared (and may be deleted from the terminal), and placed again from the disk cache when scrolled back to. Lowered to 1 for a buffer while more than max_images would stay placed.",
  },
  {
    path = "max_images",
    default = 512,
    check = positive,
    expect = "number > 0",
    doc = "Images kept in the terminal (those placed near the windows, see keep_screens, and recently used ones) before the least recently used are deleted.",
  },
  {
    path = "workers",
    default = 2,
    check = int_ge(1),
    expect = "integer >= 1",
    doc = "MathJax worker processes (renders run in parallel).",
  },
  {
    path = "image_ids.base",
    default = 0x200000,
    check = int_ge(1),
    expect = "integer >= 1",
    doc = "First kitty image id inkmath uses (ids are 24-bit: at most 0xFFFFFF); image_ids is read when the first image is shown.",
  },
  {
    path = "image_ids.span",
    default = 0x10000,
    check = int_ge(1),
    expect = "integer >= 1",
    doc = "Number of ids per Neovim instance; at least 2 * max_images (resident images stay near max_images, so ids do not run out).",
  },
  {
    path = "image_ids.per_instance",
    default = true,
    check = "boolean",
    doc = "Offset the range by the process id (one of 224 slots), so Neovims in one terminal (tmux panes) usually do not collide. Two instances share a slot with probability 1/224 (about 12% for 8 panes); then one's eviction or exit deletes the other's images. For a fixed setup use per_instance = false with a distinct base per instance. :checkhealth inkmath shows the range in use.",
  },
  {
    path = "term.backend",
    default = "auto",
    check = oneof("auto", "kitty", "iterm2", "sixel", "none"),
    expect = "one of 'auto', 'kitty', 'iterm2', 'sixel', 'none'",
    doc = "Terminal graphics backend: 'auto' detects it (kitty/Ghostty, iTerm2, Sixel), a name forces that backend, 'none' shows no images.",
  },
  {
    path = "cell_size",
    default = nil,
    check = function(v) return type(v) == "table" and positive(v.w) and positive(v.h) end,
    expect = "nil or { w = number > 0, h = number > 0 }",
    doc = "Terminal cell size in pixels, e.g. { w = 9, h = 18 }; nil detects it.",
  },
  {
    path = "node_cmd",
    default = "node",
    check = command,
    expect = "command name or argv list",
    doc = "Node.js command for the MathJax worker (string or argv prefix list).",
  },
  {
    path = "tectonic_cmd",
    default = "tectonic",
    check = command,
    expect = "command name or argv list",
    doc = "tectonic command (string or argv prefix list).",
  },
  {
    path = "magick_cmd",
    default = "magick",
    check = command,
    expect = "command name or argv list",
    doc = "ImageMagick command for the tectonic pipeline (string or argv prefix list).",
  },
  {
    path = "cache_dir",
    default = nil,
    check = "string",
    doc = 'Image cache directory; nil: stdpath("cache") .. "/inkmath".',
  },
  {
    path = "cache.max_size_mb",
    default = 200,
    check = positive,
    expect = "number > 0",
    doc = "Size cap of the image cache; the least recently used images are deleted (10 s after the first attach, then every 200 renders).",
  },
  {
    path = "timeouts.mathjax_ms",
    default = 10000,
    check = positive,
    expect = "number > 0",
    doc = "A MathJax render taking longer kills its worker.",
  },
  {
    path = "timeouts.tectonic_ms",
    default = 120000,
    check = positive,
    expect = "number > 0",
    doc = "A tectonic job taking longer fails its formulas.",
  },
  {
    path = "macros",
    default = {},
    check = "table",
    free = true,
    scope = "buffer",
    doc = 'Extra MathJax macros, e.g. { RR = "\\\\mathbb{R}" }.',
  },
  {
    path = "conceal",
    default = nil,
    check = function(v) return v == false or type(v) == "table" end,
    expect = "false or table",
    scope = "buffer",
    doc = "Window-local conceal options for attached buffers; false: never written (another plugin or you manage them).",
  },
  {
    path = "conceal.level",
    default = 2,
    check = oneof(0, 1, 2, 3),
    expect = "0, 1, 2 or 3",
    scope = "buffer",
    doc = "'conceallevel' set in windows showing attached buffers.",
  },
  {
    path = "conceal.cursor",
    default = "nvic",
    scope = "buffer",
    check = function(v) return type(v) == "string" and v:match("^[nvic]*$") ~= nil end,
    expect = "string of n, v, i, c",
    doc = "'concealcursor' set in windows showing attached buffers.",
  },
  {
    path = "equation_numbers",
    default = "document",
    check = oneof("document", "formula"),
    scope = "buffer",
    doc = 'LaTeX without an .aux file: "document" numbers equations in document order like LaTeX (an align after an equation continues at (2)); "formula" numbers each formula on its own. Numbers from the .aux file (vimtex) win either way.',
  },
  {
    path = "vimtex.math_conceal",
    default = false,
    check = "boolean",
    doc = "false: clear the math conceal (\\alpha -> α) of vimtex or of Vim's own syntax/tex.vim (g:tex_conceal flags d, m, g, s), so a revealed formula shows its source and no conceal character stands next to an inline image. true keeps it (those characters then show next to inline images).",
  },
  {
    path = "log.level",
    default = "warn",
    check = oneof(unpack(log.LEVEL_NAMES)),
    expect = "one of '" .. table.concat(log.LEVEL_NAMES, "', '") .. "'",
    doc = "Least severe message shown.",
  },
  {
    path = "overrides",
    default = {},
    check = "table",
    free = true,
    partial_configs = true,
    doc = "Per-filetype options, e.g. { markdown = { scale = 1.2 } } (buffer-scoped options only).",
  },
}

--- Checks across options, run on the resolved config: each returns an error or nil.
---@type (fun(c: table): string|nil)[]
M.constraints = {
  function(c)
    local o = c.image_ids
    if o.span < 2 * c.max_images then
      return ("image_ids.span: must be at least 2 * max_images (%d), got %d"):format(2 * c.max_images, o.span)
    end
    local space = require("inkmath.term.idspace")
    local last = o.base + o.span * (o.per_instance and space.INSTANCES or 1) - 1
    if last > space.MAX then
      return ("image_ids: base + span * %s - 1 = 0x%x exceeds 0x%x"):format(
        o.per_instance and space.INSTANCES .. " (per_instance)" or "1",
        last,
        space.MAX
      )
    end
  end,
}

---@param c table resolved config
---@return string[] errors
function M.check_constraints(c)
  local errs = {}
  for _, f in ipairs(M.constraints) do
    errs[#errs + 1] = f(c)
  end
  return errs
end

local by_path = {} ---@type table<string, inkmath.Opt>
local children = { [""] = {} } ---@type table<string, string[]> container path -> child names

local function index()
  by_path, children = {}, { [""] = {} }
  for _, o in ipairs(M.options) do
    by_path[o.path] = o
    local parent = ""
    for name in o.path:gmatch("[^.]+") do
      local path = parent == "" and name or parent .. "." .. name
      children[parent] = children[parent] or {}
      if not vim.tbl_contains(children[parent], name) then table.insert(children[parent], name) end
      parent = path
    end
  end
end
index()

--- (tests, later tasks) re-index after M.options changed
M.reindex = index

---@param path string
---@return inkmath.Opt|nil
function M.get(path) return by_path[path] end

--- path names a table of options (implied by dotted children, e.g. "inline")
---@param path string
function M.is_container(path) return children[path] ~= nil and path ~= "" end

---@return table
function M.defaults()
  local out = {}
  for _, o in ipairs(M.options) do
    if o.default ~= nil and not M.is_container(o.path) then
      local t, keys = out, vim.split(o.path, ".", { plain = true })
      for i = 1, #keys - 1 do
        t[keys[i]] = t[keys[i]] or {}
        t = t[keys[i]]
      end
      t[keys[#keys]] = vim.deepcopy(o.default)
    end
  end
  return out
end

local function levenshtein(a, b)
  local prev = {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    local cur = { [0] = i }
    for j = 1, #b do
      local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[#b]
end

--- Closest candidate: edit distance <= 2, else the only candidate `name` is a prefix of.
---@param name string
---@param candidates string[]
---@return string|nil
function M.suggest(name, candidates)
  local best, best_d
  for _, c in ipairs(candidates) do
    local d = levenshtein(name, c)
    if d <= 2 and (not best_d or d < best_d) then
      best, best_d = c, d
    end
  end
  if best then return best end
  local hits = vim.tbl_filter(function(c) return vim.startswith(c, name) end, candidates)
  return #hits == 1 and hits[1] or nil
end

local function check_value(o, v)
  if type(o.check) == "string" then return type(v) == o.check end
  return o.check(v) == true
end

local function walk(tbl, prefix, where, scope, errs, warns)
  local keys = vim.tbl_keys(tbl)
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local v = tbl[k]
    local path = prefix == "" and tostring(k) or prefix .. "." .. tostring(k)
    local shown = where .. path
    local o = by_path[path]
    if o then
      if not check_value(o, v) then
        errs[#errs + 1] = ("%s: expected %s, got %s"):format(shown, o.expect or o.check, vim.inspect(v))
      elseif scope == "buffer" and o.scope ~= "buffer" then
        errs[#errs + 1] = shown .. ": global option, not allowed in overrides"
      elseif o.partial_configs then
        for ft, sub in pairs(v) do
          if type(sub) ~= "table" then
            errs[#errs + 1] = ("%s.%s: expected table, got %s"):format(shown, tostring(ft), vim.inspect(sub))
          else
            walk(sub, "", ("%s.%s."):format(shown, tostring(ft)), "buffer", errs, warns)
          end
        end
      elseif type(v) == "table" and M.is_container(path) then
        walk(v, path, where, scope, errs, warns)
      end
    elseif M.is_container(path) then
      if type(v) ~= "table" then
        errs[#errs + 1] = ("%s: expected table, got %s"):format(shown, vim.inspect(v))
      else
        walk(v, path, where, scope, errs, warns)
      end
    else
      local s = type(k) == "string" and M.suggest(k, children[prefix] or {})
      local hint = s and (", did you mean '%s'?"):format(where .. (prefix == "" and s or prefix .. "." .. s)) or ""
      warns[#warns + 1] = ("unknown option '%s'%s"):format(shown, hint)
    end
  end
end

--- Check a (partial) user config. Missing keys are fine (defaults fill them).
---@param tbl table
---@param opts? {where?: string, scope?: "buffer"}
---@return string[] errors, string[] warnings
function M.validate(tbl, opts)
  opts = opts or {}
  local errs, warns = {}, {}
  if type(tbl) ~= "table" then
    return { ("%sexpected table, got %s"):format(opts.where or "", vim.inspect(tbl)) }, warns
  end
  walk(tbl, "", opts.where or "", opts.scope, errs, warns)
  return errs, warns
end

--- defaults of the options below container `path` (e.g. "conceal" -> {level, cursor})
local function container_defaults(path)
  local t = M.defaults()
  for name in path:gmatch("[^.]+") do
    t = type(t) == "table" and t[name] or nil
  end
  return type(t) == "table" and t or {}
end

--- Merge `over` onto a copy of `base`. Containers and free tables merge key by key
--- (overrides entries merge as partial configs); everything else, lists included, is
--- replaced. A container table replacing a non-table (`conceal = false` in a lower
--- layer) is merged onto the container's defaults, so no default goes missing.
---@param base table
---@param over table
---@param prefix? string
---@return table
function M.merge(base, over, prefix)
  prefix = prefix or ""
  local out = vim.deepcopy(base)
  for k, v in pairs(over) do
    local path = prefix == "" and tostring(k) or prefix .. "." .. tostring(k)
    local o = by_path[path]
    local mergeable = type(v) == "table" and type(out[k]) == "table" and (M.is_container(path) or (o and o.free))
    if not mergeable and type(v) == "table" and out[k] ~= nil and M.is_container(path) then
      out[k] = M.merge(container_defaults(path), v, path)
    elseif not mergeable then
      out[k] = vim.deepcopy(v)
    elseif o and o.partial_configs then
      for ft, sub in pairs(v) do
        out[k][ft] = type(sub) == "table" and type(out[k][ft]) == "table" and M.merge(out[k][ft], sub)
          or vim.deepcopy(sub)
      end
    elseif o and o.free then
      for fk, fv in pairs(v) do
        out[k][fk] = vim.deepcopy(fv)
      end
    else
      out[k] = M.merge(out[k], v, path)
    end
  end
  return out
end

return M
