# inkmath optimizations (2026-11-07)

Branch `feat/inkmath`, from 22a750a to 1380fcd. Machine: macOS, 10 cores, Neovim 0.12.5, node 20.19.

## Benchmark

`make bench` runs `dev/bench.lua` headless under `NVIM_APPNAME=inkmath-dev`. It stubs `kitty.send` and uses the real MathJax worker pool, an empty render cache (a fresh `XDG_CACHE_HOME`) and a 52x120 grid. The generated documents have about one formula per two lines. The .tex files mix inline math, `\[..\]`, `equation` and `align`. The .md file mixes inline math, `$$..$$` on one line and multi-line `$$` blocks. Every formula is distinct.

- **Cold open:** time from `attach` until every formula in the window is placed, and until the visible screen plus the margin above and below is done. The workers are already running and warmed up, so cold means an empty cache. Worker start-up is measured on its own row.
- **Keystroke:** the main-thread time of `refresh` after one edit in the middle of the file (30 edits, median/p95). A prose edit needs no render. A formula edit needs one, which runs asynchronously.
- **Scroll:** the main-thread cost of `refresh` after a scroll, and the time until newly visible formulas are placed. The scenarios are: one screen down; 6 screens with 30 ms between them (key repeat); 10 screens back to back (Ctrl-F held down); and a jump into a region that was never rendered.
- **Markdown setup:** the buffer gets a full treesitter parse before the clock starts, because the treesitter highlighter is on for markdown by default. The "no TS highlighter" rows stop the highlighter, so inkmath's own cost shows.
- **Options:** `BENCH_ONLY=` picks sections, `BENCH_WORKERS=n` sets the pool size, and `BENCH_PROFILE=1` breaks `refresh` down by function.

### Baseline (step 1, before any change, first bench version)

| benchmark | 22a750a |
|---|---|
| worker spawn → first answer | 107 ms |
| 40 renders, 1 worker | 80 ms |
| tex 1000: cold, visible placed (21) / +margin | 71 / 129 ms |
| tex 1000: warm, visible placed | 11 ms |
| tex 1000: keystroke prose / formula (median) | 7.7 / 7.8 ms |
| tex 5000: cold, visible placed / +margin | 83 / 135 ms |
| tex 5000: warm, visible placed | 30 ms |
| tex 5000: keystroke prose / formula (median, p95) | 38.7 (42.4) / 39.6 (43.9) ms |
| tex 5000: full detect alone | 37.7 ms |
| md 2000: cold, visible placed (22) | 253 ms (incl. treesitter query loading) |
| md 2000: keystroke prose / formula | 42.0 / 42.2 ms |
| md 2000: full detect alone | 31.7 ms |
| scroll 1 screen: refresh main thread | 27.5 ms |
| fast scroll 6 screens: final screen placed | 85 ms |
| jump to cold region: visible placed (median / max) | 94 / 133 ms |

What the baseline showed:

1. **Detection dominates the main thread.** Every `refresh` (on each keystroke, scroll or cursor-leave) detected the whole buffer: 38 of 39 ms in the 5000-line .tex and 32 of 42 ms in the .md. A plain scroll paid it too (27 ms).
2. **Workers are fast.** The worker handles a request in about 1.5 to 2.5 ms, but the end-to-end pipeline did 3 ms per render. Item 6 found the gap: an fsync on the main thread.
3. **Callback bookkeeping is cheap.** It came to about 5 ms for 41 render callbacks.

### Before / after (final bench script, run on 22a750a and on HEAD back to back)

