# Error-tolerant LaTeX detection (4a)

## Goal
In `.tex` buffers an unclosed `$` or `\begin` must not hide the other formulas. Formulas before
and after the broken spot stay rendered; only the open region shows its source.

Today the treesitter latex parse turns the rest of the document into one ERROR node. `core.lua`
then freezes (keeps existing placements, starts no renders while `has_error`), and buffers that
are broken from the start render nothing after the error.

Scope: LaTeX only. Markdown is assumed unaffected (a lone `$` is plain text for markdown_inline);
this is verified by a test, not assumed in code.

## Approach
Treesitter results stay the source of truth outside the error region. Inside it a small
line scanner recovers the formulas, paragraph by paragraph.

### Components
- `lua/inkmath/detect/recover.lua`: pure function `scan(lines, first_row) -> MathNode[]` (`lines[1]`
  is buffer row `first_row`; the caller passes exactly the rows to scan). No Neovim API calls
  except through the lines passed in. Output nodes have the same shape as `detect/latex.lua`'s
  (without `id`; latex.lua adds the same `node_id`).
- `lua/inkmath/detect/latex.lua`: when `tree:root():has_error()`, compute the error region
  (ERROR/MISSING nodes, and inline/display nodes spanning a blank line, each extended to its
  paragraph), call `recover.scan` on it, drop treesitter nodes that overlap the region and merge.
  It returns `has_error = true, recovered = true`; `detect/init.lua` turns that into
  `info = {has_error = false, tree_error = true}`, so `core.lua` does not freeze. `recover` runs
  in `pcall`; on failure `recovered = false` and the old behaviour (`has_error = true`, freeze)
  applies.
- The region is computed on the whole tree, so a range detect on a broken tree needs the full
  result. latex.lua memoizes it per buffer and `changedtick` (dropped on a tick change, on
  detach and for invalid buffers) and serves range calls by filtering copies of it; the refresh
  and the preview at the same tick share one scan.
- `detect/incr.lua` keeps treating a tree with errors as "detect fully" (no incremental work on
  broken trees).
- Live preview (insert mode): an unpaired opener stays source for refresh/placement, but the
  formula being typed must still preview. When the tree has errors and no detected node
  contains the cursor, `core.lua` asks `detect.open_at(buf, row, col)` (latex.lua ->
  pure `recover.open_at(lines, first_row, row, col)`): the last unpaired `$`, `$$`, `\(` or `\[`
  at/before the cursor in the cursor's paragraph, as a node from the opener to the paragraph end
  (`$`/`\(` inline, `$$`/`\[` display; nil for an empty body or inside a comment/verbatim). Used
  only by the preview, never by refresh. An open `\begin` gets no preview (as before).

### Scanner rules
- Boundaries: `$`, `\(`, `\[` end at the paragraph (blank line) at the latest; `\begin{x}` ends at
  the matching `\end{x}` or the end of the file.
- Pairing is one left-to-right pass: at each opener (`$$` before `$` at the same position) the
  first closer of the same kind in the paragraph closes it, and scanning continues after the
  closer. An opener without a closer stays source and the scan moves on past it. A backslash
  consumes the next character, so `\$` (a `$` after an odd number of backslashes) is escaped.
  With an odd count of `$`, the last unpaired one is the open one and stays source.
- `\begin{x}` without `\end{x}`: not rendered.
- Ignored: `%` comments to end of line, `verbatim`/`lstlisting`, `\verb`.
- Unbalanced `{` inside a formula is MathJax's problem (error diagnostic as today); outside math
  it is ignored.

## Error handling
Scanner failure never raises into editing (`pcall`, fall back to the freeze behaviour).

## Performance
Runs only with treesitter errors and only over the error region plus its paragraph. Target
< 1 ms for typical cases; `dev/bench.lua` gets a case with an open `$`.

## Tests
- `tests/test_recover.lua` (pure): paired/unpaired `$`, `$$`, `\$`, comment, verbatim, open
  environment, paragraph boundary, same result as treesitter on error-free text.
- Detect/core test: file with an open `$` in the middle. Formulas before and after are detected
  and placed; closing the `$` leaves no duplicates or leftovers. New formulas render while the
  error exists (replaces the freeze expectation; adjust existing freeze tests that pin the old
  behaviour).
- Markdown: a lone `$` produces no error node.
- README Limitations entry on unclosed `$`/`{` is rewritten; `make doc` if options change (none
  planned).

## Out of scope
4b (tectonic plan B), markdown recovery, a scanner for non-math constructs.
