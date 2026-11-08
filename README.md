# inkmath.nvim

Renders LaTeX math in `tex`, `markdown`, `quarto` and `rmd` buffers as real images inside Neovim.
Works in Ghostty and kitty, including through tmux. Inline math sits on the text
baseline, display math is centered, and the formula under the cursor shows its
source with a live preview float while you type.

## Requirements

- Neovim >= 0.11 with treesitter parsers `latex`, `markdown`, `markdown_inline`.
  On Neovim 0.11, [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) `main`
  no longer works (it requires 0.12 since c82bf96); use it up to and including commit `90cd658`.
- `termguicolors` on: each image id is sent as the placeholder's 24-bit foreground
  color (inside tmux the client also needs the `RGB` terminal feature, see below)
- Ghostty or kitty (>= 0.28); inside tmux: tmux >= 3.3 with `allow-passthrough on`
- MathJax backend (default): node >= 18, `mathjax-full` and `@resvg/resvg-js`
  (installed by `:InkMath build`, which runs `npm ci` in `worker/`)
- Tectonic backend / fallback: `tectonic`, ImageMagick (`magick`) with Ghostscript
- Development: `mini.nvim` (mini.test), fetched into the dev data dir

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim), as a local plugin:

```lua
{ dir = "~/Desktop/nvim-latex-plugin", ft = { "tex", "markdown", "quarto", "rmd" }, build = ":InkMath build", opts = {} }
```

### tmux

Add to `~/.tmux.conf`:

```
set -g allow-passthrough on
set -as terminal-features ',*:RGB'
```

Run `:checkhealth inkmath` to verify the setup. The full manual is `:help inkmath`.

## Configuration

No `setup()` call is needed: the plugin attaches `tex`, `markdown`, `quarto` and
`rmd` buffers on its own. A minimal lazy.nvim spec is just
`{ dir = "...", build = ":InkMath build" }`. To change options, pass only what
differs from the defaults:

```lua
require("inkmath").setup({ scale = 1.1, overrides = { markdown = { inline = { promote = true } } } })
-- or, before the plugin loads:
vim.g.inkmath = { scale = 1.1 }
```

Every option, its default and its scope are listed in `:help inkmath-options`
(generated from the option schema in `lua/inkmath/config/schema.lua`; `make doc`
regenerates it). Disable switches, conceal behaviour and per-filetype overrides
are described in `:help inkmath-config` and `:help inkmath-overrides`.

Large documents: while you are idle, formulas off-screen are rendered to the disk
cache in the background (`fill`) and shown, from the cache, when you scroll to
them. Images stay placed within `keep_screens` (default 3) window heights of each
window, so the terminal holds about `max_images` (default 512) of them however
long the document is.

## Other plugins

Plugins that render LaTeX math themselves draw over inkmath's images: turn their
math off in your own plugin spec (`:checkhealth inkmath` checks this without
loading them; `:help inkmath-interop`):

```lua
{ "MeanderingProgrammer/render-markdown.nvim", opts = { latex = { enabled = false } } },
{ "OXY2DEV/markview.nvim", opts = { latex = { enable = false } } },
{ "folke/snacks.nvim", opts = { image = { enabled = true, math = { enabled = false } } } },
```

render-markdown and markview also set `'conceallevel'` per mode. Let them own it:

```lua
require("inkmath").setup({ overrides = { markdown = { conceal = false } } })
```

In buffers they manage, a `'conceallevel'` 0 never sticks: use `:InkMath toggle`.

## vimtex

[vimtex](https://github.com/lervag/vimtex) is optional; when it is loaded for a
`tex` buffer (`b:vimtex` exists), inkmath uses its project state:

- **Multi-file projects.** In a subfile (vimtex's root file `b:vimtex.tex` is another
  file), macros and the tectonic preamble come from the root file's preamble: its
  loaded buffer if it is open, else the file on disk (re-read when its mtime
  changes). `\input{macros}`/`\include{macros}` lines in that preamble are replaced
  by the file's contents, one level deep, resolved relative to the root's directory.
  Without vimtex, each buffer uses its own preamble as before.
- **Equation numbers.** After a compile, `\newlabel{key}{{3.2}{7}...}` entries of
  the project's `.aux` file (`b:vimtex.compiler.get_file('aux')`, honouring
  latexmk's `aux_dir`, `out_dir` and the jobname; `\@input` aux files of `\include`d chapters are followed) give
  labeled rows of numbered environments (`equation`, `align`, `gather`, `multline`,
  `flalign`, `alignat`, unstarred) their real number: `\tag{3.2}` is inserted at
  the start of the row on the environment's own level (for `equation`/`multline`
  right after `\begin{..}`), never inside a nested `split`/`aligned`/`cases`, whose
  `\\` do not split rows. Rows with their own `\tag`/`\notag`/`\nonumber`, unlabeled
  rows and labels missing from the aux file keep the standalone numbering. Numbers
  are re-read on `User VimtexEventCompileSuccess` and on `BufEnter` when the aux
  file's mtime changed.