| benchmark | before (22a750a) | after (1380fcd) |
|---|---|---|
| worker spawn → first answer | 109 ms | 112 ms (now hidden by the warm-up, see the last row) |
| 40 renders: 1 / 2 / 4 workers | 89 / – / – ms | 87 / 58 / 47 ms |
| 40 trivial renders: 1 / 2 / 4 workers | 20 ms | 20 / 13 / 9 ms |
| tex 1000: attach (sync) | 7.9 ms | 8.6 ms |
| tex 1000: cold, visible placed (21 formulas) | 85.7 ms | **33.5 ms** |
| tex 1000: cold, visible + margin done (41) | 139 ms | **55 ms** |
| tex 1000: cold, main-thread cache writes (41 renders) | 118 ms | **4.7 ms** |
| tex 1000: cold, render callbacks main thread | 6.1 ms | 4.3 ms |
| tex 1000: warm, visible placed | 11.0 ms | 12.5 ms |
| tex 1000: keystroke prose (median / p95) | 7.7 / 9.0 ms | **3.3 / 5.0 ms** |
| tex 1000: keystroke formula (median / p95) | 7.7 / 9.0 ms | **3.6 / 5.5 ms** |
| tex 5000: attach (sync) | 27.5 ms | 30.9 ms |
| tex 5000: cold, visible placed | 85.5 ms | **50.2 ms** |
| tex 5000: cold, visible + margin done | 147 ms | **68 ms** |
| tex 5000: warm, visible placed | 30.9 ms | 35.7 ms |
| tex 5000: keystroke prose (median / p95) | 37.9 / 41.2 ms | **14.2 / 17.5 ms** |
| tex 5000: keystroke formula (median / p95) | 39.9 / 46.2 ms | **14.5 / 17.8 ms** |
| md 2000: attach (sync) | 17.1 ms | 19.9 ms |
| md 2000: cold, visible placed (22) | 74.4 ms | **34.0 ms** |
| md 2000: cold, visible + margin done | 132 ms | **45 ms** |
| md 2000: warm, visible placed | 18.0 ms | 23.2 ms |
| md 2000: keystroke prose (median / p95) | 40.9 / 46.2 ms | 34.3 / 38.6 ms |
| md 2000: keystroke formula (median / p95) | 40.4 / 43.8 ms | 30.6 / 34.2 ms |
| md 2000, no TS highlighter: attach (sync) | 14.9 ms | 35.6 ms (regression, see concerns) |
| md 2000, no TS highlighter: warm, visible placed | 17.7 ms | 42.4 ms (regression) |
| md 2000, no TS highlighter: cold, visible placed | 65.3 ms | 57.1 ms |
| md 2000, no TS highlighter: keystroke prose / formula | 32.6 / 36.4 ms | **14.4 / 14.6 ms** |
| scroll 1 screen: refresh main thread (median / p95) | 27.0 / 28.2 ms | **2.2 / 3.9 ms** |
| scroll 1 screen: visible placed | 27.0 ms | **2.2 ms** |
| fast scroll 6 screens (30 ms apart): final screen placed | 85 / 98 ms | **2.1 / 3.9 ms** |
| burst scroll 10 screens: final screen placed | 814 / 825 ms | **21.9 / 24.1 ms** |
| jump to cold region: refresh main thread | 26.3 ms | **2.6 ms** |
| jump to cold region: visible placed (median / max) | 26 / 154 ms | **21 / 23 ms** |
| warm open, workers not running: first edited formula placed | 138 ms | **13.6 ms** |

Full detection of a whole buffer, which still runs on every fallback, is unchanged for .tex (37.5 → 38.8 ms). In .md it went from 31 to 40 ms: a full detect after an edit parses the inline regions itself (see item 1).

## Items

### 1. Incremental detection: done (49ec4a4, 5e5c3f0, 1380fcd)

The new `detect/incr.lua` keeps the previous detection for each buffer.

- **Dirty rows.**
  - Edits come from `nvim_buf_attach` `on_bytes` and are queued. The previous nodes shift with them like extmarks, and nodes touched by an edit are dropped.
  - The changed ranges of the syntax tree come from `parser:register_cbs({ on_changedtree })`. They catch structure changes, such as a new `$` re-pairing a paragraph, a `%`, or a new environment. The queued edits are applied first, so the ranges stay in current coordinates.
