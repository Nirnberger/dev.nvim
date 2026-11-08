-- Environment matrix: which terminals count as kitty-graphics capable, and the tmux
-- passthrough check against a real (private) tmux server.
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local tmux = require("inkmath.term.tmux")
local kitty = require("inkmath.term.kitty")

local VARS = { "TERM", "TERM_PROGRAM", "KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR", "TMUX", "TMUX_PANE" }

--- Run fn with exactly `env` set for the terminal-detection variables.
local function with_env(env, fn)
  local saved = {}
  for _, k in ipairs(VARS) do
    saved[k] = vim.env[k]
    vim.env[k] = env[k]
  end
  kitty.forget()
  tmux.forget()
  local ok, res = pcall(fn)
  for _, k in ipairs(VARS) do
    vim.env[k] = saved[k]
  end
  kitty.forget()
  tmux.forget()
  assert(ok, res)
  return res
end

local TERMINALS = {
  { "ghostty (TERM_PROGRAM)", { TERM = "xterm-ghostty", TERM_PROGRAM = "ghostty" }, true },
  { "ghostty (TERM only)", { TERM = "xterm-ghostty" }, true },
  { "ghostty (resources dir)", { TERM = "xterm-256color", GHOSTTY_RESOURCES_DIR = "/x" }, true },
  { "kitty (TERM_PROGRAM)", { TERM = "xterm-kitty", TERM_PROGRAM = "kitty" }, true },
  { "kitty (TERM only)", { TERM = "xterm-kitty" }, true },
  { "kitty (window id)", { TERM = "xterm-256color", KITTY_WINDOW_ID = "3" }, true },
  { "wezterm", { TERM = "xterm-256color", TERM_PROGRAM = "WezTerm" }, false },
  { "alacritty", { TERM = "alacritty" }, false },
  { "iTerm2", { TERM = "xterm-256color", TERM_PROGRAM = "iTerm.app" }, false },
  { "Apple Terminal", { TERM = "xterm-256color", TERM_PROGRAM = "Apple_Terminal" }, false },
  { "VS Code", { TERM = "xterm-256color", TERM_PROGRAM = "vscode" }, false },
  { "linux console", { TERM = "linux" }, false },
  { "plain xterm", { TERM = "xterm" }, false },
  { "no TERM at all", {}, false },
}

for _, case in ipairs(TERMINALS) do
  local name, env, want = case[1], case[2], case[3]
  T["supported: " .. name] = function()
    eq(with_env(env, function() return kitty.supported() end), want)
  end
end

-- Real tmux ------------------------------------------------------------------------------

local function sh(argv)
  local out = vim.fn.system(argv)
  return vim.v.shell_error == 0, vim.trim(out)
end

local function stop_server(sock) sh({ "tmux", "-S", sock, "kill-server" }) end

--- A detached tmux server on a private socket; returns env for it, or nil (tmux missing).
local function start_server(sock, passthrough)
  if vim.fn.executable("tmux") ~= 1 then return nil end
  local ok = sh({
    "tmux",
    "-S",
    sock,
    "-f",
    "/dev/null",
    "new-session",
    "-d",
    "-s",
    "inkmath",
    "-x",
    "80",
    "-y",
    "24",
    "sleep 300",
  })
  if not ok then return nil end
  -- "all" needs tmux >= 3.4: a refused value skips the case rather than testing the default
  if not sh({ "tmux", "-S", sock, "set", "-g", "allow-passthrough", passthrough }) then
    stop_server(sock)
    return nil
  end
  local _, pane = sh({ "tmux", "-S", sock, "display", "-p", "-t", "inkmath", "#{pane_id}" })
  local _, pid = sh({ "tmux", "-S", sock, "display", "-p", "#{pid}" })
  return { TERM = "tmux-256color", TMUX = ("%s,%s,0"):format(sock, pid), TMUX_PANE = pane }
end

for _, case in ipairs({ { "on", true }, { "all", true }, { "off", false } }) do
  local value, want = case[1], case[2]
  T["real tmux: allow-passthrough " .. value] = function()
    local sock = vim.fn.tempname() .. ".sock"
    local env = start_server(sock, value)
    if not env then MiniTest.skip("tmux missing or too old for allow-passthrough " .. value) end
    local ok, got = pcall(with_env, env, function() return tmux.passthrough_enabled() end)
    stop_server(sock)
    assert(ok, got)
    eq(got, want)
  end
end

T["real tmux: pane-local option overrides the global one"] = function()
  local sock = vim.fn.tempname() .. ".sock"
  local env = start_server(sock, "off")
  if not env then MiniTest.skip("tmux not available") end
  sh({ "tmux", "-S", sock, "set", "-p", "-t", env.TMUX_PANE, "allow-passthrough", "on" })
  local ok, got = pcall(with_env, env, function() return tmux.passthrough_enabled() end)
  stop_server(sock)
  assert(ok, got)
  eq(got, true)
end

T["real tmux: no attached client means no kitty detection through tmux"] = function()
  local sock = vim.fn.tempname() .. ".sock"
  local env = start_server(sock, "on")
  if not env then MiniTest.skip("tmux not available") end
  local ok, got = pcall(with_env, env, function() return kitty.supported() end)
  stop_server(sock)
  assert(ok, got)
  eq(got, false)
end

return T
