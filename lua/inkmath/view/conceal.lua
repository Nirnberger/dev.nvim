-- Window conceal options of attached buffers, and whether their images are hidden
-- because a window shows the source ('conceallevel' 0). core registers the buffers
-- (apply/forget_buf) and refreshes on on_hidden_change.
--
-- `conceal = false`: no window option is ever written; a window's own 'conceallevel'
-- 0 hides the images while it lasts. With the table form, a 'conceallevel' 0 the
-- user set sticks (apply() keeps it when the buffer is shown again), but only when
-- _user_initiated() says the user set it: synchronously with typed input (a `:`
-- command or a mapping), never from a vim.schedule/timer callback (render-markdown
-- writes its win_options from vim.schedule), and never in a buffer render-markdown or
-- markview manage (they write 'conceallevel' from commands too; :InkMath toggle there).
local config = require("inkmath.config")
local log = require("inkmath.log")

local M = {}

local saved = {} ---@type table<integer, table<integer, {cl: integer, cc: string}>> buf -> win -> values before apply
local user_cl0 = {} ---@type table<integer, table<integer, true>> buf -> wins the user set 'conceallevel' 0 in
local managed = {} ---@type table<integer, true> buffers apply() ran for (until forget_buf)
local last = {} ---@type table<integer, boolean> buf -> last hidden() result
local listeners = {} ---@type (fun(buf: integer))[]
local setting = false -- we are writing the options ourselves (OptionSet ignores it)
local focused = vim.api.nvim_get_current_win() -- window the user is in (WinEnter, FocusGained)
-- a key was typed and has not finished being handled: set by vim.on_key, cleared by a
-- vim.schedule queued with the key, so it runs before any callback the key queued
local typed = false
-- other UI plugins set window options from these events (nested handlers fire OptionSet)
local PLUGIN_EVENTS = { "ModeChanged", "BufWinEnter", "WinEnter", "FileType" }

local function is_float(w) return vim.api.nvim_win_get_config(w).relative ~= "" end

local function write(w, cl, cc)
  local o = { scope = "local", win = w }
  setting = true
  pcall(vim.api.nvim_set_option_value, "conceallevel", cl, o)
  pcall(vim.api.nvim_set_option_value, "concealcursor", cc, o)
  setting = false
end

