# WP1 — PaperText

The target `PaperText` (plan.md §11.4, WP1): `PaperTextBuilder` (§7.2 steps 1–7), `QuoteMatcher` (§6.7) and `PaperRenderer` (§6.2, `chunkPageRanges`). Pure Foundation; of a raw line's bounds only `y` and `height` are read. The public surface is exactly §11.3; everything else is `internal`.

| File | What it holds |
| --- | --- |
| `PaperTextBuilder.swift` | The steps in order, step 7 (flags, title guess) |
| `MarginNumbers.swift` | Step 1 (chains in trailing and leading mode), step 6 (nearest number), a median |
| `PageFurniture.swift` | Steps 2–4: boilerplate, page numbers, repeated lines |
| `Folding.swift` | The folding of §6.7, and `FoldedText`: folded units of lines with their sources and token starts |
| `QuoteMatcher.swift` | The index, `locate` steps 1–3 and 5, spans |
| `FuzzyMatch.swift` | `locate` step 4 (rarest tokens, windows, LCS, trimming) |
| `LocationLabel.swift` | `locationLabel(for:)` |
| `PaperRenderer.swift`, `RenderRun.swift` | Rules 1–5 of §6.2, chunking |

Checked against the prototype (`docs/prototypes/text_and_citations.py`) with a throwaway test that printed both: on all seven fixtures the rendering is byte-identical, and the kind, margin number and text of every line except number-only lines are identical. Every ● value of the acceptance table holds; none had to be reported as wrong.

## Decisions

Where the plan is silent, decided inside `Sources/PaperText`:

1. **Folding.** Modifier letters (category Lm, such as U+02C6 "ˆ" and U+02BC "ʼ") fold to nothing, like combining marks: PDF text often carries accents and apostrophes as such spacing characters ("foreˆt"), and a quote written "forêt" or "don't" must match. Combining marks, format characters (soft hyphen, zero-width joiners), modifier letters and modifier symbols do not end a token; every other character that folds to nothing does.
2. **Line-end hyphens** are "-", U+2010, U+2011 and U+00AD, for the token merge of §6.7 and the de-hyphenation of §6.2. A line break inside a quote is treated as a line break of the text (the same token merge).
3. **Step 1.** When both modes qualify with the same number of chained lines, trailing mode wins (`s1_ruler`'s number-only ruler qualifies in both, with the same result). Of equal chains on a page, the one that ends earliest wins. Digits are ASCII; "a letter" after a leading number is any Unicode letter.
4. **Step 2** collapses runs of whitespace to one space before matching the pattern.
5. **Step 3.** "Whose number increases by one from the previous page" is read over the whole document: each candidate (a first or last remaining body line that is only a number) has an offset, its number minus its page position, and the candidates with the most common offset are page numbers (a tie goes to the offset nearest to "page 1 is numbered 1"). So a page without a number, or one stray number, does not stop the numbering of the pages after it, which a page-by-page reading would.
6. **Step 4.** A repeated line with no letter at all ("(1)", "□") is left in the text unless its centre lies in the top or bottom 15%: equation numbers on most pages of a mathematical paper are not a watermark. Lines are counted only while still `.body`, as the plan's order says (the prototype also counted page numbers and watermarks).
7. **Order.** Whitespace-only lines become `.empty` before steps 2–4 (no effect on them). Step 6 runs after steps 2–4, as printed, so only `.body` lines get a nearest number; the prototype ran it earlier and also numbered watermark lines, which shows nowhere.
8. **Title guess.** "Tallest" allows max(0.5 pt, 2%) below the tallest height; a line without bounds ends the run; `nil` when none of the first 15 body lines has bounds.
9. **The setting.** `stripMarginLineNumbers` is read once per `build`. When it is false, step 1 does not run, so `hasMarginLineNumbers` is false too (as in the prototype) and step 6 has nothing to do.
10. **`locate`, step 1.** Ellipses are "…", three or more dots (". . ." too) and either of them in square brackets. Pieces that fold to nothing are dropped; the first and the last remaining pieces must have 12 units each.
11. **`locate`, step 2.** With a hint and at least 12 units the whole document is searched and the hinted page preferred; equally near pages go to the earlier.
12. **`locate`, step 3.** Head = the first 80 units of the first piece (of the quote without pieces), tail = the last 80 of the last. "Distance at most 3 × q.count" is measured from the head's start to the tail's end. Equally near pairs go to the hinted page.
13. **`locate`, step 4.** Rarest = fewest occurrences in the document, then longer, then earlier in the quote; a token's first position in the quote fixes its alignment; duplicate alignments are scored once; the candidate's page is its occurrence's. A window that holds fewer quote tokens than the threshold needs is not scored (that count bounds the LCS, so results are unchanged; it makes the stage about three times faster in a debug build). Trimming takes the shortest window prefix with the full LCS, then the shortest suffix of that.
14. **Labels.** Spans are sorted by page and offset; the first (last) line touched is the first (last) `.body` line whose content range the span meets, else any line whose range it meets; a page or range found nowhere gives an unknown number.
15. **Rendering.** Lengths are counted in Unicode scalars (the prototype counts code points). A line's text is trimmed, with any line break inside it read as a space. A page without body lines still gets its marker. A sentence end that falls exactly on the page break counts (the marker then stands between the two pages' text), but a cut never moves text of the earlier page after the marker. In a run with several page breaks, once one marker found no sentence end, the later ones follow the run as well, so markers stay in order. Rule 4's "occurs unbroken elsewhere" uses the words and the hyphen-joined word pairs of every `.body` line of the paper, lower-cased. A hyphen followed by an upper-case letter is joined with one space, by rule 3 ("Bayes- Nash").
16. **Chunking** counts Swift characters (as `FakePaperRenderer` does) and is greedy. The sum of single-page sizes is used as a first test, because rendering pages together is never longer than rendering them apart; the actual rendering decides near the limit, and a final check shrinks any range that does not fit.
17. **`Fixtures/private` in the "no false positives" row.** The test reads the PDFs and `*.raw.json` dumps directly inside `Fixtures/private`; a PDF is dumped inside the test by a copy of the raw extraction of §7.2 (a second test checks that copy against the committed dump of `ay_links`). Files are named by their position only, so no file name reaches the log. Subfolders are not read: see contract problem 2.

