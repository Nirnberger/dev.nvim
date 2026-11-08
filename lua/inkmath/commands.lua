-- :InkMath[!] {sub} [args]: a registry of subcommands. Feedback for commands the
-- user ran goes straight to vim.notify (not filtered by `log.level`).
local M = {}

---@class inkmath.Subcommand
---@field run fun(args: string[], bang: boolean)
---@field desc string
---@field complete? fun(lead: string): string[]

local subs = {} ---@type table<string, inkmath.Subcommand>

---@param name string
---@param spec inkmath.Subcommand
function M.register(name, spec)
  vim.validate("name", name, "string")
  vim.validate("spec.run", spec.run, "function")
  vim.validate("spec.desc", spec.desc, "string")
  subs[name] = spec
end

---@return string[] sorted
function M.names()
  local out = vim.tbl_keys(subs)
  table.sort(out)
  return out
end

local function filter(list, lead)
  return vim.tbl_filter(function(s) return vim.startswith(s, lead) end, list)
end

---@param opts {fargs: string[], bang: boolean}
function M.run(opts)
  local name = opts.fargs[1]
  local spec = name and subs[name]
  if not spec then
    local prefix = name and ("inkmath: unknown subcommand '%s'; "):format(name) or "inkmath: "
    vim.notify(prefix .. "usage: :InkMath " .. table.concat(M.names(), "|"), vim.log.levels.ERROR)
    return
  end
  spec.run(vim.list_slice(opts.fargs, 2), opts.bang == true)
end

--- Completion: subcommand names for the first argument, then the subcommand's own.
---@param lead string
---@param line string
---@return string[]
function M.complete(lead, line)
  local args = vim.split(vim.trim(line:gsub("^%s*%S+", "", 1)), "%s+", { trimempty = true })
  if #args == 0 or (#args == 1 and lead ~= "") then return filter(M.names(), lead) end
  local spec = subs[args[1]]
  if not (spec and spec.complete) then return {} end
  local out = spec.complete(lead)
  table.sort(out)
  return filter(out, lead)
end

local function api() return require("inkmath.api") end

--- bang: every buffer (the global switch), else the current buffer
local function scope(bang) return (not bang) and 0 or nil end

M.register("enable", { desc = "Render math in this buffer (!: everywhere)", run = function(_, bang) api().enable(scope(bang)) end })
M.register("disable", { desc = "Stop rendering in this buffer (!: everywhere)", run = function(_, bang) api().disable(scope(bang)) end })
M.register("toggle", { desc = "Toggle rendering in this buffer (!: everywhere)", run = function(_, bang) api().toggle(scope(bang)) end })
M.register("refresh", { desc = "Re-render the current buffer", run = function() api().refresh(0) end })
M.register("clear-cache", {
  desc = "Delete the image cache and render again",
  run = function() vim.notify(("inkmath: cache cleared (%d files)"):format(api().clear_cache() or 0)) end,
})
M.register("status", {
  desc = "Backends, workers, queue, cache, attached buffers",
  run = function() require("inkmath.status").show() end,
})
M.register("build", {
  desc = "Install the MathJax worker's dependencies (npm ci)",
  run = function()
    local dir = require("inkmath").worker_dir
    vim.notify("inkmath: running npm ci in " .. dir)
    local ok, err = pcall(vim.system, { "npm", "ci" }, { cwd = dir, text = true }, function(res)
      vim.schedule(function()
        if res.code == 0 then
          vim.notify("inkmath: worker built")
          -- the backend works now: warn again if it breaks, attach what could not be
          require("inkmath.log").rearm("backend")
          require("inkmath.render.mathjax")._reset_available()
          api()._reapply()
        else
          vim.notify("inkmath: npm ci failed:\n" .. (res.stderr or ""), vim.log.levels.ERROR)
        end
      end)
    end)
    if not ok then vim.notify("inkmath: could not run npm: " .. tostring(err), vim.log.levels.ERROR) end
  end,
})

return M
