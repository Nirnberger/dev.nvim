local tmux = require("inkmath.term.tmux")

local M = {}

local ESC = "\27"
local ST = "\27\\"
local CHUNK = 4096
local via_tmux ---@type boolean|nil memoized tmux client_termtype check

---Write a raw terminal sequence (tmux-wrapped when needed).
---@param seq string
function M.send(seq)
  if tmux.in_tmux() then seq = tmux.wrap(seq) end
  if vim.api.nvim_ui_send ~= nil then
    vim.api.nvim_ui_send(seq)
  else
    io.stdout:write(seq)
    io.stdout:flush()
  end
end

---@return boolean
function M.is_local() return (vim.env.SSH_CONNECTION or "") == "" end

---@param id integer
---@param path string
---@param cols integer
---@param rows integer
---@param is_local boolean
---@param placeholder? boolean default true: transmit + virtual placement for Unicode placeholders (`a=T,U=1`); false: transmit only (`a=t`, overlay mode)
---@return string[]
function M.transmit_seq(id, path, cols, rows, is_local, placeholder)
  local dims = string.format("i=%d,c=%d,r=%d", id, cols, rows)
  local act = placeholder == false and "a=t" or "a=T,U=1"
  if is_local then
    return { ESC .. "_G" .. act .. ",f=100,t=f,q=2," .. dims .. ";" .. vim.base64.encode(path) .. ST }
  end
  local f = io.open(path, "rb")
  if not f then return {} end
  local bytes = f:read("*a")
  f:close()
  if not bytes or #bytes == 0 then return {} end
  local b64 = vim.base64.encode(bytes)
  local seqs = {}
  local n = math.max(1, math.ceil(#b64 / CHUNK))
  for i = 1, n do
    local data = b64:sub((i - 1) * CHUNK + 1, i * CHUNK)
    local more = i < n and 1 or 0
    if i == 1 then
      seqs[i] = ESC .. "_G" .. act .. ",f=100,t=d,q=2," .. dims .. ",m=" .. more .. ";" .. data .. ST
    else
      seqs[i] = ESC .. "_Gm=" .. more .. ";" .. data .. ST
    end
  end
  return seqs
end

---@param id integer
---@return string
function M.delete_seq(id) return string.format("%s_Ga=d,d=I,i=%d,q=2%s", ESC, id, ST) end

-- Backend interface (term/backend.lua): kitty/Ghostty draw Unicode placeholders.
M.name = "kitty"
M.mode = "placeholder"
M.delete = function(id) return M.delete_seq(id) end

---@param env? table
---@return boolean
function M.probe(env)
  if env ~= nil and env ~= vim.env then
    return env.TERM_PROGRAM == "ghostty"
      or env.TERM_PROGRAM == "kitty"
      or env.TERM == "xterm-kitty"
      or env.TERM == "xterm-ghostty"
      or (env.KITTY_WINDOW_ID or "") ~= ""
      or (env.GHOSTTY_RESOURCES_DIR or "") ~= ""
  end
  return M.supported()
end

---@return boolean
function M.supported()
  local env = vim.env
  if env.TERM_PROGRAM == "ghostty" or env.TERM_PROGRAM == "kitty" then return true end
  if env.TERM == "xterm-kitty" or env.TERM == "xterm-ghostty" then return true end
  if (env.KITTY_WINDOW_ID or "") ~= "" or (env.GHOSTTY_RESOURCES_DIR or "") ~= "" then return true end
  if tmux.in_tmux() and vim.fn.executable("tmux") == 1 then
    -- client_termtype is the outer terminal's XTVERSION reply (e.g. "ghostty 1.4.0"); it
    -- identifies Ghostty/kitty even when TERM is a generic value like xterm-256color.
    -- Asked once per session (attach runs this for every buffer): forget() asks again.
    if via_tmux == nil then
      local out = vim.fn.system({ "tmux", "display", "-p", "#{client_termname} #{client_termtype}" })
      out = out:lower()
      via_tmux = vim.v.shell_error == 0 and (out:find("ghostty") or out:find("kitty")) ~= nil
    end
    return via_tmux
  end
  return false
end

--- Ask the terminal checks' shell-outs again (FocusGained, :InkMath refresh).
function M.forget() via_tmux = nil end

return M
