-- The overlay backends in real terminals (scripts/realterm.sh): xterm -ti vt340 and foot (Sixel),
-- WezTerm (kitty graphics overlay, and OSC 1337 with term.backend = "iterm2"), Konsole (kitty
-- graphics overlay). Each runs a child Neovim (scripts/screenshots-init.lua) with inkmath on a
-- markdown file with display math; the child records where the backend painted each image.
--   1. the child picked the expected backend in overlay mode and painted at least one image
--   2. pixels (Xvfb framebuffer, or grim under sway headless): the painted cells are drawn,
--      the empty line above them is not
--   3. WezTerm only (`wezterm cli get-text`): the title is there, the image cells hold no text
--      and no escape sequence leaked onto the screen
--   4. negative control: the same run with the image left out of every paint
--      (INKMATH_SHOT_BREAK=1) must fail the pixel check
-- Skips when the terminal is missing; INKMATH_REQUIRE_<TERM>=1 (Linux CI, scripts/ci-tools.sh)
-- makes that a failure. Real iTerm2 is not tested: it needs a macOS GUI session with screen
-- recording rights, which hosted runners do not give; WezTerm speaks the same OSC 1337.
local eq = MiniTest.expect.equality
local helpers = require("tests.helpers")
local realterm = require("tests.realterm")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local script = root .. "/scripts/realterm.sh"

-- known failures: terminal name -> reason. The test still runs; a failure is reported as a
-- skip with this reason, a pass is an error (remove the entry).
local KNOWN = {}

local CASES = {
  { name = "xterm", term = "xterm", backend = "sixel" },
  { name = "foot", term = "foot", backend = "sixel" },
  { name = "wezterm", term = "wezterm", backend = "kitty" },
  { name = "wezterm-iterm2", term = "wezterm", backend = "iterm2", force = "iterm2" },
  { name = "konsole", term = "konsole", backend = "kitty" },
}

local function need(t)
  if vim.fn.has("linux") == 0 then MiniTest.skip("Linux only") end
  local r = vim.system({ "bash", script, "need", t.term }, { text = true }):wait()
  if r.code == 0 then return end
  local msg = vim.trim(r.stdout .. r.stderr)
  local var = "INKMATH_REQUIRE_" .. t.term:upper()
  if vim.env[var] == "1" then error(var .. "=1 but " .. msg) end
  MiniTest.skip(t.term .. ": " .. msg)
end

local function read_json(path)
  local ok, v = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) end)
  return ok and v or nil
end

