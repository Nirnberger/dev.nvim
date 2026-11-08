# Terminal backends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** inkmath shows math in iTerm2, Sixel terminals and kitty-protocol terminals without Unicode placeholders, without changing kitty/Ghostty behaviour.

**Architecture:** A backend interface chosen by `term/backend.lua`. kitty/Ghostty stay in `placeholder` mode (image = text cells). New backends use `overlay` mode: `view/overlay.lua` computes screen cells and paints/repaints images. Two PRs: Tasks 1-2 (interface, no behaviour change), Tasks 3-7 (overlay + backends).

**Tech Stack:** Lua (Neovim >= 0.11 API, tests on 0.12), Node worker (MathJax + resvg), mini.test.

**Spec:** `docs/superpowers/specs/2026-11-08-terminal-backends-design.md`

**Deviation from spec:** `term/kitty.lua` stays at its path (17 test files stub `inkmath.term.kitty`); it implements the interface itself. New backends live in `lua/inkmath/term/backends/`.

## Global Constraints
- Options only in `lua/inkmath/config/schema.lua`; run `make doc` after changing them (`test_doc` checks).
- Interop probes never load other plugins (`package.loaded` only).
- `.github/workflows/` is never pushed by the bot; no CI file changes in this plan.
- Worker tests: `node --test test/*.test.mjs` (not `test/`), Node 18-22.
- Backend `none` and unsupported terminals: `env.check()` warns once, no images, no errors.
- tmux: sequences go through `tmux.wrap`; Sixel/iTerm2 additionally need `allow-passthrough` (existing `tmux.passthrough_enabled()`).
- Branch `claude/terminal-backends` (worktree `/home/dev/tasks/term-backends`); PR only when the owner asks; PR 1 = Tasks 1-2, PR 2 = Tasks 3-7 (branch PR 2 from `main` after PR 1 merged).

## Review Focus
1. Terminal env says iTerm2/foot but the user set `term.backend = "kitty"`/`"none"`: the option wins; `none` shows no images and no warning spam.
2. Overlay image whose anchor line is scrolled off-screen, inside a closed fold, or in a non-visible window: nothing painted, previous paint deleted.
3. Rapid scrolling (many `WinScrolled` in one tick): one repaint, no leaked images after stop.
4. `:InkMath` disable/detach and buffer wipe while overlay images exist: all images removed.
5. Sixel/iTerm2 inside tmux without passthrough: backend rejected with a reason in `:checkhealth`, no escape garbage printed.

## File Structure
- Create `lua/inkmath/term/backend.lua`: `detect()`, `get()`, `reset()`.
- Modify `lua/inkmath/term/kitty.lua`: add `name`, `mode`, `probe(env)` (keep existing API).
- Create `lua/inkmath/term/backends/{iterm2,sixel}.lua`, `lua/inkmath/view/overlay.lua`.
- Modify `term/images.lua`, `term/cells.lua`, `health.lua`, `env.lua`, `config/schema.lua`, README, `doc/inkmath.txt` (generated).
- Create `worker/sixel.mjs`, `worker/test/sixel.test.mjs`; tests `tests/test_backend.lua`, `tests/test_overlay.lua`, extend `tests/test_matrix.lua`, `tests/test_health.lua`.

---

### Task 1: Backend interface, detection, option

**Files:** Create `lua/inkmath/term/backend.lua`, `tests/test_backend.lua`; Modify `lua/inkmath/term/kitty.lua`, `lua/inkmath/config/schema.lua`.

**Interfaces:**
- Produces `backend.get(): inkmath.Backend|nil`, `backend.detect(env?: table): inkmath.Backend|nil, string|nil` (backend, reason when nil), `backend.reset()`.
- `inkmath.Backend = { name: "kitty"|"iterm2"|"sixel", mode: "placeholder"|"overlay", send(seq: string), probe(env: table): boolean, delete(id: integer): string, paint?(img: {path:string,cols:integer,rows:integer,id:integer}, row: integer, col: integer): string[] }`.
- Option `term.backend: "auto"|"kitty"|"iterm2"|"sixel"|"none"`, default `"auto"`.

- [ ] **Step 1: Failing tests** in `tests/test_backend.lua`: `detect({TERM_PROGRAM="ghostty"})` → name `kitty`, mode `placeholder`; `detect({TERM="xterm-kitty"})` same; `detect({TERM="dumb"})` → `nil, "no supported terminal"`; option `none` → `nil, "disabled by term.backend"`; option `kitty` with env `dumb` → kitty (forced); `get()` memoizes until `reset()`.
- [ ] **Step 2:** Run `make test-file F=tests/test_backend.lua`; expect FAIL (module missing).
- [ ] **Step 3:** Implement `backend.lua` (order: option, then kitty probe; later tasks add backends to a local list) and add `name="kitty"`, `mode="placeholder"`, `probe=M.supported`, `delete=M.delete_seq` to `kitty.lua`. Add the option to `schema.lua` with doc text, run `make doc`.
- [ ] **Step 4:** `make test-file F=tests/test_backend.lua` and `make test-file F=tests/test_doc.lua`; expect PASS.
- [ ] **Step 5:** Commit `feat: terminal backend interface and term.backend option`.

