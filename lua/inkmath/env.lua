-- The environment inkmath needs (kitty graphics, tmux passthrough, a render backend,
-- 'termguicolors'): checked on attach, each failure warned once per cause with a
-- pointer to :checkhealth; rearm() checks again and lets the warnings fire again.
local log = require("inkmath.log")

local M = {}

M.CAUSES = { "kitty", "tmux", "termguicolors", "backend", "cell_size" }

-- At most M.MAX_MSG characters: a message wider than v:echospace (80 columns minus
-- the showcmd area: 68) makes Neovim wait for Enter, which on startup blocks
-- opening the file.
M.MAX_MSG = 64
local function warn(cause, msg) log.once(cause, "inkmath: " .. msg .. " (:checkhealth inkmath)") end

--- Can images be shown? (kitty and tmux memoize their shell-outs.)
---@return {mathjax: boolean, tectonic: boolean}|nil backends, nil when not
function M.check()
  local b, why = require("inkmath.term.backend").detect()
  if not b then
    return warn("kitty", why == "disabled by term.backend" and "term.backend is none" or "no kitty graphics here")
  end
  local tmux = require("inkmath.term.tmux")
  if tmux.in_tmux() and not tmux.passthrough_enabled() then return warn("tmux", "tmux needs allow-passthrough") end
  local av = require("inkmath.render").available()
  if not (av.mathjax or av.tectonic) then return warn("backend", "no renderer, run :InkMath build") end
  if not vim.o.termguicolors then
    -- image ids travel in the placeholder's fg #RRGGBB; 256-color output breaks them
    warn("termguicolors", "set 'termguicolors'")
  end
  return av
end

--- The environment may have been fixed (or broken) since: check the terminal, tmux and
--- the backend again and let their warnings fire again (FocusGained, :InkMath refresh).
function M.rearm()
  for _, cause in ipairs(M.CAUSES) do
    log.rearm(cause)
  end
  require("inkmath.term.kitty").forget()
  require("inkmath.term.backend").reset()
  require("inkmath.term.tmux").forget()
  require("inkmath.render.mathjax")._reset_available()
end

return M
