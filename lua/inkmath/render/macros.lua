local M = {}

--- Strip unescaped % comments (to end of line).
local function strip_comments(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local i = 1
    while true do
      local p = line:find("%", i, true)
      if not p then break end
      local bs = 0
      while p - bs - 1 >= 1 and line:sub(p - bs - 1, p - bs - 1) == "\\" do bs = bs + 1 end
      if bs % 2 == 0 then line = line:sub(1, p - 1) break end
      i = p + 1
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

--- Read a brace-balanced group starting at text[pos] == "{". Returns content, next pos.
local function group(text, pos)
  if text:sub(pos, pos) ~= "{" then return nil end
  local depth, i = 0, pos
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then return text:sub(pos + 1, i - 1), i + 1 end
    end
    i = i + 1
  end
  return nil
end

local function skip_ws(text, pos)
  return text:find("%S", pos) or #text + 1
end

--- Read a control sequence name at pos (either `\name` or `{\name}`). Returns name, next pos.
local function csname(text, pos)
  pos = skip_ws(text, pos)
  local braced = false
  if text:sub(pos, pos) == "{" then
    braced = true
    pos = skip_ws(text, pos + 1)
  end
  local name = text:match("^\\(%a+)", pos) or text:match("^\\(.)", pos)
  if not name then return nil end
  pos = pos + 1 + #name
  if braced then
    pos = skip_ws(text, pos)
    if text:sub(pos, pos) ~= "}" then return nil end
    pos = pos + 1
  end
  return name, pos
end

--- @param lines string[]
--- @return table<string, string|table>
function M.from_tex_preamble(lines)
  local text = strip_comments(table.concat(lines, "\n"))
  local out = {}
  local pos = 1
  while true do
    local s, e, cmd = text:find("\\(%a+)", pos)
    if not s then break end
    pos = e + 1
    if cmd == "newcommand" or cmd == "renewcommand" or cmd == "providecommand" then
      local p = skip_ws(text, pos)
      if text:sub(p, p) == "*" then p = p + 1 end
      local name, np = csname(text, p)
      if name then
        np = skip_ws(text, np)
        local nargs = text:match("^%[(%d)%]", np)
        if nargs then np = np + 3 end
        np = skip_ws(text, np)
        if text:sub(np, np) == "[" then -- optional default arg: unsupported by MathJax macros, skip it
          local close = text:find("]", np, true)
          np = close and close + 1 or np
        end
        local body, after = group(text, skip_ws(text, np))
        if body then
          out[name] = nargs and { body, tonumber(nargs) } or body
          pos = after
        end
      end
    elseif cmd == "DeclareMathOperator" then
      local p = pos
      local star = ""
      if text:sub(p, p) == "*" then star, p = "*", p + 1 end
      local name, np = csname(text, p)
      if name then
        local body, after = group(text, skip_ws(text, np))
        if body then
          out[name] = "\\operatorname" .. star .. "{" .. body .. "}"
          pos = after
        end
      end
    elseif cmd == "def" then
      local name, np = csname(text, pos)
      if name and text:sub(pos, pos) ~= "{" then
        np = skip_ws(text, np)
        local nargs = 0
        while true do -- parameter text such as #1#2
          local n = text:match("^#(%d)", np)
          if not n then break end
          nargs = tonumber(n)
          np = np + 2
        end
        local body, after = group(text, np)
        if body then
          out[name] = nargs > 0 and { body, nargs } or body
          pos = after
        end
      end
    elseif cmd == "let" then
      local name, np = csname(text, pos)
      if name then
        np = skip_ws(text, np)
        if text:sub(np, np) == "=" then np = skip_ws(text, np + 1) end
        local target = text:match("^\\%a+", np)
        if target then
          out[name] = target
          pos = np + #target
        end
      end
    end
  end
  return out
end

return M
