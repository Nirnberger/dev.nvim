-- LaTeX math -> Unicode text, for the preview float in terminals without a graphics
-- protocol. Best effort: Greek letters, operators, sub/superscripts where Unicode has
-- them, fractions as a/b, roots with √. Unknown commands stay as written.
local M = {}

local SYMBOLS = {
  alpha = "α",
  beta = "β",
  gamma = "γ",
  delta = "δ",
  epsilon = "ε",
  varepsilon = "ε",
  zeta = "ζ",
  eta = "η",
  theta = "θ",
  vartheta = "ϑ",
  iota = "ι",
  kappa = "κ",
  lambda = "λ",
  mu = "μ",
  nu = "ν",
  xi = "ξ",
  pi = "π",
  rho = "ρ",
  sigma = "σ",
  tau = "τ",
  upsilon = "υ",
  phi = "φ",
  varphi = "φ",
  chi = "χ",
  psi = "ψ",
  omega = "ω",
  Gamma = "Γ",
  Delta = "Δ",
  Theta = "Θ",
  Lambda = "Λ",
  Xi = "Ξ",
  Pi = "Π",
  Sigma = "Σ",
  Phi = "Φ",
  Psi = "Ψ",
  Omega = "Ω",
  sum = "∑",
  prod = "∏",
  int = "∫",
  oint = "∮",
  partial = "∂",
  nabla = "∇",
  infty = "∞",
  pm = "±",
  mp = "∓",
  times = "×",
  cdot = "·",
  div = "÷",
  ast = "∗",
  circ = "∘",
  leq = "≤",
  le = "≤",
  geq = "≥",
  ge = "≥",
  neq = "≠",
  ne = "≠",
  approx = "≈",
  equiv = "≡",
  sim = "∼",
  simeq = "≃",
  propto = "∝",
  ll = "≪",
  gg = "≫",
  ["in"] = "∈",
  notin = "∉",
  subset = "⊂",
  subseteq = "⊆",
  supset = "⊃",
  supseteq = "⊇",
  cup = "∪",
  cap = "∩",
  emptyset = "∅",
  varnothing = "∅",
  forall = "∀",
  exists = "∃",
  neg = "¬",
  land = "∧",
  lor = "∨",
  wedge = "∧",
  vee = "∨",
  to = "→",
  rightarrow = "→",
  leftarrow = "←",
  leftrightarrow = "↔",
  Rightarrow = "⇒",
  Leftarrow = "⇐",
  Leftrightarrow = "⇔",
  iff = "⇔",
  implies = "⇒",
  mapsto = "↦",
  ldots = "…",
  cdots = "⋯",
  dots = "…",
  vdots = "⋮",
  ddots = "⋱",
  langle = "⟨",
  rangle = "⟩",
  lbrace = "{",
  rbrace = "}",
  ell = "ℓ",
  hbar = "ℏ",
  Re = "ℜ",
  Im = "ℑ",
  left = "",
  right = "",
  quad = " ",
  qquad = "  ",
  displaystyle = "",
  textstyle = "",
  lim = "lim",
  sin = "sin",
  cos = "cos",
  tan = "tan",
  log = "log",
  ln = "ln",
  exp = "exp",
  max = "max",
  min = "min",
  det = "det",
}

local SPACING = { [","] = " ", [";"] = " ", [":"] = " ", [" "] = " ", ["!"] = "", [">"] = " " }

local BB = { R = "ℝ", N = "ℕ", Z = "ℤ", Q = "ℚ", C = "ℂ", P = "ℙ", H = "ℍ" }

-- the font commands that just pass their argument on
local PASS = {
  mathrm = true,
  mathit = true,
  mathbf = true,
  mathcal = true,
  mathsf = true,
  mathtt = true,
  text = true,
  textrm = true,
  textbf = true,
  operatorname = true,
  boldsymbol = true,
  bm = true,
  mathscr = true,
  mathfrak = true,
}

