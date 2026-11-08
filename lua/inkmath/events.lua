-- `User InkMath<name>` autocmds for other plugins and user config.
local M = {}

---@param name "Attach"|"Detach"|"Render"|"Toggle"
---@param data table
function M.emit(name, data)
  local ok, err =
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "InkMath" .. name, data = data, modeline = false })
  if not ok then
    require("inkmath.log").once(
      "event:" .. name,
      "inkmath: User InkMath" .. name .. " handler failed: " .. tostring(err)
    )
  end
end

return M
