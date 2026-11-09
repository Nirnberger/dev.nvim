# Error-tolerant LaTeX detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An unclosed `$` or `\begin` in a `.tex` buffer no longer hides the other formulas.

**Architecture:** Treesitter stays the source of truth outside the error region. Inside it a pure line scanner (`detect/recover.lua`) recovers formulas paragraph by paragraph; `detect/latex.lua` merges both and reports the region as handled so `core.lua` does not freeze.

**Tech Stack:** Lua, mini.test (`make test`, `make test-file F=...`).

**Spec:** `docs/superpowers/specs/2026-11-09-tolerant-latex-detect-design.md`

## Global Constraints

- LaTeX (`tex`) only; markdown detection is untouched.
- The scanner never raises into editing: `pcall`, on failure behave exactly as today (`has_error = true`).
- Node ids/src normalisation identical to `detect/latex.lua` (`node_id(kind, env, src)`, trimmed `src`, delimiters stripped).
- Ranges are 0-based, byte-indexed columns, `erow`/`ecol` exclusive like treesitter.
- Test runs: `timeout 100 make test-file F=tests/test_x.lua > /tmp/x.log 2>&1 < /dev/null`; full suite `INKMATH_PERF_FACTOR=3 make test`; `stylua --check lua tests`.
- Branch `claude/tolerant-latex-detect`; do not open a PR (owner has not asked).

## Review Focus

- Multibyte text before a `$` (e.g. `äö $x$`): columns must be byte offsets. Test in Task 1.
- `$` inside a `%` comment or after `\$`, `\\$` (even backslashes = real `$`). Task 1.
- Open `$$` (display) in the middle: following paragraphs still render. Task 1.
- Two formulas in one paragraph before the open `$`: both stay detected (region starts at the paragraph start). Task 2.
- Closing the broken `$` afterwards: no duplicate placements or stale marks. Task 3.

---

## File Structure

- Create `lua/inkmath/detect/recover.lua`: pure scanner.
- Modify `lua/inkmath/detect/latex.lua`: error region, merge, `recovered` flag.
- Modify `lua/inkmath/detect/init.lua`: info gets `tree_error`; `has_error` is false when recovered.
- Modify `lua/inkmath/detect/incr.lua`: uses `info.tree_error` where it decides incremental work.
- Create `tests/test_recover.lua`; modify `tests/test_detect_latex.lua`, `tests/test_core.lua`.
- Modify `dev/bench.lua` (open-`$` case), `README.md` (Limitations).

### Task 1: Scanner `recover.scan`

**Files:**
- Create: `lua/inkmath/detect/recover.lua`
- Test: `tests/test_recover.lua`

**Interfaces:**
- Produces: `M.scan(lines: string[], first_row: integer) -> {kind: "inline"|"display"|"block", src: string, env: string|nil, range: {srow,scol,erow,ecol}}[]` in source order. `lines[1]` is buffer row `first_row`. No ids.

- [ ] **Step 1: Write failing tests** in `tests/test_recover.lua` (`MiniTest.new_set()`, pure, no buffers). Assertions:
  - `scan({"a $x$ b"}, 0)` → one inline, `src == "x"`, range `{0,2,0,5}`.
  - `scan({"äö $x$"}, 3)` → `range.srow == 3`, `scol == 5` (bytes).
  - `{"$a$ and $b"}` → only `a` (last unpaired `$` stays source); `{"$a$ $b$ $c"}` → `a`,`b`.
  - `{"$a$", "", "$b"}` → `a` only, and `{"$b", "", "$c$"}` → `c` (paragraph boundary).
  - `{"\\$5 and $x$"}` → only `x`; `{"\\\\$x$"}` → `x` (two backslashes do not escape).
  - `{"% $x$", "$y$"}` → only `y`.
  - `{"$$a$$"}` → display, `src == "a"`; `{"$$ a", "", "$y$"}` → only `y` (open `$$` ends at paragraph).
  - `{"\\(x\\) \\[y\\]"}` → inline `x`, display `y`.
  - `{"\\begin{align}", "a&=b", "", "c", "\\end{align}"}` → one block, `env == "align"`, spans rows 0–4 (blank line allowed inside environments); a `\begin{align}` without `\end` → none.
  - `{"\\begin{verbatim}", "$x$", "\\end{verbatim}"}` → none; `{"\\verb|$|, $x$"}` → only `x`.
- [ ] **Step 2: Run** `make test-file F=tests/test_recover.lua` → FAIL (module missing).
- [ ] **Step 3: Implement `M.scan`** in `recover.lua`. Approach: first mask comments, `\verb…` spans and verbatim/lstlisting environments (replace with spaces of equal length so columns stay valid), then scan each paragraph (split at blank lines) left to right: `\begin{x}`→ match `\end{x}` across the rest of the file (nesting by same name), `$$` then `$` pairing, `\(` `\)`, `\[` `\]`; escaped `$` = odd number of preceding backslashes. Unmatched openers produce no node. Strip delimiters and trim like `latex.lua:86-92`.
- [ ] **Step 4: Run** the test file → PASS; `stylua --check lua tests`.
- [ ] **Step 5: Commit** `git add lua/inkmath/detect/recover.lua tests/test_recover.lua && git commit -m "detect: pure LaTeX math scanner for error regions"`.

