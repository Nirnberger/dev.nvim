--- Picks the terminal graphics backend (see docs/superpowers/specs/2026-11-08-terminal-backends-design.md).
---@class inkmath.Backend
---@field name "kitty"|"iterm2"|"sixel"
---@field mode "placeholder"|"overlay" placeholder: the image is text cells (kitty); overlay: painted at screen cells
---@field send fun(seq: string)
---@field probe fun(env: table): boolean
---@field delete fun(id: integer): string
---@field paint? fun(img: {path: string, cols: integer, rows: integer, id: integer}, row: integer, col: integer): string[]

local M = {}

local UNSET = {} -- memo sentinel: nothing cached yet
local memo = UNSET ---@type inkmath.Backend|nil|table
local memo_why ---@type string|nil

--- Candidate backends in `auto` order, by name. Later tasks add iTerm2, Sixel and kitty's overlay mode.
---@return table<string, inkmath.Backend>
local function registry() return { kitty = require("inkmath.term.kitty") } end

local AUTO_ORDER = { "kitty" }

---@param env? table environment to inspect (default: vim.env)
---@return inkmath.Backend|nil backend
---@return string|nil reason why there is none
function M.detect(env)
  env = env or vim.env
  local choice = require("inkmath.config").get().term.backend
  if choice == "none" then return nil, "disabled by term.backend" end
  local all = registry()
  if choice ~= "auto" then return all[choice] end
  for _, name in ipairs(AUTO_ORDER) do
    if all[name].probe(env) then return all[name] end
  end
  return nil, "no supported terminal"
end

---@return inkmath.Backend|nil
function M.get()
  if memo == UNSET then
    memo, memo_why = M.detect()
  end
  return memo
end

--- The backend to write to: callers run only after env.check() accepted the terminal, so
--- kitty (the pre-backend behaviour) stands in when detection has nothing.
---@return inkmath.Backend
function M.current() return M.get() or require("inkmath.term.kitty") end

---@return string|nil reason the last get() found no backend
function M.why()
  M.get()
  return memo_why
end

--- Detect again on the next get() (option change, FocusGained, :InkMath refresh).
function M.reset()
  memo, memo_why = UNSET, nil
end

return M
