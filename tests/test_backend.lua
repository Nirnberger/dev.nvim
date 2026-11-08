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

return T