- **Expansion.** The dirty range grows until no old node, and no re-detected node, crosses its boundary. In markdown it also grows to the surrounding blank lines and to the enclosing `$$` blocks. Only those rows are detected again: `latex.detect` and the new bounded `markdown.detect` take `srow`/`erow`.
- **Full-detect fallbacks:**
  - no previous result, or a buffer reload;
  - a syntax tree with errors, now or at the last detection;
  - more than 64 queued edits, or a dirty range wider than max(400 rows, half the buffer);
  - in markdown, a change to the list of `$$` line pairs that the line scanner finds (`markdown.block_pairs`). A `$$` line added, removed or fenced into code re-pairs every later block.
- **Copies.** Callers get copies, because core rewrites ids and labels rewrite `src`.

Markdown needed more than bounding the rows. `LanguageTree:parse({lo, hi})` cost as much as `parse(true)`, about 11 ms for 2000 lines, because it re-runs the injection machinery over the whole document. Bounded detection now parses the `inline` and `pipe_table_cell` regions in range itself with a `vim._create_ts_parser("markdown_inline")` parser. It uses the same included ranges as the injection (the node minus its named children). Regions with no `$` are skipped. If the private API is missing, it falls back to the LanguageTree.

A whole-buffer detect reuses the LanguageTree's injected trees when they are already valid, as it always did. That is the usual case with the highlighter on. Otherwise it parses the regions itself.

Two Neovim 0.12 quirks turned up along the way:

- A nil timeout makes `TSParser:parse` give up at once, and the next parse resumes the unfinished one. The code now calls `reset()` and passes an explicit timeout.
- An incremental reparse of markdown_inline injections can disagree with a fresh parse of the same text, so even the old full detect was not a pure function of the text. This is why bounded detection parses afresh.

The parse itself is now the floor. Tree-sitter's incremental reparse costs about 5.5 ms for the 5000-line .tex, and about 5 ms for the 2000-line .md plus about 15 ms of LanguageTree work for the highlighter's injections. The highlighter would otherwise pay that cost at the next redraw.

### 2. Visible-first scheduling with directional prefetch: done (494993d)

`refresh` collects the nodes that need a render and orders them:

1. visible rows, top to bottom;
2. the screen in the scroll direction. The direction comes from the last topline per window and buffer, and defaults to downward.
3. the other side of the margin, nearest first.

Cached renders are placed at once in that order, as before. The scan range itself (the window ± one screen) is unchanged.

### 3. Bounded, cancellable render queue: done (494993d, same commit as item 2)

Each `refresh` replaces the buffer's queue, so nodes that left the margin are dropped before they reach a worker. A queued job is also dropped at start when the buffer's changedtick, generation or ctx changed since it was queued (edited away). At most `_max_inflight = 8` distinct render keys run at once. A render that joins one already in flight does not take a slot. Burst scrolling across 10 screens went from 814 to 22 ms.

Items 2 and 3 share the same code path, so they are one commit.

### 4. Worker throughput, pool vs batching: pool, `workers = 2` (627a750)

The measurement settled it:

- 40 trivial renders cost about 0.5 ms each round trip, so batching could save at most that per request.
- 40 real renders take 87 ms with 1 worker, 58 ms with 2 and 47 ms with 4.

`render/mathjax.lua` keeps a pool of slots. A request goes to the running worker with the fewest pending requests. Every slot keeps its own exactly-once callbacks, its own timeout (which kills only that worker) and its own restart cap (first spawn plus 3 restarts). The option is `workers` (validated as an integer ≥ 1), and the README is updated.

### 5. Warm-up: done (9fc8dcd)

Worker load, from spawn to the first answer, takes about 110 ms. The first attach now schedules `mathjax.warm()`. It starts the pool, and each worker renders `x^2` once, so the MathJax setup and the JIT are done early. Measured on a warm open, where no render is needed, followed by an edit 300 ms later: the first edited formula is placed in 13.6 ms instead of 138 ms.

### 6. Cheaper bookkeeping: done (f4035ee)

