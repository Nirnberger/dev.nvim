-- Equation numbers from the .aux file: parsing and \tag injection.
local function L() return require("inkmath.labels") end -- lazy: a load error must fail cases, not the file

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return vim.uv.fs_realpath(d)
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function block(env, src)
  return { id = "x", kind = "block", env = env, src = src, range = { srow = 0, scol = 0, erow = 0, ecol = 1 } }
end

T["parse"] = MiniTest.new_set()

T["parse"]["plain, hyperref and cleveref entries"] = function()
  local labels = L().parse({
    "\\relax",
    "\\newlabel{eq:a}{{3.2}{7}}",
    "\\newlabel{eq:b}{{4}{9}{Results}{equation.4}{}}",
    "\\newlabel{eq:b@cref}{{[equation][4][]4}{[1][9][]9}}",
    "\\newlabel{sec:x}{{2.1}{3}{Intro}{section.2.1}{}}",
    "\\newlabel{weird}{{\\textup {A}\\relax 1}{3}}",
    "\\newlabel{empty}{{}{3}}",
  })
  eq(labels["eq:a"], "3.2")
  eq(labels["eq:b"], "4")
  eq(labels["eq:b@cref"], nil)
  eq(labels["sec:x"], "2.1")
  eq(labels["weird"], nil) -- not a plain number: never injected into TeX
  eq(labels["empty"], nil)
end

T["parse"]["read follows \\@input one level and is mtime-cached"] = function()
  local d = tmpdir()
  write(d .. "/main.aux", { "\\newlabel{eq:a}{{1}{1}}", "\\@input{chap/one.aux}" })
  write(d .. "/chap/one.aux", { "\\newlabel{eq:c}{{2.5}{4}}" })
  local labels = L().read(d .. "/main.aux")
  eq(labels["eq:a"], "1")
  eq(labels["eq:c"], "2.5")
  eq(L().read(d .. "/missing.aux"), nil)
  eq(L().read(nil), nil)
end

T["apply"] = MiniTest.new_set()

local labels = { ["eq:a"] = "3.2", ["eq:b"] = "3.3", ["eq:c"] = "3.4" }

T["apply"]["labeled equation gets its number"] = function()
  local n = block("equation", "\\begin{equation}\n  a = b \\label{eq:a}\n\\end{equation}")
  L().apply({ n }, labels)
  eq(n.src, "\\begin{equation}\\tag{3.2}\n  a = b \\label{eq:a}\n\\end{equation}")
end

T["apply"]["starred, unlabeled, unknown label, display and inline stay"] = function()
  local cases = {
    block("equation*", "\\begin{equation*} a \\label{eq:a} \\end{equation*}"),
    block("equation", "\\begin{equation} a \\end{equation}"),
    block("equation", "\\begin{equation} a \\label{eq:zzz} \\end{equation}"),
    block("equation", "\\begin{equation} a \\tag{X}\\label{eq:a} \\end{equation}"),
    block("pmatrix", "\\begin{pmatrix} a \\label{eq:a} \\end{pmatrix}"),
    { id = "d", kind = "display", src = "a \\label{eq:a}", range = {} },
    { id = "i", kind = "inline", src = "a \\label{eq:a}", range = {} },
  }
  local before = vim.tbl_map(function(n) return n.src end, cases)
  L().apply(cases, labels)
  eq(vim.tbl_map(function(n) return n.src end, cases), before)
end

T["apply"]["align: per row, \\notag rows skipped"] = function()
  local n = block(
    "align",
    table.concat({
      "\\begin{align}",
      "  a &= b \\label{eq:a} \\\\",
      "  c &= d \\notag \\label{eq:b} \\\\",
      "  e &= f \\label{eq:c}",
      "\\end{align}",
    }, "\n")
  )
  L().apply({ n }, labels)
  eq(
    n.src,
    table.concat({
      "\\begin{align}\\tag{3.2}",
      "  a &= b \\label{eq:a} \\\\",
      "  c &= d \\notag \\label{eq:b} \\\\\\tag{3.4}",
      "  e &= f \\label{eq:c}",
      "\\end{align}",
    }, "\n")
  )
end

T["apply"]["the number is part of the cache key"] = function()
  local cache = require("inkmath.render.cache")
  local ctx = { color = "#ffffff", cell_w = 10, cell_h = 20, container_px = 800, macros = {} }
  local a = block("equation", "\\begin{equation} a \\label{eq:a} \\end{equation}")
  local b = vim.deepcopy(a)
  local k0 = cache.key(a, ctx, "mathjax")
  L().apply({ a }, labels)
  L().apply({ b }, { ["eq:a"] = "9" })
  eq(k0 ~= cache.key(a, ctx, "mathjax"), true)
  eq(cache.key(a, ctx, "mathjax") ~= cache.key(b, ctx, "mathjax"), true)
end

