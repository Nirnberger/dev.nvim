--- Pure, tolerant scanner for TeX math regions. Used where the treesitter tree is broken (error regions):
--- finds `$..$`, `$$..$$`, `\(..\)`, `\[..\]` and math environments by plain text scanning.
--- Unmatched openers produce no node. Comments, `\verb` spans and verbatim environments are ignored.
local M = {}

local MATH_ENVS = {}
for _, n in ipairs({
  "equation",
  "align",
  "alignat",
  "flalign",
  "gather",
  "multline",
  "eqnarray",
  "displaymath",
  "math",
}) do
  MATH_ENVS[n] = true
end

local VERBATIM_ENVS = { verbatim = true, Verbatim = true, lstlisting = true, minted = true }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function mask(line, a, b) return line:sub(1, a - 1) .. string.rep(" ", b - a + 1) .. line:sub(b + 1) end

--- Replace comments, \verb spans and verbatim environments by spaces (columns stay valid).
local function mask_all(lines)
  local out = {}
  for k, line in ipairs(lines) do
    local i = 1
    while i <= #line do
      local ch = line:sub(i, i)
      if ch == "\\" then
        local s, e, delim = line:find("^\\verb%*?([^%a%s*])", i)
        if s then
          local stop = line:find(delim, e + 1, true) or #line
          line = mask(line, i, stop)
          i = stop + 1
        else
          i = i + 2
        end
      elseif ch == "%" then
        line = mask(line, i, #line)
        break
      else
        i = i + 1
      end
    end
    out[k] = line
  end
  local open
  for k, line in ipairs(out) do
    local from = 1
    if not open then
      local s, e, name = line:find("\\begin{([%a]+)%*?}")
      if s and VERBATIM_ENVS[name] then
        open = name
        from = s
      end
    end
    if open then
      local s, e = line:find("\\end{" .. open .. "%*?}", from)
      if s then
        out[k] = mask(line, from, e)
        open = nil
      else
        out[k] = mask(line, from, #line)
      end
    end
  end
  return out
end

--- @param lines string[] lines[1] is buffer row `first_row`
--- @param first_row integer
--- @return {kind: string, src: string, env: string|nil, range: {srow: integer, scol: integer, erow: integer, ecol: integer}}[]
function M.scan(lines, first_row)
  local n = #lines
  local m = mask_all(lines)
  local blank = {}
  for k, l in ipairs(lines) do
    blank[k] = l:match("^%s*$") ~= nil
  end
  local out = {}

  -- pend[r]: last row of the paragraph containing row r (one backward pass)
  local pend = {}
  for r = n, 1, -1 do
    pend[r] = (r < n and not blank[r + 1] and not blank[r]) and pend[r + 1] or r
  end
  -- openers that already failed to find a closer: no later one of the same kind can succeed
  local failed = {}
  local noend = {}

  --- Original text from (r1,c1) to (r2,c2), both inclusive, 1-based columns.
  local function slice(r1, c1, r2, c2)
    if r1 == r2 then return lines[r1]:sub(c1, c2) end
    local parts = { lines[r1]:sub(c1) }
    for r = r1 + 1, r2 - 1 do
      parts[#parts + 1] = lines[r]
    end
    parts[#parts + 1] = lines[r2]:sub(1, c2)
    return table.concat(parts, "\n")
  end

  --- First closer of `kind` at/after (r,c), not beyond row `last`. Returns row, start col, end col (inclusive).
  local function find_close(r, c, last, kind)
    for rr = r, last do
      local line = m[rr]
      local i = rr == r and c or 1
      while i <= #line do
        local ch = line:sub(i, i)
        if ch == "\\" then
          local nx = line:sub(i + 1, i + 1)
          if (kind == "paren" and nx == ")") or (kind == "brack" and nx == "]") then return rr, i, i + 1 end
          i = i + 2
        elseif kind == "dollar" and ch == "$" then
          return rr, i, i
        elseif kind == "dd" and line:sub(i, i + 1) == "$$" then
          return rr, i, i + 1
        else
          i = i + 1
        end
      end
    end
  end

  local function find_env_end(r, c, name)
    local pn = vim.pesc(name)
    local b, e = "\\begin%s*{" .. pn .. "}", "\\end%s*{" .. pn .. "}"
    local depth = 1
    local saw_end = false
    for rr = r, n do
      local line = m[rr]
      local i = rr == r and c or 1
      while true do
        local bs, be = line:find(b, i)
        local es, ee = line:find(e, i)
        if not bs and not es then break end
        if es then saw_end = true end
        if bs and (not es or bs < es) then
          depth = depth + 1
          i = be + 1
        else
          depth = depth - 1
          if depth == 0 then return rr, ee end
          i = ee + 1
        end
      end
    end
    return nil, nil, saw_end
  end

  local function emit(kind, r1, c1, r2, c2, src, env)
    out[#out + 1] = {
      kind = kind,
      src = src,
      env = env,
      range = { srow = first_row + r1 - 1, scol = c1 - 1, erow = first_row + r2 - 1, ecol = c2 },
    }
  end

  local r, c = 1, 1
  while r <= n do
    local line = m[r]
    if blank[r] or c > #line then
      r, c = r + 1, 1
    else
      local ch = line:sub(c, c)
      if ch == "\\" then
        local nx = line:sub(c + 1, c + 1)
        local name, after = line:match("^\\begin%s*{([^}]+)}()", c)
        if name then
          local base = name:gsub("%*$", "")
          local er, ec
          -- only "no \end{name} anywhere after this point" is memoized (depth failures are not)
          local ne = noend[name]
          if MATH_ENVS[base] and not (ne and (r > ne[1] or (r == ne[1] and c >= ne[2]))) then
            local saw
            er, ec, saw = find_env_end(r, after, name)
            if not er and not saw then noend[name] = { r, c } end
          end
          if er then
            emit("block", r, c, er, ec, slice(r, c, er, ec), name)
            r, c = er, ec + 1
          else
            c = after
          end
        elseif nx == "(" or nx == "[" then
          local kind = nx == "(" and "paren" or "brack"
          local fk = kind .. pend[r]
          local er, cs, ce
          if not failed[fk] then
            er, cs, ce = find_close(r, c + 2, pend[r], kind)
            if not er then failed[fk] = true end
          end
          if er then
            emit(nx == "(" and "inline" or "display", r, c, er, ce, trim(slice(r, c + 2, er, cs - 1)))
            r, c = er, ce + 1
          else
            c = c + 2
          end
        else
          c = c + 2
        end
      elseif ch == "$" then
        local double = line:sub(c + 1, c + 1) == "$"
        local kind = double and "dd" or "dollar"
        local fk = kind .. pend[r]
        local er, cs, ce
        if not failed[fk] then
          er, cs, ce = find_close(r, c + (double and 2 or 1), pend[r], kind)
          if not er then failed[fk] = true end
        end
        if er then
          local open = double and 2 or 1
          emit(double and "display" or "inline", r, c, er, ce, trim(slice(r, c + open, er, cs - 1)))
          r, c = er, ce + 1
        else
          c = c + (double and 2 or 1)
        end
      else
        c = c + 1
      end
    end
  end
  return out
end

return M
