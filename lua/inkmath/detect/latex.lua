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

--- Replace treesitter nodes in the error regions by the tolerant scanner's. Returns the new
--- list, or nil on failure (the caller keeps the old behaviour).
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
    if not hit then kept[#kept + 1] = n end
  end
  local recover_mod = require("inkmath.detect.recover")
  for _, r in ipairs(regions) do
    if r[1] <= hi and r[2] >= lo then
      for _, n in ipairs(recover_mod.scan(vim.list_slice(lines, r[1] + 1, r[2] + 1), r[1])) do
        if n.range.srow <= hi and n.range.erow >= lo then
          n.id = node_id(n.kind, n.env, n.src)
          kept[#kept + 1] = n
        end
      end
    end
  end
  return kept
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
  local q = get_query()
  local lo, hi = srow or 0, erow or math.huge
  local out = {}
  for id, node in q:iter_captures(tree:root(), bufnr, srow or 0, erow and erow + 1 or -1) do
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
  if not tree:root():has_error() then return out, false, false end
  local rok, res = pcall(recover, bufnr, tree, out, lo, hi)
  if rok and res then return res, true, true end
  return out, true, false
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
