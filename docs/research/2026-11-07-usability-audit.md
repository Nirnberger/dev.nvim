# inkmath.nvim usability audit (branch feat/inkmath, 2026-11-07)

Read-only audit of the code as of commit 62d7038. Citations are `file:line`. Items marked
(unverified) are inferences about other plugins' behaviour, not tested here.

## Top 10 improvements (effort S/M/L)

| # | Improvement | Effort |
|---|---|---|
| 1 | Add `plugin/inkmath.lua` (defines `:InkMath`, no `setup()` needed, optional auto-start), plus a `vim.g.inkmath` / defaults path so a missing `setup()` still works | S |
| 2 | Guard `attach`: skip non-file buffers (`buftype ~= ""`: LSP hover floats, cmp/blink docs, chat/prompt buffers), add `enabled(buf)` predicate and `vim.b.inkmath_disable` / `vim.g.inkmath_disable`, add a `max_filesize` / `max_lines` limit | S |
| 3 | Make disable sticky and add global scope: `:InkMath enable/disable/toggle [!]`, state survives `FileType` re-fire, `require("inkmath").enable(buf)` etc. | M |
| 4 | Fix the preview float for invalid TeX (it keeps showing the last good image), and make float `border`/`winhighlight`/placement configurable (honour `vim.o.winborder`) | S |
| 5 | Ship `doc/inkmath.txt` (`:help inkmath`) and a minimal public API: `is_rendered(buf, pos)`, `node_at(buf, pos)`, `render_to_image(tex, opts, cb)`, `status()`, `User InkMath*` events | M |
| 6 | Coexistence: offset the kitty image-id range / make it configurable (snacks.image), stop fighting over `conceallevel` with render-markdown/markview (opt-out `conceal.manage = false`, no sticky `user_cl0` on plugin-driven changes), document "disable their latex" recipes | M |
| 7 | Config hygiene: reject unknown keys (typos pass silently), wrap errors in a readable message, apply config live (re-run `setup()` => refresh attached buffers, re-apply conceal), do not reset unspecified keys on a second `setup()` | M |
| 8 | Expose hard-coded knobs: `node_path`, `tectonic_path`, `magick_path`, `cache_dir`, `timeout_ms`, per-kind enable (`inline`/`display`), per-filetype overrides, `log_level`, preview `border/position/size`, `max_formula_len` | M |
| 9 | Feedback: `:InkMath status` (backend, workers, queue length, cache size/path, last errors), `:checkhealth` pointer in notifications, progress counter for statusline (`require("inkmath").status()`), notify after `build` finishes and re-attach open buffers; make `notify_once` re-arm after the cause is fixed | M |
| 10 | Disk cache management: size/age cap (cache grows unbounded, only `clear-cache` frees it), `:InkMath cache-dir`/`cache-size`, key includes MathJax/worker version | M |

## 1. Config surface

### Configurable today (`lua/inkmath/config.lua:3-22`)
filetypes, backend, fallback, highlight (fg colour source group only), scale,
inline.{x_height,baseline,promote,promote_ratio}, display.center, preview.{enabled,debounce_ms},
debounce_ms, max_images, workers, cell_size, macros, conceal.{level,cursor},
vimtex.math_conceal.

Caveats on those:
- `filetypes` is effectively not extensible: attach accepts any listed ft (`init.lua:61-66`)
  but `detect` only knows `markdown` and `tex` (`detect/init.lua:11-14`), and `ctx.build` only
  handles `tex`/`markdown` (`ctx.lua:179-184`). Adding `quarto`, `rmd`, `plaintex` attaches,
  sets conceallevel (`core.lua:534-552`) and renders nothing. Note `.tex` files that Neovim
  types as `plaintex` (no `g:tex_flavor`) are never handled; README does not mention it.
- `display.center` and `inline.*` are per-kind but there is no switch to turn a kind off
  (`detect` always returns both).
- `macros` is global only; there is no per-filetype/per-buffer option table at all.

