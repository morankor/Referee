# WP2 — PDFBridge

Notes of the Wave 1 package PDFBridge (`plan.md` §11.4), for the Gate 1 integrator. Everything here was measured on this machine (Command Line Tools 26.6, Swift 6.3.3, macOS 26) with the committed fixtures.

## What exists after this step

| Part | State |
| --- | --- |
| `RawExtractor.extract(from:)` | Complete (pages, lines, links, outline). Its output for the seven committed PDFs is byte-identical to `Fixtures/raw` (the frozen comparison in `PDFBridgeSmokeTests` passes). Hardened only in ways no fixture reaches (decision 6) |
| `PDFPaperService` | `load(url:)`, `load(data:fileName:)`, SHA-256 with CryptoKit, `isEncrypted`, the four `PaperError` cases, bounds of stripped lines, `rects(for:in:)`, `unload`. One extraction `PDFDocument` per loaded document, counted per load (decision 2) |
| `SelectionInfoBuilder.make(from:in:)` | The raw selection of §7.4: one span per text range of each line selection, one rectangle per line, PDFKit's text |
| `PageGeometry` (internal) | The bounds of a text range, used by `rects` and by the bounds of stripped lines (decision 1) |
| Tests | 39 in `PDFBridgeTests` (the 6 Wave 0 smoke tests kept unchanged, 33 new) in six suites, one file each, plus `PDFBridgeTestHelpers.swift`; every row of WP2's table has at least one |

## Decisions

Things the plan left open, decided inside `Sources/PDFBridge`.

1. **The bounds of a text range are taken between its outermost characters whose own boxes are plausible.** `PDFSelection.bounds(for:)` is the union of the boxes PDFKit gives each character. On the `lineno` fixture (`ay_nolinks`) the glued margin digits *and the character just before them* have boxes that reach back across the page. On page 1, line "Table 2 is 0.91 … difficult to14", every character's box is exact (e.g. "T" 110.9–118.9) except "o" (x 296.6–493.5; the glyph itself starts at 493.6), "1" (−2.2–296.7) and "4" (100.9–197.0). Over all four pages of `ay_nolinks`, 132 characters have a box wider than 1.6 times its height; all are margin digits, the character before them, or the seven spaces that stand for the gaps between table columns. Among the other five text fixtures, only the three that have the same table show any such boxes, and those are the same seven spaces. So a range that merely *ends* at such a character gets bounds that begin mid-line, although it contains no margin digit.
   *Done:* `PageGeometry.bounds(of:on:in:)` skips blank characters and characters whose box is more than twice as wide as it is high (no single glyph is). It finds the first and the last remaining character from the outside in and returns PDFKit's bounds of the range between them. If those bounds reach beyond the two outer boxes, it unites the plausible boxes one by one instead. It returns nil when nothing visible with a plausible box is left. A line costs 4 or 5 PDFKit calls (a single-character selection takes 2–5 µs). The rectangle can be one glyph short where a margin number is glued: "…difficult to" ends at 493.6 instead of about 499.5.
   *Effect on the plan's own example* (the Table 2 quote, spans {676, 18} and {697, 59}, the values of §4.3):

   | | "The coefficient in" | "Table 2 is 0.91 … crosses one" |
   | --- | --- | --- |
   | this service | x 410.2, y 189.2, w 82.7, h 10.6 | x 110.9, y 165.2, w 286.2, h 10.6 |
   | PDFKit's bounds of the span, as §6.7 words it | x 296.6, w 196.3 (starts at "[2020], Lee …") | the same as above |
   | sample of §4.3 | x 384.2, w 111 | x 110.9, w 281 |

   Both versions pass WP2's row ("x ≥ 100 and width < 400") and Gate 1's ("starting at x ≥ 100"): the thresholds do not tell them apart. The tests also pin the left edge to the first character's box; a mutation run with PDFKit's plain bounds fails them by 113.5 pt (that rectangle) and 51.2 pt (the bounds of the centred line "Anonymous").
