# inkmath.nvim

Neovim plugin: renders LaTeX math (tex/markdown/quarto/rmd) as images via the kitty graphics
protocol (Unicode placeholders; Ghostty, kitty, through tmux). Lua plugin + Node worker.

## Layout
- `lua/inkmath/`: `core` (attach/redraw), `detect/` (treesitter), `render/` (mathjax worker, tectonic
  fallback, cache, queue), `term/` (kitty, tmux, cells, images), `view/` (placer, conceal, folds),
  `config/schema.lua` (all options; `doc/inkmath.txt` is generated from it), `interop.lua`, `vimtex.lua`.
- `worker/`: MathJax + resvg (`mathjax.mjs`), own tests in `worker/test/`.
- `tests/`: mini.test, one `test_*.lua` per module; `helpers.lua`, `minit.lua` (bootstrap).
- `dev/`: `run.sh [file] [--tmux]` manual run, `bench.lua`, samples. `docs/`: specs/reports (history).
- `scripts/ci-tools.sh`: CI tool install (nvim, tree-sitter, tectonic, imagemagick).

## Commands
- `make test` (all), `make test-file F=tests/test_x.lua`, `make test-worker` (needs `cd worker && npm ci`),
  `make deps` (clone mini.nvim + treesitter parsers), `make doc` (regenerate help), `make bench`.
- `cd worker && npm ci` once; `:InkMath build` does the same for users.

## Test env
- Needs on PATH: nvim >= 0.12, node >= 18, `tree-sitter` CLI + C compiler (parsers), `tectonic`, `magick` (IM7).
  Binaries I download go to `~/.local/bin`.
- Tectonic tests skip themselves without tectonic/magick (`helpers.need_tectonic()`).
- Tests set a temp `XDG_CACHE_HOME`; `minit.lua` keeps tectonic's bundle cache on the real path
  (cold cache = minutes of downloads = timeouts).
- Timing limits scale with `INKMATH_PERF_FACTOR` (CI uses 3; `helpers.perf(ms)`).
- `tests/test_kitty_real.lua`: real kitty under `xvfb-run` (placeholders via `kitty @ get-text --ansi`, `--dump-commands`,
  Xvfb `-fbdir` pixels). Skips without kitty/xvfb-run; `INKMATH_REQUIRE_KITTY=1` (set by ci-tools.sh on Linux) makes that a failure.
- `tests/test_matrix.lua`: terminal env matrix + real tmux on a private socket (skips without tmux;
  `allow-passthrough all` needs tmux >= 3.4).

## Conventions / pitfalls
- Options live only in `config/schema.lua`; run `make doc` after changing them (test_doc checks it).
- Interop probes (`interop.lua`) read `package.loaded` only: never load other plugins.
- `node --test test/` breaks on Node 22: use `test/*.test.mjs`.
- `.github/workflows/` can't be pushed by the bot: commit on the branch, don't push, hand the hash to the owner.