The profile found the largest single cost. `cache.put` wrote the metadata JSON with `writefile`'s default fsync. That blocked the main loop for about 2.5 ms per finished render (118 ms for 41 renders) and serialized the whole pipeline behind it. With 2 workers, it was why the pool barely helped at first. It now writes with `"S"` (no fsync). A lost file is just a cache miss, because `get` validates the file.

Per render callback, `cursor.update` and `images.evict` each walked every placed node or resident image. They are now coalesced into one scheduled tick per batch of finished renders, and `refresh` still evicts once. Callback main-thread time went from 6.1 to 4.3 ms per 41 renders.

## Tests

`make test` runs 219 cases with 0 failures, and `make test-worker` passes 13 of 13.

New test files:

- **`tests/test_detect_incr.lua`:**
  - randomized edit sequences in .tex and .md (10 seeds × 80 steps each, 1 to 3 edits between detections, balanced and risky snippets): after each step the incremental result equals a full detect;
  - the incremental path is really exercised (more than 80 incremental detections each). During development the test also ran with 40 to 80 seeds.
  - the unchanged buffer reuses its result, and callers get copies;
  - an edit far from the math re-detects only nearby rows, with the right shifted ranges;
  - a bounded markdown detect equals the full result in its rows;
  - the own inline parse equals the LanguageTree injections on quotes, lists, tables, HTML, code and `$$`.
- **`tests/test_queue.lua`:**
  - queue order: visible first, then the screen ahead, then the rest, also after scrolling up;
  - requests start visible-first;
  - at most 8 are in flight, and a finished render starts the next;
  - requests for nodes scrolled out of view are dropped and the new view is served visible-first;
  - requests for edited-away nodes are dropped.
- **`tests/test_pool.lua`:**
  - 2 workers serve the requests;
  - killing a worker mid-flight still gives every callback exactly once;
  - a timeout gives exactly one callback and the worker is replaced;
  - the restart cap is per worker;
  - `warm` is idempotent and leaves no extra callbacks;
  - attach pre-starts the pool;
  - `workers = 1` behaves like a single worker.

## Concerns

- **Markdown attach without the TS highlighter is slower.** Attach went from 15 to 36 ms and the warm open from 18 to 42 ms. A full markdown detect parses every inline region itself when the LanguageTree's injections are not parsed yet, and the old `parse(true)` was cheaper in that case. With the default highlighter on, it is 17 → 20 ms.
- **Markdown keystrokes improved less with the highlighter on.** They went from 41 to 34 ms. About 20 ms of that is Neovim's own LanguageTree reparse and injection bookkeeping, which is shared with the highlighter.
- **One private API is in use.** `vim._create_ts_parser` is used, with a fallback to the LanguageTree.
- **The default pool doubles memory.** Each node worker is a separate process.
- **The randomized test uses fixed seeds.** One reason: with an incremental markdown_inline reparse, Neovim's own full detect could differ from a fresh parse of the same text. Bounded detection now avoids that by parsing afresh.

## Fix round 1

The review found one Critical and three Important issues; this round also fixes the cheap minors. Commits: 6c87c08, f92f84f, 5b40000, 6d99831, 32f8992, ba4860d. Where this section disagrees with item 1 above, this section applies.

### What changed

1. **(Critical) Every edit applied twice after a re-attach.** After `incr.forget` plus a re-detect (`:InkMath disable`/`enable`, or a language change), the old `nvim_buf_attach` callback looked up `states[buf]` and fed the new state. Fix:
   - each `on_bytes` and `on_reload` closure serves only the state it was made for, and detaches itself otherwise;
   - `on_changedtree` is registered once per parser;
   - a different parser instance forces a full detect (M4).

   New tests, which fail on the old code: forget → re-detect (also repeated toggles) → edit equals a full detect; the same across a tex → markdown → tex language change.
