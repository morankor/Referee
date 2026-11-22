# WP7 — ScholarKit

Notes of work package 7 (`plan.md` §11.4): the reference resolver of §8.7. Read by the Gate 1 integrator and by WP8b, WP9 and WP11, who show what it returns.

## What exists after this step

| File (`Sources/ScholarKit/`) | What it does |
| --- | --- |
| `ReferenceResolver.swift` | The public actor: cache lookup, the steps, `forget`, `fetchPDF`, `searchURL`. Public surface exactly as §11.3; one internal initialiser more, with `clock:` and `maxPDFBytes:` for tests |
| `ReferenceLookup.swift` | Steps 1–4 of §8.7: printed arXiv id (no request), printed DOI → OpenAlex, else Crossref → validation → OpenAlex, else `notFound` |
| `CandidateValidator.swift` | The validation rule of §8.7 and the choice among candidates |
| `CrossrefCandidate.swift`, `OpenAlexWork.swift`, `JSONFields.swift` | Lenient parsers of the two answers (a field of the wrong type reads as absent) |
| `ServiceRequests.swift` | The two URLs, query encoding, `User-Agent`, the contact address |
| `ServiceClient.swift` | One GET under the host's limits, with the single retry |
| `HostLimiter.swift`, `ResolverClock.swift` | Per-host token buckets and in-flight caps; the injectable clock |
| `LookupCacheStore.swift` | `sessions/<sha256>/references.json` |
| `PDFStore.swift`, `PDFDownloader.swift` | `<cacheDirectory>/papers/<sha256(url)>.pdf`, LRU eviction, the https-only download |
| `ReferenceText.swift` | Folding (§6.7), DOI and arXiv normalisation, title words, SHA-256 |

`Tests/ScholarKitTests/`: 97 tests in 13 suites, one suite per acceptance row plus the text and parser units; the live row skips with a reason unless `REFEREE_LIVE_NET=1`. The whole target runs in about 0.7 s: a test clock does all the waiting.

## Decisions

Things the plan left open, decided inside this package.

