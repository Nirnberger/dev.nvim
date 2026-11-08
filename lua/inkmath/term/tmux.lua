local M = {}

function M.in_tmux()
  return (vim.env.TMUX or "") ~= ""
end

---Wrap an escape sequence in tmux's DCS passthrough (inner ESCs doubled).
---@param seq string
---@return string
function M.wrap(seq)
  return "\27Ptmux;" .. seq:gsub("\27", "\27\27") .. "\27\\"
end

--- Value of allow-passthrough at one scope: "g" global, "w" window, "p" pane.
---@param scope "g"|"w"|"p"
---@return string|nil
function M._show(scope)
  local cmd = { "tmux", "show", "-" .. scope .. "v" }
  local pane = vim.env.TMUX_PANE
  if scope ~= "g" and pane and pane ~= "" then vim.list_extend(cmd, { "-t", pane }) end
  cmd[#cmd + 1] = "allow-passthrough"
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then return nil end
  return vim.trim(out)
end

local passthrough ---@type boolean|nil memoized: attach asks for every buffer

--- allow-passthrough may be set globally or window/pane-locally; any `on`/`all` counts.
--- Asked once per session; forget() asks again.
---@return boolean
function M.passthrough_enabled()
  if passthrough ~= nil then return passthrough end
  passthrough = false
  if vim.fn.executable("tmux") ~= 1 then return false end
  for _, scope in ipairs({ "p", "w", "g" }) do
    local v = M._show(scope)
    if v == "on" or v == "all" then
      passthrough = true
      break
    end
  end
  return passthrough
end

--- Ask tmux again (FocusGained, :InkMath refresh: the user may have fixed tmux.conf).
function M.forget() passthrough = nil end

return M
