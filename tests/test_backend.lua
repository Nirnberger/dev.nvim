local config = require("inkmath.config")
local backend = require("inkmath.term.backend")
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.setup({})
      backend.reset()
    end,
    post_case = function()
      config.setup({})
      backend.reset()
    end,
  },
})
local eq = MiniTest.expect.equality

T["ghostty is kitty in placeholder mode"] = function()
  local b = backend.detect({ TERM_PROGRAM = "ghostty" })
  eq(b.name, "kitty")
  eq(b.mode, "placeholder")
end

T["xterm-kitty is kitty in placeholder mode"] = function()
  local b = backend.detect({ TERM = "xterm-kitty" })
  eq(b.name, "kitty")
  eq(b.mode, "placeholder")
end

T["unknown terminal has no backend and a reason"] = function()
  local b, why = backend.detect({ TERM = "dumb" })
  eq(b, nil)
  eq(why, "no supported terminal")
end

T["term.backend none disables with a reason"] = function()
  config.setup({ term = { backend = "none" } })
  local b, why = backend.detect({ TERM_PROGRAM = "ghostty" })
  eq(b, nil)
  eq(why, "disabled by term.backend")
end

T["term.backend kitty forces kitty on an unknown terminal"] = function()
  config.setup({ term = { backend = "kitty" } })
  local b = backend.detect({ TERM = "dumb" })
  eq(b.name, "kitty")
  eq(b.mode, "placeholder")
end

T["get memoizes until reset"] = function()
  config.setup({ term = { backend = "kitty" } })
  local first = backend.get()
  config.setup({ term = { backend = "none" } })
  eq(backend.get(), first)
  backend.reset()
  eq(backend.get(), nil)
end

T["iTerm2 is detected as overlay"] = function()
  for _, env in ipairs({ { TERM_PROGRAM = "iTerm.app" }, { LC_TERMINAL = "iTerm2" } }) do
    local b = backend.detect(env)
    eq(b.name, "iterm2")
    eq(b.mode, "overlay")
  end
end

T["iTerm2 paint positions the cursor and sends an inline file"] = function()
  local b = backend.detect({ TERM_PROGRAM = "iTerm.app" })
  local path = vim.fn.tempname() .. ".png"
  local f = assert(io.open(path, "wb"))
  f:write("PNGDATA")
  f:close()
  local out = table.concat(b.paint({ path = path, cols = 3, rows = 2, id = 1 }, 5, 7))
  os.remove(path)
  eq(out:find("\27[5;7H", 1, true) ~= nil, true)
  eq(out:find("]1337;File=inline=1;width=3;height=2;preserveAspectRatio=1:", 1, true) ~= nil, true)
  eq(out:find(vim.base64.encode("PNGDATA"), 1, true) ~= nil, true)
  eq(out:sub(-3), "\7\0278")
end

T["iTerm2 paint of a missing file is empty"] = function()
  local b = backend.detect({ TERM_PROGRAM = "iTerm.app" })
  eq(b.paint({ path = "/nonexistent.png", cols = 1, rows = 1, id = 1 }, 1, 1), {})
end

T["term.backend iterm2 forces iTerm2"] = function()
  config.setup({ term = { backend = "iterm2" } })
  eq(backend.detect({ TERM = "dumb" }).name, "iterm2")
end

T["sixel is detected from TERM"] = function()
  for _, env in ipairs({ { TERM = "foot" }, { TERM = "mlterm" }, { TERM = "xterm-sixel" }, { WT_SESSION = "x" } }) do
    local b = backend.detect(env)
    eq(b and b.name, "sixel")
    eq(b.mode, "overlay")
  end
end

T["DA1 reply with attribute 4 means sixel"] = function()
  local sixel = require("inkmath.term.backends.sixel")
  eq(sixel.da1_has_sixel("\27[?62;4;c"), true)
  eq(sixel.da1_has_sixel("\27[?62;22c"), false)
  eq(sixel.da1_has_sixel("\27[?64;14;c"), false)
  eq(sixel.da1_has_sixel("junk"), false)
end

T["a DA1 reply after the probe gave up detects sixel and attaches again"] = function()
  local sixel = require("inkmath.term.backends.sixel")
  local env_mod, api = require("inkmath.env"), require("inkmath.api")
  local rearmed, reapplied = 0, 0
  local o1, o2 = env_mod.rearm, api._reapply
  env_mod.rearm = function() rearmed = rearmed + 1 end
  api._reapply = function() reapplied = reapplied + 1 end
  sixel._watch_late()
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27[?62;4;c" } })
  vim.wait(200, function() return reapplied > 0 end, 10)
  env_mod.rearm, api._reapply = o1, o2
  sixel._forget()
  eq({ rearmed, reapplied }, { 1, 1 })
end

T["sixel paint sends the .six file at the cell"] = function()
  local b = backend.detect({ TERM = "foot" })
  local base = vim.fn.tempname()
  local f = assert(io.open(base .. ".six", "wb"))
  f:write("\27Pq#0~\27\\")
  f:close()
  local out = table.concat(b.paint({ path = base .. ".png", cols = 1, rows = 1, id = 1 }, 3, 4))
  os.remove(base .. ".six")
  eq(out, "\0277\27[3;4H\27Pq#0~\27\\\0278")
end

T["sixel paint without .six is empty and never blocks"] = function()
  local b = backend.detect({ TERM = "foot" })
  local old = vim.fn.executable
  vim.fn.executable = function() return 0 end
  local out = b.paint({ path = "/nonexistent/x.png", cols = 1, rows = 1, id = 1 }, 1, 1)
  vim.fn.executable = old
  eq(out, {})
end

T["WezTerm and Konsole are kitty in overlay mode"] = function()
  for _, env in ipairs({ { TERM_PROGRAM = "WezTerm" }, { KONSOLE_VERSION = "230800" } }) do
    local b = backend.detect(env)
    eq(b.name, "kitty")
    eq(b.mode, "overlay")
  end
end

T["term.backend kitty forces placeholder mode on WezTerm"] = function()
  config.setup({ term = { backend = "kitty" } })
  eq(backend.detect({ TERM_PROGRAM = "WezTerm" }).mode, "placeholder")
end

T["kitty overlay places a transmitted image without moving the cursor"] = function()
  local b = backend.detect({ TERM_PROGRAM = "WezTerm" })
  eq(
    b.paint({ path = "/x.png", cols = 3, rows = 2, id = 9 }, 4, 5),
    { "\0277\27[4;5H\27_Ga=p,i=9,c=3,r=2,C=1,q=2\27\\\0278" }
  )
  eq(b.delete(9), "\27_Ga=d,d=i,i=9,q=2\27\\")
end

T["overlay transmit has no virtual placement"] = function()
  local kitty = require("inkmath.term.kitty")
  eq(kitty.transmit_seq(7, "/tmp/a.png", 3, 1, true, false)[1]:find("U=1", 1, true), nil)
  eq(kitty.transmit_seq(7, "/tmp/a.png", 3, 1, true, false)[1]:find("a=t,", 1, true) ~= nil, true)
end

return T
