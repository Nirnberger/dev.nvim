# Similar plugins to inkmath.nvim: landscape survey (2026-11-07)

Method: GitHub READMEs, `gh api` repo metadata (`pushed_at`, stars, open issues; pulled 2026-11-07), issue searches, and a few source greps. "Last push" is the repo-wide `pushed_at` value, which may include non-default branches. Items marked (unverified) were not confirmed on a primary page.

## Comparison table

| Plugin | Last push | Approach | Terminal / tmux | Inline | Display / multi-line | Cursor reveal / live preview | Backend |
|---|---|---|---|---|---|---|---|
| snacks.nvim image | 2026-05-25 | Image (kitty placeholders) | kitty, ghostty; tmux via passthrough; no zellij; WezTerm no inline | yes | yes (treesitter-found math nodes) | `doc.inline` or `doc.float` hover; conceal experimental | tectonic or pdflatex, then ImageMagick; typst |
| mdmath.nvim (Thiago4532) | 2024-12-27 (stale) | Image (kitty placeholders) | kitty >=0.28, ghostty; tmux via passthrough | yes (md only) | "dynamic size" for non-inline | anti-conceal at cursor, hide in insert | Node (MathJax, per README) + rsvg-convert + ImageMagick |
| mdmath forks (ApexGP, e-denny) | ApexGP 2026-11-07 | same, maintained fork | kitty, ghostty >=1.0; macOS tested | yes | dynamic width/height | same plus `checkhealth` | same |
| typst-concealer | 2026-08-19 | Image (kitty placeholders), Typst | kitty, ghostty only; tmux partial | yes | yes (math/code blocks) | live preview in insert mode | typst |
| image.nvim | 2026-09-04 | Generic image layer, no math | kitty, sixel, ueberzugpp; first-class tmux | n/a | n/a | n/a | ImageMagick |
| render-latex.nvim (techwizrd) | 2026-10-17 | Image for display math; conceal/highlight for inline | kitty-compatible or nvim image API; tmux via passthrough | conceal fallback, no image | yes (`$$`, `\[ \]`) | `live_preview`, equation toggle; no documented cursor reveal | Rust worker (RaTeX) |
| latex-preview.nvim (sonv) | 2026-10-03 | Hover float image via snacks | kitty tested; tmux not documented | yes (at cursor) | yes | hover at cursor, 300 ms debounce | MathJax 4 persistent Node + rsvg-convert |
| mathjax.nvim (SleepySwords) | 2024-10-29 (dead) | Image via image.nvim | kitty | no | `$$` blocks only | manual command | MathJax via Node |
| latexrenderer (ArbitRandomUser) | 2023-03-14 (dead) | Image via hologram.nvim | kitty, Linux | no | `$$` blocks | manual | dvipng |
| nabla.nvim | 2025-04-21 | ASCII art in float | any | popup | popup | popup on keypress, not live | built-in Lua parser (treesitter) |
| utftex.nvim | 2026-07-27 (Codeberg) | Unicode art in extmarks | any | no (fenced `latex` blocks) | yes | concealed in normal mode, live | `utftex` binary |
| render-markdown.nvim LaTeX | 2026-10-10 | Unicode / text virtual lines | any | yes | yes | cursor-line anti-conceal | utftex, then latex2text |
| unicode-math.nvim | 2025-06-10 | Unicode text rewrite | any | yes | partial | live (debounced) | Lua tables; "katex" option undocumented |
| sigil.nvim | 2026-04-28 | Symbol prettify (alpha to α) | any | yes | n/a | `unprettify_at_point` | none (tables) |
| vimtex conceal | 2026-11-06 | Syntax conceal | any | yes | no layout | `concealcursor` | none |
| Emacs: org-latex-preview, xenops, math-preview | see sections | Images (SVG) | GUI Emacs | yes | yes | auto-toggle (xenops, org) | LaTeX + dvisvgm; MathJax (math-preview) |

## Per-plugin notes