### Task 2: Route existing code through the backend (no behaviour change)

**Files:** Modify `lua/inkmath/term/images.lua:58,96,105`, `lua/inkmath/term/cells.lua:55`, `lua/inkmath/health.lua:138-150`, `lua/inkmath/env.lua:19,37`; Test: whole suite.

**Interfaces:** Consumes `backend.get()`, `backend.reset()` from Task 1. Produces: `env.check()` uses `backend.detect()`, warns with its reason; `env.rearm()` calls `backend.reset()` and `kitty.forget()`.

- [ ] **Step 1:** Failing test in `tests/test_health.lua`: with `term.backend="none"`, health reports "terminal graphics disabled by term.backend" (not the kitty error).
- [ ] **Step 2:** Run it; expect FAIL.
- [ ] **Step 3:** Replace direct `kitty.send/delete_seq` calls in `images.lua`/`cells.lua` with the backend's `send`/`delete` (placeholder mode only; `transmit_seq` stays kitty-specific behind `backend.get().name == "kitty"`); update health/env messages.
- [ ] **Step 4:** `make test` — all existing tests incl. `test_kitty_real` and `test_matrix` pass, new test passes.
- [ ] **Step 5:** Commit `refactor: images/cells/env talk to the active terminal backend`. **Stop here for PR 1** (ask the owner).

### Task 3: Overlay view (`view/overlay.lua`)

**Files:** Create `lua/inkmath/view/overlay.lua`, `tests/test_overlay.lua`; Modify `lua/inkmath/core.lua` (attach/detach hooks), `view/placer.lua` (skip placeholder marks when `backend.mode == "overlay"`).

**Interfaces:**
- Produces `overlay.cell(win: integer, lnum: integer, col: integer): {row:integer,col:integer}|nil` (1-based screen cell via `screenpos`; nil if line not visible, in a closed fold, or outside the window), `overlay.repaint()`, `overlay.clear(buf?: integer)`.
- Consumes `backend.get().paint` / `.delete`.

- [ ] **Step 1: Failing tests** (child Neovim, fake backend recording sequences): `cell` returns nil for a scrolled-off line and a folded line; `repaint()` called 5× in one tick issues one paint per visible image (debounce via `vim.schedule`); after scrolling an image off-screen the next repaint emits its `delete`; `clear(buf)` deletes all of the buffer's images; wiping the buffer clears.
- [ ] **Step 2:** Run `make test-file F=tests/test_overlay.lua`; expect FAIL.
- [ ] **Step 3:** Implement with autocmds `WinScrolled`, `VimResized`, `CursorHold`, `TextChanged`, `ModeChanged`, `BufWipeout`; debounce one repaint per tick; keep a table of painted images keyed by buffer+mark id; track painted state to diff.
- [ ] **Step 4:** Run the file and `test_placer.lua`, `test_core.lua`; expect PASS.
- [ ] **Step 5:** Commit `feat: overlay view for non-placeholder terminals`.

### Task 4: iTerm2 backend

**Files:** Create `lua/inkmath/term/backends/iterm2.lua`; Modify `term/backend.lua`; Test: `tests/test_backend.lua`.

**Interfaces:** Produces backend `iterm2` (`mode="overlay"`). `paint(img,row,col)` returns `{ CSI row;col H, OSC "1337;File=inline=1;width=<cols>;height=<rows>;preserveAspectRatio=1:<base64 PNG> BEL }` (cursor save/restore around it); `delete(id)` returns `""` (overlay repaint overwrites; stale cells are cleared by `\27[2K`-free redraw via `:redraw!`, see Step 3). `probe`: `TERM_PROGRAM=iTerm.app` or `LC_TERMINAL=iTerm2`.

- [ ] **Step 1: Failing tests:** `detect({TERM_PROGRAM="iTerm.app"})` → `iterm2`/`overlay`; `paint()` output starts with cursor positioning for the given row/col and contains `]1337;File=inline=1;width=3;height=2` for a 3x2 image; inside tmux the sequences are `tmux.wrap`ped.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement; deletion decision: `delete` triggers `vim.cmd("redraw!")` once per repaint batch (documented limit: flicker).
- [ ] **Step 4:** Run `make test-file F=tests/test_backend.lua`; expect PASS.
- [ ] **Step 5:** Commit `feat: iTerm2 inline-image backend`.

### Task 5: Sixel encoder (worker) and backend

