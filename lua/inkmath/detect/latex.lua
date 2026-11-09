local M = {}

local SKIP = {
  comment = true,
  line_comment = true,
  block_comment = true,
  verbatim_environment = true,
  listing_environment = true,
}

local QUERY = [[
  (inline_formula) @inline
  (displayed_equation) @display
  (math_environment) @block
]]

local function node_id(kind, env, src) return require("inkmath.detect").node_id(kind, env, src) end

local MATH = { inline_formula = true, displayed_equation = true, math_environment = true }

--- Excluded: inside a comment/verbatim (SKIP) or nested in another math node (only
--- outermost math counts). One walk up the ancestors: O(depth) per node.
local function excluded(node)
  local p = node:parent()
  while p do
    local t = p:type()
    if SKIP[t] or MATH[t] or t:find("verb", 1, true) then return true end
    p = p:parent()
  end
  return false
end

local query
local function get_query()
  query = query or vim.treesitter.query.parse("latex", QUERY)
  return query
end

--- The grammar does not parse \verb, so check the text before the node on its line.
local function in_verb(line, scol)
  local i = 1
  while true do
    local s, e, delim = line:find("\\verb%*?([^%a%s*])", i)
    if not s or s >= scol + 1 then return false end
    local close = line:find(delim, e + 1, true)
    if not close then return true end -- unterminated: runs to end of line
    if scol + 1 <= close then return true end
    i = close + 1
  end
end

