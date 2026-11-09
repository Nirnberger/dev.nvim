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
- `lua/inkmath/detect/recover.lua`: pure function `scan(lines, first_row, last_row) -> MathNode[]`.
  No Neovim API calls except through the lines passed in. Output nodes have the same shape and
  `node_id` as `detect/latex.lua`.
- `lua/inkmath/detect/latex.lua`: when `tree:root():has_error()`, compute the error region
  (ERROR/MISSING nodes, extended to the end of their paragraph), call `recover.scan` on it, drop
  treesitter nodes that overlap the region, merge, and sort by position. `has_error` is returned
  `false` when the scanner covered the region (so `core.lua` does not freeze). The scanner is
  wrapped in `pcall`; on failure the old behaviour (`has_error = true`) applies.
- `detect/incr.lua` keeps treating a tree with errors as "detect fully" (no incremental work on
  broken trees).

### Scanner rules
- Boundaries: `$`, `\(`, `\[` end at the paragraph (blank line) at the latest; `\begin{x}` ends at
  the matching `\end{x}` or the end of the file.
- Pairing order per paragraph: `$$` first, then `$`. A `$` preceded by an odd number of
  backslashes is escaped. With an odd count of `$`, the last unpaired one is the open one and
  stays source.
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