### Task 2: Merge in `latex.detect`, `tree_error` flag

**Files:**
- Modify: `lua/inkmath/detect/latex.lua` (`M.detect`, ends at `:103`), `lua/inkmath/detect/init.lua:46-65`, `lua/inkmath/detect/incr.lua` (uses of `info.has_error`, e.g. `:310`, `:462`, `:552`)
- Test: `tests/test_detect_latex.lua`

**Interfaces:**
- Consumes: `recover.scan` (Task 1).
- Produces: `latex.detect(buf, srow, erow) -> nodes, has_error, recovered` (`recovered: boolean`); `detect.detect` returns `info = {has_error = tree_error and not recovered, tree_error = tree_error}`; other detectors return `tree_error == has_error`.

- [ ] **Step 1: Write failing tests** in `tests/test_detect_latex.lua` (helper `d(lines)` returns nodes; use `detect.detect(buf)` for info):
  - `{"$a$ $b$ $c", "", "$y$", "", "\\[z\\]"}` → sources `a, b, y, z` (in order), `info.has_error == false`, `info.tree_error == true`.
  - `{"$\\frac{$ a", "", "$y$"}` → contains `y`.
  - error-free text → `info.tree_error == false`, nodes identical to before (existing tests keep passing).
  - ids equal those of the same formula in an error-free buffer (`node_id` parity).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** in `latex.lua`: when `tree:root():has_error()`, collect rows of `ERROR`/missing nodes (walk the tree), expand to paragraph bounds, drop treesitter nodes overlapping that row range, add `recover.scan` nodes (given `node_id`), all inside `pcall`; on failure return `has_error = true, recovered = false`. Thread `recovered` through `detect/init.lua` as specified. In `incr.lua` replace the `info.has_error` decisions about incremental work with `info.tree_error` (keep `core.lua` on `has_error`).
- [ ] **Step 4: Run** `tests/test_detect_latex.lua` and `tests/test_detect_incr.lua` → PASS.
- [ ] **Step 5: Commit** `detect: recover formulas around parse errors in LaTeX`.

### Task 3: Core behaviour, old freeze tests, bench, docs

**Files:**
- Modify: `tests/test_core.lua` (cases near `:340-385`), `dev/bench.lua`, `README.md` Limitations (unclosed `$`/`{` entry)
- Test: `tests/test_core.lua`

**Interfaces:**
- Consumes: Task 2 detection (`has_error == false` when recovered, so `frozen` in `core.lua:291` stays false).

- [ ] **Step 1: Write/adjust tests** in `test_core.lua`: new case "open dollar keeps other formulas": insert `a lone $ here` above formulas in `doc_buf()`; after `core.refresh`, formulas below the line are still placed and a newly typed formula below renders; then close the `$` (edit the line) and assert placements equal the pre-edit count (no duplicates/stale marks). Adjust the existing cases that pin the freeze (`closing the brace resumes refresh`, `cursor reveal works while frozen`) only where they fail because formulas now render; keep their intent.
- [ ] **Step 2: Run** `tests/test_core.lua` → FAIL on the new case (or pass only after Task 2; confirm RED by `git stash`-free check: run before Task 2 code is merged if executing out of order).
- [ ] **Step 3: Implement** nothing in lua if Task 2 suffices; add the open-`$` case to `dev/bench.lua` and rewrite the README Limitations entry (open `$`/`{` now recovered per paragraph; unclosed `\begin` without `\end` and the last unpaired `$` stay source).
- [ ] **Step 4: Run** `INKMATH_PERF_FACTOR=3 make test`, `stylua --check lua tests`, `make doc` (no diff expected), `make bench` (open-`$` case < 1 ms scanner cost). Expected: all green.
- [ ] **Step 5: Commit and push** `git commit -am "core: formulas around an open \$ keep rendering; docs and bench"`, `git push -u origin claude/tolerant-latex-detect`; check `gh run list --branch claude/tolerant-latex-detect -L 3`.

---

## Self-review

- Spec coverage: scanner rules → Task 1; merge, pcall fallback, `has_error` semantics, incr untouched on broken trees → Task 2; core/freeze tests, markdown unaffected (existing markdown tests unchanged; add a one-line assertion in `tests/test_detect_markdown.lua` that a lone `$` gives `info.tree_error == false` in Task 2), bench, README → Tasks 2–3.
- Types consistent: `scan(lines, first_row)`, `recovered`, `tree_error` used identically in all tasks.
