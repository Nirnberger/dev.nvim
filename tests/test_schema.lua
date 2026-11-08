local schema = require("inkmath.config.schema")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local expect = { match = require("tests.expect").match }

T["defaults equal v1 defaults"] = function()
  local d = schema.defaults()
  eq(d.inline, { x_height = 0.45, baseline = 0.78, promote = false, promote_ratio = 1.6 })
  eq(d.conceal, { level = 2, cursor = "nvic" })
  eq(d.filetypes, { "tex", "markdown", "quarto", "rmd" }) -- quarto/rmd since v2 Task 10
  eq(d.cell_size, nil)
  eq(d.overrides, {})
end
T["unknown key warns with suggestion"] = function()
  local _, w = schema.validate({ scal = 2 })
  eq(#w, 1)
  expect.match(w[1], "scal.*did you mean 'scale'")
end
T["nested unknown key"] = function()
  local _, w = schema.validate({ inline = { baseline = 0.8, xheight = 1 } })
  expect.match(w[1], "inline.xheight.*inline.x_height")
end
T["unknown key without a close match has no suggestion"] = function()
  local e, w = schema.validate({ zzzzzzzz = 1 })
  eq(#e, 0)
  eq(w[1]:find("did you mean", 1, true), nil)
end
T["free tables accept any key"] = function()
  local e, w = schema.validate({ macros = { RR = "\\mathbb{R}" } })
  eq(#e + #w, 0)
end
T["conceal = false accepted"] = function() eq(#schema.validate({ conceal = false }), 0) end
T["all errors are reported"] = function()
  local e = schema.validate({ backend = "x", scale = -1, inline = { promote = 1 } })
  eq(#e, 3)
  expect.match(e[1], "^backend: expected 'mathjax' or 'tectonic', got \"x\"")
end
T["container must be a table"] = function() expect.match(schema.validate({ inline = 3 })[1], "inline: expected table") end
T["global-only key rejected in overrides"] = function()
  local e = schema.validate({ overrides = { markdown = { workers = 4 } } })
  expect.match(e[1], "overrides.markdown.workers.*global")
end
T["overrides entries are validated"] = function()
  local e, w = schema.validate({ overrides = { markdown = { scale = "big", scal = 1 } } })
  expect.match(e[1], "overrides.markdown.scale: expected number > 0")
  expect.match(w[1], "overrides.markdown.scal.*'overrides.markdown.scale'")
end
T["suggest: distance and unique prefix"] = function()
  eq(schema.suggest("backnd", { "backend", "fallback" }), "backend")
  eq(schema.suggest("prom", { "promote", "promote_ratio" }), nil)
  eq(schema.suggest("promote_rat", { "promote", "promote_ratio" }), "promote_ratio")
  eq(schema.suggest("zz", { "backend" }), nil)
end
T["merge replaces lists and merges containers"] = function()
  local m = schema.merge(schema.defaults(), { filetypes = { "tex" }, inline = { baseline = 0.8 } })
  eq(m.filetypes, { "tex" })
  eq(m.inline.x_height, 0.45)
  eq(schema.merge(schema.defaults(), { filetypes = {} }).filetypes, {})
  eq(schema.merge(schema.defaults(), { conceal = false }).conceal, false)
end

T["preview.border: names and 1/2/4/8-entry lists"] = function()
  for _, ok in ipairs({
    "rounded",
    "single",
    "double",
    "bold",
    "solid",
    "shadow",
    "none",
    { "+" },
    { "+", "-" },
    { "+", "-", "+", "|" },
    { "+", "-", "+", "|", "+", "-", "+", "|" },
    { { "+", "Normal" }, "-" },
  }) do
    eq(#schema.validate({ preview = { border = ok } }), 0)
  end
  for _, bad in ipairs({ "rouned", { "+", "-", "+" }, {}, { 1 }, 3 }) do
    eq(#schema.validate({ preview = { border = bad } }), 1)
  end
end
T["log.level choices come from log"] = function()
  for _, l in ipairs(require("inkmath.log").LEVEL_NAMES) do
    eq(#schema.validate({ log = { level = l } }), 0)
  end
  eq(#schema.validate({ log = { level = "trace" } }), 1)
end

return T
