# inkmath.nvim — Design Spec

Date: 2026-11-07
Status: Approved design, awaiting spec review

## 1. Goal

Render LaTeX math as real typeset images directly inside the Neovim buffer, smoothly
(no flicker, never blocking typing), for inline, display, and multi-line math.

### Agreed requirements (from user)

- Rendering style: real images (not Unicode substitution).
- File types (v1): LaTeX (`.tex`) and Markdown (`.md`).
- Must handle all three cases: inline `$…$`, display (`$$…$$`, `\[…\]`, `equation`),
  and multi-line (`align`, `gather`, `cases`, matrices, plain `\\` in `$$` blocks) —
  explicitly covering the gaps of snacks.nvim's image module.
- Environment: Ghostty inside tmux, macOS.
- Editing UX: everything rendered except the formula under the cursor, which shows its
  source plus a live preview float.
- Approach: own plugin; MathJax (node, long-lived worker) as fast default backend,
  tectonic as high-fidelity fallback.
- Development and testing happen in an isolated Neovim build (`NVIM_APPNAME=inkmath-dev`);
  the user's main config (`~/.config/nvim`) is not touched until they opt in.

### Assumptions

- Smoothness has priority over feature breadth.
- Colors match the active colorscheme (user runs tokyonight).
- Coexists with vimtex; does not replace it.
- Neovim ≥ 0.11 (needed for `conceal_lines`); user has 0.12.5.

### Non-goals (v1)

- Typst, org, norg, or math in code comments.
- Terminals other than Ghostty/kitty (no Sixel/iTerm protocol, no Unicode fallback renderer).
- TikZ/figures; only math.
- Editing the rendered image or WYSIWYG input.

## 2. Architecture

Plugin name: `inkmath.nvim`.

```
lua/inkmath/
  init.lua          setup(), user commands
  config.lua        defaults + validation
  health.lua        :checkhealth inkmath
  detect/
    init.lua        dispatch by filetype; returns MathNode list
    latex.lua       treesitter `latex` parser
    markdown.lua    treesitter `markdown_inline` (latex_block) + `$$` block scanner
  render/
    init.lua        backend selection + fallback chain, async job queue
    mathjax.lua     client for the node worker (JSON lines over stdio)
    tectonic.lua    batch renderer: formulas → standalone PDF → PNG per page
    cache.lua       content-addressed PNG cache on disk + in-memory index
    macros.lua      extract \newcommand/\def/\DeclareMathOperator/\let from preamble
  term/
    kitty.lua       kitty graphics protocol: transmit, placeholders, delete
    tmux.lua        passthrough wrapping, detection
    cells.lua       cell pixel size detection, scaling helpers
  view/
    placer.lua      extmark placement (inline + display/block)
    cursor.lua      reveal-under-cursor + live preview float
    state.lua       per-buffer state: nodes, placements, image ids
worker/
  mathjax.mjs       mathjax-full TeX→SVG, @resvg/resvg-js SVG→PNG
  package.json
dev/
  init.lua          minimal isolated config for NVIM_APPNAME=inkmath-dev
  run.sh            launch test build (optionally in isolated tmux server)
  samples/          sample .tex and .md files covering all cases
tests/              mini.test specs (headless)
worker/test/        node --test specs
```

### Core data type

```lua
---@class inkmath.MathNode
---@field id string        hash of (kind, src, env) — stable across edits elsewhere in the buffer
---@field kind "inline"|"display"|"block"
---@field src string       TeX source without delimiters
---@field env? string      environment name for block math (align, gather, …)
---@field range {srow:integer, scol:integer, erow:integer, ecol:integer} 0-based, end-exclusive
```

### Data flow

1. Trigger: `BufEnter`, `TextChanged`, `TextChangedI`, `WinScrolled`, `ColorScheme`,
   `VimResized`, `FocusGained`, `VimResume`. Debounced 80 ms (50 ms for live preview).
2. Detect math nodes in the visible window range ± 1 screen of margin.
3. Diff against current placements in `view/state.lua` (by node id + range).
4. Cache hit → place immediately. Cache miss → enqueue async render; existing image
   (if any) stays in place until the new one is ready (no flicker).
5. Render result → transmit image to terminal (once per image id) → place extmarks.

All rendering is async (`vim.system` / worker stdio callbacks). The main loop never
waits on a renderer.

## 3. Detection

### LaTeX (`latex` treesitter parser)

- Inline: `inline_formula` (`$…$`, `\(…\)`).
- Display: `displayed_equation` (`$$…$$`, `\[…\]`).
- Block: `math_environment` (`equation`, `equation*`, `align`, `align*`, `gather`,
  `gather*`, `multline`, `multline*`, `flalign`, `alignat`). The full environment is
  passed to the renderer; starred/unstarred controls numbering display.
