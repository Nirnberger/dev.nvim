-- Resolved configuration: schema defaults < vim.g.inkmath < setup() < overrides[ft].
-- The option list, defaults and checks live in inkmath.config.schema.
local log = require("inkmath.log")
local schema = require("inkmath.config.schema")

local M = {}

--- bumped on every successful setup/reset; caches of resolved configs key on it
M.generation = 0

local base ---@type table|nil vim.g.inkmath, read lazily (nil: not read yet)
local user = {} ---@type table accumulated setup() opts
local resolved ---@type table|nil defaults < base < user
local by_ft = {} ---@type table<string, table> resolved + overrides[ft], this generation

local notify = log.notify

local function warn_all(warns)
  for _, w in ipairs(warns) do notify("inkmath: " .. w, vim.log.levels.WARN) end
end

local function warn_unregistered(filetypes)
  local registry = require("inkmath.detect.registry")
  for _, ft in ipairs(filetypes) do
    if not registry.get(ft) then
      notify(("inkmath: filetype '%s' has no math detector; add one with require(\"inkmath\").register_filetype()"):format(ft),
        vim.log.levels.WARN)
    end
  end
end

local function errors_message(errs)
  return "inkmath: invalid config:\n  - " .. table.concat(errs, "\n  - ")
end

local function invalidate()
  M.generation = M.generation + 1
  resolved, by_ft = nil, {}
end

--- per-key errors of a layer, then (when there are none) the cross-option checks of
--- the config it would resolve to
local function check(layer, b, u, opts)
  local errs, warns = schema.validate(layer, opts)
  if #errs == 0 then errs = schema.check_constraints(schema.merge(schema.merge(schema.defaults(), b), u)) end
  return errs, warns
end

local function read_base()
  if base then return end
  local g = vim.g.inkmath
  base = {}
  if g == nil then return end
  local errs, warns = check(g, type(g) == "table" and g or {}, {}, { where = "vim.g.inkmath." })
  if #errs == 0 then base = g end -- first, so its own log.level filters the warnings
  warn_all(warns)
  if #errs > 0 then notify(errors_message(errs) .. "\n(vim.g.inkmath ignored)", vim.log.levels.ERROR) end
end

--- Validate `opts` and make it the user layer; `extend` merges it onto the previous
--- one (so a second setup() adds to the first). Nothing changes on error.
---@param opts table|nil
---@param extend boolean
---@return boolean ok, string|nil err all errors, one per line
function M.set(opts, extend)
  read_base()
  opts = opts or {}
  local new = type(opts) == "table" and (extend and schema.merge(user, opts) or vim.deepcopy(opts)) or nil
  local errs, warns = check(opts, base, new or {})
  if #errs > 0 then return false, errors_message(errs) end
  warn_all(warns)
  user = new
  invalidate()
  if opts.filetypes then warn_unregistered(opts.filetypes) end
  return true, nil
end

--- v1 module entry point, kept for tests and dev/ scripts (user code calls
--- require("inkmath").setup, which extends and notifies): the opts REPLACE earlier
--- setup() opts; raises one readable error listing every bad key (the previous
--- config stays in effect).
---@param opts table|nil
---@return boolean
function M.setup(opts)
  local ok, err = M.set(opts, false)
  if not ok then error(err, 0) end
  return true
end

--- (tests) forget setup() opts and re-read vim.g.inkmath on the next access
function M.reset()
  base, user = nil, {}
  invalidate()
end

--- merged user opts (vim.g.inkmath and setup()), without defaults
---@return table
function M.user()
  read_base()
  return schema.merge(base, user)
end

--- The resolved config, with `overrides[filetype]` applied when `buf` is given.
--- Shared between callers: treat it as read-only.
---@param buf? integer
---@return table
function M.get(buf)
  if not resolved then
    read_base()
    resolved = schema.merge(schema.merge(schema.defaults(), base), user)
  end
  if not buf then return resolved end
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  return M.for_ft(vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype or "")
end

--- The resolved config with `overrides[ft]` applied.
---@param ft string
---@return table
function M.for_ft(ft)
  local r = M.get()
  local over = r.overrides[ft]
  if not over then return r end
  local c = by_ft[ft]
  if not c then
    c = schema.merge(r, over)
    by_ft[ft] = c
  end
  return c
end

--- the config a render ctx was built with (ad-hoc ctx tables in tests have none)
---@param ctx table|nil
---@return table
function M.of(ctx)
  return ctx and ctx.opts or M.get()
end

return M