2. **Loads are counted.** The service keys a document by its SHA-256 and keeps, per document, the extraction `PDFDocument`, the finished `PaperText`, the page strings and a load count. Each `load` adds one, each `unload` removes one, and the document is released at zero. An extra `unload` does nothing. If two windows show the same file, or a duplicate open is closed again, the document is not taken from a window that still uses it. When a document is loaded again, the latest load's text serves `rects`. `rects` for a document that is not loaded returns `[]` and logs `pdf.rects.notLoaded`.
3. **`rects(for:in:)`**: for each span, the intersection with the `contentRange` of every line of its page (any kind; a `.marginNumberOnly` line has an empty content and never counts), measured as in decision 1. A piece that holds only blank characters gives no rectangle. Spans on a page the document does not have, with a negative or overflowing range, or outside every line give nothing; a span running past the end of the page string is cut to it. Nothing is ever passed to PDFKit outside the page string.
4. **Bounds of stripped lines.** Every line whose `contentRange` differs from `range` gets the bounds of its `contentRange` by decision 1. They are `nil` when nothing visible is left, as on a line that was only a number; `page.selection(for:)` of an empty range is `nil` too. Lines whose `contentRange == range` keep whatever bounds the builder gave.
5. **`load`.** `.notAPDF` unless `%PDF-` *starts* at one of the first 1,024 bytes (a marker that begins at byte 1,023 is accepted, one at 1,024 is not). `PDFDocument(data:)` returning nil gives `.unreadable("it is damaged")`. Then `isLocked` gives `.encrypted`, and no pages gives `.empty`. Log events, with numbers, booleans and fixed ids only: `pdf.load.done` (pages, links, encrypted, textLayer, marginNumbers, ms) and `pdf.load.failed` (reason: `unreadable`, `notAPDF`, `encrypted`, `empty`). A test checks that neither the file name nor page text reaches the log.
6. **`RawExtractor`**, unchanged on every fixture:
   - The lines are sorted into string order, and a line that overlaps the previous one keeps only its part after it, so the promise of `RawPage.lines` (ranges increase and never overlap) holds for any PDF.
   - A null or non-finite rectangle becomes `bounds == nil`, and a non-finite coordinate becomes 0. Before, `CGRect.null` would have put infinities into `PageRect`, which `JSONEncoder` refuses, in the dump or in a saved anchor.
   - An outline item without a destination takes the destination of its go-to action.
7. **`SelectionInfoBuilder`.** For each line selection (or the selection itself, if PDFKit gives no lines) and each page it lies on: one span per text range, with line breaks trimmed at both ends, and the line's bounds as its rectangle. PDFKit reports a selection made from {697, 84} as {697, 85}, its line break included. Pages of another document are skipped. `text` is `selection.string`, unchanged. nil when no span is left.
8. **Tests.** `TrailingDigitsBuilder` (trailing digits, at most two, are the margin number) stands in for PaperText's builder, which this target cannot import. `shasum -a 256` is run as `/usr/bin/shasum`. The protected copies are written from `num_links` into a temporary folder (measured value 2 below). Two mutations were run and reverted: PDFKit's plain bounds instead of decision 1, and ignoring `contentRange`. A test was added for the second because none caught it: on these lines the glyph rule alone already drops the digits.

## Measured values that differ from the plan

