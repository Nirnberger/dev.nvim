-- plugin/inkmath.lua in a fresh child Neovim (no inkmath module loaded yet)
local h = require("tests.helpers")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "NONE" })
      child.o.runtimepath = root .. "," .. child.o.runtimepath
    end,
    post_once = function() child.stop() end,
  },
})
local eq = MiniTest.expect.equality

local function loaded_modules()
  return child.lua_get([[vim.tbl_filter(function(m) return m:find("^inkmath") end, vim.tbl_keys(package.loaded))]])
end

T["command exists without setup"] = function()
  child.cmd("runtime plugin/inkmath.lua")
  eq(child.fn.exists(":InkMath"), 2)
end
T["loading does not require inkmath modules"] = function()
  child.cmd("runtime plugin/inkmath.lua")
  eq(loaded_modules(), {})
end
T["loading is cheap"] = function()
  local ms = child.lua_get([[(function()
    local t = vim.uv.hrtime()
    vim.cmd("runtime plugin/inkmath.lua")
    return (vim.uv.hrtime() - t) / 1e6
  end)()]])
  eq(ms < 1 * h.perf_factor, true)
end
T["guard prevents double load"] = function()
  child.cmd("runtime plugin/inkmath.lua")
  MiniTest.expect.no_error(function() child.cmd("runtime plugin/inkmath.lua") end)
  eq(child.g.loaded_inkmath, 1)
end
T["no default keymaps"] = function()
  child.cmd("runtime plugin/inkmath.lua")
  local maps = child.lua_get([[vim.tbl_map(function(m) return m.lhs end, vim.tbl_filter(function(m)
    return (m.desc or ""):find("^inkmath") ~= nil end, vim.api.nvim_get_keymap("")))]])
  for _, lhs in ipairs(maps) do eq(vim.startswith(lhs, "<Plug>"), true) end
  eq(child.fn.maparg("<Plug>(inkmath-toggle)", "n") ~= "", true)
  eq(child.fn.maparg("<leader>m", "n"), "")
end
T["highlights are default"] = function()
  child.api.nvim_set_hl(0, "InkMathError", { fg = 0xff0000 })
  child.cmd("runtime plugin/inkmath.lua")
  eq(child.api.nvim_get_hl(0, { name = "InkMathError" }).fg, 0xff0000)
  eq(child.api.nvim_get_hl(0, { name = "InkMathPreviewBorder" }).link, "FloatBorder")
  eq(child.api.nvim_get_hl(0, { name = "InkMathPreviewError" }).link, "DiagnosticError")
  child.cmd("colorscheme default") -- :hi clear, then ColorScheme
  eq(child.api.nvim_get_hl(0, { name = "InkMathError" }).link, "DiagnosticUnderlineError")
end
T["other filetypes load nothing"] = function()
  child.cmd("runtime plugin/inkmath.lua")
  child.cmd("setfiletype python")
  child.lua("vim.wait(20, function() return false end)")
  eq(loaded_modules(), {})
end
T["configured filetype goes through the api"] = function()
  child.cmd("runtime plugin/inkmath.lua")
  child.lua([[require("inkmath.api")._auto = function(b) _G.auto = b end]])
  child.cmd("setfiletype markdown")
  child.lua("vim.wait(200, function() return _G.auto ~= nil end)")
  eq(child.lua_get("_G.auto"), child.api.nvim_get_current_buf())
end
T["vim.g.inkmath.filetypes before setup"] = function()
  child.g.inkmath = { filetypes = { "rst" } }
  child.cmd("runtime plugin/inkmath.lua")
  child.lua([[require("inkmath.api")._auto = function(b) _G.auto = b end]])
  child.cmd("setfiletype markdown")
  child.lua("vim.wait(50, function() return _G.auto ~= nil end)")
  eq(child.lua_get("_G.auto"), vim.NIL)
end
T["inline default filetypes match the schema"] = function()
  local src = table.concat(vim.fn.readfile(root .. "/plugin/inkmath.lua"), "\n")
  local inline = src:match("or (%b{})%s*\nend")
  eq(loadstring("return " .. inline)(), require("inkmath.config.schema").defaults().filetypes)
end

return T
