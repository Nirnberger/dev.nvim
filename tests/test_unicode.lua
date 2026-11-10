local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local u = require("inkmath.render.unicode")

T["greek letters and operators"] = function()
  eq(u.convert("\\alpha + \\beta"), "α + β")
  eq(u.convert("a \\leq b \\neq c"), "a ≤ b ≠ c")
  eq(u.convert("\\sum_{i=1}^{n} i"), "∑ᵢ₌₁ⁿ i")
end

T["super and subscripts"] = function()
  eq(u.convert("x^2"), "x²")
  eq(u.convert("x_{12}"), "x₁₂")
  eq(u.convert("e^{-x}"), "e⁻ˣ")
end

T["fractions and roots"] = function()
  eq(u.convert("\\frac{a}{b}"), "a/b")
  eq(u.convert("\\frac{a+b}{c}"), "(a+b)/c")
  eq(u.convert("\\sqrt{x}"), "√x")
  eq(u.convert("\\sqrt{x+1}"), "√(x+1)")
end

T["font commands and spacing"] = function()
  eq(u.convert("\\mathbb{R}"), "ℝ")
  eq(u.convert("\\mathrm{d}x"), "dx")
  eq(u.convert("a \\, b"), "a b")
end

T["unknown commands stay readable"] = function()
  eq(u.convert("\\foo{x}"), "\\foo{x}")
  eq(u.convert("x^{\\gamma}"), "x^γ")
end

return T
