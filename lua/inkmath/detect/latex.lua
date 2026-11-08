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

--- @param srow? integer first row (inclusive) to look at; default: whole buffer
--- @param erow? integer last row (inclusive)
--- @return inkmath.MathNode[] nodes, boolean has_error
function M.detect(bufnr, srow, erow)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "latex", { error = false })
  if not ok or not parser then return {}, false end
  local tree = parser:parse()[1]
  if not tree then return {}, false end
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
  return out, tree:root():has_error()
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
