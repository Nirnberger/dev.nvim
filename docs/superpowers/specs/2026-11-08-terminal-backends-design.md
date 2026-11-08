# Terminal backends (design)

## Goal
inkmath renders math in more terminal emulators than kitty/Ghostty: iTerm2 (inline images),
Sixel terminals (foot, Windows Terminal, xterm, mlterm) and kitty-protocol terminals that lack
Unicode placeholders (WezTerm, Konsole). Quality bar: **best effort** for the new overlay path,
documented limits, no behaviour change for kitty/Ghostty.

## Non-goals
- Pixel-exact clipping at window borders, occlusion by floats, flicker-free repaint.
- Loading other plugins (image.nvim) as a dependency.
- Automated tests against iTerm2/WezTerm (no Linux package; manual only).

## Architecture
`lua/inkmath/term/backends/<name>.lua`, each returns:

| field | meaning |
|---|---|
| `name` | `kitty`, `iterm2`, `sixel` |
| `mode` | `placeholder` (text cells carry the image) or `overlay` (painted at screen cells) |
| `transmit(id, img)` | sequences to upload/prepare an image (placeholder mode) |
| `paint(img, row, col)` | sequence that draws the image at a screen cell (overlay mode) |
| `delete(id)` | sequence that removes it |
| `probe(env)` | pure function: env + replies -> boolean |

`term/init.lua` picks the backend (`detect()`): option `term.backend = "auto"|"kitty"|"iterm2"|"sixel"|"none"`
(in `config/schema.lua`, then `make doc`). `auto` order: kitty/Ghostty (placeholder) >
kitty-protocol without placeholders (overlay, `a=T` at cursor) > iTerm2 (`TERM_PROGRAM=iTerm.app`, XTVERSION) >
Sixel (DA1 attribute 4). Works through tmux via `client_termtype`/passthrough as today.
Sixel in tmux needs `allow-passthrough`; otherwise the backend reports "unsupported".

`images.lua` and `cells.lua` call the active backend instead of `kitty.*` (only change to existing code).
`kitty.lua` moves to `backends/kitty.lua` unchanged in behaviour.

### Overlay mode
New `view/overlay.lua`. For each visible image-bearing range: `vim.fn.screenpos`/`win_screenpos` -> cell,
skip when outside the window, hidden by a fold, or the window is not the current one's visible region.
Repaint on `WinScrolled`, `VimResized`, `CursorHold`, `TextChanged`, `ModeChanged`; delete images that
left the screen. Debounced (one repaint per event-loop tick). Where an image cannot be drawn the
source text stays visible (existing conceal fallback). Known limits (documented in README/help):
flicker, images may overlap splits/floats, tmux needs passthrough.

### Health / env
`:checkhealth inkmath` and `env.lua` show backend, mode and why a backend was rejected.

## Delivery: two PRs
1. **Interface**: backend table, `detect()`, option, kitty behind the interface. No behaviour change;
   existing tests (incl. `test_kitty_real`, `test_matrix`) stay green.
2. **Overlay**: `view/overlay.lua`, `iterm2`, `sixel`, kitty-without-placeholders, docs.

## Testing
- Unit: escape strings per backend (iTerm2 `OSC 1337;File=`, Sixel DCS via ImageMagick `magick ... sixel:-`
  or a small encoder), detection matrix (extend `tests/test_matrix.lua`), overlay position maths and
  repaint triggers in a child Neovim.
- Real: xterm under Xvfb with `-ti vt340` for Sixel (pixels via `Xvfb -fbdir`); skips without xterm.
- Manual: iTerm2, WezTerm, foot, Konsole (checklist in the PR).
- Screenshot job: not extended (kitty only).

## Open risks
- Sixel encoding needs a tool or encoder; prefer a small Lua/Node encoder in the worker to avoid new deps.
- DA1 probing needs an async terminal query; reuse the `\27[16t` pattern in `cells.lua`.
- Overlay on terminals that scroll images with text (iTerm2) may double-draw; verify manually.