## Contract problems

1. **`TextRange` is ambiguous in type position** (Appendix A.1, `Sources/RefereeCore/Basics.swift`). With the macOS 26 SDK, `import Foundation` also brings the Apple Events C struct `TextRange` (CoreServices, `AE.framework/Headers/AERegistry.h`). In a file that imports Foundation and RefereeCore, a parameter or property declared as `TextRange` fails with "'TextRange' is ambiguous for type lookup in this context"; expressions such as `TextRange(location:length:)` resolve. *Workaround:* `RefereeCore.TextRange` in my one type annotation. Every Wave 1 target will meet this; Gate 1 may want to say so in §3.7, or add a note to `Basics.swift`.
2. **The row "no false positives" assumes `Fixtures/private` holds no line-numbered PDF**, while §3.3 and §3.6 (and Q7) put the journal-system PDFs the user may add in the same folder, and those do have margin numbers. *Workaround:* the test reads only files directly inside `Fixtures/private`; journal-system PDFs belong in a subfolder (for example `Fixtures/private/journal/`), which this row does not read. Gate 1 should say so where §3.6 describes the folder (or give those files a test that expects `true`).

## Acceptance

Run on Command Line Tools 26.6 (Swift 6.3.3), after touching every file this step owns.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh -j 2` | exit 0; no warning or error | `Build complete! (5.32s)` |
| `scripts/test.sh -j 2 --filter PaperTextTests` | exit 0; no warning; one test skipped (`noMarginNumbersInARealPaper(file:)`: "Fixtures/private holds no PDF and no raw dump") | `test.sh: OK (51 tests)` |
| `scripts/test.sh -j 2` | exit 0; no warning or error; the same one skip | `test.sh: OK (177 tests)` |
| `git status --porcelain \| wc -l` | | `0` |

Acceptance rows and the tests that hold them (`Tests/PaperTextTests`): line numbers on text lines → `lineNumbersOnTextLines`, `glueAndRemovalKeepTheTextAndItsRange`; ruler → `ruler`; no false positives → `noFalsePositives`, `noMarginNumbersInARealPaper` (skipped here: `Fixtures/private` is absent in a worktree); setting respected → `settingRespected`, `theSettingIsReadAtEachBuild`; page furniture → `pageFurnitureOfTheLinenoFixture`, `pageFurnitureOfTheRulerFixture`; numbered lists → `numberedListsAreNotLineNumbers`; exact anchors → `exactAnchors`; across a page → `acrossAPage`; two columns → `twoColumnsSmoke` (the crossing quote returns `nil`); fuzzy → `fuzzy` (score 0.9); ellipsis → `ellipsis`; absent → `absent`; short quotes → `shortQuotes`; repeated text → `repeatedText`; folding → `folding`; labels → `labels`; rendering → `rendering`; chunking → `chunking`, `chunkingALongSyntheticPaper`; robustness → `emptyDocuments`, `oneCharacterPages`, `linesWithoutBounds`, `linesThatDisagreeWithTheirPage`, `randomUnicode`; speed → `speed`.

## For Gate 1

- **Speed.** The row's work (matcher for 60 pages, about 178,000 folded units, and 50 quotes of five kinds) took 0.11–0.19 s in a debug build while the other Wave 1 agents were building: about 0.035 s to build the matcher, about 1 ms per exact quote and about 1.3 ms per fuzzy one.
- **`ay_nolinks` and `s1_ruler` through the real service** (Gate 1's "pipeline on every fixture"): the builder gives exactly the §7.2 table. Line bounds are left raw, as the protocol says; highlight rectangles starting at x ≥ 100 depend on `PDFPaperService` recomputing the bounds of the 44 `.body` lines of `ay_nolinks` with digits glued to them. 54 lines there (and all 240 ruler lines of `s1_ruler`) have `contentRange != range`; for the `.marginNumberOnly` ones the content range is empty.
- **Where the rules are weak on real files** (R4, Q7; nothing in the fixtures shows these): running heads that alternate between even and odd pages are each on about half the pages, below step 4's 60%; a page whose chain has fewer than five members (a short last page) keeps its glued numbers; a heading at the top of a page is joined to an open run from the previous page, because rule 3's pitch test cannot apply across pages; numbers that PDFKit puts on lines of their own twice (a ruler on both margins) would leave one copy in the text.