**Files:** Create `worker/sixel.mjs`, `worker/test/sixel.test.mjs`, `lua/inkmath/term/backends/sixel.lua`; Modify `worker/mathjax.mjs` (add a `sixel` output next to the PNG when requested — read `lua/inkmath/render/mathjax.lua` and `worker/mathjax.mjs` first to follow the existing request/cache protocol), `lua/inkmath/render/cache.lua` if the cache key needs a format suffix.

**Interfaces:**
- Produces `encode(rgba: Uint8Array, width: number, height: number): string` in `worker/sixel.mjs` (DCS `P0;1;q` ... ST, palette ≤ 256 colours, 6-row bands, RLE `!n`, transparent pixels left unset via `P0;1;q`).
- Backend `sixel` (`mode="overlay"`): `paint` reads the cached `.six` file next to `img.path` and returns cursor-position + its contents; `probe` = DA1 reply contains attribute `4` (async query, reuse the `TermResponse` pattern from `cells.lua`; timeout 200 ms ⇒ false) or `TERM` matches `foot|mlterm|^xterm.*sixel`; `backend.get()` rejects inside tmux without passthrough.

- [ ] **Step 1: Failing tests:** `sixel.test.mjs`: a 2x6 image with one red and one blue column encodes to a string starting `\x1bP` and ending `\x1b\\`, with two colour definitions `#0;2;100;0;0` / `#1;2;0;0;100`; fully transparent input encodes to an empty raster; palette over 256 colours is quantised to ≤ 256. Lua: `detect` with DA1 reply `\27[?62;4;c` → sixel; without `4` → not sixel.
- [ ] **Step 2:** `cd worker && node --test test/*.test.mjs` and the Lua test; expect FAIL.
- [ ] **Step 3:** Implement encoder (median-cut or fixed 6x6x6 cube quantisation is fine), wire into worker, backend `paint`.
- [ ] **Step 4:** `make test-worker` and `make test-file F=tests/test_backend.lua`; expect PASS.
- [ ] **Step 5:** Commit `feat: Sixel encoder and backend`.

### Task 6: kitty protocol without placeholders (WezTerm, Konsole)

**Files:** Modify `lua/inkmath/term/kitty.lua` (add `paint`, `probe_overlay`), `term/backend.lua`, `lua/inkmath/health.lua:138-150`; Test: `tests/test_backend.lua`, `tests/test_health.lua`.

**Interfaces:** Produces a second kitty entry in the backend list with `mode="overlay"`: `paint` sends `ESC _Ga=T,f=100,t=f,q=2,c=<cols>,r=<rows>,i=<id>;<base64 path> ST` after cursor positioning (no `U=1`); `probe_overlay(env)`: `TERM_PROGRAM=="WezTerm"` or `KONSOLE_VERSION` non-empty. Remote (non-local) uses direct transmit like `transmit_seq`.

- [ ] **Step 1: Failing tests:** `detect({TERM_PROGRAM="WezTerm"})` → `kitty`/`overlay`; health no longer errors for WezTerm/Konsole, instead reports "kitty graphics without placeholders: overlay mode (limits: see help)"; `term.backend="kitty"` forces `placeholder` mode on those terminals.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement; order in `detect`: kitty placeholder terminals, then kitty overlay, iTerm2, Sixel.
- [ ] **Step 4:** `make test-file F=tests/test_backend.lua` and `F=tests/test_health.lua`; PASS.
- [ ] **Step 5:** Commit `feat: overlay mode for kitty-protocol terminals without placeholders`.

### Task 7: Matrix tests, real Sixel test, docs

**Files:** Modify `tests/test_matrix.lua`, README, `lua/inkmath/config/schema.lua` doc strings (then `make doc`); Create `tests/test_sixel_real.lua`.

- [ ] **Step 1: Failing tests:** matrix rows for iTerm2 (`TERM_PROGRAM=iTerm.app`), foot (`TERM=foot`), WezTerm, Konsole, Alacritty (no backend: warning once, no images) each with and without tmux passthrough; `test_sixel_real.lua`: `xvfb-run xterm -ti vt340 -e nvim ...`, reads the Xvfb framebuffer (`-fbdir`) and asserts non-background pixels where the formula should be; skips without xterm/xvfb-run (`INKMATH_REQUIRE_SIXEL=1` makes a skip a failure; do not set it in CI scripts).
- [ ] **Step 2:** Run both; expect FAIL.
- [ ] **Step 3:** Fix any matrix gaps found; write README section "Supported terminals" (table: terminal, mode, notes, known limits: flicker, splits/floats overlap, tmux passthrough) and a manual checklist for iTerm2/WezTerm/foot/Konsole in the PR description.
- [ ] **Step 4:** `make doc && make test`; expect 0 failures (xterm test skips on the box if xterm is missing; say so in the report).
- [ ] **Step 5:** Commit `docs+tests: terminal matrix, real Sixel test, supported terminals`. **Stop for PR 2** (ask the owner).