### snacks.nvim image (folke)
- Repo: https://github.com/folke/snacks.nvim. Last push 2026-05-25, about 8.2k stars, about 150 open issues (https://api.github.com/repos/folke/snacks.nvim).
- Approach: image, kitty graphics with Unicode placeholders. Math in `markdown` and `latex` files, plus Typst math (https://github.com/folke/snacks.nvim/blob/main/docs/image.md).
- Terminals: kitty and ghostty. WezTerm gets no inline rendering. zellij is unsupported. tmux works, and snacks tries to set `allow-passthrough` itself (same doc). Tmux support and tectonic landed in v2.21.0 (https://newreleases.io/project/github/folke/snacks.nvim/release/v2.21.0).
- Backend: source shows tectonic and pdflatex commands, plus typst, followed by ImageMagick conversion, with outputs cached in a cache directory (https://raw.githubusercontent.com/folke/snacks.nvim/main/lua/snacks/image/convert.lua). A user reports about 0.4 s per equation with tectonic versus about 0.13 s with pdflatex and a custom template (via search result, unverified; see https://github.com/folke/snacks.nvim/blob/main/docs/image.md).
- Config: `math.latex.font_size`, `math.latex.packages`, `math.latex.tpl` templates, `snacks: header` comment blocks for per-document preamble, `doc.max_width` and `doc.max_height`, experimental `doc.conceal` (docs link above).
- Limitations from issues:
  - Ghost or duplicate text with conceal: https://github.com/folke/snacks.nvim/issues/2821
  - Lines hidden at `conceallevel` >= 2 for some environments: https://github.com/folke/snacks.nvim/issues/2569
  - Cropping with conceal and treesitter: https://github.com/folke/snacks.nvim/issues/2391
  - White halos on dark backgrounds: https://github.com/folke/snacks.nvim/issues/2644
  - A lone `$c$` is scaled to fill a row, so it appears huge (reported in secondary sources; Typst variant: https://github.com/folke/snacks.nvim/issues/2612)
  - Clipped long equations: https://github.com/folke/snacks.nvim/issues/2101
  - A bare `=` on its own line breaks rendering: https://github.com/folke/snacks.nvim/issues/2451
  - Images not re-rendered on buffer re-entry: https://github.com/folke/snacks.nvim/issues/2634
- Borrow: `snacks: header` comment blocks for a per-document preamble; template placeholders (`${header}`, `${content}`, `${color}`); a documented `checkhealth`.
- Closest competitor: it is the only mainstream plugin with the same transport (placeholders, tmux) and both tex and md support. It has no cursor-reveal UX of its own and no MathJax path.

### mdmath.nvim (Thiago4532) and forks
- Repo: https://github.com/Thiago4532/mdmath.nvim. Last push 2024-12-27, 241 stars, alpha status (https://api.github.com/repos/Thiago4532/mdmath.nvim). Effectively dormant upstream.
- Active forks: https://github.com/ApexGP/mdmath.nvim (pushed 2026-11-07) and https://github.com/e-denny/mdmath.nvim. The ApexGP fork adds `checkhealth`, a protocol-version check between the Lua client and the Node processor, a `file`/`direct`/`auto` transfer mode, LuaCATS annotations, tests, benchmarks, and a release workflow.
- Approach: images through kitty with Unicode placeholders, Markdown only, inline equations only upstream. Node server in `mdmath-js`, with ImageMagick and `rsvg-convert` (https://github.com/Thiago4532/mdmath.nvim).
- Terminals: kitty >= 0.28, ghostty >= 1.0 (fork). WezTerm and Konsole lack placeholders, so the fork keeps source visible and warns once. tmux needs `allow-passthrough`.
- Cursor behavior: anti-conceal when the cursor is on the equation, optional hide in insert mode, 400 ms update interval.
- Issues: tmux not working (closed) https://github.com/Thiago4532/mdmath.nvim/issues/5, macOS pixel-size ioctl failure https://github.com/Thiago4532/mdmath.nvim/issues/2.
- Borrow: protocol version handshake between Lua and the Node worker; transfer mode switch (file vs direct payload); `checkhealth`.

### typst-concealer (PartyWumpus)
- Repo: https://github.com/PartyWumpus/typst-concealer. Last push 2026-08-19, 65 stars, 3 open issues.
- Approach: image, kitty Unicode placeholders, Typst. ghostty and kitty only. tmux is partial: two plugin instances can overwrite each other's images. zellij unsupported.
- Features: live preview as you type in insert mode, math and code blocks, three styling modes ("colorscheme", "simple", "none") that match the colorscheme, optional diagnostics, per-buffer toggle.
- Limitations: spacing rule for inline math, occasional escape-sequence garbage on screen, transparency bug, dangling image IDs on close (all from the README TODO list).
- Borrow: matching the colorscheme foreground and background automatically; cleanup of dangling image IDs on buffer close; showing compiler diagnostics at the equation.

### image.nvim (3rd)
- Repo: https://github.com/3rd/image.nvim. Last push 2026-09-04, about 2.1k stars, 78 open issues.
- No math support. LaTeX request still open: https://github.com/3rd/image.nvim/issues/189. Backends are kitty, ueberzugpp, and sixel. Claims first-class tmux (>= 3.3, `allow-passthrough on`, `visual-activity off`, `focus-events on`). Ghostty is "preliminary". Requires ImageMagick (https://github.com/3rd/image.nvim).
- Relevance: a dependency for mathjax.nvim, not a competitor. Its tmux checklist (focus-events, visual-activity) is worth copying into inkmath's health check.

### render-latex.nvim (techwizrd; AndreaCovelli is a fork)
- Repo: https://github.com/techwizrd/render-latex.nvim. Last push 2026-10-17, 63 stars, 13 open issues. Fork: https://github.com/AndreaCovelli/render-latex.nvim (pushed 2026-11-02).
- Approach: display math (`$$`, `\[ \]`) as transparent PNG images. Raw LaTeX stays in the buffer. Inline math deliberately uses conceal or highlight to avoid flicker. A persistent Rust worker based on RaTeX batches visible equations, keeps a warm cache, and prefetches in the scroll direction. Prebuilt workers for Linux, macOS, and Windows are auto-installed.
- Requirements: Neovim 0.10+, Neovim image API or kitty-compatible terminal. tmux needs `allow-passthrough on`, with a `:RenderLatex tmux_check` command. Placeholder-based rendering is listed as planned, not done.
- Status: early release; folding, inline display-math, SVG, and download checksums are not implemented. It conflicts with render-markdown.nvim's LaTeX rendering, which must be disabled.
- Borrow: visible-range batching with directional prefetch; prebuilt worker binaries with a checksum; `:Cmd tmux_check`; `equation_toggle` raw/rendered switch; `hide_on_cmdline`.
- Note: RaTeX is a non-TeX layout engine, so it has the same fidelity tradeoff as MathJax. Package-heavy documents will not match what pdflatex produces.

### latex-preview.nvim (sonv)
- Repo: https://github.com/sonv/latex-preview.nvim. Last push 2026-10-03, 21 stars.
- Approach: hover float image at the cursor for math, plus referenced equations, theorems, and BibTeX entries. Uses a persistent MathJax 4 Node process, rasterized with `rsvg-convert`, placed through snacks.nvim. No LaTeX compilation. Macros are collected from the project preamble. Debounced live edits (300 ms). Content-hashed render reuse, with an optional persistent cache directory.
- Limits: not a full TeX engine (TikZ and arbitrary packages unsupported); label and citation lookup is local to the file; macros after `\begin{document}` are ignored. No tmux documentation.
- This is the nearest idea-match to inkmath's MathJax worker and live preview float.
- Borrow: preview of `\ref`/`\eqref` targets (show the referenced equation); preamble macro harvesting; modified-buffer renders in temp files versus persistent cache for saved buffers.

### mathjax.nvim (SleepySwords) and latexrenderer
- https://github.com/SleepySwords/mathjax.nvim: last push 2024-10-29, 4 stars. Block-only `$$`, manual trigger, MathJax through Node, displayed via image.nvim. A `% Lines: N` comment sets block height.
- https://github.com/ArbitRandomUser/latexrenderer: last push 2023-03-14, 38 stars. dvipng via hologram.nvim, kitty on Linux, no inline math, hard-coded colors.
- Both are dead. Historical proof that MathJax-through-Node has been tried several times. Idea: `% Lines: N` as a user override for reserved height.

### nabla.nvim (jbyuki)
- Repo: https://github.com/jbyuki/nabla.nvim. Last push 2025-04-21, 751 stars, 25 open issues.
- ASCII art popup of the expression under the cursor (`require("nabla").popup()`), from the treesitter latex parser. Terminal-agnostic. Not a live in-buffer preview; virtual-line support is a discussion (issue #35 per README).
- Borrow: nothing technical beyond the popup, but it shows the demand for a fallback for terminals without graphics. inkmath could ship a text fallback when kitty graphics are unavailable.

### utftex.nvim
- Repo (Codeberg, not GitHub): https://codeberg.org/VOXEL0798/utftex.nvim. Latest commit 2026-07-27.
- Unicode art via the `utftex` binary (libtexprintf) in extmarks, for fenced `latex` code blocks in Markdown and TeX. Concealed in normal mode. Modifiers on the fence line: `=` numeric evaluation (latex2plain, kalker), `~` center, `|~` and `~|` align to widest formula. Multi-line renders stay rigid as one block. Picks up render-markdown.nvim highlight groups.
- Borrow: fence-line modifiers (center/align/evaluate); inheriting highlight groups from render-markdown.

### render-markdown.nvim LaTeX
- Repo: https://github.com/MeanderingProgrammer/render-markdown.nvim. Last push 2026-10-10, about 5.2k stars (docs: https://github.com/MeanderingProgrammer/render-markdown.nvim/blob/main/doc/latex.md).
- Unicode text via `converter = { 'utftex', 'latex2text' }` (tried in order), `position` above, below, or center (center single-line only), `top_pad`/`bottom_pad`. Inline and block on by default. Needs treesitter `latex` parser, libtexprintf or pylatexenc.
- Coexistence note: must be disabled when render-latex.nvim is used. inkmath should document the same.
- Borrow: ordered converter fallback list (analogous to inkmath's MathJax then tectonic).

### unicode-math.nvim and sigil.nvim
- https://github.com/atomashevic/unicode-math.nvim: pushed 2025-06-10, 1 star. Rewrites math to Unicode in markdown on a delay. Layout is lost (fractions and roots flatten); `katex` option undocumented.
- https://github.com/Prgebish/sigil.nvim: pushed 2026-04-28, 35 stars. Prettify-symbols clone (`\alpha` to α) for tex, plaintex, latex, typst via extmarks, math-context restriction, atomic motions (h/l/w/b/e/x/s/c treat a symbol as one char), `unprettify_at_point = true | "line"`, lazy mode for big files (visible area plus buffer, defaults 500 lines and 50 lines), debounce 30 ms, `:SigilBenchmark`.
- Borrow from sigil: lazy visible-window processing for large files; `unprettify_at_point = "line"` reveal granularity; atomic motions across a rendered span.

### vimtex conceal
- Repo: https://github.com/lervag/vimtex. Last push 2026-11-06, about 6.4k stars. Requires Vim 9.2 or Neovim 0.12.4 for current master, pin v2.18 for older editors (README).
- The README does not describe a conceal option or a math image preview; conceal is syntax-based Unicode substitution (`:h vimtex-syntax-conceal`, not fetched). It has no 2D layout. Coexistence is a hard requirement for inkmath: avoid double-concealing (see snacks issues 2821 and 2569 for what happens when image overlays and conceal fight).

### Emacs: org-latex-preview, xenops, math-preview
- Org's new preview (Karthik Chikmagalur's work): live updates with an adjustable delay, precompiled preamble for speed, org-persist caching, consistent equation numbering, scale/zoom/page-width settings, dvisvgm and dvipng, and dvisvgm >= 3.0 centers display math (https://abode.karthinks.com/org-latex-preview/). The older manual only covers manual `C-c C-x C-l` previews (https://orgmode.org/manual/Previewing-LaTeX-fragments.html). Tracker: https://github.com/tecosaur/org-latex-preview-todos (pushed 2026-10-18). Async design discussion: https://list.orgmode.org/87r1v6rw7y.fsf@gmail.com/T/.
- xenops: https://github.com/dandavison/xenops, pushed 2026-07-30, 348 stars; author says maintenance time is limited. Cursor reveal: rendered image is shown when the cursor leaves; Enter or click removes the image to edit; `xenops-reveal-on-entry` reveals on entry. Background rendering with a task queue capped by `xenops-math-latex-max-tasks-in-flight` (default 32), cancellable. SVG cache directory keyed per fragment; `xenops-regenerate` forces refresh. Also renders tables, TikZ, and includegraphics. `$...$` spanning multiple lines can't be parsed.
- math-preview: https://github.com/emacsmirror/math-preview. Persistent Node MathJax child process over JSON, pre-start command to cut first-render time, auto equation numbering, user macros and package preload, preprocess and SVG postprocess hooks, copy SVG. Known issue: re-rendering a labeled equation yields "multiply defined" labels (workarounds: strip labels or reset numbering).
- Borrow list: in-flight cap and cancellable queue (xenops); persistent MathJax process with early start and JSON protocol (math-preview, same shape as inkmath); equation-number reset on re-render (math-preview pitfall); precompiled preamble (org); reveal-on-entry choice (xenops).

## What inkmath does differently / gaps vs. others

Does anything already do everything inkmath does? No. Nothing surveyed combines (a) Unicode-placeholder kitty images that survive tmux, (b) MathJax with a tectonic fallback, (c) inline, display, and multi-line math, (d) .tex and .md, (e) cursor reveal plus a live preview float, and (f) vimtex coexistence.

Closest per axis:
- Transport and tmux: snacks.nvim image (same placeholders, plus both filetypes). mdmath forks (placeholders, md only).
- Backend: latex-preview.nvim (persistent MathJax 4, but hover-only, no in-buffer inline images, no TeX fallback). snacks has TeX engines but no MathJax.
- Cursor reveal: mdmath (anti-conceal), xenops and sigil in other forms.
- Worker and cache: render-latex.nvim (Rust, prefetch), but display math only and no placeholders yet.

Where others are ahead (gaps):
1. Large-file performance: visible-range batching and directional prefetch (render-latex.nvim), lazy mode (sigil). Verify inkmath handles thousand-line files.
2. Preamble and macro handling: snacks has header comments and templates; latex-preview.nvim harvests macros from the project preamble. Needs verification for inkmath, especially `\newcommand` in .tex files and multi-file projects.
3. Reference and numbering features: preview of `\ref`/`\eqref` targets (latex-preview.nvim), consistent numbering (org, math-preview).
4. Non-graphics fallback: utftex, render-markdown, nabla serve terminals without kitty graphics (WezTerm, zellij, plain tmux without passthrough).
5. Distribution: prebuilt worker binaries with checksums (render-latex.nvim) versus requiring Node.
6. Health tooling: tmux check commands (render-latex.nvim), `checkhealth` (mdmath fork, snacks), protocol version handshake.
7. Typst: snacks and typst-concealer cover it. Out of scope for inkmath, noted for completeness.

Pitfalls others hit that inkmath should test against (from the issue lists above):
- Conceal plus image overlay conflicts (snacks 2821, 2569, 2391).
- White halos on dark backgrounds (snacks 2644).
- Tiny single-symbol formulas blown up to row height (snacks 2612 and secondary reports).
- Clipping of long equations (snacks 2101).
- Equations that start a line with `=` (snacks 2451).
- Images not redrawn on buffer re-entry (snacks 2634).
- Duplicate-instance image collisions (typst-concealer README).
- Duplicate labels on re-render (math-preview).

## Ideas to borrow, ranked by value

1. Visible-range scheduling with directional prefetch, batched worker requests, and a warm content-hash cache (render-latex.nvim, sigil lazy mode, latex-preview.nvim cache split). Highest value for perceived speed in long papers. https://github.com/techwizrd/render-latex.nvim, https://github.com/Prgebish/sigil.nvim
2. Preamble and macro harvesting plus per-document override, e.g. a `% inkmath: header` comment block and a template with `${header}`, `${content}`, `${color}` (snacks), collecting `\newcommand` from the project preamble (latex-preview.nvim). https://github.com/folke/snacks.nvim/blob/main/docs/image.md, https://github.com/sonv/latex-preview.nvim
3. Bounded in-flight queue that is cancellable on edit, plus a persistent worker pre-started on first buffer (xenops, math-preview). https://github.com/dandavison/xenops/, https://github.com/emacsmirror/math-preview
4. Reveal-granularity options: per span, per line (sigil `unprettify_at_point = "line"`), reveal on entry versus on keypress (xenops), hide-in-insert and `hide_on_cmdline`. https://github.com/Prgebish/sigil.nvim, https://github.com/techwizrd/render-latex.nvim
5. Health and diagnostics: `checkhealth` with a tmux check (passthrough, focus-events, visual-activity), and a Lua/worker protocol version handshake. https://github.com/3rd/image.nvim, https://github.com/ApexGP/mdmath.nvim
6. Equation numbering and `\ref`/`\eqref` target preview in the float, with label reset on re-render. https://github.com/sonv/latex-preview.nvim, https://abode.karthinks.com/org-latex-preview/
7. Text fallback for non-graphics terminals using an ordered converter list (utftex, then latex2text), with `position` options and fence modifiers for center/align. https://github.com/MeanderingProgrammer/render-markdown.nvim/blob/main/doc/latex.md, https://codeberg.org/VOXEL0798/utftex.nvim
8. Prebuilt worker binaries with checksum verification, to drop the Node requirement for MathJax users who do not have it. https://github.com/techwizrd/render-latex.nvim
9. Colorscheme-derived foreground and background, with a transparency-halo test. https://github.com/PartyWumpus/typst-concealer, https://github.com/folke/snacks.nvim/issues/2644
10. User height override comment (`% Lines: N`) for multi-line blocks. https://github.com/SleepySwords/mathjax.nvim
