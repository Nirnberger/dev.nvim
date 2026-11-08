-- inkmath in a real kitty under Xvfb. kitty runs a child Neovim that loads inkmath and opens a
-- markdown file with display math. Three readings of what kitty itself saw and drew:
--   1. --dump-commands: kitty parsed one a=T graphics command (U=1, PNG) for the image id
--   2. `kitty @ get-text --ansi`: the screen holds a rows x cols grid of U+10EEEE placeholders
--      whose fg color is that id and whose row/column diacritics count 0.. up
--   3. Xvfb's framebuffer (-fbdir, XWD): the placeholder cells have drawn pixels, an empty
--      row above them does not
-- Skips only when kitty or xvfb-run is missing; with INKMATH_REQUIRE_KITTY=1 (Linux CI) it fails instead.
local eq = MiniTest.expect.equality
local helpers = require("tests.helpers")
local DIA = require("inkmath.term.diacritics")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local PH = 0x10EEEE

local function need_tools()
  local missing = {}
  for _, exe in ipairs({ "kitty", "xvfb-run" }) do
    if vim.fn.executable(exe) ~= 1 then missing[#missing + 1] = exe end
  end
  if #missing == 0 then return end
  local msg = "missing: " .. table.concat(missing, ", ")
  if vim.env.INKMATH_REQUIRE_KITTY == "1" then error("INKMATH_REQUIRE_KITTY=1 but " .. msg) end
  MiniTest.skip(msg)
end

local DIA_INDEX = {}
for i, cp in ipairs(DIA) do
  DIA_INDEX[cp] = i - 1
end

--- One screen line of `get-text --ansi` -> list of cells { cp, fg = "r:g:b"|nil, dia = {..} }.
local function parse_line(line)
  local cells, fg = {}, nil
  local i, n = 1, #line
  while i <= n do
    local s, e, params = line:find("^\27%[([%d:;]*)m", i)
    if s then
      if params == "" or params == "0" then fg = nil end
      for p in (params .. ";"):gmatch("([^;]*);") do
        local rgb = p:match("^38:2:(%d+:%d+:%d+)$")
        if rgb then fg = rgb end
        if p == "39" then fg = nil end
      end
      i = e + 1
    else
      local len = vim.str_utf_end(line, i) + 1
      local cp = vim.fn.char2nr(line:sub(i, i + len - 1))
      if DIA_INDEX[cp] and #cells > 0 then
        table.insert(cells[#cells].dia, DIA_INDEX[cp])
      else
        cells[#cells + 1] = { cp = cp, fg = fg, dia = {} }
      end
      i = i + len
    end
  end
  return cells
end

--- Xvfb -fbdir file (XWD, 32 bpp) -> pixel(x, y) returning r, g, b.
local function read_xwd(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  local function u32(off)
    local a, b, c, d = data:byte(off + 1, off + 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  local hdr, w, h, lsb = u32(0), u32(16), u32(20), u32(28) == 0
  local bpp, bpl, ncolors = u32(44), u32(48), u32(76)
  assert(bpp == 32, "unexpected XWD bits per pixel " .. bpp)
  local base = hdr + ncolors * 12
  return w,
    h,
    function(x, y)
      local o = base + y * bpl + x * 4
      local b0, b1, b2, b3 = data:byte(o + 1, o + 4)
      if lsb then return b2, b1, b0 end
      return b1, b2, b3
    end
end

local T = MiniTest.new_set()

T["kitty: unicode placeholders, graphics command and drawn pixels"] = function()
  need_tools()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/fb", "p")
  local sock, doc, init = dir .. "/kitty.sock", dir .. "/doc.md", dir .. "/init.lua"
  vim.fn.writefile({ "# Title", "", "$$", "\\int_0^1 x^2 \\, dx = \\frac{1}{3}", "$$", "", "end" }, doc)
  vim.fn.writefile({
    ("vim.opt.runtimepath:prepend(%q)"):format(root),
    "vim.o.termguicolors = true",
    "vim.o.cmdheight = 1",
    [[require("inkmath").setup({})]],
    "vim.api.nvim_create_autocmd('VimEnter', { callback = function() vim.defer_fn(function()",
    "  local c = require('inkmath.term.cells').cell_size()",
    ("  vim.fn.writefile({ vim.json.encode(c or vim.NIL) }, %q)"):format(dir .. "/cells.json"),
    "end, 200) end })",
  }, init)

  local dump = {}
  local proc = vim.system({
    "xvfb-run",
    "-a",
    "-s",
    "-screen 0 1024x768x24 -fbdir " .. dir .. "/fb",
    "kitty",
    "--config",
    "NONE",
    "-o",
    "linux_display_server=x11",
    "-o",
    "allow_remote_control=socket-only",
    "-o",
    "initial_window_width=80c",
    "-o",
    "initial_window_height=24c",
    "-o",
    "window_padding_width=0",
    "--listen-on",
    "unix:" .. sock,
    "--dump-commands",
    "nvim",
    "-u",
    init,
    doc,
  }, {
    env = { TMUX = "", TMUX_PANE = "", SSH_CONNECTION = "", XDG_CACHE_HOME = dir .. "/cache" },
    stdout = function(_, d)
      if d then dump[#dump + 1] = d end
    end,
    stderr = function() end,
  })
  local function rc(args)
    local r = vim.system(vim.list_extend({ "kitty", "@", "--to", "unix:" .. sock }, args), { text = true }):wait(10000)
    return r.code == 0 and r.stdout or nil
  end
  local function stop()
    rc({ "close-window" })
    if proc:wait(5000).code == nil then proc:kill(9) end
  end

  local ok, err = pcall(function()
    -- 1. the screen: wait until the placeholder grid is there
    local screen
    local found = vim.wait(helpers.perf_factor * 20000, function()
      screen = vim.uv.fs_stat(sock) and rc({ "get-text", "--ansi" })
      return screen ~= nil and screen:find(vim.fn.nr2char(PH), 1, true) ~= nil
    end, 200)
    assert(found, "no placeholders on the kitty screen:\n" .. tostring(screen))

    local lines = vim.split(screen, "\n", { plain = true })
    local grid = {} ---@type {line:integer, cells:table[]}[]
    for li, line in ipairs(lines) do
      local cells = parse_line(line)
      local ph = vim.tbl_filter(function(c) return c.cp == PH end, cells)
      if #ph > 0 then grid[#grid + 1] = { line = li, cells = ph } end
    end
    eq(lines[1]:gsub("\27%[[%d:;]*m", ""):match("^(%S+ %S+)"), "# Title")

    -- 2. kitty's parser: the graphics command for this image
    local cmd
    for _, rec in ipairs(vim.split(table.concat(dump), "\n", { plain = true })) do
      local json = rec:match("^graphics_command (%b{})")
      if json then
        local c = vim.json.decode(json)
        if c.action == "T" then cmd = c end
      end
    end
    assert(cmd, "kitty saw no a=T graphics command")
    eq({ cmd.unicode_placement, cmd.format, cmd.transmission_type }, { 1, 100, "f" })
    local want_fg = ("%d:%d:%d"):format(math.floor(cmd.id / 65536) % 256, math.floor(cmd.id / 256) % 256, cmd.id % 256)

    -- the grid: num_lines rows of num_cells placeholders, colored with the id, diacritics 0..
    eq(#grid, cmd.num_lines)
    for r, row in ipairs(grid) do
      eq(row.line, grid[1].line + r - 1)
      eq(#row.cells, cmd.num_cells)
      for c, cell in ipairs(row.cells) do
        eq(cell.fg, want_fg)
        eq(cell.dia, { r - 1, c - 1 })
      end
    end

    -- 3. pixels: placeholder cells were drawn, the empty line above them stays background
    local cs
    vim.wait(5000, function()
      local okj, v = pcall(vim.json.decode, table.concat(vim.fn.readfile(dir .. "/cells.json")))
      cs = okj and v or nil
      return cs ~= nil
    end, 50)
    assert(type(cs) == "table" and cs.w > 0, "child reported no cell size")
    local function count(px, y0, y1, x1, bg)
      local n = 0
      for y = y0, y1 - 1, 2 do
        for x = 0, x1 - 1, 2 do
          local r, g, b = px(x, y)
          if math.abs(r - bg[1]) + math.abs(g - bg[2]) + math.abs(b - bg[3]) > 60 then n = n + 1 end
        end
      end
      return n
    end
    local empty = grid[1].line - 1 -- line 2 of the file, 1-based screen line
    local img_y0, img_y1 = (grid[1].line - 1) * cs.h, grid[#grid].line * cs.h
    local inked, blank
    vim.wait(helpers.perf_factor * 5000, function()
      local _, _, px = read_xwd(dir .. "/fb/Xvfb_screen0")
      local bg = { px(cs.w * 2, (empty - 1) * cs.h + 2) }
      blank = count(px, (empty - 1) * cs.h, empty * cs.h, cmd.num_cells * cs.w, bg)
      inked = count(px, img_y0, img_y1, cmd.num_cells * cs.w, bg)
      return inked > 50
    end, 200)
    MiniTest.add_note(
      ("kitty: id=%d grid=%dx%d cell=%dx%d inked=%d blank=%d"):format(
        cmd.id,
        cmd.num_cells,
        cmd.num_lines,
        cs.w,
        cs.h,
        inked,
        blank
      )
    )
    assert(inked > 50, ("image cells not drawn (%d inked samples)"):format(inked))
    eq(blank, 0)
  end)
  stop()
  vim.fn.delete(dir, "rf")
  assert(ok, err)
end

return T
