-- Other plugins that render LaTeX math or own 'conceallevel': one entry per plugin,
-- shared by health (is its math rendering on?) and view/conceal (does it manage
-- this buffer?). Every probe reads only modules that are already loaded
-- (package.loaded, rawget): asking must never load or set up another plugin.
local M = {}

local function loaded(name) return package.loaded[name] end

---@class inkmath.Interop
---@field name string
---@field loaded fun(): boolean the plugin is active in this session
---@field latex_on fun(): boolean|nil it renders LaTeX math (nil: config unreadable)
---@field manages? fun(buf: integer): boolean it is attached to `buf` and sets its 'conceallevel'
---@field fix string what to put in the user's own plugin spec to turn its math off

---@type inkmath.Interop[]
M.plugins = {
  {
    -- plugin/render-markdown.lua calls setup(), which stores the resolved config in
    -- render-markdown.state (lua/render-markdown/state.lua M.setup: M.config = config;
    -- latex.enabled defaults to true, settings.lua M.latex.default)
    name = "render-markdown",
    loaded = function() return loaded("render-markdown") ~= nil or loaded("render-markdown.state") ~= nil end,
    latex_on = function()
      local st = loaded("render-markdown.state")
      if type(st) ~= "table" then return nil end
      local v = vim.tbl_get(st, "config", "latex", "enabled")
      if type(v) == "boolean" then return v end
    end,
    -- core/manager.lua M.attached(buf); writes win_options from vim.schedule
    manages = function(buf)
      local m = loaded("render-markdown.core.manager")
      return type(m) == "table" and type(m.attached) == "function" and m.attached(buf) == true
    end,
    fix = "latex = { enabled = false } in your render-markdown.nvim opts",
  },
  {
    -- markview works without setup(): plugin/markview.lua loads markview.autocmds,
    -- which loads markview.spec. `latex` is external config (spec.__external_config):
    -- spec.config.latex holds only the user's keys until markview's own spec.get()
    -- merges lua/markview/config/latex.lua (enable = true) into it, so a missing
    -- `enable` means the default, on. (spec.get is not called: it would load that
    -- module.)
    name = "markview",
    loaded = function() return loaded("markview.spec") ~= nil or loaded("markview") ~= nil end,
    latex_on = function()
      local spec = loaded("markview.spec")
      if type(spec) ~= "table" then return true end -- markview without its spec yet: defaults
      local cfg = spec.tmp_config or spec.config
      local l = type(cfg) == "table" and cfg.latex
      if l == nil then return true end
      if type(l) ~= "table" then return nil end
      return l.enable ~= false
    end,
    -- lua/markview/state.lua state.buf_attached(buf)
    manages = function(buf)
      local s = loaded("markview.state")
      return type(s) == "table" and type(s.buf_attached) == "function" and s.buf_attached(buf) == true
    end,
    fix = "latex = { enable = false } in your markview.nvim opts",
  },
  {
    -- Snacks has an __index metatable that require()s snacks.<name>: rawget only.
    -- snacks.image renders document math when image.enabled (default nil, off) and
    -- doc.enabled and math.enabled (both default true): lua/snacks/image/init.lua,
    -- `if M.config.enabled and M.config.doc.enabled`. Once loaded, Snacks.image.config
    -- is the resolved config; before, the user's opts are Snacks.config.image.
    name = "snacks.image",
    loaded = function() return M._snacks_image_cfg() ~= nil end,
    latex_on = function()
      local cfg = M._snacks_image_cfg()
      if not cfg then return false end
      local doc, math = cfg.doc, cfg.math
      return (doc == nil or type(doc) == "table" and doc.enabled ~= false)
        and (math == nil or type(math) == "table" and math.enabled ~= false)
    end,
    fix = "image = { math = { enabled = false } } in your snacks.nvim opts",
  },
}

--- The snacks.image config when snacks.image is enabled (or already loaded), else nil.
---@return table|nil
function M._snacks_image_cfg()
  local S = rawget(_G, "Snacks")
  if type(S) ~= "table" then return nil end
  local img = rawget(S, "image")
  if type(img) == "table" and type(rawget(img, "config")) == "table" then
    local cfg = rawget(img, "config")
    return cfg.enabled and cfg or nil
  end
  local conf = rawget(S, "config")
  -- Snacks.config.image: the user's opts (its __index only creates an empty table)
  local user = type(conf) == "table" and conf.image
  if type(user) == "table" and user.enabled then return user end
  return nil
end

--- Plugins that are loaded and manage `buf`'s conceal options.
---@param buf integer
---@return string[] names
function M.managers(buf)
  local out = {}
  for _, p in ipairs(M.plugins) do
    if p.manages and p.loaded() then
      local ok, yes = pcall(p.manages, buf)
      if ok and yes then out[#out + 1] = p.name end
    end
  end
  return out
end

return M
