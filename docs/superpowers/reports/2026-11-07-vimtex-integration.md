# vimtex integration: report (2026-11-07)

Branch `feat/inkmath`, on top of 1b56acc. One commit per item:

| Item | Commit | Summary |
|---|---|---|
| 1 | 527ec8b | `lua/inkmath/vimtex.lua` adapter |
| 2 | c2dc0f2 | root-file preamble/macros for subfiles; `ctx.lua` + `fcache.lua` extracted |
| 3 | f8ac5e3 | equation numbers from `.aux` via injected `\tag{n}` |
| 4 | 1eefb8a | vimtex math conceal cleared per buffer; `conceallevel` 0 hides images |
| 5 | 4cc1155 | folds: display images in closed folds are not placed |

Final state: `make test` 0 fails; `make test-worker` 13 pass, 0 fail.

## vimtex facts verified

Checked against vimtex 3f96503 (2026-10-30) at `~/.local/share/nvim/lazy/vimtex`
(read only). I also probed it live in an isolated `NVIM_APPNAME=inkmath-dev nvim -u NONE`
with that directory prepended to `rtp`, using a scratch project
(`main.tex` with `\input{macros}` and `\include{chap/one}`, plus `chap/one.tex` with `%! TEX root`).

- `b:vimtex` is the project state dict. In a subfile, `.tex` is the absolute root
  file (`.../main.tex`), `.root` is its directory and `.name` is `main`. Lua's
  `vim.b[buf].vimtex` converts it to a table (`autoload/vimtex/state.vim`).
- `b:vimtex.compiler.out_dir` holds the configured value, e.g. `build`, possibly
  relative. `b:vimtex.compiler.get_file(ext)` tries `$VIMTEX_OUTPUT_DIRECTORY`,
  `out_dir` and `file_info.root`, in that order, each joined with
  `file_info.jobname` (relative roots resolve against `file_info.root`). It returns
  the first readable file, or `''` (`autoload/vimtex/compiler/_template.vim`:
  `_output_roots`, `_get_file_candidates`, `get_file`). Live check: `''` before the
  aux existed, `.../build/main.aux` afterwards.
- `g:vimtex_syntax_conceal` (`:h g:vimtex_syntax_conceal`, doc/vimtex.txt ~2647)
  is **global only**. `autoload/vimtex/syntax/core.vim` reads it while it defines
  the syntax rules, e.g. `if !g:vimtex_syntax_conceal.math_symbols | return | endif`.
  There is no buffer-local variant. `g:vimtex_syntax_conceal_disable` is global too.
  Syntax items, however, are buffer-local.
- Math conceal groups, from `:syntax list` on a live vimtex buffer:
  - `texMathSymbol` (744 of 745 items conceal; also used for `math_fracs`)
  - `texCmdGreek` (41/42)
  - `texMathSuper`/`texMathSub`/`texMathSuperSub` (all or nearly all)
  - `texMathDelim` (64/67)
  - the math zones' `concealends` (`math_bounds`)

  Live check after `syntax clear` of the first six: `\alpha` became `texMathCmd`
  (`Statement`, as before), `\leq` became `texMathCmd`, `^2`/`_1` became
  `texMathZoneTI` (`Special`, as before), `\left(` became `texMathDelimMod`
  (`Type`, as before) and `\{` became `texSpecialChar`. `synconcealed` went
  1 -> 0. Highlight colors are kept; only the conceal goes away.
- vimtex re-defines syntax on the `Syntax` event (`syntax/tex.vim`). Package syntax,
  e.g. `p/amssymb.vim` and `p/unicode_math.vim`, which add `texMathSymbol`, loads in
  `vimtex#syntax#packages#init()`. That runs from `init_post` (`User VimtexEventInitPost`)
  and after a successful compile (`autoload/vimtex/compiler.vim`, just before
  `doautocmd User VimtexEventCompileSuccess`).
- `User VimtexEventCompileSuccess` is documented at doc/vimtex.txt ~4405.

## Item 1: adapter `lua/inkmath/vimtex.lua`