- Preamble (text before `\begin{document}`) is scanned by `render/macros.lua`.

### Markdown (`markdown` + `markdown_inline` parsers)

- Inline: `latex_block` nodes delimited by single `$`.
- Display: `latex_block` with `$$`, plus a fallback line scanner for `$$` blocks
  spanning multiple lines (parser coverage is inconsistent).
- Fenced code blocks and inline code are never treated as math.
- Multi-line `$$` with a top-level `\\` (outside any environment) is auto-wrapped in
  `\begin{gathered}…\end{gathered}`.

## 4. Rendering

### Backend: MathJax worker (default)

- Long-lived `node worker/mathjax.mjs` process, started lazily on first math node.
- Protocol: newline-delimited JSON. Request
  `{id, tex, display, macros, color, ex_px, scale}` → response
  `{id, ok, png_path, width_px, height_px, baseline_px, error?}`.
- MathJax output gives width, height, depth; worker converts SVG → PNG with resvg at
  target pixel density, transparent background, foreground = `color`.
- Crash handling: auto-restart up to 3 times per session, then disable the backend
  and fall back to tectonic.

### Backend: tectonic (fallback / opt-in)

- Used when MathJax returns an error (unknown package/command), when the user sets
  `backend = "tectonic"`, or when node is unavailable.
- Batches all pending formulas of a buffer into one document using the document's real
  preamble + `\usepackage[active,tightpage]{preview}`; one page per formula.
- PDF → PNG per page via ImageMagick (`magick -density …`). Baseline taken from the
  `Preview: Snippet` lines (height/depth) that the preview package writes to the log.

### Fallback chain

`mathjax` → `tectonic` → error marker. Each step is per formula.

### Cache

- Key: `sha256(backend, tex, display, macros_hash, color, cell_w, cell_h, scale)`.
- Location: `stdpath("cache")/inkmath/<key>.png` + metadata `<key>.json`
  (width, height, baseline).
- In-memory LRU index of metadata; disk cache cleared with `:InkMath clear-cache`.

### Macros

- `.tex`: `\newcommand`, `\renewcommand`, `\def`, `\DeclareMathOperator`, `\let`
  from the preamble are converted to MathJax macros.
- `.md`: optional `macros` table in config; also reads `$$\newcommand…$$` blocks at the
  top of the file.

### Colors

- Foreground from the `Normal` highlight's `fg` (configurable highlight group).
- Transparent background. `ColorScheme` event re-renders visible nodes (cache key changes).

## 5. Terminal layer

### Cell size

Order: LuaJIT FFI `ioctl(TIOCGWINSZ)` on stdout (`ws_xpixel/ws_ypixel` ÷ cols/rows) →
`tmux display -p '#{client_cell_width} #{client_cell_height}'` → config
`cell_size = {w, h}`. Re-read on `VimResized` and `FocusGained`.

### Kitty graphics protocol with Unicode placeholders

- Transmit: `a=T,U=1,f=100,q=2,i=<id>,c=<cols>,r=<rows>` with base64 PNG data in
  4096-byte chunks (`m=1` … `m=0`). PNG is passed by file path (`t=f`) when the
  terminal is local, else direct data.
- Place: write `U+10EEEE` placeholder cells with row/column diacritics; the image id is
  encoded in the foreground color of a per-image highlight group
  (`InkMathImg<id>`, `fg = #RRGGBB` from id).
- Delete: `a=d,d=I,i=<id>` for evicted images (configurable max resident images, default 512).
- Re-transmit all resident images on `FocusGained` / `VimResume` / tmux pane switch,
  because the terminal may have dropped them.

### tmux

- Detect via `$TMUX`. Wrap every graphics escape in
  `\ePtmux;` … `\e\\` with inner `\e` doubled.
- Requires `set -g allow-passthrough on`; checked with
  `tmux show -gv allow-passthrough` and reported by `:checkhealth`.
- Placeholders are plain text, so scrolling, splits, folds, detach/attach work without
  redraw logic.

## 6. Placement (view layer)

### Inline

- Image is scaled to exactly 1 row. Font size chosen so MathJax `ex` ≈ terminal x-height
  (default 0.45 × cell height, configurable).
- Baseline: image padded vertically so the math baseline sits at the text baseline
  (default 0.78 × cell height, configurable).
- Width in cells `N = ceil(width_px / cell_w)`.
- Extmark: `conceal = ""` over the source range plus `virt_text_pos = "inline"`
  containing N placeholder cells.
- Tall inline math is scaled down to fit one row. Option `inline.promote` (default
  `false`): when true, inline math taller than `inline.promote_ratio` × cell height is
  additionally shown as a display block below the line.

