-- Real equation numbers: `\newlabel{key}{{3.2}{7}...}` entries of the project's .aux
-- file, injected into labeled numbered environments as `\tag{3.2}` before the
-- `\label{key}`. The tag is part of node.src, so it is part of the cache key.
local fcache = require("inkmath.fcache")

local M = {}

-- amsmath environments that number their rows (unstarred only)
local NUMBERED = { equation = true, align = true, gather = true, multline = true, flalign = true, alignat = true }

--- brace group starting at s[pos] == "{": content, position after the closing brace
local function group(s, pos)
  if s:sub(pos, pos) ~= "{" then return nil end
  local depth = 0
  for i = pos, #s do
    local c = s:sub(i, i)
    if c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then return s:sub(pos + 1, i - 1), i + 1 end
    end
  end
end

--- only plain numbers such as 3, 3.2, A.1, 2-4 are injected into TeX
local function plain(num) return num ~= "" and num:match("^[%w%.%-]+$") ~= nil end

---@param lines string[]
---@return table<string, string> labels, string[] inputs  files named by \@input{...}
function M.parse(lines)
  local out, inputs = {}, {}
  for _, l in ipairs(lines) do
    local key, rest = l:match("^%s*\\newlabel{([^}]*)}()")
    if key and not key:find("@cref", 1, true) then
      -- {{num}{page}...}: the first inner group only (whitespace tolerated)
      local outer = group(l, l:find("%S", rest) or rest)
      local num = outer and group(outer, outer:find("%S") or 1)
      if num and plain(num) then out[key] = num end
    end
    local inp = l:match("^%s*\\@input{([^}]+)}")
    if inp then inputs[#inputs + 1] = inp end
  end
  return out, inputs
end

local function parsed(path)
  return fcache.derive(path, "labels", function(lines)
    local labels, inputs = M.parse(lines)
    return { labels = labels, inputs = inputs }
  end)
end

local merged = {} ---@type table<string, {key: string, labels: table<string, string>}>

--- Labels of the aux file plus those of the aux files it \@input's (one level deep,
--- relative to its directory: \include'd chapters write their own .aux). nil when the
--- file does not exist. Cached by the stamps of all those files; read-only result.
---@param path string|nil
---@return table<string, string>|nil
function M.read(path)
  if not path then return nil end
  local p = parsed(path)
  if not p then
    merged[path] = nil
    return nil
  end
  local dir = vim.fs.dirname(path)
  local files = { path }
  for _, inp in ipairs(p.inputs) do
    files[#files + 1] = inp:sub(1, 1) == "/" and inp or (dir .. "/" .. inp)
  end
  local stamps = {}
  for i, f in ipairs(files) do stamps[i] = fcache.stamp(f) or "-" end
  local key = table.concat(stamps, "|")
  local m = merged[path]
  if m and m.key == key then return m.labels end
  local out = {}
  for i = #files, 1, -1 do -- the main file wins on duplicate keys
    local sub = i == 1 and p or parsed(files[i])
    if sub then
      for k, v in pairs(sub.labels) do out[k] = v end
    end
  end
  merged[path] = { key = key, labels = out }
  return out
end

--- Rows of the outermost environment: {start, stop} character ranges at nesting
--- depth 1, split only on depth-1 `\\` (a `\\` inside split/aligned/cases/pmatrix
--- belongs to the nested environment). `start` is where a `\tag` may go: right
--- after `\begin{env}` (and alignat's `{n}`) or after the row's `\\`. With
--- `one_row` the whole body is one row (equation, multline).
---@param src string
---@param one_row boolean
---@return {[1]: integer, [2]: integer}[]
function M.rows(src, one_row)
  local rows, depth, i, n, start = {}, 0, 1, #src, nil
  while i <= n do
    local c = src:sub(i, i)
    if c == "%" then
      i = (src:find("\n", i, true) or n) + 1
    elseif c ~= "\\" then
      i = i + 1
    elseif src:sub(i + 1, i + 1) == "\\" then
      if depth == 1 and not one_row then
        rows[#rows + 1] = { start, i - 1 }
        start = i + 2
      end
      i = i + 2
    else
      local word = src:match("^%a+", i + 1)
      local name, after
      if word == "begin" or word == "end" then name, after = src:match("^%s*{([^}]*)}()", i + 1 + #word) end
      if name and word == "begin" then
        depth = depth + 1
        if depth == 1 then
          start = src:match("^%s*{%d+}()", after) or after -- alignat{n}
          after = start
        end
        i = after
      elseif name then
        if depth == 1 then rows[#rows + 1] = { start, i - 1 } end
        depth = depth - 1
        i = after
      else
        i = i + 1 + (word and #word or 1) -- other command or escaped char (\{, \%)
      end
    end
  end
  return rows
end

local function has_tag(text)
  return text:find("\\tag", 1, true) or text:find("\\notag", 1, true) or text:find("\\nonumber", 1, true)
end

--- Inject `\tag{n}` into labeled rows of numbered block environments (in place). The
--- tag goes at depth 1 at the start of the row (for equation/multline right after
--- `\begin{env}`), never inside a nested split/aligned/cases, where amsmath and
--- MathJax reject it. Rows with their own \tag/\notag/\nonumber are left alone.
---@param nodes inkmath.MathNode[]
---@param labels table<string, string>|nil
function M.apply(nodes, labels)
  if not labels or next(labels) == nil then return end
  for _, n in ipairs(nodes) do
    if n.kind == "block" and n.env and NUMBERED[n.env] and n.src:find("\\label", 1, true) then
      local one = n.env == "equation" or n.env == "multline"
      local ins = {}
      for _, r in ipairs(M.rows(n.src, one)) do
        local text = n.src:sub(r[1], r[2])
        if not has_tag(text) then
          for key in text:gmatch("\\label%s*{([^}]*)}") do
            if labels[key] then
              ins[#ins + 1] = { r[1], "\\tag{" .. labels[key] .. "}" }
              break
            end
          end
        end
      end
      for k = #ins, 1, -1 do
        local pos, t = ins[k][1], ins[k][2]
        n.src = n.src:sub(1, pos - 1) .. t .. n.src:sub(pos)
      end
    end
  end
end

--- strip a `%` comment (an unescaped `%` and the rest of the line)
local function uncomment(l)
  local i = 1
  while true do
    local p = l:find("%", i, true)
    if not p then return l end
    local bs = 0
    while p - bs > 1 and l:sub(p - bs - 1, p - bs - 1) == "\\" do bs = bs + 1 end
    if bs % 2 == 0 then return l:sub(1, p - 1) end
    i = p + 1
  end
end

--- numbered rows of an environment's source: rows without \tag, \notag or \nonumber
local function numbered_rows(src, env)
  local n = 0
  for _, r in ipairs(M.rows(src, env == "equation" or env == "multline")) do
    if not has_tag(src:sub(r[1], r[2])) then n = n + 1 end
  end
  return n
end

--- Equation numbers in document order, as LaTeX counts them without an .aux file:
--- {[row of \begin{env}] = number of its first numbered row} for the unstarred
--- numbered environments (one counter; \numberwithin and \setcounter are ignored).
---@param lines string[]
---@return table<integer, integer>
function M.numbering(lines)
  local starts, count = {}, 0
  local i = 1
  while i <= #lines do
    local l = uncomment(lines[i])
    local env, after = l:match("\\begin%s*{(%a+)}()")
    if env and NUMBERED[env] then
      -- collect to the matching \end{env} (same-name nesting counted)
      local body, depth, j, rest = {}, 0, i, l:sub(after)
      body[1] = l
      local function scan(text)
        for word, name in text:gmatch("\\(%a+)%s*{(%a+%*?)}") do
          if name == env then
            if word == "begin" then depth = depth + 1 elseif word == "end" then depth = depth - 1 end
          end
        end
      end
      depth = 1
      scan(rest)
      while depth > 0 and j < #lines do
        j = j + 1
        local lj = uncomment(lines[j])
        body[#body + 1] = lj
        scan(lj)
      end
      local src = table.concat(body, "\n")
      local b = src:find("\\begin%s*{" .. env .. "}")
      starts[i - 1] = count + 1
      count = count + numbered_rows(src:sub(b), env)
      i = j + 1
    else
      i = i + 1
    end
  end
  return starts
end

local numbering_cache = {} ---@type table<integer, {tick: integer, starts: table<integer, integer>}>

--- Inject `\tag{n}` (document-order numbers, see numbering) into every numbered row
--- of the numbered environments among `nodes` (in place).
---@param buf integer
---@param nodes inkmath.MathNode[]
function M.number(buf, nodes)
  local tick = vim.b[buf].changedtick
  local c = numbering_cache[buf]
  if not c or c.tick ~= tick then
    c = { tick = tick, starts = M.numbering(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) }
    numbering_cache[buf] = c
  end
  for _, n in ipairs(nodes) do
    local k = n.kind == "block" and n.env and NUMBERED[n.env] and c.starts[n.range.srow]
    if k then
      local ins = {}
      for _, r in ipairs(M.rows(n.src, n.env == "equation" or n.env == "multline")) do
        if not has_tag(n.src:sub(r[1], r[2])) then
          ins[#ins + 1] = { r[1], "\\tag{" .. k .. "}" }
          k = k + 1
        end
      end
      for x = #ins, 1, -1 do
        local pos, t = ins[x][1], ins[x][2]
        n.src = n.src:sub(1, pos - 1) .. t .. n.src:sub(pos)
      end
    end
  end
end

--- (detach) forget a buffer's numbering
function M.forget(buf) numbering_cache[buf] = nil end

return M