### Hard-coded but should be configurable
| What | Where |
|---|---|
| Preview float: `border = "rounded"`, `style = "minimal"`, `focusable=false`, anchor `bufpos={erow,scol}`, `row=1,col=0`, size = image size, no `winhighlight`/`zindex`/`title` | `view/cursor.lua:144-159` |
| Error highlight `InkMathError` (link, `default=true`, so user-overridable, OK) | `core.lua:67` |
| Error severity ERROR, diagnostic source/namespace | `core.lua:151-153` |
| Image colour: only fg from one hl group; no explicit hex, no light/dark override | `ctx.lua:175-176` |
| node path: `vim.fn.exepath("node")` | `render/mathjax.lua:31` |
| tectonic/magick paths: `exepath(...)`, `gs` only via health | `render/tectonic.lua:20,203,207` |
| Cache dir `stdpath("cache")/inkmath` | `render/cache.lua:21-23` |
| MathJax request timeout 10 s (module field, not config) | `render/mathjax.lua:5` |
| Tectonic job timeout 120 s | `render/tectonic.lua:297` |
| In-flight MathJax cap `_max_inflight = 8` | `core.lua:~300` (`M._max_inflight`) |
| Worker restart cap `MAX_RESTARTS = 3` | `render/mathjax.lua:4` |
| Reveal behaviour (visual mode reveals every node touching the selected rows; insert is inclusive of the end col) | `view/cursor.lua:39-55` |
| Scan window/margins for rendering (visible + 1 screen) | `core.lua:~400-440` |
| Fold behaviour: display nodes in closed folds are not placed | `view/folds.lua` |
| Keymaps: none provided (no toggle/reveal/peek mapping, no `<Plug>`) | whole repo |
| Log level / debug log: absent; everything is `vim.notify` with fixed levels | `core.lua:49-63` |
| Max formula size/length, max image cols/rows: no limit anywhere (only the 10 s timeout) | worker, `render/init.lua` |
| Max buffer size: none | `core.lua:718-760` |

### Validation quality
- Types and ranges of known keys are validated (`config.lua:30-66`) using the
  `vim.validate(name, value, validator, msg)` form, which is deprecated-style in 0.11 but works.
- Unknown keys are accepted silently (typo `scal = 2` does nothing).
- `filetypes` elements are not checked (`config.lua:31`), `macros` values not checked
  (non-string reaches the worker), `highlight` group existence not checked (falls back to white/black).
- Failure mode is an uncaught `error()` with the raw `vim.validate` message and Lua traceback
  from `setup()`; fine for lazy.nvim but not friendly.

### setup() required? Twice? Live?
- Required for anything to happen automatically: the only thing that registers the `FileType`
  autocmd is `init.setup` (`init.lua:57-68`). Without it nothing attaches, and `:InkMath` is
  not defined until something `require`s `inkmath` (see section 3). Defaults are otherwise used
  (`config.lua:24`), so `:InkMath enable` works after a manual `require("inkmath")`.
- Called twice: works. `config.setup` re-merges onto the *defaults*, not the previous config
  (`config.lua:70`), so keys given only in the first call are lost; the `inkmath_filetype`
  group is cleared and recreated (`init.lua:60`). Not additive, not documented.
- Live changes: mostly read per use (`debounce_ms`, `workers`, `preview.*`, `max_images`,
  `scale`, `inline.*` via `config.get()` and cache key `render/cache.lua:51-53`) but `setup()`
  does not trigger `refresh_all`, does not re-apply `conceal.*` to attached windows, does not
  attach already-open buffers (`init.lua` has no `nvim_list_bufs` loop; with `event=VeryLazy`
  or late `setup()`, buffers already open are not attached), and changing `filetypes` does not
  detach buffers of removed filetypes. The `highlight` colour only updates on `ColorScheme`
  (`core.lua:~612`).

## 2. Commands / API

### `:InkMath` (`init.lua:6-54`)
- Subcommands: `enable`, `disable`, `toggle`, `refresh`, `clear-cache`, `build`. All act on the
  **current buffer** (`enable/disable/toggle/refresh`) or globally (`clear-cache`, `build`).
- `nargs = 1`: `:InkMath` with no argument gives Neovim's generic E471; extra args are ignored.
- Completion: prefix filter over `vim.tbl_keys(subcommands)`, unsorted (`init.lua:51-53`), no
  `:InkMath!`, no argument completion.