1. **`source`** says how the work was identified: `.entryText` when the arXiv id or DOI is in the entry (confidence 1.0), `.crossref` when Crossref's search found the DOI (confidence 0.5 + 0.5 × title share). The metadata of both DOI paths comes from OpenAlex. See contract problem 3.
2. **Results without a record.** An arXiv result, and a printed DOI that OpenAlex answers with 404, carry the entry's own parsed title, surnames and year, so the card is never emptier than the entry. A Crossref match whose DOI OpenAlex does not know keeps Crossref's title, authors ("Sepp Hochreiter"), year and venue. OpenAlex authors are its display names.
3. **What counts as failed.** A lookup that could not be completed is `.failed` (confidence 0) and keeps the identifiers already known (DOI and `https://doi.org/…`), so the card can still offer Copy DOI and the browser. This includes a Crossref match followed by an OpenAlex failure: a second failure of any request fails the whole lookup, which is never cached. Also failed: a network error (not retried), any status other than 2xx, 404, 429 and 5xx (not retried), a 2xx body that is not the service's JSON, a Crossref 404, and a `Retry-After` above 60 s (not waited for). An OpenAlex 404 is "keep the DOI".
4. **What is cached.** Only what a request taught: `.resolved` (180 days) and `.notFound` (30 days). An arXiv result, and an entry with no parsed first surname, need no request and are not written. Such an entry is not sent to Crossref at all: no candidate could pass validation without a surname, so the disclosure would buy nothing. It is `.notFound`.
5. **Choosing a candidate.** All accepted candidates are scored by title share; the highest wins, Crossref's order breaking ties. Title words: markup and the common HTML entities removed, split at spaces, punctuation and symbols, folded; words of four letters or more count, and a title that has none ("On AI") is judged on all its words. A word "occurs" when it is a substring of the folded `rawText`, which is what survives PDF lines without spaces. Thresholds are compared in whole numbers (`matched × 100 ≥ words × 60`, or 85). When either year is unknown the 60% rule applies.
6. **Limits.** Each bucket holds one token, so requests never come in a burst: Crossref 1 request/s and 1 in flight (with a contact address 3/s and 3), OpenAlex 5/s and 5 in flight. A slot is held from before a request until its body has been read; waiters are served first come, first served, and a cancelled waiter leaves without a slot. A 429 or 5xx holds the whole host back for `Retry-After` (seconds or an HTTP date) or 2 s, then the request is retried once. Settings are read at each call, so a contact address set mid-session applies to the next request.
7. **Timeouts and sizes.** A lookup request times out after 30 s of silence (the shared session tolerates 600); a lookup answer over 4 MB is refused. A PDF times out after 60 s of silence.
8. **The contact address** goes to Crossref only, in `mailto=` and as `User-Agent: Referee/<version> (mailto:<address>)`; OpenAlex and PDF hosts never see it. A setting that is not a plain ASCII address (spaces, `()<>[]\",;:`, other than one `@`, no dot in the domain) is ignored and the public pool used, so it cannot break the query or the header. WP11 may want to validate the field when it is typed.
9. **Version.** `Referee/<CFBundleShortVersionString>` only when running inside the `local.referee.app` bundle; elsewhere (tests, `referee-cli`, `scripts/run.sh`) `Referee/0.1.0`, the default of `scripts/bundle.sh`.
10. **Encoding.** The Crossref query is `rawText` with white space collapsed, then its first 300 characters; it and the Scholar query are percent-encoded with only RFC 3986's unreserved characters left as they are, so `&`, `=`, `+`, `#` and quotation marks in a reference cannot change the URL. The OpenAlex path keeps a DOI's slashes and encodes `<`, `>`, `#`, `?`, `%`. `searchURL` uses the parsed title with white space collapsed, else the first 200 characters of the collapsed `rawText`.
11. **The cache file** is `{"lookups": {<key>: ResolvedReference}, "schemaVersion": 1}`, written atomically with the project's JSON options (ISO 8601, pretty, sorted keys, slashes unescaped); the document's folder is created with mode 0700 when missing. Expired lookups are dropped when the file is rewritten; a damaged file or another `schemaVersion` counts as empty and is replaced. `resolvedAt` is truncated to whole seconds, so what is returned equals what a restarted app reads back. A cache hit returns the stored result with the asking entry's `id`. A document id that is not plain letters and digits (at most 128) is not cached at all, since it names a folder.
12. **`forget`** drops the memory copy, deletes `references.json`, then removes the folder with `rmdir`, which only succeeds on an empty folder, so a `session.json` there is never touched. It also bumps a per-document counter: a lookup that was under way when its document was forgotten still answers but is not written back, so no folder reappears after "Delete Review Data…".
13. **PDF cache.** 1 MB = 1,000,000 bytes (as the Finder counts). Least recently used goes first; "used" is the modification date, set from the injected clock on download and on every hand-out from the cache. The file just handed out is never evicted, so a single PDF larger than the whole limit stays until the next fetch. Downloads stream into a hidden `.partial` file in the same folder and are renamed into place; a partial file is deleted on any failure, and one older than an hour (an interrupted download) at the next eviction. A declared `Content-Length` over 100 MB is refused before the body. Redirects are followed only to https; one to http ends the fetch with `.noOpenAccessPDF` (offered in the browser instead, like an http address). Errors: not connected → `.offline`; HTTP status → `.downloadFailed("HTTP 404")`; cancelled → `.downloadFailed("it was cancelled")`, because the protocol allows only `ResolverError`. PDF hosts get no rate limit: one request per click.
14. **Logging** (`Log.event`): `scholar.request` (host, attempt, status or error id), `scholar.resolve` (status, via), `scholar.pdf` (cached, accepted, bytes), `scholar.forget`, `scholar.pdf.evicted`, `scholar.cache.unreadable`, `scholar.cache.unwritable`. Never a reference, a DOI, a PDF host or a document hash; a test with a log sink checks this.
15. **Tests.** The internal initialiser takes the clock (`ResolverClock`); tests use `@testable import ScholarKit` and a `TestClock` whose sleeps move its own time, so spacing and `Retry-After` are measured in its time and cost none. The recorded bodies of Appendix D.10 and the two hand-written ones are Swift literals (`ScholarKitBodies.swift`): the manifest declares no resources, and a JSON file in a test target's folder makes SwiftPM warn. The fixture entries are built from `Fixtures/raw/num_links.raw.json` with the joining rules of §8.1. Email addresses in tests are put together at run time, so no file holds one. `HostLimiter.occupancy(_:)` exists for the limiter's unit tests.
16. **Not tested:** the https-only redirect rule, because `StubURLProtocol` cannot answer with a redirect.

