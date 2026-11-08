local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local f = function(l) return require("inkmath.render.macros").from_tex_preamble(l) end

T["newcommand"] = function() eq(f({ "\\newcommand{\\R}{\\mathbb{R}}" }), { R = "\\mathbb{R}" }) end
T["nargs"] = function() eq(f({ "\\newcommand{\\norm}[1]{\\lVert #1\\rVert}" }), { norm = { "\\lVert #1\\rVert", 1 } }) end
T["renewcommand"] = function() eq(f({ "\\renewcommand{\\R}{X}" }), { R = "X" }) end
T["def"] = function() eq(f({ "\\def\\eps{\\varepsilon}" }), { eps = "\\varepsilon" }) end
T["operator"] = function() eq(f({ "\\DeclareMathOperator{\\tr}{tr}" }), { tr = "\\operatorname{tr}" }) end
T["operator star"] = function()
  eq(f({ "\\DeclareMathOperator*{\\argmax}{arg\\,max}" }), { argmax = "\\operatorname*{arg\\,max}" })
end
T["let"] = function() eq(f({ "\\let\\phi\\varphi" }), { phi = "\\varphi" }) end
T["multiline"] = function()
  eq(f({ "\\newcommand{\\foo}{", "  a + {b}", "}" }), { foo = "\n  a + {b}\n" })
end
T["ignores others"] = function() eq(f({ "\\usepackage{amsmath}" }), {}) end

return T
