local M = {}

--- a command from the config (`node_cmd`, ...) or a plain name
---@param cmd string|string[]
---@return string[]|nil argv
local function exe(cmd, required_for)
  local argv = require("inkmath.render").argv(cmd)
  local name = type(cmd) == "string" and cmd or table.concat(cmd, " ")
  if argv then
    vim.health.ok(name .. " found: " .. argv[1])
    return argv
  end
  vim.health.warn(name .. " not found (" .. required_for .. ")")
end

--- language.add returns nil, err for a missing parser.
---@param lang string
---@return boolean ok, string|nil err
function M._parser_ok(lang)
  local ok, res, err = pcall(vim.treesitter.language.add, lang)
  if not ok then return false, tostring(res) end
  if res == true then return true, nil end
  return false, err or "parser not found"
end

---@return string|nil
function M._tmux_termfeatures()
  if vim.fn.executable("tmux") ~= 1 then return nil end
  local res = vim.system({ "tmux", "display", "-p", "#{client_termfeatures}" }, { text = true }):wait(2000)
  if res.code ~= 0 then return nil end
  return vim.trim(res.stdout or "")
end

---@class inkmath.InteropLine
---@field level "ok"|"warn"|"info"
---@field msg string
---@field fix? string advice (a config snippet)

--- inkmath writes 'conceallevel' for some filetype it shares with render-markdown or
--- markview (the global config, or an override of a markdown-like filetype)
local function conceal_managed()
  local config = require("inkmath.config")
  local registry = require("inkmath.detect.registry")
  for _, ft in ipairs(config.get().filetypes) do
    local spec = registry.get(ft)
    if (not spec or spec.lang == "markdown") and config.for_ft(ft).conceal ~= false then return true end
  end
  return false
end

--- 'conceallevel' of the windows showing attached buffers
local function conceal_lines(out)
  local core = package.loaded["inkmath.core"]
  if not core then return end
  local config = require("inkmath.config")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if core.is_attached(b) then
      local c = config.get(b).conceal
      for _, w in ipairs(vim.fn.win_findbuf(b)) do
        local cl = vim.wo[w].conceallevel
        if vim.api.nvim_win_get_config(w).relative == "" and cl < 2 then
          local why = c == false and "inkmath does not manage it (conceal = false): set it to 2, e.g. in an ftplugin"
            or ("inkmath sets conceal.level = %d"):format(c.level)
          out[#out + 1] = {
            level = "warn",
            msg = ("'conceallevel' %d < 2 in window %d (buffer %d): concealed source shows next to the images; %s"):format(
              cl,
              w,
              b,
              why
            ),
          }
        end
      end
    end
  end
end