## Contract problems

1. **ScholarKit needs CryptoKit, which §2.1 does not list.** The cache key ("SHA-256 of the folded `rawText`", §8.7) and the PDF file names (`<sha256(url)>.pdf`, §4.2) need SHA-256; §2.1 gives ScholarKit's imports as `RefereeCore` only. *Done here:* `ReferenceText.swift` imports CryptoKit, a system framework, so the manifest is untouched. *Suggested:* add CryptoKit to the ScholarKit row of §2.1, as Gate 0 did for TestSupport.
2. **The card's "Lookup failed: <reason>" has nowhere to get the reason from** (§8.6). `ResolvedReference` (Appendix A.3) has no field for it, and `resolve` never throws. *Done here:* nothing inside the public shape can carry it; a failed result has status `.failed`, confidence 0 and the identifiers already known, and the reason goes only to the log (`scholar.request`, field `error`). *Suggested:* either a `failureReason: String?` on `ResolvedReference` (a sentence safe to show, such as "Crossref is busy; try again in a minute"), or §8.6 says "Lookup failed" with Retry.
3. **`ResolutionSource` is not defined, and two of its cases cannot be produced** (Appendix A.3). The plan never says what `source` means. `.linkAnnotation` cannot be told apart from `.entryText`, because `ParsedReference.doi` merges DOIs from the text and from link annotations (§8.3); `.openAlex` would describe an OpenAlex search, which G.2 decision 5 removed. *Done here:* decision 1; `.linkAnnotation` and `.openAlex` are never returned. *Suggested:* state the meaning in A.3 and drop the two cases, or keep them for later and say so.

## For Gate 1 and Wave 2

- **Settings ▸ References "PDF cache size and Clear"** (§9.6) has no API in `ReferenceResolving`. WP11 can work on `<cacheDirectory>/papers/` directly: the size is the sum of its `*.pdf` files, and deleting the folder is safe at any time (a download in progress then fails with "it could not be saved"). If an API is preferred, it belongs in the protocol.
- **Delete Review Data** (WP8b) calls `deleteSession` and then `forget`: both orders leave nothing behind, and a lookup that finishes in between is not written back (decision 12).
- **Background lookups** (`resolveReferencesInBackground`) can call `resolve` for every entry at once: the limiter queues them (about one Crossref request a second); arXiv and DOI entries do not wait for Crossref.
- **The live run** (below) was the only request this package sent to the real services: one to api.crossref.org with the public reference of the fixture, one to api.openalex.org with its DOI, `User-Agent: Referee/0.1.0`, no contact address.
- For the coordinator: the agents' scratch folders appear to be shared. A test log of this package written under a common file name once came back interleaved with another worktree's build output (an `error` line from WP4's tests). Nothing in any worktree was affected; logs here were then written under a name of this package's own.

## Acceptance

Run on Command Line Tools 26.6 (Swift 6.3.3) at the last commit, after touching every file of `Sources/ScholarKit` and `Tests/ScholarKitTests`.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh -j 2` | exit 0; no line with "warning" or "error"; the 14 ScholarKit files recompiled | `Build complete! (6.97s)` |
| `scripts/test.sh -j 2 --filter ScholarKitTests` | exit 0; no "warning"; the live row skipped with its reason | `test.sh: OK (97 tests)` |
| `scripts/test.sh -j 2` | exit 0; no "warning" or "error"; every target passes (the others are Wave 0 placeholders here) | `test.sh: OK (225 tests)` (`Test run with 225 tests in 38 suites passed`) |
| `REFEREE_LIVE_NET=1 scripts/test.sh -j 2 --filter ScholarKitLiveTests` (run once) | exit 0; the test printed `live lookup: status=resolved doi=10.1162/neco.1997.9.8.1735 source=crossref confidence=1.0 year=1997 pdf=none` | `test.sh: OK (1 tests)` |
| `git status --porcelain \| wc -l` | | `0` |
