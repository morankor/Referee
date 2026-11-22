# WP3 — CitationKit

Notes of work package WP3 (`plan.md` §11.4), on branch `wp/3-citationkit`. Read by Gate 1.

## What was built

`CitationIndexer.buildIndex(paper:links:)` (the only public declaration, as in §11.3) runs these internal pieces, one per file in `Sources/CitationKit/`:

| Piece | Plan | What it does |
| --- | --- | --- |
| `BodyText`, `FlowText` | §8.1, §8.4 | The `.body` lines with text, in document order; the body text outside the list joined with line breaks, with the way back to `(pageIndex, utf16Offset)` |
| `Folding` | §6.7 | NFKD, letters and digits only, lower-cased (CitationKit cannot import PaperText, so it has its own copy) |
| `BibliographyLocator` | §8.2 | Heading, style, left edge per page, hanging or not, entry starts, the end rules (a)–(d), fewer than three entries → no list |
| `EntryText`, `EntryParser`, `AuthorKeys` | §8.1, §8.3, §8.4 step 1 | Entry text, then surnames, year and suffix, title, DOI, arXiv id, URL; the folded author keys |
| `TextMentionFinder` | §8.4 | Numeric brackets (one mention per number or range); author–year by year and left context |
| `LinkMentionFinder` | §8.5 | Citation links (destination inside the list's vertical extent), target entry, merging of natbib pieces |
| `MentionMerger` | §8.5 | Pairs the k-th link mention with the k-th text mention per page and entry, sorts, renumbers |
| `CitationAnalysis` | — | Runs the pieces and keeps every stage, so tests can look at the link path before the merge |

Tests (`Tests/CitationKitTests/`, 39 tests) cover every row of the acceptance table:

| Row | Test |
| --- | --- |
| reference list, author–year ● | `CitationFixtureTests.authorYearReferenceList` |
| the list ends only on evidence | `CitationListEndTests` (taller "A Proofs"; "Appendix" at the left edge in the list's size; the two continuation lines, hanging and flush left; "References 12" and other headings; also rule (c), a keyword line and an earlier column in a numeric list, labels on lines of their own) |
| mentions, round brackets ● | `CitationFixtureTests.roundBracketMentions` |
| mentions, square brackets ● | `CitationFixtureTests.squareBracketMentionsHaveTheSameTargets` |
| not citations | `CitationTextMentionTests` (employee, possessive, "Smith (2019, 2021)"; also keys, ties, suffixes, a citation across a page break) |
| link path ● | `CitationFixtureTests.linkPath` |
| numeric ● | `CitationFixtureTests.numericFixture`; synthetic "[3–5]" and "[99]" in `CitationTextMentionTests` |
| numeric links ● | `CitationFixtureTests.numericLinks` |
| two columns, smoke ● | `CitationFixtureTests.twoColumnsSmoke` |
| parser table | `CitationParserTests.parse` (24 entries: economics, AER, Chicago, APA, numeric, IEEE, "et al.", particles, initials before and after, Springer with and without spaces, label on its own line, DOI at the end and broken at a slash, arXiv ids that look like years, page ranges and volumes that look like years) |
| no list | `CitationRobustnessTests.aDocumentWithoutAReferenceHeadingGivesAnEmptyIndex`, `degenerateInputsGiveAnEmptyIndex` |
| robustness | `CitationRobustnessTests` (seeded random text, random text after a planted heading, a 5,001-line document with 4,000 citations and 1,000 entries: 0.15 s in the debug test build) |

Every ● value held as printed: none was bent. Input in tests is `identityPaperText` of the committed dumps, as the brief says.

## Decisions

Where the plan was silent, or where I chose between two readings:

1. **Blank body lines** (empty or only white space) are skipped everywhere.
2. **Entry text (§8.1).** Rule (b), a URL or DOI broken at `/ - _ . = &`, is checked before rule (a), the hyphen, so that "doi:10.1000/abc-" + "def" keeps its hyphen. Rule (a) requires a letter before the hyphen, as the plan says (the prototype did not check).
3. **Years.** The optional suffix letter must not be followed by another letter: in space-less text "2019and" is 2019 without the suffix "a" (the plan's `[a-z]?` would take it). Digits are matched as `[0-9]` (ICU's `\d` also matches other scripts' digits). The status word "n.d." is matched without a word boundary after it (the prototype's `\b` there never matches).
4. **Year rule details (§8.3).** "Touches a page range" = a digit, optional spaces and a dash (hyphen, en and em dash, minus) right before, or the same after; "followed by (" means immediately.
5. **Authors in numeric lists** (and in an author–year entry with no year) end at the first period after a lower-case letter or closing quotation mark, or earlier at an opening quotation mark (IEEE `J. Smith, “Title,”`) or an opening parenthesis (`J. Smith (2001). Title.`). A period must be followed by white space or the end.
6. **Surnames, two additions to §8.3.** (a) A piece of written-out given names that follows a comma right after a one-word surname is dropped: "Avery, Christopher, and Peter Zemsky" → [Avery, Zemsky], "Banerjee, Abhijit V." → [Banerjee]. Without it the AER and Chicago styles, the commonest in economics, get a spurious second surname and no citation matches. (b) "Jr", "Sr", "II", "III", "IV" are dropped.
7. **"et al." printed in the list** also gives the key s1 + "etal", whatever the number of names left (an entry "Acemoglu, D., et al. (2011)" is cited as "Acemoglu et al. (2011)"). `ParsedReference` has no field for this; it is internal (`ParsedEntry.authorsTruncated`).
8. **Entry starts, author–year lists that do not hang.** "Begins with an upper-case letter" also accepts lower-case particles before one ("van der Berg, J. (2005)…").
9. **End rule (c)** needs an actual next line (the plan's wording); the prototype also fired at the last line of the document.
10. **Title.** A quoted title is the quoted text; after numeric authors a parenthesised year is skipped; a period after a single letter ("U.S.") does not end the sentence; "?" and "!" end it and are kept. Quotation marks and trailing `,.;:` are removed.
11. **Identifiers.** URL: trailing `.,;:` and an unbalanced `)` or `]` removed. DOI from a link: the part after "doi.org/", percent-decoded. arXiv id also from link URLs; the version is dropped from `arxiv.org/abs/…` ids. A URL link lies inside an entry when its centre is within one of the entry's line bounds, 2 pt of slack.
12. **`rawText` keeps a numeric entry's label** ("[1] Dzmitry Bahdanau, …"), as printed. `spans` and `bibliographyHeading` are the lines' ranges without surrounding white space.
13. **Mention text and spans follow §8.4 literally**: from where the key begins to the end of the year, line breaks as spaces ("Bikhchan- dani et al. (1992", "Kogan (2020"). See contract problem 1.
14. **Link pieces (§8.5).** Same line: vertical centres within max(3 pt, 0.3 × height) and a gap of −2 to 12 pt. Next line down: lower by more than half a line height and by less than max(40 pt, 2.5 × height), starting further left. A piece "is just a year" when its letters and digits are a year (brackets PDFKit may include are ignored). Pieces are joined with a space, or without the hyphen for "Zem-" + "sky" ("Avery and Zemsky 1998"). The y range is exactly the plan's (no extra slack below; the prototype allowed 4 pt). Links on pages the paper does not have, and internal links into a list page that holds no entry's first line, are ignored.
15. **Merge.** A merged mention has source `.linkAnnotation` (its target came from the link) and the text mention's page. Before pairing, link mentions are put in text order (the line under the rectangle) rather than annotation order, so that on a page PDFKit re-orders (page 2 of `num_twocol_links`) the k-th of each kind still mean the same citation. When sorting, a mention with only rectangles is placed by that same estimate.

## Contract problems

No blocking problem; three places where Appendix A.3 and §8 disagree or are silent. No workaround was needed for any of them.

1. **`CitationMention.text`** (Appendix A.3, comment `"Smith and Jones (2019)"`) vs §8.4 step 5 (the mention ends at the end of the year: `"Smith and Jones (2019"`). I followed §8.4, for the text and for the spans. If the card should show a balanced, de-hyphenated text ("Bikhchandani et al. (1992)"), Gate 1 should decide it once and change §8.4; it is a small change in `TextMentionFinder.authorYearMentions`.
2. **`BibEntry.rawText`** (Appendix A.3, comment "entry lines joined by a space") vs §8.1 (no space at a word hyphen or a broken DOI). I followed §8.1.
3. **The source of a merged mention** is not stated in §8.5 (`MentionSource` has two cases). I chose `.linkAnnotation`. Consequence for WP8b (§8.4: "`ReviewSessionModel` fills `rects` … right after indexing"): fill rectangles only for mentions whose `rects` is empty, which are exactly the unpaired `.textPattern` ones; a merged mention already carries the link's rectangles, the exact click targets.

## For Gate 1

- **`ay_nolinks` and `s1_ruler` through a real-like pipeline.** Not part of my acceptance, but I checked it with throwaway scripts outside the tree: the prototype's line cleaning (`text_and_citations.py build`) exported as `PaperText`, the bounds of the 44 `ay_nolinks` lines that lost a margin number recomputed with `PDFPage.selection(for:)` as §7.2 says `PDFPaperService` does, then `CitationIndexer`: both give 9 entries with the first surnames of the table and the same 15 mention targets. So Gate 1's row "citations with line numbers" should hold if WP1 classifies like the prototype and WP2 recomputes the bounds. On the raw bounds (x = −2.2 on those lines) it would not: the left edge is wrong.
- **In this worktree the page numbers stay in the text** (`identityPaperText`), so the entries that end a page read "… Working paper. 3" and "… 68(2):371–398. 4". With the real builder they do not; no test depends on it.
- **Known limits of the plan's rules,** seen while testing, none in a ● row: in an author–year list that does not hang, a continuation line that begins with a capital after a line ending in "." and has a year within two lines starts an entry of its own (hanging lists, the fixtures' and APA's, are unaffected); in a two-column author–year list the left edge is per page, so right-column entries are not at it (numeric two-column lists are found by number); space-less "DzmitryBahdanau" stays one surname; "encoder-" + "decoder" becomes "encoderdecoder" (§8.1 rule a).
- Performance: the 5,001-line document takes about 0.15 s in the unoptimised test build, nearly all of it parsing 1,000 entries and matching 4,000 citations.

## Acceptance

Run at the last commit, after touching every file in `Sources/CitationKit/` and `Tests/CitationKitTests/`.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh -j 2` | exit 0; no "warning" or "error" | `Build complete! (5.08s)` |
| `scripts/test.sh -j 2 --filter CitationKitTests` | exit 0 | `test.sh: OK (39 tests)` |
| `scripts/test.sh -j 2` | exit 0; no "warning" or "error"; every target's tests pass | `test.sh: OK (167 tests)` |
| `git status --porcelain \| wc -l` | | `0` |