--- nested environments: the tag must stay at the outer level. Each case is also
--- rendered by the real MathJax worker, which rejects \tag inside split & co.
local NESTED = {
  {
    "equation+split",
    "equation",
    "\\begin{equation}\\begin{split}a&=b\\\\&=c\\label{eq:a}\\end{split}\\end{equation}",
    "\\begin{equation}\\tag{3.2}\\begin{split}a&=b\\\\&=c\\label{eq:a}\\end{split}\\end{equation}",
  },
  {
    "equation+aligned",
    "equation",
    "\\begin{equation}\n\\begin{aligned} a&=b \\\\ c&=d \\end{aligned} \\label{eq:a}\n\\end{equation}",
    "\\begin{equation}\\tag{3.2}\n\\begin{aligned} a&=b \\\\ c&=d \\end{aligned} \\label{eq:a}\n\\end{equation}",
  },
  {
    "equation+cases",
    "equation",
    "\\begin{equation} f = \\begin{cases} 1 & x \\\\ 0 & y \\label{eq:a} \\end{cases} \\end{equation}",
    "\\begin{equation}\\tag{3.2} f = \\begin{cases} 1 & x \\\\ 0 & y \\label{eq:a} \\end{cases} \\end{equation}",
  },
  {
    "align with a pmatrix row",
    "align",
    "\\begin{align} A &= \\begin{pmatrix} 1 \\\\ 2 \\end{pmatrix} \\label{eq:a} \\\\ b &= c \\label{eq:b} \\end{align}",
    "\\begin{align}\\tag{3.2} A &= \\begin{pmatrix} 1 \\\\ 2 \\end{pmatrix} \\label{eq:a} \\\\\\tag{3.3} b &= c \\label{eq:b} \\end{align}",
  },
  {
    "align with two labeled rows",
    "align",
    "\\begin{align} a &= b \\label{eq:a} \\\\ c &= d \\label{eq:b} \\end{align}",
    "\\begin{align}\\tag{3.2} a &= b \\label{eq:a} \\\\\\tag{3.3} c &= d \\label{eq:b} \\end{align}",
  },
  {
    "alignat argument kept",
    "alignat",
    "\\begin{alignat}{2} a &= b \\label{eq:a} \\end{alignat}",
    "\\begin{alignat}{2}\\tag{3.2} a &= b \\label{eq:a} \\end{alignat}",
  },
}

for _, c in ipairs(NESTED) do
  T["apply"]["nested: " .. c[1]] = function()
    local n = block(c[2], c[3])
    L().apply({ n }, labels)
    eq(n.src, c[4])
    if c[2] == "alignat" then return end
    local render = require("inkmath.render")
    local ctx = { color = "#ffffff", cell_w = 10, cell_h = 20, container_px = 800, macros = {} }
    local done, img, err
    render.render(n, ctx, function(i, e)
      done, img, err = true, i, e
    end, { no_fallback = true })
    vim.wait(30000, function() return done end, 20)
    eq(err, nil)
    eq(img ~= nil, true)
  end
end

T["parse"]["M8: only the first inner group, whitespace tolerated"] = function()
  local l = L().parse({
    "\\newlabel{a}{ {5}{1}}",
    "\\newlabel{b}{{6}{2}{Title {with} braces}{equation.6}{}}",
    "\\newlabel{c}{7}", -- malformed: no inner group
  })
  eq(l.a, "5")
  eq(l.b, "6")
  eq(l.c, nil)
end

T["parse"]["M3: merged labels cached by the aux stamps"] = function()
  local d = tmpdir()
  write(d .. "/main.aux", { "\\newlabel{eq:a}{{1}{1}}", "\\@input{one.aux}" })
  write(d .. "/one.aux", { "\\newlabel{eq:c}{{2}{4}}" })
  local a = L().read(d .. "/main.aux")
  eq(rawequal(L().read(d .. "/main.aux"), a), true)
  write(d .. "/one.aux", { "\\newlabel{eq:c}{{3}{4}}" })
  local st = vim.uv.fs_stat(d .. "/one.aux")
  vim.uv.fs_utime(d .. "/one.aux", st.atime.sec, st.mtime.sec + 5)
  local b = L().read(d .. "/main.aux")
  eq(rawequal(b, a), false)
  eq(b["eq:c"], "3")
end

-- without an .aux file, equations are numbered in document order (an align after an
-- equation continues the count), not each formula from (1)
T["numbering counts rows in document order"] = function()
  local starts = L().numbering({
    "\\begin{equation}",
    "a",
    "\\end{equation}", -- row 0: (1)
    "\\begin{equation*}",
    "b",
    "\\end{equation*}", -- unnumbered
    "\\begin{align}",
    "x &= 1 \\\\",
    "y &= 2 \\notag \\\\",
    "z &= 3",
    "\\end{align}", -- row 6: (2), (3)
    "% \\begin{equation} commented \\end{equation}",
    "\\begin{gather} p \\tag{A} \\\\ q \\end{gather}", -- row 12: (4) for q
    "\\begin{multline} m \\\\ n \\end{multline}", -- row 13: (5)
    "\\begin{equation}\\begin{split} s \\\\ t \\end{split}\\end{equation}", -- row 14: (6)
  })
  eq(starts, { [0] = 1, [6] = 2, [12] = 4, [13] = 5, [14] = 6 })
end

T["number injects document-order tags into unlabeled rows"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "\\begin{equation}", "a", "\\end{equation}", "\\begin{align}", "x \\\\ y \\nonumber \\\\ z", "\\end{align}" }
  )
  local function blk(srow, src, env) return { kind = "block", env = env, src = src, range = { srow = srow } } end
  local nodes = {
    blk(0, "\\begin{equation}\na\n\\end{equation}", "equation"),
    blk(3, "\\begin{align}\nx \\\\ y \\nonumber \\\\ z\n\\end{align}", "align"),
  }
  L().number(buf, nodes)
  eq(nodes[1].src, "\\begin{equation}\\tag{1}\na\n\\end{equation}")
  eq(nodes[2].src, "\\begin{align}\\tag{2}\nx \\\\ y \\nonumber \\\\\\tag{3} z\n\\end{align}")
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
