# inkmath v2: final review fixes (3a23719..ea279c6)

Status: DONE. Critical #1, Important #2-#4 and the cheap minors are fixed. Each has a regression test, and I checked that every one fails without its fix. #5 is not fixed (reason below).

## Commits (branch feat/inkmath)

- edd4c51 fix(detect): never take the precheck skip for an edit that removed text (#2)
- 971d959 fix: background fill only warms the disk cache; placements stay near the windows (#1, #6, #9, #10, #11, part of #12)
- bd16cb4 fix(cache): clear-cache epoch keeps later renders out of stale flows; worker recreates the dir (#3, #8)
- 246ebee fix(cache): prune keeps images resident in the terminal; a missing PNG at retransmit re-renders (#4, #7)
- ea279c6 feat(status): resident images vs max_images, placed images and fill state; minor cleanups (#13, rest of #12, #10 test, prune flake)

## Tests

- `make test`: 442 cases, 0 fails (424 before).
- `make test-worker`: 15/15 (14 before).
- `lua/inkmath/core.lua`: 690 lines (694 before). New module: `view/residency.lua`.

## What changed

### #1 Critical: the background fill now only warms the disk cache

- **Fill jobs never place.** Fill jobs are flagged `warm`, and `render_node` skips the deliver/place step for them. An error is still recorded as a diagnostic. Each buffer keeps a warm set of the formulas already in the disk cache, keyed by kind and src, in `fill.lua`. Each refresh checks a ctx signature: the cache key of a fixed probe node, which covers macros, colour, cell size and preamble. A different signature resets the set. Fill steps and the "work left" check skip warm formulas without a cache lookup or sha256.
- **Placements stay near the windows.** New `view/residency.lua` (`trim`, `trim_later`, `evict`, `forget_key`).
  - After each refresh, when idle, it clears placements farther than `keep_screens` window heights from every window.
  - `keep_screens` is a new schema key: default 3, integer >= 1.
  - If more than `max_images` would stay placed, it trims to 1 screen.
  - The trim runs idle, not inline, because deleting many extmarks cost about 5 ms on a jump.
  - Scrolling back places formulas again from the cache.
- **Ids never run out below `max_images`.** The schema already rejects `image_ids.span < 2 * max_images`. Since placements are now bounded, that guarantee holds again. Test: `max_images = 100`, `span = 200`, `per_instance = false`, 1000 formulas, fill to completion; every visible formula is still placed after a jump to the bottom and back.
- **A reused id clears its old placement.** New `images.on_drop`: when `alloc` takes the id of an image placed since the last evict, core clears that placement and refreshes. A placeholder never points at a reused id.
- **Scrolling from the cache is cheaper:**
  - A cache hit is read once: `render_node` takes the image `render.cached` returned (#6).
  - `cache.get` memoizes the metadata, so a later hit only stats the PNG.
  - `placer` caches the diacritic strings.
- **Docs:** schema docs for `fill.enabled`, `keep_screens`, `max_images` and `image_ids.span`; `doc/inkmath.txt` (performance section and generated options); a README paragraph.

### #2 precheck

`bytes_cb` sets `st.removed` for any edit with an old extent, and `can_skip` refuses those edits. Pure insertions (typing) still skip: tex skip ratio 1.0, unchanged.

Tests: deleting a `\begin{comment}` or `\begin{verbatim}` line with no highlighter, deleting a `\\`, and pure insertions still skipping.

### #3 clear-cache epoch

`cache.clear` bumps `cache.epoch`. The render flows and the shared MathJax stage are keyed by `epoch .. ":" .. key`, so a request made after a clear never joins an old flow. The worker runs `mkdirSync(dirname(out), { recursive: true })` before it writes.

#8 is fixed in the same commit: clear renames the directory away and runs `rm -rf` asynchronously.

### #4 prune and retransmit

- `cache.prune` skips the keys in `images.keys()`, the resident images.
- `images.retransmit_all` drops an image whose PNG is gone and notifies `on_drop`. Core clears its placements and schedules a refresh, which re-renders it.

#7 is fixed in the same commit: prune also deletes worker temp files older than 60 s and metadata files that have no PNG.

### Minors

- **#9:** `fill.enabled` is checked in every step.
- **#10:** InsertEnter calls `mathjax.available()` at the time of the event.
- **#11:** WinScrolled now counts as input for idle tasks.
- **#12:**
  - Removed: `queue.push` `opts.append`, `core.conceal_off`, and the v1 core aliases (`_queue`, `_reset_queue`, `_max_inflight`). Their tests were moved to `render/queue`.
  - Added: `cache.max_bytes()`.
- **#13:** `:InkMath status` shows `N resident / max_images M`, plus `placed` and `fill running|done|pending|off` per buffer.
- **Test flake:** prune now calls back only after its async unlinks finish. The prune tests failed under load (seen once before these changes, reproducible with test_api run before test_cache).

## Bench (make bench, this machine; before = 3a23719)

| row | before | after | target |
|---|---|---|---|
| md 2000 keystroke prose / formula, TS hl on | 2.1 / 4.2 ms | 2.0 / 4.7 ms | < 8 ✔ |
| tex 5000 keystroke prose / formula | 1.7 / 1.7 ms | 1.4 / 1.4 ms | < 5 ✔ |
| attach sync tex 1000 / tex 5000 / md 2000 | 0.2 / 0.5 / 1.0 ms | 0.3 / 0.6 / 1.1 ms | < 10 ✔ |
| after fill: placed / resident, tex 5000 | 2068 / 2068 (every formula) | **41 / 41** | ≤ max_images |
| after fill: placed / resident, md 2000 | 909 / 909 | **45 / 45** | |
| after fill: jump far, visible placed (new row) | n/a | 5.3 / 8.6 ms (tex 5000, median/max) | |
| background fill complete, tex 5000 | 27.1 s | 26.5 s | |
| scroll 1 screen: refresh median/p95 | 3.1 / 6.0 ms | 2.8 / 6.6 ms | |
| scroll 1 screen: visible placed median/max | 3.1 / 34.6 ms | 2.8 / 35.9 ms | |
| fast scroll 6 / burst 10 screens | 3.5 / 22.6 ms | 2.7 / 23.2 ms | |
| jump to cold region: refresh main-thread | 3.1 ms | 4.7 ms | |
| jump to cold region: visible placed | 20.9 ms | 22.2 ms | |

About "jump to cold region: refresh": the jump targets lie in regions the earlier burst scrolls already rendered.
- **Before:** those placements stayed forever, so the jump found them already placed.
- **Now:** they were trimmed, so the jump places them again from the cache.

That costs about 1.5 ms (about 7 ms before the get memo and diacritic cache). It is the price of the "placed only near the windows" design.

The bench's fill row now waits for `fill.state(buf) == "done"`, because placed count no longer reaches the total. Full output: `bench_after.txt` in the session scratchpad.

## Not fixed

- **#5 (off-screen stale placements after bulk edits): not fixed.**
  - Node ids carry the source hash, so the first refresh after the jump clears the old placement ("gone"). The old image can show only during the scroll debounce (`debounce_ms`, 80 ms).
  - Placements beyond `keep_screens` are now trimmed anyway.
  - Clearing them at edit time would need the edited ranges plumbed from detect/incr into core. That is not cheap.
- **#12 leftovers, kept on purpose:** `mathjax.start_all` stays, since tests use it. The scattered constants (`PRUNE_EVERY`, the idle slice/delay) are fine as internals.
- **Maintainability suggestion, not done:** moving the fill step out of `core.refresh` into `fill.lua` through a `core.scan`. `refresh` still has two return contracts.
