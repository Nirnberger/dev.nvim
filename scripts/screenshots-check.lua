-- Used by scripts/screenshots.sh: did kitty draw every image whose placeholders are on screen?
-- Usage: nvim -l scripts/screenshots-check.lua <root> <screen> <xwd> <cell_w> <cell_h> <bg rrggbb>
--   <screen>: `kitty @ get-text --ansi --add-wrap-markers` (one \r per soft wrap); <xwd>: Xvfb's framebuffer (-fbdir)
-- Exit 0 when each image id (placeholder fg color) has pixels unlike <bg> inside its cells and
-- at least one placeholder is on screen; otherwise prints the blank ids and exits 1.
local root, screen_file, xwd, cw, ch, bg_hex = unpack(_G.arg)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
cw, ch = tonumber(cw), tonumber(ch)
local bg = { tonumber(bg_hex:sub(1, 2), 16), tonumber(bg_hex:sub(3, 4), 16), tonumber(bg_hex:sub(5, 6), 16) }
local PH = 0x10EEEE

local DIA = {}
for _, cp in ipairs(require("inkmath.term.diacritics")) do
  DIA[cp] = true
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

-- image id (fg "r:g:b") -> list of { row, col } (0-based cells)
local cells = {}
-- soft-wrapped lines come joined, with \r where kitty wrapped them: one screen row each
local text = (read(screen_file) or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
local row = 0
for line in (text .. "\n"):gmatch("([^\n]*)\n") do
  local col, fg, i = -1, nil, 1
  while i <= #line do
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
      if not DIA[cp] then
        col = col + 1
        if cp == PH and fg then
          cells[fg] = cells[fg] or {}
          table.insert(cells[fg], { row, col })
        end
      end
      i = i + len
    end
  end
  row = row + 1
end
if next(cells) == nil then
  print("no placeholder cells on screen")
  os.exit(1)
end

local data = read(xwd)
if not data or #data < 100 then
  print("no framebuffer at " .. xwd)
  os.exit(1)
end
local function u32(off)
  local a, b, c, d = data:byte(off + 1, off + 4)
  return ((a * 256 + b) * 256 + c) * 256 + d
end
local hdr, lsb, bpp, bpl, ncolors = u32(0), u32(28) == 0, u32(44), u32(48), u32(76)
assert(bpp == 32, "unexpected XWD bits per pixel " .. bpp)
local base = hdr + ncolors * 12
local function inked(x, y)
  local b0, b1, b2, b3 = data:byte(base + y * bpl + x * 4 + 1, base + y * bpl + x * 4 + 4)
  local r, g, b
  if lsb then
    r, g, b = b2, b1, b0
  else
    r, g, b = b1, b2, b3
  end
  return math.abs(r - bg[1]) + math.abs(g - bg[2]) + math.abs(b - bg[3]) > 60
end

local blank = {}
for id, list in pairs(cells) do
  local found = false
  for _, c in ipairs(list) do
    for y = c[1] * ch, (c[1] + 1) * ch - 1 do
      for x = c[2] * cw, (c[2] + 1) * cw - 1 do
        if inked(x, y) then
          found = true
          break
        end
      end
      if found then break end
    end
    if found then break end
  end
  if not found then blank[#blank + 1] = ("%s (%d cells)"):format(id, #list) end
end
if #blank > 0 then
  table.sort(blank)
  print("images not drawn, by placeholder color: " .. table.concat(blank, ", "))
  os.exit(1)
end
