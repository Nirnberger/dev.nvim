-- Pixel checks for the overlay backends in real terminals (tests/test_terminals_real.lua,
-- scripts/realterm-check.lua). Screens come from scripts/realterm.sh shot as binary PPM.
local M = {}

--- Binary PPM (P6, maxval 255) -> width, height, pixel(x, y) returning r, g, b.
---@param path string
---@return integer|nil w
---@return integer|nil h
---@return (fun(x: integer, y: integer): integer, integer, integer)|nil
function M.read_ppm(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  -- header: P6 <ws> w <ws> h <ws> maxval <one ws>, comments start with #
  local fields, pos = {}, 1
  while #fields < 4 do
    local s, e, tok = data:find("^%s*([^%s#]+)", pos)
    if not s then
      local cs, ce = data:find("^%s*#[^\n]*\n", pos)
      if not cs then return nil end
      pos = ce + 1
    else
      fields[#fields + 1] = tok
      pos = e + 1
    end
  end
  local w, h, max = tonumber(fields[2]), tonumber(fields[3]), tonumber(fields[4])
  if fields[1] ~= "P6" or not w or not h or max ~= 255 then return nil end
  local base = pos + 1 -- one whitespace byte after maxval
  if #data < base - 1 + w * h * 3 then return nil end
  return w, h, function(x, y)
    local o = base + (y * w + x) * 3
    return data:byte(o, o + 2)
  end
end

--- Samples (every 2nd pixel) in [x0, x1) x [y0, y1) that differ from `bg`, and how many were taken.
function M.ink(px, x0, y0, x1, y1, bg)
  local n, total = 0, 0
  for y = y0, y1 - 1, 2 do
    for x = x0, x1 - 1, 2 do
      local r, g, b = px(x, y)
      total = total + 1
      if math.abs(r - bg[1]) + math.abs(g - bg[2]) + math.abs(b - bg[3]) > 60 then n = n + 1 end
    end
  end
  return n, total
end

--- Per painted image: inked samples inside its cells, and in the screen row above it over the
--- same columns (an empty line in the test document). Both regions keep a quarter cell away from
--- their edges, so a window off by a few pixels does not mix them up.
---@param ready table the ready file of scripts/screenshots-init.lua
---@param ppm string
---@return {id: integer, inked: integer, samples: integer, above: integer}[]|nil results nil: no readable screen
function M.measure(ready, ppm)
  local w, h, px = M.read_ppm(ppm)
  if not px then return nil end
  local cw, ch = ready.cell.w, ready.cell.h
  local mx, my = math.floor(cw / 4), math.floor(ch / 4)
  local out = {}
  for _, p in ipairs(ready.paints) do
    local x0, y0 = (p.col - 1) * cw, (p.row - 1) * ch
    local x1, y1 = math.min(w, x0 + p.cols * cw), math.min(h, y0 + p.rows * ch)
    -- background: the first cell of the row above the image
    local bg = { px(x0 + mx, math.max(0, y0 - ch + my)) }
    local inked, samples = M.ink(px, x0 + mx, y0 + my, x1 - mx, y1 - my, bg)
    out[#out + 1] = {
      id = p.id,
      inked = inked,
      samples = samples,
      above = p.row > 1 and M.ink(px, x0 + mx, y0 - ch + my, x1 - mx, y0 - my, bg) or 0,
      bg = bg,
    }
  end
  return out
end

--- Which cells of the top left `cols` x `rows` have ink: one string per row, '#' inked, '.' not
--- (diagnostics in failure messages, the CI keeps no screen images of the tests).
---@return string
function M.cellmap(ppm, cw, ch, cols, rows, bg)
  local w, h, px = M.read_ppm(ppm)
  if not px then return "(no screen)" end
  local out = {}
  for r = 0, rows - 1 do
    local line = {}
    for c = 0, cols - 1 do
      local x0, y0 = c * cw, r * ch
      local n = (x0 + cw <= w and y0 + ch <= h) and M.ink(px, x0, y0, x0 + cw, y0 + ch, bg) or 0
      line[#line + 1] = n >= 2 and "#" or "."
    end
    out[#out + 1] = table.concat(line)
  end
  local r, g, b = px(w - 1, h - 1)
  return ("screen %dx%d, corner pixel %d,%d,%d, bg %d,%d,%d\n%s"):format(
    w,
    h,
    r,
    g,
    b,
    bg[1],
    bg[2],
    bg[3],
    table.concat(out, "\n")
  )
end

--- Is every painted image drawn? At least 3 inked samples and 0.5 % of them: a formula is thin
--- strokes (display math is centered in a wide box), an inline one only a few cells.
---@return boolean ok
---@return string why
function M.drawn(ready, ppm)
  local res = M.measure(ready, ppm)
  if not res then return false, "no readable screen at " .. ppm end
  if #res == 0 then return false, "no paints recorded" end
  local blank = {}
  for _, r in ipairs(res) do
    if r.inked < math.max(3, r.samples * 0.005) then
      blank[#blank + 1] = ("id %d (%d of %d inked)"):format(r.id, r.inked, r.samples)
    end
  end
  if #blank > 0 then return false, "blank: " .. table.concat(blank, ", ") end
  return true, ""
end

return M