### Display and block

- Rows `H = ceil(height_px / cell_h)`.
- Source lines hidden with extmark `conceal_lines = ""`; placeholder rows drawn as
  `virt_lines` attached to the first source line (or `virt_lines_above` on the next
  line when concealing the first line would drop the virt_lines).
- Horizontal centering within `textwidth` (or window width if `textwidth = 0`).
- Equation numbers for unstarred environments rendered by MathJax (`tags = "ams"`) and
  right-aligned.

### Cursor reveal and live preview

- `CursorMoved`/`CursorMovedI`: if the cursor is inside a node's range, remove that
  node's conceal/virt_text (source visible).
- Live preview: floating window anchored below the node (`relative = "win"`), showing
  the current source rendered via the worker, updated debounced at 50 ms. Closed on
  leaving the node; the node's image is then replaced by the new render.
- Visual mode and the current search match also reveal source.

## 7. Configuration (defaults)

```lua
require("inkmath").setup({
  filetypes = { "tex", "markdown" },
  backend = "mathjax",          -- "mathjax" | "tectonic"
  fallback = true,              -- mathjax error → tectonic
  highlight = "Normal",         -- fg color source
  scale = 1.0,
  inline = { x_height = 0.45, baseline = 0.78, promote = false, promote_ratio = 1.6 },
  display = { center = true },
  preview = { enabled = true, debounce_ms = 50 },
  debounce_ms = 80,
  max_images = 512,
  cell_size = nil,              -- { w = 9, h = 18 } override
  macros = {},                  -- extra MathJax macros
})
```

Commands: `:InkMath enable|disable|toggle|refresh|clear-cache|build`
(`build` runs `npm ci` in `worker/`).

## 8. Error handling and degradation

| Condition | Behavior |
|---|---|
| Terminal lacks kitty graphics / tmux passthrough off | One warning; source stays visible; `:checkhealth inkmath` explains the fix |
| node or worker deps missing | All formulas go to tectonic; live preview disabled |
| Neither backend available | Plugin disables itself for the buffer with a message |
| TeX error in a formula | Source stays visible, underlined; `vim.diagnostic` entry with the TeX message |
| Worker crash | Auto-restart up to 3×, then fall back to tectonic |
| Cell size unknown | Use `cell_size` config or warn and disable images |

The plugin never throws into the user's editing flow; all errors surface as
diagnostics or a single `vim.notify` per cause.

## 9. Isolated test build

- `NVIM_APPNAME=inkmath-dev` → separate config/data/state/cache dirs.
- `dev/init.lua`: adds the repo to `runtimepath`, installs treesitter parsers
  `latex`, `markdown`, `markdown_inline` into the dev data dir, calls `setup()`.
  Nothing else loaded.
- `dev/run.sh [file] [--tmux]`: launches the dev build on `dev/samples/*`;
  `--tmux` starts an isolated tmux server (`tmux -L inkmath`) with
  `allow-passthrough on` to test the tmux path without touching the user's sessions.
- `dev/samples/`: `inline.md`, `display.md`, `multiline.md` (`$$` with `\\`),
  `document.tex` (preamble macros, align, gather, cases, matrices, numbered equations),
  `broken.tex` (TeX errors).
- Opt-in to main config later via a local lazy.nvim spec (`dir = "~/Desktop/nvim-latex-plugin"`).

## 10. Testing

- **Lua (mini.test, headless `nvim --headless` under `NVIM_APPNAME=inkmath-dev`):**
  detection per filetype and edge cases (escaped `\$`, code blocks, nested envs),
  macro extraction, cache keys, sizing/baseline math, kitty escape sequence
  byte-exactness, tmux wrapping, extmark placement (conceal + virt_text/virt_lines).
- **Worker (`node --test`):** TeX → PNG dimensions and baseline for fixtures; error
  responses for invalid TeX; golden PNGs compared with a pixel tolerance.
- **Manual:** `dev/run.sh` in Ghostty directly and with `--tmux`; checklist covering
  scrolling, splits, folds, cursor reveal, live preview, colorscheme switch, pane switch.

## 11. Dependencies

- Runtime: Neovim ≥ 0.11, treesitter parsers (`latex`, `markdown`, `markdown_inline`),
  Ghostty or kitty (≥ 0.28), tmux ≥ 3.3 with `allow-passthrough on` when in tmux.
- MathJax backend: node ≥ 18, `mathjax-full`, `@resvg/resvg-js` (installed via
  `:InkMath build` → `npm ci` in `worker/`).
- Tectonic backend: `tectonic`, ImageMagick (`magick`) with Ghostscript.
- Dev: `mini.nvim` (mini.test) fetched into the dev data dir.