- `state(buf)` returns `b:vimtex` if it is a table with a non-empty `tex`, else nil.
- `available(buf)` is `state ~= nil`.
- `root_file(buf)` is the normalized `b:vimtex.tex`.
- `aux_file(buf)` tries vimtex's own `b:vimtex.compiler.get_file('aux')` first,
  through `nvim_buf_call` + `eval`, overridable as `_vim_get_file`. If that fails,
  it uses the same candidate roots (env, `out_dir`, root) + jobname (`file_info.jobname`,
  then `.name`, then the root's basename). It returns the first existing candidate,
  else the highest-precedence expected path, so an aux created by a later compile
  is noticed by mtime.
- Everything is pcall-guarded and returns nil/false without vimtex.
- I did not use `exists("*vimtex#...")`: `b:vimtex` only exists once vimtex has
  loaded, and requiring the autoload function would make the adapter impossible
  to stub.

Tests: `tests/test_vimtex.lua` (10 cases). They cover absent vimtex, an invalid
buffer, a malformed `b:vimtex`, the root file, aux next to the root, relative
`out_dir` with jobname taking precedence over a stale root copy, absolute
`out_dir`, the not-built-yet expected path, and the `get_file` path both used and
quietly failing on a stub dict. RED: 10/10 fail (`module 'inkmath.vimtex' not
found`). The first GREEN run had 4 failures: `ipairs` stopped at a nil
`$VIMTEX_OUTPUT_DIRECTORY`. After the fix, 0 fail. I also checked the adapter
live against real vimtex.

## Item 2: root preamble for multi-file projects

- New `lua/inkmath/ctx.lua` holds the ctx building moved out of core (`build`,
  `macro_only`, markdown macro blocks). `core.ctx` delegates to it.
- New `lua/inkmath/fcache.lua` reads small files synchronously, cached by
  `mtime.sec.nsec:size`, with derived values cached per file version.
- `ctx.tex_preamble(buf)`:
  - Without vimtex it is `latex.preamble(buf)`, as before.
  - With vimtex, it takes the root file's preamble: the loaded root buffer if
    there is one (unsaved edits count, and this also covers the buffer being the
    root), else the file on disk, sliced before `\begin{document}` and cached by
    mtime. An unreadable root falls back to the buffer.
  - It then splices `\input{f}`, `\input f` and `\include{f}` lines one level deep,
    relative to the root's directory. `f.tex` is tried before `f`, the included
    file is mtime-cached, and unresolvable lines are kept. Splicing also fixes
    tectonic, which compiles in a temp dir where a relative `\input` cannot resolve.

Tests: `tests/test_ctx.lua` (8 cases). They cover:
- no vimtex means the subfile's own (empty) preamble;
- the subfile gets the root's preamble from disk;
- `\input` is spliced;
- the no-brace, explicit-extension, trailing-comment and missing-file forms;
- a loaded root buffer wins over disk;
- the mtime cache (no re-read while unchanged, re-read after a rewrite with a
  bumped mtime, checked with the `fcache._reads` counter);
- the root buffer itself;
- the unreadable-root fallback.

RED: 8/8 fail (module not found). GREEN: 0 fail. `test_core.lua` stayed green
after the extraction.

## Item 3: real equation numbers from `.aux`

- New `lua/inkmath/labels.lua`. `parse(lines)` reads
  `\newlabel{key}{{num}{page}...}`. Plain and hyperref (5-group) forms work;
  `@cref` keys are skipped. Only plain numbers (`[%w.-]+`, e.g. `3.2`, `A.1`) are
  accepted, so `\textup{A}1` is never injected into TeX. It also collects
  `\@input{...}` aux files.
- `read(path)` merges the aux files that are `\@input` one level deep, because
  `\include`d chapters write their own `.aux`. Everything is cached by mtime
  through `fcache`.
- `apply(nodes, labels)` handles block nodes of unstarred `equation`, `align`,
  `gather`, `multline`, `flalign` and `alignat`. It splits the source into rows
  at `\\` and inserts `\tag{n}` before the first known `\label{key}` of each row,
  unless that row already has `\tag`, `\notag` or `\nonumber`. Unlabeled rows,
  starred environments, `\[...\]` and inline math are untouched.
- `ctx.build` adds `labels`, `aux` and `aux_stamp` for tex buffers with vimtex.
  `core.refresh` calls `labels.apply(all, ctx.labels)` right after detection.
  The tag is part of `node.src`, so it is part of the cache key: a changed number
  re-renders and the old image is not reused.
- Re-read triggers:
  - global `User VimtexEventCompileSuccess` schedules a refresh of attached tex
    buffers (the aux stamp changed, so it is re-parsed);
  - buffer `BufEnter` refreshes only if `ctx.aux_changed` (path or stamp differ
    from the last ctx).

I checked it live with the real MathJax worker: `\tag{3.2}\label{x}` in `equation`
renders with "(3.2)" at the right edge (looked at the PNG). Tagged `align` renders
too.

Tests:
- `tests/test_labels.lua` (6 cases): parse forms; `read` following `\@input` and
  nil for missing/nil paths; a labeled equation; starred/unlabeled/unknown/
  already-tagged/non-numbered/display/inline left alone; `align` per row with
  `\notag`; different numbers giving different cache keys. RED 6/6 (module not
  found), GREEN 0.
- `tests/test_core.lua` (4 cases, render stubbed to record `n.src`): a labeled
  equation is sent with `\tag{3.2}` and the unlabeled one unchanged; compile
  success after rewriting the aux gives `\tag{4.1}`; BufEnter with an unchanged
  aux re-renders nothing and with a changed mtime gives the new number; without
  vimtex nothing is injected. RED, with the core/ctx wiring stashed: 3 fail (the
  no-vimtex case passes by design). GREEN 0.

README: new "vimtex" section bullet "Equation numbers"; the Limitations entry on
standalone numbering now names the exceptions.

## Item 4: conceal coexistence

(a) vimtex math conceal. vimtex has no buffer-local switch (see the facts above),
so `vimtex.clear_math_conceal(buf)` runs `syntax clear` on `texMathSymbol`,
`texCmdGreek`, `texMathSuperSub`, `texMathSuper`, `texMathSub` and `texMathDelim`
inside the buffer, only when `b:vimtex_syntax` exists (set by vimtex's
`syntax/tex.vim`).

Core calls it:
- on attach;
- on buffer `Syntax` (scheduled, after vimtex reloads);
- on `User VimtexEventInitPost`/`VimtexEventCompileSuccess` (package syntax can
  add `texMathSymbol` again).

On detach, `vimtex.reload_syntax` (`let &l:syntax = &l:syntax`) restores the
groups. The new config option `vimtex = { math_conceal = false }` (validated)
opts out when set to true. Live check with real vimtex: `\alpha` synconcealed
1 -> 0 (texCmdGreek -> texMathCmd), and back to 1/texCmdGreek after the reload.
`math_bounds` (`$` delimiters) and non-math conceal stay; the README points to
`g:vimtex_syntax_conceal = { math_bounds = 0, ... }` for those.

(b) `conceallevel` 0. `core.conceal_off(buf)` is true when some window showing
the buffer has `conceallevel` 0, unless `conceal.level = 0` is configured. In
that case `refresh` clears the placements, revealed entries and preview, sets
`hidden[buf]` and returns; diagnostics, errors and the cache are kept. `deliver`
also skips hidden buffers, so in-flight renders cannot re-place images.

A global `OptionSet conceallevel` autocmd refreshes the current buffer when its
hidden state should flip. `set_win_opts`/`restore_win_opts` set a `setting_opts`
flag so the plugin's own option changes are ignored. Going back above 0
re-places the images from the cache. This makes the user's `<leader>uc` keymap
(`vim.o.conceallevel = 0/2`, keymaps.lua:122-130, read only) hide and show the
images too.

Tests:
- `test_vimtex.lua` (2): with a vimtex-like `syntax match texMathSymbol ... conceal`,
  it is cleared and a `texCmdAccent` conceal is kept; without `b:vimtex_syntax`,
  or on an invalid buffer, nothing happens.
- `test_core.lua` (3): `vim.wo.conceallevel = 0` hides the images, a refresh while
  hidden places nothing, 2 re-places them, and the same with `vim.o`;
  `conceal.level = 0` in setup still places; clear is called on attach and on
  `Syntax`, but not with `math_conceal = true`.
- `test_config.lua` (1): validation.
- RED, with core/config stashed: the 2 core cases fail (images stay at
  `conceallevel` 0; clear not called). The vimtex cases fail on the missing
  function. GREEN: 0 fail.

README:
- "Conceal options" now describes `conceallevel` 0 hiding the images.
- The "vimtex" section has a "Math conceal" bullet: what is cleared, why
  (global-only option), restore on disable, the opt-out, and
  `g:vimtex_syntax_conceal` for the rest.
- The config defaults block lists `vimtex = { math_conceal = false }`.

## Item 5: folds

Headless findings. Neovim 0.11 keeps a screen grid in `--headless`, so
`screenstring()`/`screenpos()` after `:redraw!` work. I probed this in a scratch
script, then wrote it into tests.

- A closed manual fold over a display block (`2,4fold`) takes **one** screen row.
  virt_lines and `conceal_lines` inside the fold are not drawn: `screenpos` of the
  line after the fold moves from row 5 to row 3.
- virt_lines attached to the fold's first line are drawn neither above nor below
  the fold line.
- **Leak:** the block's first-row **overlay virt_text** is drawn over the fold
  line when the block starts the fold. This happens with every `foldtext`
  (`foldtext()`, `""`, a custom string), so the first image row covered the fold
  text.
- A fold starting above the block (`1,5fold`) and a fold inside the block's
  concealed rows (`3,4fold`) are fine.
- Inline virt_text on a folded line is drawn only with `foldtext=""` (the line is
  shown as is, where it is correct).

Fix in `lua/inkmath/view/folds.lua` + core:
- `folds.hidden(buf, node)`: display/block nodes whose first row is inside a
  closed fold in any window showing the buffer (`foldclosed` via `nvim_win_call`).
  In `refresh` these are cleared and not placed, revealed entries are dropped, and
  they are remembered in `folded[buf]`. `deliver` also refuses them.
- No event fires on `zc`/`zo`/`zM`/`zR`, and `WinScrolled`/`CursorMoved` do not
  reliably fire either. So a decoration provider `on_win`, for the current window
  only, computes the folded rows among its display images and remembered folded
  rows in view, and schedules a debounced refresh when that signature changes.
  Opening the fold therefore re-places the image (a cache hit, so synchronous).

Tests in `tests/test_core.lua` (5): a closed fold over a block takes 1 screen row
and no placeholder (U+10EEEE) cell is on the fold row; `zR` puts the image back on
screen and in state; a fold starting above hides it entirely; a fold inside the
block changes nothing; inline images on a folded line are not drawn with the
default foldtext. RED: 1 fail, "takes one screen row" at
`row_has_image(2) == false`, i.e. the leak. The others already held; the re-place
case became meaningful once hiding existed. GREEN: 0 fail.

README Limitations: a new "Closed folds" entry covers the behavior, the any-window
rule, how fold changes are detected, and that it works with vimtex folding.

## Concerns / not done

- On `BufWinEnter`, `set_win_opts` (existing behavior) still forces the configured
  `conceallevel`. A user's `conceallevel=0` toggle is undone when the buffer is
  shown again in a window, so the images come back.
- Fold hiding and conceal hiding are per buffer. A fold closed, or
  `conceallevel` 0, in one split hides the images in the other split too.
  Fold changes made in a non-current window are only noticed at the next refresh.
- Only one `\input` level is spliced; a local `\usepackage{mystyle}` (.sty) is not
  inlined. `eqnarray` is not tagged.
- The live preview float, which renders the node freshly detected while typing,
  shows the standalone number, not the aux number.
- `docs/research/` appeared untracked during the session; it is not mine and was
  left alone.
- Manual verification in a real Ghostty/kitty with vimtex is not done (no terminal
  here). The vimtex parts were verified headless against the real vimtex source.

## Fix round 1 (review)

Base a6aa07b. Commits: f59616a (I1), 23009c0 (I2), d7f1053 (minors).

### I1: `\tag` inside nested environments (f59616a)

Problem: rows were split on every `\\`, so the tag landed inside
`split`/`aligned`/`cases`. I confirmed it with the real worker: injecting
`\tag{3.2}` inside `split` returns `{ backend = "mathjax", message = "\tag not
allowed in split environment" }`.

Change in `lua/inkmath/labels.lua`:
- `M.rows(src, one_row)` scans the source while tracking `\begin`/`\end` depth.
  It skips `%` comments and escaped characters, and splits only on depth-1 `\\`.
- The tag goes at the start of the labeled row on the outer level: right after
  `\begin{env}` (after alignat's `{n}`), or right after the row's `\\`.
- `equation`/`multline` count as one row.
- Rows with `\tag`/`\notag`/`\nonumber` are still skipped.

Tests (`tests/test_labels.lua`): two existing expectations were updated to the new
tag position, and six new "nested:" cases were added:
- equation+split;
- equation+aligned;
- equation+cases;
- align with a pmatrix containing `\\` on a labeled row;
- align with 2 labeled rows (both tagged);
- alignat keeps `{2}`.

Each case except alignat is also rendered through the real MathJax worker
(`no_fallback`) and must give an image with no error. In `tests/test_core.lua`,
`tagged()` was updated. RED, with the old `labels.lua` stashed: 8 fail. GREEN: 0.

### I2: all of vimtex's math conceal (23009c0)

Change: `vimtex.clear_math_conceal(buf)` no longer clears groups. It reloads the
buffer's syntax (`let &l:syntax = &l:syntax`, in the buffer) with
`g:vimtex_syntax_conceal` temporarily patched: `math_bounds`, `math_delimiters`,
`math_fracs`, `math_super_sub`, `math_symbols`, `greek`, `styles` and `spacing`
are set to 0, and the user's other keys are kept. The global is restored right
after, even if the reload errors.

`vimtex._reloading[buf]` is set during the reload, and core's `Syntax` handler
skips it, so there is no loop. Re-apply runs:
- after other `Syntax` reloads (scheduled);
- after `User VimtexEventInitPost`/`VimtexEventCompileSuccess`, now deferred with
  `vim.schedule` so it runs after vimtex's own `init_post`/`packages#init`.

Detach still reloads the syntax with the user's settings. The opt-out
`vimtex = { math_conceal = true }` is kept.

Facts used:
- `autoload/vimtex/options.vim` 351-365: defaults and the key list. `init_option`
  (699) runs once and fills in missing keys.
- `autoload/vimtex/syntax/core.vim` reads the global while defining rules: styles
  ~1804-1888, math_delimiters ~2299, symbols ~2060, sub/super ~1894. So do
  `p/unicode_math.vim` (styles, math_symbols) and `p/amsmath.vim` (128,
  math_delimiters).
- `syntax/tex.vim` re-runs `init_post` (package syntax) on a load when `b:vimtex`
  exists.

Live check, real vimtex, line `x $\mathbf{x} + \text{if} + \left( \alpha^2 \right) \quad \mathrm{d}$ y`
plus text `caf\'e`:
- before: `synconcealed` = 1 for `\mathbf`, `{x}`, `\text`, `\left(`, `\alpha`,
  `^2`, `\quad`, `\mathrm`, `$`;
- after: 0 for all of them, while `\'e` (texCmdAccent, in text) stays 1;
- the global equals what it was before; a plain syntax reload brings everything
  back (the detach path).

Tests:
- `tests/test_vimtex.lua`: a fake syntax file in a temp rtp that, like vimtex,
  sets `b:vimtex_syntax` and adds conceal items only for the global keys that are
  on. It checks that `\alpha` and `\mathbf` are no longer concealed, the accent
  still is, the patched keys seen by the syntax file are 0 and accents/cites 1,
  the global is restored and `_reloading` is cleared. Also a no-vimtex-syntax
  case and an invalid buffer.
- `tests/test_core.lua`: `Syntax` during our own reload is ignored, and
  `VimtexEventInitPost` re-applies.

RED: `\mathbf` was still concealed (1 vs 0). GREEN: 0.

Trade-off, documented in the README: vimtex has one key for math and text in
`styles` and `spacing`, so in attached buffers `\textbf{..}`/`\quad` in text are
not concealed either.

### Minors (d7f1053)

- **M1.** Fallback roots are env, `aux_dir` (latexmk), `out_dir`, root. When no
  candidate exists, `b:vimtex.compiler.get_output_signature('aux')` (only if the
  compiler has it) gives the expected path. Live check with
  `g:vimtex_compiler_latexmk = {'aux_dir':'auxd','out_dir':'build'}` and nothing
  built: signature `.../auxd/main.aux`, which `aux_file` returns. Tests: aux_dir
  precedence; signature hook. RED 2, GREEN.
- **M2.** The root buffer is found by realpath over `nvim_list_bufs()` (loaded
  only), with realpaths memoized per name. Test: the root opened under a
  symlinked directory with unsaved edits wins. This already passed before the
  change (`bufnr()` matched the file identity); the lookup was changed as
  requested.
- **M3.** The root preamble is cached per root, keyed by `buf:<n>:<changedtick>`
  or `file:<stamp>`, plus the stamps of the spliced `\input` files. Merged labels
  are cached by the stamps of the aux and its `\@input` files. Both return the
  cached table (read-only), with no deep copy. Tests: identity while unchanged,
  rebuilt after a root-buffer edit and after an `\input` file changes; labels
  identity, rebuilt after a sub-aux change. RED 2, GREEN.
- **M4.** `on_cursor` and the debounced preview close the preview and do not
  render while the buffer is hidden (`conceallevel` 0). Test: no preview while
  hidden, one after setting 2 again. RED 1, GREEN.
- **M5.** The OptionSet handler re-checks every attached buffer. Test: conceallevel
  set via the API on another buffer's window hides and re-places the images. This
  already passed before (the API sets options in that window's context); the
  change makes it independent of that.
- **M6.** A `WinClosed` autocmd drops that window's `fold_sig` entries (and
  `user_cl0`). Test via `core._fold_sig`. RED (field missing), GREEN.
- **M8.** The aux parser takes the first inner group, skipping whitespace before
  either brace. Malformed `\newlabel{c}{7}` is ignored. Test with
  `{ {5}{1}}`, braces in the hyperref title, and the malformed form. RED 1, GREEN.
- **M10.** OptionSet (except `:setglobal`) records `conceallevel` 0 for an
  attached buffer per (buf, win). Turning it back on (> 0) in a window clears that
  window's override for all buffers. `set_win_opts` (BufWinEnter) keeps 0 for
  overridden windows. Test: 0 survives `enew` + switching back, 2 survives
  likewise, and 0 → switch away → `vim.o` 2 → back shows the images again. RED 1,
  GREEN. This resolves the earlier BufWinEnter concern.

README:
- Conceal options: the toggle sticks per window.
- vimtex: equation numbers mention `aux_dir` and the outer-level tag position.
- vimtex: the math conceal bullet is rewritten for the reload approach and its
  trade-off.

### Commands and output

```
timeout 300 make test-file F=tests/test_labels.lua   # Fails (0)
timeout 120 make test-file F=tests/test_vimtex.lua   # Fails (0)
timeout 120 make test-file F=tests/test_ctx.lua      # Fails (0)
timeout 300 make test-file F=tests/test_core.lua     # Fails (0)
timeout 900 make test                                # Fails (0) and Notes (0)
make test-worker                                     # pass 13, fail 0
```

Remaining concerns: hiding for folds and `conceallevel` 0 is still per buffer
(other splits are affected), and nothing has been checked in a real Ghostty/kitty
window.