- Errors: unknown subcommand => `vim.notify` ERROR with a usage line (`init.lua:43`). `clear-cache`
  is silent on success. `build` prints start/finish; npm missing is handled (`init.lua:27,36`) but
  after a successful build nothing re-attaches buffers that failed with "no render backend"
  (`core.lua:731-733` returns false) and the message does not tell the user to `:InkMath enable`.
- No `status`, `info`, `log`, `cache-dir` subcommands.

### Lua API (`init.lua`)
Public: `setup(opts)` and `worker_dir`. Everything else is internal modules with no stability
promise: `core.attach/detach/is_attached/refresh/refresh_all/clear_cache/ctx`
(`core.lua:718,778,819-821,826,129`).
- Enable/disable: per buffer only (`enable`/`disable` use current buf, `init.lua:7-14`). No
  global switch; no `vim.b.inkmath_disable`/`vim.g.inkmath_disable` (grep finds none); no
  `enabled = function(buf) end` predicate. Disable is not sticky: a re-fired `FileType`
  (`:e!`, `:set ft=`, reload) re-attaches (`init.lua:61-66`).
- `<Plug>` mappings: none. Keymaps: none.
- User autocmd events: none emitted (no `nvim_exec_autocmds` in `lua/`). Plugin only *listens* to
  `User VimtexEventCompileSuccess/InitPost` (`core.lua:~626`).

### What another plugin would need and can get today
| Need | Status |
|---|---|
| Is a range rendered? | `require("inkmath.view.state").get(buf).nodes[id]` has `node.range` and `marks`; internal, ids are content hash + `#n` |
| Formula under cursor | `detect.detect(buf,row,row)` + own hit test (`core.lua` on_cursor logic, `cursor.contains` is exported) |
| Render an arbitrary string to an image | `render.render(node, ctx, cb, opts)` works with a hand-built node `{id,kind,src,range}` and `core.ctx(buf)`, then `images.ensure` + `placer.placeholder_rows` for a float (this is what `view/cursor.lua:128-161` does). Undocumented, needs a buffer ctx |
| Events when rendering finishes / errors | none |
| Pause rendering for a buffer | only `detach` |

## 3. Lazy loading

- No `plugin/` dir, no `ftplugin/`, no `doc/` (confirmed by `ls`). The `:InkMath` command is
  created at `require("inkmath")` time (`init.lua:49`), so the command does not exist until the
  module is required. With lazy.nvim, `opts = {}` triggers `require("inkmath").setup` on load, so
  it works; with `ft = {...}` lazy loads on FileType and re-fires it, so the new autocmd
  catches the buffer (README recipe, `README.md` Install). With `cmd = "InkMath"` lazy-loading
  it would fail (no stub command) unless the user adds `cmd`, which then loads and registers it.
- Cost when required: low. `init.lua` requires nothing at top level; `config` is loaded in
  `setup`; `core` (843 lines, requires 15 modules: treesitter detect, term, render, vimtex) is
  only loaded by the first attach/subcommand (`init.lua:8`, pcall at `:65`). No ffi/cdef or
  spawn until attach (`cells.lua:15` lazily). Good.
- Without `setup()`: nothing attaches (above). A `plugin/inkmath.lua` that registers the command
  and, if `vim.g.inkmath` / defaults say so, the FileType autocmd would fix this and also make
  `build = ":InkMath build"` robust (today it relies on lazy loading the plugin and running
  `opts` first).
- Silent attach failures: `FileType` callback is `pcall(attach)` (`init.lua:65`) so an
  exception during attach is swallowed with no message.

## 4. Usability gaps (user view)

- **First run**: install node deps via `:InkMath build` (`npm ci`, async, `init.lua:25-37`). If
  the user opens a `.tex` file before it finishes, attach returns false with a once-only warning
  (`core.lua:731-733`) and does not retry after build completes. `notify_once` is keyed by cause
  forever (`core.lua:46-51`), so fixing the problem and breaking it again never re-warns.
  `:checkhealth inkmath` exists (`health.lua`) and is thorough (nvim version, parsers, kitty,
  termguicolors, tmux passthrough/RGB, node deps, tectonic flag, magick/gs, cell size) but is
  only mentioned in README, not in the notifications.
