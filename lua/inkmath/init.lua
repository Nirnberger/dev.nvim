-- require("inkmath"): setup() plus the public API (inkmath.api) through __index.
local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.worker_dir = root .. "/worker"

-- without plugin/ loading (--noplugin, a bare rtp entry) the entry point still exists
if not vim.g.loaded_inkmath then vim.cmd.source(vim.fn.fnameescape(root .. "/plugin/inkmath.lua")) end

---@param opts table|nil
---@return boolean ok false: invalid opts (notified; the previous config stays)
function M.setup(opts)
  local ok, err = require("inkmath.config").set(opts, true)
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end
  require("inkmath.api")._reapply()
  return true
end

return setmetatable(M, { __index = function(_, k) return require("inkmath.api")[k] end })