local function env_name(node, bufnr)
  local begin = node:field("begin")[1] or node:child(0)
  local name = begin and begin:field("name")[1]
  if not name then return nil end
  return (vim.treesitter.get_node_text(name, bufnr):gsub("^{", ""):gsub("}$", ""))
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- Rows of ERROR / missing nodes (whole tree; subtrees without errors are skipped).
local function error_rows(root)
  local rows = {}
  local function walk(node)
    if node:type() == "ERROR" or node:missing() then
      local sr, _, er = node:range()
      rows[#rows + 1] = { sr, er }
      return
    end
    for child in node:iter_children() do
      if child:has_error() or child:missing() then walk(child) end
    end
  end
  walk(root)
  return rows
end

--- Merge row ranges, each expanded to its paragraph (up to the surrounding blank lines).
local function paragraph_regions(lines, rows)
  local last = #lines - 1
  local function blank(r) return lines[r + 1]:match("^%s*$") ~= nil end
  local regions = {}
  for _, r in ipairs(rows) do
    local lo, hi = math.min(r[1], last), math.min(r[2], last)
    while lo > 0 and not blank(lo - 1) do
      lo = lo - 1
    end
    while hi < last and not blank(hi + 1) do
      hi = hi + 1
    end
    regions[#regions + 1] = { lo, hi }
  end
  table.sort(regions, function(a, b) return a[1] < b[1] end)
  local merged = {}
  for _, r in ipairs(regions) do
    local m = merged[#merged]
    if m and r[1] <= m[2] + 1 then
      m[2] = math.max(m[2], r[2])
    else
      merged[#merged + 1] = { r[1], r[2] }
    end
  end
  return merged
end

--- The range starts inside a comment or verbatim node of the tree.
local function in_skip(tree, rg)
  local node = tree:root():descendant_for_range(rg.srow, rg.scol, rg.srow, rg.scol)
  while node do
    local t = node:type()
    if SKIP[t] or t:find("verb", 1, true) then return true end
    node = node:parent()
  end
  return false
end

--- Replace the treesitter nodes `out` in the error regions (error rows widened to their
--- paragraph) by the tolerant scanner's; keeps only nodes overlapping rows lo..hi. Errors
--- raise (the caller's pcall keeps the treesitter result).
local function recover(bufnr, tree, out, lo, hi)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local rows = error_rows(tree:root())
  -- inline/display math cannot span a blank line: such a node is a mis-parse (an unclosed `$`
  -- paired with a later one), and the tree reports its error elsewhere
  for _, n in ipairs(out) do
    if n.kind ~= "block" and n.range.erow > n.range.srow then
      for r = n.range.srow + 1, n.range.erow - 1 do
        if lines[r + 1]:match("^%s*$") then
          rows[#rows + 1] = { n.range.srow, n.range.erow }
          break
        end
      end
    end
  end
  local regions = paragraph_regions(lines, rows)
  local kept = {}
  for _, n in ipairs(out) do
    local hit = false
    for _, r in ipairs(regions) do
      if n.range.srow <= r[2] and n.range.erow >= r[1] then
        hit = true
        break
      end
    end
    if not hit and n.range.srow <= hi and n.range.erow >= lo then kept[#kept + 1] = n end
  end
  local recover_mod = require("inkmath.detect.recover")
  for _, r in ipairs(regions) do
    if r[1] <= hi and r[2] >= lo then
      for _, n in ipairs(recover_mod.scan(vim.list_slice(lines, r[1] + 1, r[2] + 1), r[1])) do
        if n.range.srow <= hi and n.range.erow >= lo and not in_skip(tree, n.range) then
          n.id = node_id(n.kind, n.env, n.src)
          kept[#kept + 1] = n
        end
      end
    end
  end
  return kept
end

--- Treesitter math nodes overlapping rows lo..hi (of the whole tree, outermost only).
local function collect(bufnr, tree, lo, hi)
  local q = get_query()
  local out = {}
  for id, node in q:iter_captures(tree:root(), bufnr, lo, hi == math.huge and -1 or hi + 1) do
    local kind = q.captures[id]
    local sr, sc, er, ec = node:range()
    if
      sr <= hi
      and er >= lo
      and not excluded(node)
      and not in_verb(vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or "", sc)
    then
      local text = vim.treesitter.get_node_text(node, bufnr)
      local src, env = text, nil
      if kind == "block" then
        env = env_name(node, bufnr)
      elseif kind == "inline" then
        src = trim(text:gsub("^\\%(", ""):gsub("\\%)$", ""):gsub("^%$", ""):gsub("%$$", ""))
      else
        if text:sub(1, 2) == "$$" then
          src = trim(text:sub(3, -3))
        else
          src = trim(text:gsub("^\\%[", ""):gsub("\\%]$", ""))
        end
      end
      out[#out + 1] = {
        id = node_id(kind, env, src),
        kind = kind,
        src = src,
        env = env,
        range = { srow = sr, scol = sc, erow = er, ecol = ec },
      }
    end
  end
  return out
end

--- Full result of a broken tree per buffer: {tick, nodes, recovered}. A range detect on a
--- broken tree needs the whole tree's error regions, so it is served from here while the
--- changedtick is unchanged (the refresh just computed it). Entries of invalid buffers are
--- dropped on every store; forget() drops one on detach.
local memo = {} ---@type table<integer, {tick: integer, nodes: inkmath.MathNode[], recovered: boolean}>
M._memo = memo

--- Copies of the nodes overlapping lo..hi (callers mutate nodes, e.g. numbering ids).
local function from_memo(m, lo, hi)
  local out = {}
  for _, n in ipairs(m.nodes) do
    if n.range.srow <= hi and n.range.erow >= lo then
      out[#out + 1] = { id = n.id, kind = n.kind, src = n.src, env = n.env, range = vim.deepcopy(n.range) }
    end
  end
  return out
end

--- @param srow? integer first row (inclusive) to look at; default: whole buffer
--- @param erow? integer last row (inclusive)
--- @return inkmath.MathNode[] nodes, boolean has_error, boolean recovered
--- has_error: the tree has syntax errors; recovered: the error regions were re-scanned
function M.detect(bufnr, srow, erow)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "latex", { error = false })
  if not ok or not parser then return {}, false, false end
  local tree = parser:parse()[1]
  if not tree then return {}, false, false end
  local lo, hi = srow or 0, erow or math.huge
  if not tree:root():has_error() then
    memo[bufnr] = nil
    return collect(bufnr, tree, lo, hi), false, false
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local m = memo[bufnr]
  if not (m and m.tick == tick) then
    -- the error region is computed on the whole tree, so a range detect equals the full one
    local all = collect(bufnr, tree, 0, math.huge)
    local rok, res = pcall(recover, bufnr, tree, all, 0, math.huge)
    m = { tick = tick, nodes = rok and res or all, recovered = rok and res ~= nil }
    for b in pairs(memo) do
      if not vim.api.nvim_buf_is_valid(b) then memo[b] = nil end
    end
    memo[bufnr] = m
  end
  return from_memo(m, lo, hi), true, m.recovered
end

--- Drop the buffer's memoized result (detach).
function M.forget(bufnr) memo[bufnr] = nil end

--- Live preview only: the formula being typed at (row, col) on a broken tree, whose closer
--- is not typed yet (see recover.open_at). nil when there is none.
---@return inkmath.MathNode|nil
function M.open_at(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "latex", { error = false })
  local tree = ok and parser and parser:parse()[1]
  if not tree then return nil end
  local function blank(r) return vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1]:match("^%s*$") ~= nil end
  local last = vim.api.nvim_buf_line_count(bufnr) - 1
  if row > last or blank(row) then return nil end
  local lo, hi = row, row
  while lo > 0 and not blank(lo - 1) do
    lo = lo - 1
  end
  while hi < last and not blank(hi + 1) do
    hi = hi + 1
  end
  local para = vim.api.nvim_buf_get_lines(bufnr, lo, hi + 1, false)
  local n = require("inkmath.detect.recover").open_at(para, lo, row, col)
  if not n or in_skip(tree, n.range) then return nil end
  n.id = node_id(n.kind, nil, n.src)
  return n
end

--- Lines before \begin{document} ({} if there is none).
function M.preamble(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:match("^%s*\\begin%s*{document}") then return vim.list_slice(lines, 1, i - 1) end
  end
  return {}
end

return M