2. **(Important) Head-of-line blocking behind tectonic.** A queue slot was held until MathJax and the tectonic fallback had both finished. Now `render()` reports the end of the MathJax stage (`opts.on_stage`), and the queue frees the slot there. Tectonic work holds no slot, since tectonic's own queue batches.
   - Reviewer's repro `hol.lua` (12 fallbacks first, 30 MathJax formulas after them): the MathJax formulas were placed at 758–2858 ms, now at **154 ms**.
   - Reviewer's repro `tect.lua` (`backend = "tectonic"`, 60 formulas): it took 10 runs and 4.75 s, now **2 runs and 3.49 s**.
   - New tests, which fail on the old code: 30 MathJax renders get placed while 12 fallbacks are held forever; `backend = tectonic` with 24 formulas uses at most 3 tectonic runs.
3. **(Important) Duplicate writes of the same PNG.**
   - (a) The worker writes `out.tmp.<pid>.<id>` and then calls `renameSync`. Tectonic's final magick step writes a temp `.png` and then calls `os.rename`. New worker test: two concurrent renders to the same path and one failing render leave no temp files behind.
   - (b) The MathJax stage is deduped by the mathjax cache key across the normal and the `nofallback:` preview flow. New test: a concurrent preview and normal render of the same node make 1 worker request.
4. **(Important) Markdown full detection.** It is back to `LanguageTree:parse(true)`. The private per-region parser (`vim._create_ts_parser`) is removed altogether, and the earlier private-API concern with it.
   - Incremental markdown detection now parses the whole LanguageTree first: about free right after a highlighter parse, about 11 ms per 2000 lines otherwise.
   - It registers `on_changedtree` recursively, so markdown_inline reparses that change rows nobody edited (tree-sitter keeps state between parses) mark those rows dirty.
   - Only the detection is bounded, and the result always equals a full detect of the same LanguageTree (M1).
5. **Minors:**
   - **M1:** a new randomized test runs `parser:parse(true)` between edit and detect, like the highlighter, with blockquotes, lists and tables in the document, on 10 fixed seeds. It also passed on 60 seeds. The reviewer's `rand_hl.lua` now gives 0 mismatches against a full detect over 2400 steps (1822 of them incremental). It still reports 26 mismatches against a fresh buffer. Those come from Neovim's incremental markdown_inline reparse, and the old full detect had them too.
   - **M2:** `cache.get` requires a PNG with a size above 8 bytes and the PNG signature; anything else is a miss. Test added.
   - **M4:** see 1.
   - **M7:** attach warms one worker. Another starts when a request finds every running worker busy. The warm-up render uses the normal send path, including the timeout. `start()` makes sure one worker runs; `start_all()` starts the whole pool.

### Numbers after fix round 1 (`make bench`, same script)

| benchmark | before (22a750a) | after round 0 | after fix round 1 |
|---|---|---|---|
| tex 1000: cold, visible placed | 85.7 ms | 33.5 ms | 34.6 ms |
| tex 5000: cold, visible placed | 85.5 ms | 50.2 ms | 43.7 ms |
| tex 5000: keystroke prose (median / p95) | 37.9 / 41.2 ms | 14.2 / 17.5 ms | 14.1 / 19.6 ms |
| md 2000: attach (sync) | 17.1 ms | 19.9 ms | 17.9 ms |
| md 2000: warm, visible placed | 18.0 ms | 23.2 ms | 23.1 ms |
| md 2000: keystroke prose / formula | 40.9 / 40.4 ms | 34.3 / 30.6 ms | 34.3 / 33.9 ms |
| md 2000, no TS hl: attach (sync) | 14.9 ms | 35.6 ms | **17.4 ms** |
| md 2000, no TS hl: warm, visible placed | 17.7 ms | 42.4 ms | **23.2 ms** |
| md 2000, no TS hl: keystroke prose / formula | 32.6 / 36.4 ms | 14.4 / 14.6 ms | 25.2 / 29.6 ms |
| md 2000: full detect alone | 31.2 ms | 40.0 ms | 31.4 ms |
| scroll 1 screen: refresh main thread | 27.0 ms | 2.2 ms | 2.6 ms |
| burst scroll 10 screens: final screen placed | 814 ms | 21.9 ms | 22.8 ms |
| jump to cold region: visible placed (median / max) | 26 / 154 ms | 21 / 23 ms | 26 / 27 ms |
| warm open, workers not running: first edit placed | 138 ms | 13.6 ms | 14.9 ms |
| 12 fallbacks + 30 MathJax: MathJax placed (`hol.lua`) | 758–2858 ms | — | 154 ms |
| `backend = tectonic`, 60 formulas (`tect.lua`) | 10 runs / 4.75 s | — | 2 runs / 3.49 s |