- **Math conceal.** vimtex conceals math as unicode (`\alpha` -> `α`, `^2` -> `²`,
  `\mathbf{x}` -> bold `x`, `\left(` -> `(`) and, because inkmath sets
  `concealcursor=nvic`, that would also apply to the source of the formula under the
  cursor. vimtex's switch `g:vimtex_syntax_conceal` (`:h g:vimtex_syntax_conceal`) is
  global and read when the syntax rules are defined, so for each attached buffer
  inkmath reloads that buffer's syntax with the global temporarily patched
  (`math_bounds`, `math_delimiters`, `math_fracs`, `math_super_sub`, `math_symbols`,
  `greek`, `styles`, `spacing` set to 0; your other keys unchanged) and restores the
  global right after. Other buffers keep your settings. vimtex has one key for math
  and text in `styles` and `spacing`, so `\textbf{..}`/`\quad` in text are not
  concealed in attached buffers either; accents, ligatures, cites, `\item` and
  sections are untouched. The reload is repeated after other syntax reloads and
  after `User VimtexEventInitPost`/`VimtexEventCompileSuccess` (vimtex loads package
  syntax then), and `:InkMath disable` reloads the syntax with your settings. To keep
  vimtex's math conceal, set `vimtex = { math_conceal = true }`.

## Commands

`:InkMath enable|disable|toggle|refresh|clear-cache|build|status` act on the
current buffer; `:InkMath! enable|disable|toggle` on every buffer. `build` runs
`npm ci` in `worker/` (and attaches buffers that lacked a backend), `status`
prints the backends, workers, render queue, cache size, resident images (against
`max_images`) and attached buffers (placed images, background fill state).
No keys are mapped; `<Plug>(inkmath-toggle)` and friends are listed in
`:help inkmath-mappings`. Lua API and `User InkMath*` events: `:help inkmath-api`.

## Development

```sh
./dev/run.sh [file]            # isolated nvim (NVIM_APPNAME=inkmath-dev), default dev/samples/document.tex
./dev/run.sh dev/samples/multiline.md --tmux   # same, inside a private tmux server
make test                      # all Lua tests (mini.test)
make test-file F=tests/test_samples.lua
make test-worker               # node tests for the MathJax worker
make doc                       # regenerate the options section of doc/inkmath.txt
```

Sample files live in `dev/samples/`. `tests/test_samples.lua` smoke-tests all of
them against a stubbed terminal.

## Manual verification

These need a real Ghostty/kitty window and have not been ticked off yet.

```sh
./dev/run.sh dev/samples/document.tex
./dev/run.sh dev/samples/inline.md
./dev/run.sh dev/samples/multiline.md
./dev/run.sh dev/samples/broken.tex
./dev/run.sh dev/samples/multiline.md --tmux   # run from Ghostty
```

- [x] 1. Inline math sits on the text baseline.
- [x] 2. Display blocks are centered.
- [x] 3. `align` shows equation numbers (document order without an .aux file).
- [ ] 4. `<C-d>`/`<C-u>` scrolling keeps images aligned.
- [ ] 5. `:vsplit` shows images in both windows.
- [ ] 6. `zfap` fold + `zo` hides and shows correctly.
- [ ] 7. The cursor in a formula shows its source, and the preview float updates while typing in insert mode.
- [ ] 8. `:colorscheme default` re-renders in the new color.
- [ ] 9. `broken.tex` shows diagnostics and leaves the source visible.
- [x] 10. `\$5` and code-block dollars stay as text.
- [ ] 11. Adjacent environments: two `equation` blocks (and two `$$` blocks in
      markdown) with no line between them both show their image.
- [ ] 12. Type `$` mid-paragraph in `document.tex`: the images below stay; after
      deleting it (or closing it) everything renders normally again.
- [ ] 15. `conceal = false` with render-markdown.nvim (latex off): images show in
      normal mode, hide while render-markdown sets `'conceallevel'` 0, and a
      `:setlocal conceallevel=0` typed there does not stick after `:b#`.
- [ ] 16. snacks.nvim with `image.enabled = true, math.enabled = false`: snacks
      images and inkmath's math coexist; `:checkhealth inkmath` shows "ok".
- [ ] 17. A `.qmd` file (quarto) renders like markdown.
- [ ] 18. Typing in a large `.tex` file never stutters; in insert mode inside a
      broken formula the preview float shows the TeX error.
- [ ] 19. `:InkMath status` lists the attached buffer and the cache.

In tmux (`--tmux`), repeat 1-12 and also:

- [ ] 13. Switch tmux windows and come back: images are still there.
- [ ] 14. Detach (`prefix d`) and `tmux -L inkmath attach`: images come back.

## Limitations

- Each formula renders standalone, so numbered equations show `(1)` rather than the
  document's real number, except labeled equations in a vimtex project that has been
  compiled (see [vimtex](#vimtex)). Unlabeled rows, numbers that are not plain
  (`\textup{A}1`) and projects never compiled still show the standalone numbering.
- Display width is taken from the first window showing the buffer.
- The tectonic fallback relies on tectonic's unstable `-Z continue-on-errors` flag
  (checked by `:checkhealth inkmath`).
- Typst, org and terminals other than Ghostty/kitty are not supported.
- An unclosed `$` or `{` in LaTeX source breaks the treesitter parse of the rest of
  the document. This is mitigated: while the parse has errors, the images already
  shown are kept (they move with the text) and nothing new is rendered or cleared;
  normal updates resume once the parse is clean again. A file that has had errors
  since it was opened is still refreshed as is, so formulas after the error may be
  missing there until it is fixed.
- Closed folds: Neovim does not draw virt_lines or concealed lines inside a closed
  fold, but it does draw a display image's first row over the fold line when the
  block starts the fold. So display images whose first line is inside a closed fold
  are not placed, in every window showing the buffer (folds are per window, images
  per buffer), and are placed again when the fold opens. Fold changes are noticed
  when the current window redraws; a fold changed in another window is picked up at
  the next refresh (scroll, edit, `BufEnter`). Works with any 'foldmethod',
  including vimtex's (`g:vimtex_fold_enabled`, `g:vimtex_fold_manual`).
- The plugin sets `conceallevel`/`concealcursor` for attached windows (configurable,
  see `:help inkmath-config`).