--- Window-local values for this buffer only (like :setlocal), so other buffers later
--- shown in the window keep their own; previous values are saved for restore().
---@param buf integer
function M.apply(buf)
  managed[buf] = true
  local c = config.get(buf).conceal
  if not c then return M.restore(buf) end -- conceal = false: never touch window options (undo earlier writes)
  saved[buf] = saved[buf] or {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if not is_float(w) then -- floats keep their own options
      local o = { scope = "local", win = w }
      saved[buf][w] = saved[buf][w] or {
        cl = vim.api.nvim_get_option_value("conceallevel", o),
        cc = vim.api.nvim_get_option_value("concealcursor", o),
      }
      -- a user's conceallevel 0 (toggle keymap) sticks when the buffer is shown again
      write(w, (user_cl0[buf] and user_cl0[buf][w]) and 0 or c.level, c.cursor)
    end
  end
end

--- Put back the values apply() replaced, in windows still showing the buffer.
---@param buf integer
function M.restore(buf)
  for w, v in pairs(saved[buf] or {}) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then write(w, v.cl, v.cc) end
  end
  saved[buf] = nil
end

---@param win integer
function M.forget_win(win)
  for _, t in pairs(user_cl0) do t[win] = nil end
end

---@param buf integer
function M.forget_buf(buf)
  saved[buf], user_cl0[buf], managed[buf], last[buf] = nil, nil, nil, nil
end

--- Some non-floating window showing the buffer has 'conceallevel' 0 (while the
--- configured level is not 0 itself): the source is meant to be read there, so no
--- images. Recomputed on every call; is_hidden() returns the last result.
---@param buf integer
---@return boolean
function M.hidden(buf)
  local res = false
  local c = config.get(buf).conceal
  if c == false or c.level ~= 0 then
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do
      if not is_float(w) and vim.wo[w].conceallevel == 0 then
        res = true
        break
      end
    end
  end
  last[buf] = res
  return res
end

---@param buf integer
---@return boolean
function M.is_hidden(buf) return last[buf] == true end

--- fn(buf) runs when a 'conceallevel' change flips hidden() of a managed buffer.
---@param fn fun(buf: integer)
function M.on_hidden_change(fn) listeners[#listeners + 1] = fn end

--- (tests) the user's 'conceallevel' 0 is remembered for this window
function M._sticky(buf, win) return (user_cl0[buf] and user_cl0[buf][win]) == true end

--- Did the user (not a plugin) set the 'conceallevel' this OptionSet reports? All of:
--- the table form is configured; `:set`/`:setlocal` (not :setglobal, not a modeline);
--- run while a typed key is being handled (a `:` command, a mapping), not from a
--- scheduled or timer callback; no other plugin that owns 'conceallevel'
--- (render-markdown, markview: interop.managers) is attached to the buffer; the
--- window is the one the user is in (a plugin writing another window's option switches
--- curwin for the write); not inside a nested handler of an event UI plugins write
--- window options from. ev fields default to the current OptionSet.
---@param ev? {buf?: integer, win?: integer, command?: string, stack?: string, typed?: boolean, managers?: string[]}
---@return boolean
function M._user_initiated(ev)
  ev = ev or {}
  local buf = ev.buf or vim.api.nvim_get_current_buf()
  local cmd = ev.command or vim.v.option_command
  if setting or config.get(buf).conceal == false or (cmd ~= "setlocal" and cmd ~= "set") then return false end
  if ev.typed == nil and not typed or ev.typed == false then return false end
  if #(ev.managers or require("inkmath.interop").managers(buf)) > 0 then return false end
  if (ev.win or vim.api.nvim_get_current_win()) ~= focused then return false end
  local stack = ev.stack or vim.fn.expand("<stack>")
  for _, e in ipairs(PLUGIN_EVENTS) do
    if stack:find(e .. " Autocommands", 1, true) then return false end
  end
  return true
end

--- Re-evaluate hidden() and notify the listeners when it flipped (a write that fired no
--- OptionSet: a non-nested FileType handler or ftplugin).
---@param buf integer
function M.recheck(buf)
  if managed[buf] and (last[buf] == true) ~= M.hidden(buf) then
    for _, fn in ipairs(listeners) do fn(buf) end
  end
end

local function on_optionset()
  local b, w = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if vim.v.option_command ~= "setglobal" then
    if tonumber(vim.v.option_new) == 0 then
      if managed[b] and M._user_initiated() then
        user_cl0[b] = user_cl0[b] or {}
        user_cl0[b][w] = true
      end
    else
      M.forget_win(w) -- conceal back on in this window: drop the override for every buffer
    end
  end
  -- any managed buffer may be shown in the window whose value changed
  for mb in pairs(managed) do M.recheck(mb) end
end

local group = vim.api.nvim_create_augroup("inkmath_conceal", { clear = true })
vim.on_key(function()
  if typed then return end
  typed = true
  vim.schedule(function() typed = false end)
end, vim.api.nvim_create_namespace("inkmath_conceal_keys"))
vim.api.nvim_create_autocmd({ "WinEnter", "FocusGained" }, {
  group = group,
  callback = function() focused = vim.api.nvim_get_current_win() end,
})
-- 'conceallevel' 0 hides the images (e.g. a conceal toggle keymap), > 0 shows them
vim.api.nvim_create_autocmd("OptionSet", {
  group = group,
  pattern = "conceallevel",
  callback = function()
    if not setting and next(managed) then log.guard("conceallevel", on_optionset) end
  end,
})

return M