--- Start the terminal with the child Neovim; returns a session with ready(), shot(), text(), stop().
local function launch(t, dir, doc, broken)
  local log = {}
  local proc = vim.system({
    "bash",
    script,
    "run",
    t.term,
    dir,
    "80",
    "24",
    "nvim",
    "--noplugin",
    "-u",
    root .. "/scripts/screenshots-init.lua",
    doc,
  }, {
    detach = true, -- own process group: stop() kills the terminal, its display server and the child
    env = {
      INKMATH_ROOT = root,
      INKMATH_SHOT_READY = dir .. "/ready.json",
      INKMATH_SHOT_BACKEND = t.force or "auto",
      INKMATH_SHOT_BREAK = broken and "1" or "0",
      XDG_CACHE_HOME = dir .. "/cache",
    },
    stdout = function(_, d)
      if d then log[#log + 1] = d end
    end,
    stderr = function(_, d)
      if d then log[#log + 1] = d end
    end,
  })
  local s = { log = log }
  function s.ready()
    local ready
    vim.wait(helpers.perf_factor * 30000, function()
      ready = read_json(dir .. "/ready.json")
      return ready ~= nil or proc:is_closing()
    end, 100)
    return ready
  end
  function s.shot()
    local out = dir .. "/screen.ppm"
    local r = vim.system({ "bash", script, "shot", t.term, dir, out }):wait(10000)
    return r.code == 0 and out or nil
  end
  function s.text()
    local r = vim.system({ "bash", script, "text", t.term, dir }, { text = true }):wait(10000)
    return r.code == 0 and r.stdout or nil
  end
  function s.stop()
    pcall(vim.uv.kill, -proc.pid, "sigterm")
    if not vim.wait(3000, function() return proc:is_closing() end, 50) then pcall(vim.uv.kill, -proc.pid, "sigkill") end
    pcall(proc.wait, proc, 2000)
  end
  function s.dump()
    local inner = vim.uv.fs_stat(dir .. "/inner.log") and table.concat(vim.fn.readfile(dir .. "/inner.log"), "\n") or ""
    local rc = proc:is_closing() and proc:wait(0) or nil
    return ("%s\n[terminal %s, %s]"):format(
      table.concat(log):sub(-3000),
      rc and ("exited code=%s signal=%s"):format(rc.code, rc.signal) or "still running",
      inner ~= "" and inner or "inner command did not exit"
    )
  end
  return s
end

local DOC = { "# Title", "", "$$", "\\int_0^1 x^2 \\, dx = \\frac{1}{3}", "$$", "", "end" }

--- One run: wait for the ready file, then poll the screen until `want(results)` or the timeout.
local function run(t, broken, want, timeout)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local doc = dir .. "/doc.md"
  vim.fn.writefile(DOC, doc)
  local s = launch(t, dir, doc, broken)
  local ok, res = pcall(function()
    local ready = s.ready()
    assert(ready, "no ready file from the child Neovim; terminal output:\n" .. s.dump())
    local out = { ready = ready }
    vim.wait(timeout, function()
      local ppm = s.shot()
      out.measure = ppm and realterm.measure(ready, ppm) or nil
      return out.measure ~= nil and want(out.measure)
    end, 200)
    out.text = s.text()
    return out
  end)
  s.stop()
  vim.fn.delete(dir, "rf")
  assert(ok, res)
  return res
end

local function all_drawn(m)
  if #m == 0 then return false end
  for _, r in ipairs(m) do
    if r.inked <= 50 then return false end
  end
  return true
end

local function check(t)
  -- 1.-3. the real run
  local res = run(t, false, all_drawn, helpers.perf_factor * 10000)
  local ready, m = res.ready, res.measure
  eq({ ready.backend, ready.mode }, { t.backend, "overlay" })
  assert(#ready.paints > 0, "nothing painted: " .. vim.json.encode(ready))
  assert(m, "no readable screen")
  local notes = {}
  for _, r in ipairs(m) do
    notes[#notes + 1] = ("id=%d inked=%d above=%d"):format(r.id, r.inked, r.above)
  end
  MiniTest.add_note(
    ("%s: backend=%s cell=%dx%d %s"):format(t.name, ready.backend, ready.cell.w, ready.cell.h, table.concat(notes, " "))
  )
  for _, r in ipairs(m) do
    assert(r.inked > 50, ("%s: image %d not drawn (%d inked samples)"):format(t.name, r.id, r.inked))
    eq(r.above, 0)
  end
  if t.term == "wezterm" then
    local text = assert(res.text, "wezterm cli get-text gave nothing")
    local lines = vim.split(text, "\n", { plain = true })
    assert(lines[1]:find("# Title", 1, true), "no title on screen:\n" .. text)
    for _, bad in ipairs({ "\27", "1337", "_G", "Ga=", "File=" }) do
      assert(not text:find(bad, 1, true), ("escape leftover %q on screen:\n%s"):format(bad, text))
    end
    for _, p in ipairs(ready.paints) do
      for row = p.row, p.row + p.rows - 1 do
        local cells = vim.fn.strcharpart(lines[row] or "", p.col - 1, p.cols)
        assert(vim.trim(cells) == "", ("text under image %d, screen row %d: %q"):format(p.id, row, lines[row]))
      end
    end
  end
  -- 4. negative control: the same paints without image data leave the cells blank
  local bad = run(t, true, function() return false end, helpers.perf_factor * 2000)
  assert(bad.measure, "no readable screen in the negative control")
  for _, r in ipairs(bad.measure) do
    assert(
      r.inked <= 50,
      ("%s: negative control drew %d samples: the pixel check proves nothing"):format(t.name, r.inked)
    )
  end
  MiniTest.add_note(("%s: negative control blank (%d images)"):format(t.name, #bad.measure))
end

local T = MiniTest.new_set()

for _, t in ipairs(CASES) do
  T[t.name .. ": " .. t.backend .. " overlay draws the image in the real terminal"] = function()
    need(t)
    if not KNOWN[t.name] then return check(t) end
    local ok, err = pcall(check, t)
    if ok then error(t.name .. " passes now: remove it from KNOWN in " .. debug.getinfo(1, "S").source) end
    MiniTest.skip(("KNOWN FAILURE %s (%s): %s"):format(t.name, KNOWN[t.name], tostring(err):sub(1, 300)))
  end
end

return T
