-- Small synchronous file reads, cached by (mtime, size): re-read only when the file
-- changed on disk. Used for the vimtex root preamble, its \input files and .aux files.
local M = {}

M._reads = 0 -- number of actual disk reads (tests)

---@type table<string, {stamp: string, lines: string[], derived: table<string, any>}>
local entries = {}

--- "sec.nsec:size" of the file, or nil when it is not a readable regular file.
---@param path string
---@return string|nil
function M.stamp(path)
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" then return nil end
  return ("%d.%d:%d"):format(st.mtime.sec, st.mtime.nsec or 0, st.size)
end

local function entry(path)
  local stamp = M.stamp(path)
  if not stamp then
    entries[path] = nil
    return nil
  end
  local e = entries[path]
  if e and e.stamp == stamp then return e end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  M._reads = M._reads + 1
  e = { stamp = stamp, lines = lines, derived = {} }
  entries[path] = e
  return e
end

--- Lines of the file (nil if unreadable). Do not modify the returned table.
---@param path string
---@return string[]|nil
function M.lines(path)
  local e = entry(path)
  return e and e.lines
end

--- fn(lines) computed once per file version and cached under `tag`.
---@generic T
---@param path string
---@param tag string
---@param fn fun(lines: string[]): T
---@return T|nil
function M.derive(path, tag, fn)
  local e = entry(path)
  if not e then return nil end
  if e.derived[tag] == nil then e.derived[tag] = fn(e.lines) end
  return e.derived[tag]
end

function M.clear() entries = {} end

return M