- **node missing**: `mathjax.available()` false => falls back to tectonic silently if present
  (`render/init.lua:149`); if both missing => single warning (`core.lua:731-733`). node present but
  `node_modules` missing => same "run :InkMath build". tectonic missing while MathJax errors =>
  the MathJax error is shown (`render/init.lua:155-163`). OK. `magick` required for tectonic
  (`tectonic.lua:20`); a missing `gs` is only caught by health.
- **Terminal support**: unsupported terminal => one warning and no images (`core.lua:723`).
  `kitty.supported()` shells out to tmux with `vim.fn.system` (blocking) in the attach path
  (`term/kitty.lua:72`), as does tmux passthrough detection (`term/tmux.lua:22`).
- **conceallevel**: plugin forces window-local `conceallevel=2`, `concealcursor=nvic` on every
  attached window at attach and at each `BufWinEnter` (`core.lua:534-552, 757`) and restores on
  detach. This overrides the user's value (e.g. 3) for *all* other conceal too (markdown links,
  emphasis). Configurable via `conceal.*` but there is no "do not touch" option
  (`conceal.level = nil`). Setting conceallevel to 0 hides all images (`core.lua:378-385,
  648-680`), a nice toggle but undocumented as a feature beyond README and sticky per window.
- **Insert mode**: formula under the cursor reveals source (inclusive end col,
  `cursor.lua:49`) and a debounced live preview float opens below it (`core.lua:570-605`). The
  float only uses MathJax (`no_fallback`, `cursor.lua:173-177`). **Gap**: on a TeX error the
  preview callback returns early (`cursor.lua:174`), so the float keeps showing the previous good
  image while the source is invalid; no error text is shown in the float either.
- **Visual mode**: any node overlapping the selected *rows* is revealed
  (`cursor.lua:39-54`). `V` over a screenful reveals and reflows everything. Probably intended
  (so you can see what you select) but not configurable.
- **wrap / nowrap**: display images are overlay + virt_lines (`placer.lua:100-122`), clipped at
  the window edge, never wrapped; inline images are inline virt_text. Display width is taken from
  `textwidth` or the *first window's* width (`ctx.lua:185-192`); README lists this limitation.
- **Splits showing the same buffer**: images placed per buffer (extmarks), so both windows show
  them. The container width (and thus display image width) is the first window's, so different
  widths mis-center in the other (documented). Fold hiding applies if any window folded it
  (`folds.lua:30-36`); conceallevel 0 in any window hides all (`core.lua:378`).
- **Docs**: only README.md (201 lines). No `doc/inkmath.txt`, so `:help inkmath` fails. README
  has an unticked manual verification checklist (README "Manual verification").
- **Statusline / progress**: none. No API to read queue length / pending count (`core.lua:
  M._queue` is a test hook). Renders for cold buffers silently pop in. `M._max_inflight = 8`
  limits queueing but gives no feedback.
- **Bad LaTeX**: handled well: failed render clears the placement so the source stays visible,
  sets `InkMathError` extmark highlight and a `vim.diagnostic` entry in namespace
  `inkmath_err` with the MathJax message (`core.lua:~140-155, 270-273`), source `inkmath`.
  Diagnostics follow the user's `vim.diagnostic.config`; no way to turn them off other than
  `vim.diagnostic.enable(false, {ns_id=...})`. The treesitter-parse-error freeze for unclosed
  `$` is documented (README Limitations).
- **Clearing the cache**: `:InkMath clear-cache` (`core.lua:826-845`) deletes
  `stdpath("cache")/inkmath` (`cache.lua:116-118`) and re-renders. The location is not
  documented in README and there is no size/age cap or version in the key.
- Large buffers/non-file buffers: no `buftype` check in attach (grep `buftype` in `core.lua`: none),
  so any buffer of a listed filetype attaches, including LSP hover/signature floats (filetype
  `markdown`), completion doc windows, and chat/prompt buffers of AI plugins (unverified which
  of these set ft=markdown, but ft=markdown scratch buffers are common). There is also no
  max file size / line count.

## 5. Coexistence risks and global state

