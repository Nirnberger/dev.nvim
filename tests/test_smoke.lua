-- Smoke checks that hold on every Neovim version / machine: every module loads, and the
-- plugin degrades (no hang, no error) when its external tools are missing.
vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local T = MiniTest.new_set({
  hooks = { post_case = function() require("inkmath.config").setup({}) end },
})
local eq = MiniTest.expect.equality

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function modules()
  local out = {}
  for _, f in ipairs(vim.fn.globpath(root .. "/lua", "inkmath/**/*.lua", false, true)) do
    local mod = f:sub(#root + #"/lua/" + 1, -5):gsub("/", "."):gsub("%.init$", "")
    out[#out + 1] = mod
  end
  table.sort(out)
  return out
end

T["every module loads"] = function()
  local mods = modules()
  assert(#mods > 40, "found only " .. #mods .. " modules")
  local bad = {}
  for _, m in ipairs(mods) do
    local ok, err = pcall(require, m)
    if not ok then bad[#bad + 1] = m .. ": " .. tostring(err):sub(1, 200) end
  end
  eq(bad, {})
end

T["plugin file loads twice without error"] = function()
  vim.cmd("source " .. vim.fn.fnameescape(root .. "/plugin/inkmath.lua"))
  vim.cmd("source " .. vim.fn.fnameescape(root .. "/plugin/inkmath.lua"))
end

local MISSING = "inkmath-no-such-command"

T["no tools: available() is all false"] = function()
  require("inkmath.config").setup({ node_cmd = MISSING, tectonic_cmd = MISSING, magick_cmd = MISSING })
  require("inkmath.render.mathjax")._reset_available()
  local a = require("inkmath.render").available()
  eq(a.mathjax, false)
  eq(a.tectonic, false)
end

T["no tools: a render fails fast with `unavailable`, never hangs"] = function()
  require("inkmath.config").setup({ node_cmd = MISSING, tectonic_cmd = MISSING, magick_cmd = MISSING })
  require("inkmath.render.mathjax")._reset_available()
  local n = { id = "q", kind = "inline", src = "x^2", range = { 0, 0, 0, 3 } }
  local c = { color = "#c0caf5", cell_w = 10, cell_h = 20, container_px = 800, macros = {} }
  local done, img, err
  require("inkmath.render").render(n, c, function(i, e)
    done, img, err = true, i, e
  end)
  vim.wait(10000, function() return done end, 20)
  assert(done, "render callback not called")
  eq(img, nil)
  eq(type(err), "table")
  eq(err.unavailable, true)
  require("inkmath.render.mathjax")._reset_available()
end

T["no tools: :checkhealth inkmath reports warnings and does not raise"] = function()
  require("inkmath.config").setup({ node_cmd = MISSING, tectonic_cmd = MISSING, magick_cmd = MISSING })
  local warned = 0
  local orig = vim.health.warn
  vim.health.warn = function() warned = warned + 1 end
  local ok, err = pcall(require("inkmath.health").check)
  vim.health.warn = orig
  assert(ok, err)
  assert(warned >= 2, "expected warnings for the missing tools, got " .. warned)
end

return T