local SUP = {
  ["0"] = "⁰",
  ["1"] = "¹",
  ["2"] = "²",
  ["3"] = "³",
  ["4"] = "⁴",
  ["5"] = "⁵",
  ["6"] = "⁶",
  ["7"] = "⁷",
  ["8"] = "⁸",
  ["9"] = "⁹",
  ["+"] = "⁺",
  ["-"] = "⁻",
  ["="] = "⁼",
  ["("] = "⁽",
  [")"] = "⁾",
  n = "ⁿ",
  i = "ⁱ",
  x = "ˣ",
  y = "ʸ",
  a = "ᵃ",
  b = "ᵇ",
  c = "ᶜ",
  d = "ᵈ",
  e = "ᵉ",
  f = "ᶠ",
  g = "ᵍ",
  h = "ʰ",
  j = "ʲ",
  k = "ᵏ",
  l = "ˡ",
  m = "ᵐ",
  o = "ᵒ",
  p = "ᵖ",
  r = "ʳ",
  s = "ˢ",
  t = "ᵗ",
  u = "ᵘ",
  v = "ᵛ",
  w = "ʷ",
  z = "ᶻ",
  ["−"] = "⁻",
  ["∗"] = "*",
  ["′"] = "′",
}
local SUB = {
  ["0"] = "₀",
  ["1"] = "₁",
  ["2"] = "₂",
  ["3"] = "₃",
  ["4"] = "₄",
  ["5"] = "₅",
  ["6"] = "₆",
  ["7"] = "₇",
  ["8"] = "₈",
  ["9"] = "₉",
  ["+"] = "₊",
  ["-"] = "₋",
  ["="] = "₌",
  ["("] = "₍",
  [")"] = "₎",
  a = "ₐ",
  e = "ₑ",
  h = "ₕ",
  i = "ᵢ",
  j = "ⱼ",
  k = "ₖ",
  l = "ₗ",
  m = "ₘ",
  n = "ₙ",
  o = "ₒ",
  p = "ₚ",
  r = "ᵣ",
  s = "ₛ",
  t = "ₜ",
  u = "ᵤ",
  v = "ᵥ",
  x = "ₓ",
}

--- Find the end of the group opened at s[i] == "{" (index of its "}"), or nil.
local function group_end(s, i)
  local depth = 0
  local j = i
  while j <= #s do
    local c = s:sub(j, j)
    if c == "\\" then
      j = j + 1 -- skip the escaped char
    elseif c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then return j end
    end
    j = j + 1
  end
end

local convert

--- One argument at s[i]: a {group}, a \command or a single character.
---@return string raw source of the argument
---@return integer next index
local function read_arg(s, i)
  while s:sub(i, i) == " " do
    i = i + 1
  end
  local c = s:sub(i, i)
  if c == "{" then
    local e = group_end(s, i) or #s + 1
    return s:sub(i + 1, e - 1), e + 1
  elseif c == "\\" then
    local name = s:match("^\\(%a+)", i)
    local len = name and #name + 1 or 2
    return s:sub(i, i + len - 1), i + len
  end
  local ch = s:match("^[%z\1-\127\194-\244][\128-\191]*", i) or ""
  return ch, i + #ch
end

local function script(map, text)
  local out = {}
  for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
    if ch == " " then
      -- dropped
    elseif map[ch] then
      out[#out + 1] = map[ch]
    else
      return nil
    end
  end
  return table.concat(out)
end

local function wrap(text)
  if text:find("[%s%+%-%*/=<>]") or text:find("[±×÷≤≥≠]") then return "(" .. text .. ")" end
  return text
end

---@param s string LaTeX math source
---@return string
function convert(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" then
      local name = s:match("^\\(%a+)", i)
      if name then
        i = i + 1 + #name
        if name == "frac" or name == "dfrac" or name == "tfrac" then
          local a, b
          a, i = read_arg(s, i)
          b, i = read_arg(s, i)
          out[#out + 1] = wrap(convert(a)) .. "/" .. wrap(convert(b))
        elseif name == "sqrt" then
          local a
          a, i = read_arg(s, i)
          out[#out + 1] = "√" .. wrap(convert(a))
        elseif name == "mathbb" then
          local a
          a, i = read_arg(s, i)
          out[#out + 1] = BB[a] or convert(a)
        elseif PASS[name] then
          local a
          a, i = read_arg(s, i)
          out[#out + 1] = convert(a)
        elseif SYMBOLS[name] then
          out[#out + 1] = SYMBOLS[name]
        else
          -- unknown: keep it as written, its group too
          out[#out + 1] = "\\" .. name
          if s:sub(i, i) == "{" then
            local a
            a, i = read_arg(s, i)
            out[#out + 1] = "{" .. convert(a) .. "}"
          end
        end
      else
        local nx = s:sub(i + 1, i + 1)
        i = i + 2
        out[#out + 1] = SPACING[nx] or nx
      end
    elseif c == "^" or c == "_" then
      local a
      a, i = read_arg(s, i + 1)
      local text = convert(a)
      out[#out + 1] = script(c == "^" and SUP or SUB, text)
        or (c .. (vim.fn.strchars(text) > 1 and "(" .. text .. ")" or text))
    elseif c == "{" or c == "}" then
      i = i + 1
    elseif c == "&" then
      out[#out + 1] = "  "
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return (table.concat(out):gsub("%s+", " "))
end

M.convert = function(s) return vim.trim(convert(s)) end

return M