### Trade-offs

- Markdown attach and full detect are about back to the baseline. Opening a cached markdown file is still about 5 ms slower: incr's bookkeeping (copies and `$$` pairs) remains.
- Markdown keystrokes without the highlighter go 32.6 → 25 ms, against 14 ms with the removed private parser. That is the price of one source of truth, which item 4 asked for.

Tests: `make test` runs 226 cases with 0 failures, and `make test-worker` passes 14 of 14.

## v2

Phase 3 of the v2 plan (Tasks 11-14): trigger precheck, parse-free keystroke path,
viewport-bounded fallbacks with stale rows, deferred attach with a bounded first
detection, lazy worker spawn, idle-sliced background fill. `make bench` on the same
machine, before = aa12e93 (end of Phase 2), after = Task 14. Keystroke rows are the
synchronous main-thread time of the refresh after one keystroke (medians; p95 in
the raw output). With the treesitter highlighter on, its own parse runs during the
refresh debounce, before the clock starts (it happens with or without inkmath).

| benchmark | before (aa12e93) | after (v2) | target |
|---|---|---|---|
| tex 5000: keystroke prose / formula | 15.0 / 15.4 ms | 1.6 / 1.6 ms | < 5 ms |
| md 2000: keystroke prose / formula, TS highlighter on | 41.9 / 41.5 ms | 2.6 / 4.1 ms | < 8 ms |
| md 2000, no TS hl: keystroke prose / formula | 27.9 / 33.8 ms | 1.2 / 1.3 ms | |
| tex 1000: attach (sync) | 15.2 ms | 0.3 ms | < 10 ms |
| tex 5000: attach (sync) | 36.4 ms | 0.4 ms | < 10 ms |
| md 2000: attach (sync) | 27.1 ms | 0.7 ms | < 10 ms |
| tex 5000: first refresh after attach (deferred) | (in attach) | 10.2 ms | |
| md 2000: first refresh after attach (deferred) | (in attach) | 16.1 ms | |
| tex 5000: attach -> visible placed (warm) | 36.4 ms | 10.6 ms | |
| md 2000: attach -> visible placed (warm) | 27.1 ms | 16.9 ms | |
| tex 5000: keystroke -> formula placed | n/a | 18.5 ms | |
| md 2000: keystroke -> formula placed (incl. highlighter parse) | n/a | 67.2 ms | |
| prose keystroke precheck skip ratio (tex / md) | n/a | 1.0 / 0.0 | |
| warm open: workers spawned | 1 (warm-up) | 0 | |
| background fill complete (tex 5000, 2068 formulas, not cached) | n/a | 27.3 s | |
| warm open, first edited formula placed (InsertEnter warm-up) | 9.1 ms | 11.3 ms | |
| scroll 1 screen: visible placed median / max | 3.0 / 6.0 ms | 2.8 / 33.7 ms | |

Notes:
- md prose skip ratio is 0: the bench document has no blank lines between its
  prose and math lines, and the markdown precheck scans whole paragraphs (a block
  marker or a filled blank line can re-pair `$` across them). Those keystrokes use
  the parse-free path instead.
- The deferred first refresh is still one main-thread block (tex 5000: 10 ms, md
  2000: 16 ms: bounded detection of the screen plus its margin, and markdown's
  `$$` pair scan of the whole tree); it runs right after the file opens.
- The background fill renders at most `fill.max_jobs` (4) uncached formulas per idle
  step (one step per 50 ms idle slice), hence 27 s for 2068 uncached formulas.