### State the plugin mutates
| Global state | Where | Note |
|---|---|---|
| Window-local `conceallevel`/`concealcursor` of attached windows | `core.lua:534-552` | saved/restored per buf+win on detach; `BufWinEnter` re-applies |
| `vim.g.vimtex_syntax_conceal`, temporarily patched then restored | `vimtex.lua:134-143` | safe in single thread, but a sync error between patch and restore is guarded by pcall; also reloads buffer syntax |
| Highlight groups `InkMathImg<id>` (one per image, `fg=#id`, `default=false`) | `term/images.lua:85-90` | up to `max_images`+ groups, wiped by `:hi clear`, handled on `ColorScheme` (`core.lua:612-621`); visible in `:hi`, break themes that enumerate groups |
| `InkMathError` (link, default) | `core.lua:66-68` | friendly |
| Decoration provider `inkmath_folds` | `core.lua:685` | global `on_win`, returns false |
| Autocmds | groups `inkmath` (`core.lua:24`), `inkmath_filetype` (`init.lua:60`), `inkmath_cellquery` (`cells.lua:44`) | all grouped; the `TermResponse` one is deleted after use |
| `OptionSet conceallevel` global autocmd | `core.lua:645-680` | reacts to *anyone's* conceallevel changes |
| Terminal: kitty graphics image ids `1..N`, deleted with `d=I` | `term/images.lua:5-9`, `kitty.lua:60` | no namespace/offset; `VimLeavePre` only stops workers (`core.lua:706`), terminal images are not deleted at exit |
| `g:` vars owned by inkmath | none | good; no global options (`vim.o.*` writes) set |

### Specific plugin risks
- **render-markdown.nvim / markview.nvim**: both manage `conceallevel`/`concealcursor` per
  window (render-markdown `win_options`), both also render `$..$` math themselves (latex
  converters/virt text). Two problems: (a) both plugins write the same window options; the
  last writer wins and inkmath's `OptionSet` handler treats a drop to 0 by *another plugin* as
  the user hiding images and stores it sticky in `user_cl0` (`core.lua:648-671`), hiding all
  images until conceal is raised in that window again (unverified interaction, but the code path
  does not distinguish the source of the change). (b) double rendering of math: users must
  disable the other plugin's latex feature; README does not say so. inkmath hides source with
  `conceal=""` extmarks, which these plugins' anti-conceal logic may un-conceal on the cursor row
  (unverified).
- **snacks.image**: also uses kitty Unicode placeholders and renders `$..$`/`\[..\]` in markdown
  and tex by default (`doc.inline`/`math`). Both use placeholder fg colour = image id, and inkmath
  ids start from 1 (`images.lua:8`), so id collisions in the terminal are plausible; inkmath's
  `d=I,i=<id>` delete (`kitty.lua:60`) would then remove the other plugin's image
  (unverified, depends on snacks id allocation). Also double render unless snacks' math is off.
- **vimtex conceal**: handled explicitly (reloads syntax with math conceal off, repeated on
  `Syntax`, `VimtexEventInitPost`, `VimtexEventCompileSuccess`; `core.lua:~626-640, 760-766`).
  Side effect: `\textbf`/`\quad` conceal disabled too (`vimtex.lua:120-123`, documented). Other
  buffers keep user settings.
- **nvim-ufo**: ufo folds use manual foldmethod + virt text; inkmath asks `foldclosed()`
  per window (`folds.lua:22-23`), so display images in closed folds are hidden; ufo's fold text
  overlay vs inline images on the fold line is described in `folds.lua` header (only correct with
  `foldtext=""`). Likely compatible but untested (unverified).
- **Completion popups (nvim-cmp / blink.cmp)**: inline images are `virt_text_pos="inline"` with
  conceal, which shifts text columns on the line; menus anchored by screen column should follow
  `screenpos` and are fine; ghost text in the same line may misalign (unverified). Completion doc
  windows with `ft=markdown` are attach candidates (no `buftype` guard, section 4).
- **Other**: noice/hover/telescope previews with `ft=markdown`: same no-buftype-guard issue.
  Image eviction pins only images in attached buffers and previews (`core.lua:~162-180`),
  fine.

## Positive notes
Solid design: guarded callbacks (`core.lua:57-64`), generations to drop stale renders, cache keys
include scale/cell/container/macros, window-local option restore on detach, health check, fold
and vimtex awareness, tests for most modules (`tests/*.lua`, 20 files).

## Suggested order
1, 2, 4 (quick wins, S), then 3, 5, 6 (integration, M), then 7-10.
