local M = {}

local function node_id(kind, env, src) return require("inkmath.detect").node_id(kind, env, src) end

--- Remove balanced \begin{x}..\end{x} spans, then report whether a `\\` remains.
local function has_toplevel_break(src)
  local s = src
  while true do
    local b, be, name = s:find("\\begin%s*{([^}]*)}")
    if not b then break end
    local pat = "\\(%a+)%s*{" .. vim.pesc(name) .. "}"
    local depth, pos, close_end = 1, be + 1, nil
    while depth > 0 do
      local ms, me, which = s:find(pat, pos)
      if not ms then break end
      if which == "begin" then depth = depth + 1 elseif which == "end" then depth = depth - 1 end
      pos = me + 1
      if depth == 0 then close_end = me end
    end
    if close_end then
      s = s:sub(1, b - 1) .. " " .. s:sub(close_end + 1)
    else
      s = s:sub(1, b - 1) .. " " .. s:sub(be + 1) -- unbalanced: drop the opener only
    end
  end
  return s:find("\\\\", 1, true) ~= nil
end

local function wrap(src)
  if has_toplevel_break(src) then return "\\begin{gathered}" .. src .. "\\end{gathered}" end
  return src
end

local function make(kind, src, srow, scol, erow, ecol)
  return {
    id = node_id(kind, nil, src), kind = kind, src = src,
    range = { srow = srow, scol = scol, erow = erow, ecol = ecol },
  }
end

local function key(r) return r.srow .. ":" .. r.scol .. ":" .. r.erow .. ":" .. r.ecol end

--- Text of a 0-based end-exclusive range.
local function range_text(bufnr, sr, sc, er, ec)
  return table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {}), "\n")
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- Collect {sr, er} row spans of code blocks from the block-level markdown tree.
local function code_rows(parser, bufnr, lo, hi)
  local rows = {}
  local q = vim.treesitter.query.parse("markdown", "[(fenced_code_block) (indented_code_block)] @c")
  local tree = parser:trees()[1]
  if not tree then return rows end
  for _, node in q:iter_captures(tree:root(), bufnr, lo, hi) do
    local sr, _, er, ec = node:range()
    if ec == 0 then er = er - 1 end
    rows[#rows + 1] = { sr, er }
  end
  return rows
end

local function in_code_rows(rows, row)
  for _, r in ipairs(rows) do
    if row >= r[1] and row <= r[2] then return true end
  end
  return false
end

--- The LanguageTree's markdown_inline trees after parsing rows [lo, hi] (bounded) or
--- the whole buffer. detect/incr parses the whole tree first (see there), so a
--- bounded call then parses nothing.
local function get_inline_trees(parser, lo, hi, bounded)
  parser:parse(bounded and { lo, hi } or true)
  local child = parser:children().markdown_inline
  local out = {}
  if child then
    for _, t in pairs(child:trees()) do out[#out + 1] = t end
  end
  return out
end

--- Collect code_span ranges from the markdown_inline trees.
local function code_spans(trees, bufnr, lo, hi)
  local spans = {}
  local q = vim.treesitter.query.parse("markdown_inline", "(code_span) @c")
  for _, tree in ipairs(trees) do
    for _, node in q:iter_captures(tree:root(), bufnr, lo, hi) do
      spans[#spans + 1] = { node:range() }
    end
  end
  return spans
end

local function in_span(spans, sr, sc, er, ec)
  for _, s in ipairs(spans) do
    local starts_after = sr > s[1] or (sr == s[1] and sc >= s[2])
    local ends_before = er < s[3] or (er == s[3] and ec <= s[4])
    if starts_after and ends_before then return true end
  end
  return false
end

--- The `$$` line scanner over `lines` (lines[1] is row `off`): calls
--- pair(i, j) with indices into `lines` for each `$$` line i closed by the `$$` line j.
local function scan(lines, off, rows, pair)
  local function in_code(idx) return in_code_rows(rows, off + idx - 1) end
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if line:find("$$", 1, true) and not in_code(i) and trim(line) == "$$" and not line:match("\\%s*$") then
      local j = i + 1
      while j <= #lines and not in_code(j) and trim(lines[j]) ~= "$$" do j = j + 1 end
      if j <= #lines and not in_code(j) then
        pair(i, j)
        i = j
      end
    end
    i = i + 1
  end
end

--- Row pairs {open, close} of the `$$` blocks the line scanner finds in the whole
--- buffer (also the ones with an empty body). detect/incr compares them: a `$$` line
--- added, removed or (un)fenced re-pairs every later block.
---@param bufnr integer
---@return integer[][]
function M.block_pairs(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown", { error = false })
  if not ok or not parser then return {} end
  parser:parse()
  local rows = code_rows(parser, bufnr)
  local out = {}
  scan(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 0, rows, function(i, j) out[#out + 1] = { i - 1, j - 1 } end)
  return out
end

--- @param srow? integer first row (inclusive) to look at; default: whole buffer. A
--- bounded call parses only the injections of those rows and must not start or end
--- inside a `$$` ... `$$` block (the line scanner pairs `$$` lines within the rows;
--- see block_pairs).
--- @param erow? integer last row (inclusive)
function M.detect(bufnr, srow, erow)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown", { error = false })
  if not ok or not parser then return {}, false end
  local bounded = srow ~= nil or erow ~= nil
  local nlines = vim.api.nvim_buf_line_count(bufnr)
  local lo = srow or 0
  local hi = math.min(erow or (nlines - 1), nlines - 1)
  parser:parse() -- the block tree (injections: get_inline_trees)
  local qlo, qhi = lo, hi + 1
  local rows = code_rows(parser, bufnr, qlo, qhi)
  local itrees = get_inline_trees(parser, qlo, qhi, bounded)
  local spans = code_spans(itrees, bufnr, qlo, qhi)
  local out, seen = {}, {}

  local function add(n)
    local k = key(n.range)
    local r = n.range
    if seen[k] or in_span(spans, r.srow, r.scol, r.erow, r.ecol) then return end
    seen[k] = true
    out[#out + 1] = n
  end

  -- 1. treesitter: latex_block in the markdown_inline trees
  local iq = vim.treesitter.query.parse("markdown_inline", "(latex_block) @m")
  for _, tree in ipairs(itrees) do
    for _, node in iq:iter_captures(tree:root(), bufnr, qlo, qhi) do
      local sr, sc, er, ec = node:range()
      if sr <= hi and er >= lo and not in_code_rows(rows, sr) then
        local text = range_text(bufnr, sr, sc, er, ec)
        local dl = text:match("^%$%$") and 2 or 1
        if #text >= 2 * dl then
          local src = trim(text:sub(dl + 1, #text - dl))
          if src ~= "" then
            add(make(dl == 2 and "display" or "inline", wrap(src), sr, sc, er, ec))
          end
        end
      end
    end
  end

  -- 2. line scanner: `$$` alone on its line opens a block that a later `$$`-only line closes
  local lines = vim.api.nvim_buf_get_lines(bufnr, lo, hi + 1, false)
  scan(lines, lo, rows, function(i, j)
    local src = trim(table.concat(vim.list_slice(lines, i + 1, j - 1), "\n"))
    local scol = lines[i]:find("%$%$") - 1
    local ecol = lines[j]:find("%$%$") + 1
    if src ~= "" then add(make("display", wrap(src), lo + i - 1, scol, lo + j - 1, ecol)) end
  end)

  return out
end

return M