1. **§6.7, "sub-ranges that exclude them are exact (x = 110.9) [V]"** holds for ranges that start at the line's left edge, not for ranges that end at the character before glued margin digits (decision 1). §6.7's algorithm ("`page.selection(for: intersection)?.bounds(for: page)`") and the §7.2 sentence on recomputed bounds are implemented as decision 1 describes. *Suggested:* reword both, and replace the §4.3 sample rectangles with the measured ones above.
2. **WP2 row "protected PDFs" ●, "page 1 text equal to the original's"**: true for `num_links`, false for `ay_round_nolinks`, `ay_nolinks`, `ay_links` and `s1_ruler`. `PDFDocument.write(to:withOptions:)` re-encodes the fonts, and the "ff" and "ffi" ligatures then come back from `page.string` as "!" and "\"" ("effect" → "e!ect", "payoff" → "payo\"", "Office" → "O!ce"). This happens *with or without a password* (a plain copy differs at the same places). The copy of `ay_nolinks` page 2 also comes back re-spaced ("i= 1,2,..." → "i = 1, 2, . . ."), and `num_links` page 2 too ("feugiatmagna" → "feugiat magna"). So encryption itself does not change the text; re-serialisation does. The row does not name a fixture; the test uses `num_links`, where it holds. This also supports §4.6 and §6.2: a re-serialised manuscript would no longer have the original's text.
3. **`PaperError.empty` cannot be produced with real data on macOS 26.** PDFKit returns nil for a well-formed PDF whose page tree is empty (a hand-made file with a valid cross-reference table, `/Count 0`), and for every malformed page tree tried. CoreGraphics refuses it too. A `CGContext` PDF closed without a page opens with one page. So such a file is `.unreadable`. The check stays in case PDFKit ever opens one, and the test accepts either.
4. **A user password needs an owner password** in `write(to:withOptions:)`: with `.userPasswordOption` alone PDFKit writes a file that is not encrypted. The test sets both.

Also observed (consistent with the plan): every line selection of every fixture page has exactly one text range and lies on one page. `numberOfCharacters` equals the UTF-16 length of `page.string` on all 23 pages. `page.selection(for:)` of a range that is only a line break is not index-consistent: {781, 1} on `ay_nolinks` page 1 returns the string "4", the character before. Line breaks and blanks are therefore never measured.

## Contract problems

None. The public surface of §11.3 and Appendix A is unchanged, and no frozen test failed. Two things are documented by this package only and might belong in Appendix A.2, `PaperService`:

- Each `load` must be matched by one `unload` (decision 2).
- `rects(for:in:)` answers only for a document loaded through the same service and not yet unloaded.

## For Gate 1

- **WP8b's model must call `unload` exactly once per `load`** (`close()`, and `deleteReviewData()` through it), and `rects` only for the paper it loaded. A test that builds a `LoadedPaper` with `makeSamplePaper` and asks the *real* service for rectangles gets `[]` (`pdf.rects.notLoaded` in the log). The engine (WP6) and the CLI only ask for rectangles of a paper that was loaded through the same service, which works.
- With "Remove margin line numbers: Never", `contentRange == range`, so the digits can only be kept out of rectangles by the glyph rule of decision 1. That rule drops them on full-width lines (both digits of "…to14" have implausible boxes), but not always on short lines. On "3 Results31", for instance, the "1" has a plausible box.
- The test output contains the line "CoreGraphics PDF has logged an error. Set environment variable "CG_PDF_VERBOSE" to learn more." (once per run). CoreGraphics writes it to standard error when PDFKit is given damaged data. Wave 0's smoke test does that, and so does the "failures" row. It is not a compiler warning or error, and it was there before this package.
- Gate 1's row "selection on a real page" should hold through this service: the raw spans of the two-line drag give two rectangles with x ≥ 100 and width < 400 (tested here without the normalizer: x 311.5 and 110.9).

## Acceptance

Run on the tree of the last commit, after touching every file of this package (so that all four sources and all seven test files were compiled again), on a machine shared with eight other builds. The other targets are still Wave 0 placeholders in this worktree.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh -j 2` | exit 0; no line with "warning" or "error" | `Build complete! (5.01s)` (incremental: the four PDFBridge files and their dependants) |
| `scripts/test.sh -j 2 --filter PDFBridgeTests` | exit 0; no "warning"; the only line with "error" is the CoreGraphics notice above | `test.sh: OK (39 tests)` |
| `scripts/test.sh -j 2` | exit 0; the same | `test.sh: OK (162 tests)` (Gate 0's 129 and the 33 new ones) |
| `git status --porcelain \| wc -l` | | `0` |

The full suite also passed three more times in a row before the last commit.