--- Checks against other plugins (also :checkhealth inkmath); testable without vim.health.
---@return inkmath.InteropLine[]
function M._interop()
  local out = {}
  local managers = {}
  for _, p in ipairs(require("inkmath.interop").plugins) do
    if p.loaded() then
      local on = p.latex_on()
      if on == nil then
        out[#out + 1] = {
          level = "warn",
          msg = p.name .. " is loaded; make sure latex is off (inkmath renders the math)",
          fix = p.fix,
        }
      elseif on then
        out[#out + 1] = { level = "warn", msg = p.name .. " renders LaTeX math too: turn it off there", fix = p.fix }
      else
        out[#out + 1] = { level = "ok", msg = p.name .. ": its LaTeX rendering is off" }
      end
      if p.manages then managers[#managers + 1] = p.name end
    end
  end
  if package.loaded["image"] then
    out[#out + 1] = {
      level = "info",
      msg = "image.nvim deletes every terminal image (d=a) when it clears its own;"
        .. " inkmath sends its images again on FocusGained and VimResized",
    }
  end
  if #managers > 0 and conceal_managed() then
    out[#out + 1] = {
      level = "info",
      msg = table.concat(managers, " and ")
        .. (#managers > 1 and " set" or " sets")
        .. " 'conceallevel' too; consider `conceal = false` so inkmath leaves it to them",
    }
  end
  conceal_lines(out)
  return out
end

function M.check()
  local h = vim.health
  h.start("inkmath")
  if vim.fn.has("nvim-0.12") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.12 required")
  end

  for _, lang in ipairs({ "latex", "markdown", "markdown_inline" }) do
    local ok, err = M._parser_ok(lang)
    if ok then
      h.ok("treesitter parser: " .. lang)
    else
      h.error("treesitter parser missing: " .. lang .. " (" .. tostring(err) .. "; :TSInstall " .. lang .. ")")
    end
  end

  local tmux = require("inkmath.term.tmux")
  local backend, why = require("inkmath.term.backend").detect()
  if backend then
    if backend.mode == "placeholder" then
      h.ok("terminal supports kitty graphics")
    else
      h.ok(
        ("terminal graphics: %s without Unicode placeholders, overlay mode (images can flicker, floats may cover them)"):format(
          backend.name
        )
      )
    end
  elseif why == "disabled by term.backend" then
    h.error("terminal graphics disabled by term.backend = 'none'")
  else
    h.error("terminal has no supported graphics protocol (kitty/Ghostty, WezTerm, Konsole, iTerm2, Sixel terminals)")
  end
  if vim.o.termguicolors then
    h.ok("'termguicolors' is on")
  else
    h.error("'termguicolors' is off: image ids are sent as 24-bit colors (`:set termguicolors`)")
  end
  if tmux.in_tmux() then
    if tmux.passthrough_enabled() then
      h.ok("tmux allow-passthrough is on")
    else
      h.error("tmux: add `set -g allow-passthrough on` to tmux.conf")
    end
    local feats = M._tmux_termfeatures()
    if feats and feats:find("RGB", 1, true) then
      h.ok("tmux client has the RGB terminal feature")
    elseif feats then
      h.error("tmux client lacks the RGB feature (truecolor): add `set -as terminal-features ',*:RGB'` to tmux.conf")
    else
      h.warn("could not query tmux client_termfeatures")
    end
  end

  local worker = require("inkmath").worker_dir
  local cfg = require("inkmath.config").get()
  if exe(cfg.node_cmd, "MathJax backend") then
    if vim.uv.fs_stat(worker .. "/node_modules") then
      h.ok("worker dependencies installed")
    else
      h.warn("worker/node_modules missing: run :InkMath build")
    end
  end

  local tectonic = exe(cfg.tectonic_cmd, "fallback backend")
  if tectonic then
    local res = vim.system(vim.list_extend(tectonic, { "-Z", "help" }), { text = true }):wait(10000)
    local out = (res.stdout or "") .. (res.stderr or "")
    if res.code == 0 and out:find("continue-on-errors", 1, true) then
      h.ok("tectonic supports -Z continue-on-errors")
    else
      h.warn("could not confirm tectonic supports -Z continue-on-errors (the fallback relies on it)")
    end
  end
  exe(cfg.magick_cmd, "tectonic fallback: PDF to PNG")
  exe("gs", "tectonic fallback: PDF rendering")

  local ok, cs = pcall(require("inkmath.term.cells").cell_size)
  if ok and cs then
    h.ok(string.format("cell size: %dx%d px", cs.w, cs.h))
  else
    h.warn("could not detect cell size (set `cell_size` in setup)")
  end

  local id_lo, id_hi = require("inkmath.term.images").range()
  h.info(("kitty image ids: %d..%d (image_ids)"):format(id_lo, id_hi - 1))

  h.start("inkmath: other plugins")
  local lines = M._interop()
  if #lines == 0 then h.ok("no conflicting plugin loaded") end
  for _, l in ipairs(lines) do
    if l.level == "warn" then
      h.warn(l.msg, l.fix and { l.fix } or nil)
    else
      h[l.level](l.msg)
    end
  end
end

return M
