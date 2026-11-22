# Referee — implementation plan

A macOS PDF reader for peer review: the manuscript on the left, AI-drafted referee comments in a sidebar to approve, reject, discuss or add to, questions about any highlighted passage, clickable citations that open the cited paper, and a generated referee report to edit and export. Works with Anthropic, OpenAI, Google, xAI and Ollama, by API key or through the vendor's own command-line tool for subscription plans.

Plan date: 2026-11-22, second version: revised after an independent review (`docs/plan-review.md`). Appendix G lists every change by review finding. Target machine: macOS 26.6.1, Apple silicon, 24 GiB memory, Command Line Tools only (no Xcode).

**Contents.** 0 How to read this plan · 1 Product definition · 2 Architecture · 3 Toolchain & build · 4 Data model & persistence · 5 LLM layer · 6 Review engine · 7 PDF layer · 8 Citations · 9 UI/UX · 10 Self-verification hooks · 11 Work breakdown · 12 Security & privacy · 13 Risks and open questions · Appendix A Contracts (Swift) · B Prompts, rubric, lint · C Fixture sources · D Recorded streams · E Sources · F Verification log · G Revision log

## 0. How to read this plan

**Audience.** Coding agents who see this file and a two-paragraph assignment, and cannot talk to each other. Everything two agents must agree on is written here as a concrete name, signature, format or command. If something you need is not specified, decide locally inside your own files and record the decision in `docs/contract-notes/<your work package>.md`; do not change a shared contract.

**Evidence tags.** Every external fact carries one of:

- **[V]** verified on this machine on 2026-11-22 by running it. Appendix F lists what was run and by whom (the plan's author, the coordinator, or the independent reviewer).
- **[V, prototype]** a Python prototype of the algorithm, run on the real PDFKit output of the fixtures. The Swift code does not exist yet.
- **[D]** taken from the vendor's official documentation fetched on 2026-11-22 (URLs in Appendix E), not exercised here.
- **[A]** assumption. Each has a fallback, listed in §13.

**Reading order for a coder.** §2 (architecture), §3 (build rules), §11 (your work package and the surface in §11.3), Appendix A (contracts), then the section for your area. §0.1 and §13 tell you what is known to be shaky.

### 0.1 Deviations from the brief (blocking flaws found during research)

1. **Google subscription route changed.** The brief says to drive `gemini -p` for Google-account plans. Since 2026-06-18 Gemini CLI no longer serves free or Google AI Pro/Ultra accounts; Google moved them to **Antigravity CLI (`agy`)** [D: gemini-cli README, Google Developers blog; confirmed by the reviewer]. The Google subscription provider drives `agy`. Gemini CLI is not implemented. `agy` is not installed on this machine and its only documented installer is a shell script piped from the web, so the adapter is built from documentation and labelled experimental (§5.6.4).
2. **xAI has an official subscription route.** The brief says Grok is API-key only unless research finds one. xAI ships **Grok Build (`grok`)**, a CLI with browser sign-in, a headless mode and an Agent Client Protocol mode [D]. It is added as a CLI provider, labelled experimental: it is not installed here, and xAI's pages do not say whether non-interactive use draws on a subscription's included usage. The adapter talks to it over the Agent Client Protocol, the only documented interface that both takes the prompt on standard input and reports tool use (§5.6.4).
3. **Gemini API surface.** Google labels `generateContent`/`streamGenerateContent` "legacy" and directs new projects to the **Interactions API**, generally available at `v1` [D]. The Gemini API-key provider uses `POST /v1/interactions`.
4. **Unpaywall dropped.** Unpaywall now runs on the OpenAlex database and returns the same open-access fields [D]. A DOI lookup on OpenAlex is free and needs neither key nor email [V]. The resolver uses OpenAlex and never needs an email; Crossref `mailto` stays an optional setting, empty by default.
5. **Test fallback dropped.** The coordinator verified Swift Testing under Command Line Tools 26.6 with extra command-line flags [V]. There is no custom test runner.
6. **Broken Codex install.** The npm copy at `/opt/homebrew/bin/codex` (0.128.0) is unusable: during research its launch hung after macOS rejected the native binary's code signature, and now the binary file is gone and the wrapper fails at once with `ENOENT` [V]. The Codex CLI bundled inside `/Applications/ChatGPT.app` (0.167.0-alpha.3.2) works and is logged in [V]. Consequences: binary resolution must validate candidates and enforce a launch timeout (§5.6.1), and the user should reinstall Codex.
7. **Subscription CLIs are agents, not model endpoints.** None of the four can be trusted to be "text in, text out" on the strength of its flags: Claude Code documents a way to remove every tool, Codex keeps a residual one whatever the flags, Antigravity has no flag that removes tools, and Grok Build's flags have not been tried. Every CLI adapter therefore watches the CLI's own event stream and kills the run when a tool appears (§5.6.3). What that does and does not guarantee is stated per provider in §12.5.

Decisions taken by the coordinator after the review, which this version implements: both experimental CLI adapters stay in v1, hardened; one-line smoke prompts and a bounded manuscript-delivery experiment through Claude Code and Codex are allowed (§11.6); two-column reading-order repair is cut; reference lookup is reduced to OpenAlex and Crossref; `referee-cli` is trimmed; work is organised with two review gates (§11).

---

## 1. Product definition

### 1.1 The reviewer's workflow

1. **Open the manuscript.** File ▸ Open, drag a PDF onto the window or Dock icon, or "Open With ▸ Referee" in Finder. The app reads the file once into memory, never writes to it, and restores any earlier review of the same file (matched by SHA-256 of its bytes, so renaming or moving the PDF does not lose the review).
2. **Local analysis, instant, offline.** Text extraction, removal of margin line numbers and watermarks from the text stream, reference-list parsing, citation detection. Nothing leaves the machine.
3. **Choose where the text goes.** A toolbar indicator always shows the destination ("Local · gemma4:e4b", "Anthropic API · <model>", "Claude Code (subscription)"). The first time a non-local provider would receive this manuscript, the app asks for confirmation and states what will be sent (PDF file or extracted text, how many requests, to which host).
4. **Run the review (⌘R).** The model reads the paper against the rubric and writes comments. Each comment appears in the sidebar while it is being written, then snaps to its quoted passage, which is highlighted in the PDF.
5. **Triage from the keyboard.** J/K move between comments and scroll the PDF to each passage; A approves, R rejects, D opens a discussion with the model about that comment, E edits it, N adds the reviewer's own comment (anchored to the current selection if there is one).
6. **Discuss.** In a comment's thread the reviewer argues with the model. The model may propose a revised comment or propose withdrawing it; the reviewer accepts or discards the proposal.
7. **Ask about a passage.** Select text in the PDF; a small bar offers Ask AI, Comment, Copy and preset questions ("Check this step", "Is this claim supported?"). Answers stream into the Chat tab and can be turned into a comment.
8. **Follow citations.** Click an in-text citation, numeric ("[12]", "[3–5]") or author–year ("Smith and Jones (2019)", "(Smith et al., 2020; Lee, 2021)"). A card shows the reference entry and resolved metadata; "Open PDF" opens an open-access copy in an in-app viewer window, otherwise "Open in Browser" goes to the DOI or publisher page, and "Search Google Scholar" always works.
9. **Generate the report (⇧⌘R).** From approved comments and the reviewer's own comments the model drafts the referee report: summary assessment, recommendation, publication probability, major concerns, minor concerns, questions for the authors, written to read as a human referee wrote it. A local checker flags AI-sounding words and patterns.
10. **Edit and export.** Edit the Markdown, then copy as plain text (for a journal web form) or export `.md`, `.txt`, `.docx`, `.pdf`.
11. Everything is autosaved. Closing and reopening the PDF restores comments, threads, questions and the report.

### 1.2 User stories (v1 scope)

| # | As a referee I can… | Section |
|---|---|---|
| U1 | open a PDF and read it with thumbnails, outline, search and zoom | §7 |
| U2 | see AI comments appear live, each tied to a highlighted passage | §6, §9 |
| U3 | approve, reject and edit comments with single keys, and filter them by status and kind | §9.3, §9.4 |
| U4 | discuss a comment and accept a revised version proposed by the AI | §6.8 |
| U5 | add my own comments, anchored to a selection or free-standing | §9.3 |
| U6 | select text and ask the AI about it, with the paper as context | §6.9 |
| U7 | click a citation and open the cited paper | §8 |
| U8 | generate, edit and export a referee report in my rubric and voice | §6.10 |
| U9 | choose any of five vendors, by API key or subscription CLI, and pick the model from a live list | §5 |
| U10 | keep a confidential manuscript on my machine (Ollama) and always see where text is going | §9.7, §12 |
| U11 | edit the rubric, prompts and report template | §9.6, Appendix B |
| U12 | review PDFs as journal systems send them: no links, line numbers on the text lines or a ruler of numbers down the margin, "Page N of M" headers, footers, watermarks, double spacing; and cite "page 3, line 14" as the journal's own numbering shows it | §6.7, §7.2, §8 |

### 1.3 Non-goals for v1

- OCR. A scanned PDF with no text layer opens and can be sent natively to providers that accept PDFs, but comments anchor to pages only. The app says so.
- Reading order on multi-column pages. Such a PDF opens and can be reviewed, but the extracted text follows PDFKit's order, which is wrong on some two-column pages [V]: a quote that crosses a column break anchors to its page only. The user's field is single-column. One two-column fixture is kept as a smoke test.
- PDFs that need a password to open. (A PDF with an owner password and copying disabled, which the reviewer names as a common journal-system case, opens normally and its text is readable [V].)
- Writing annotations into the PDF, or any modification of the user's file.
- Web search or literature search by the model. "Missing literature" comments come from the model's own knowledge and are labelled "verify".
- Gemini CLI (`gemini`), Vertex AI, Amazon Bedrock, Azure, OpenRouter or other gateways.
- Multi-turn provider sessions, tool use, or agentic behaviour. Every request is one prompt in, text out.
- Sync, collaboration, iOS, localisation, auto-update, App Store sandboxing, notarisation.
- Superscript numeric citations without link annotations (Nature style); they work only when the PDF has links.
- A Zotero/BibTeX integration; reviewing several manuscripts in one window; comparing revisions of a manuscript.
- A general undo stack. Decisions are reversible with U, edits and accepted revisions keep the previous versions, and reports keep ten versions.
- A separate "pre-submission coaching" mode for the user's own drafts. The reviewer's notes field is passed to every prompt and can carry such an instruction.

---

## 2. Architecture

### 2.1 Targets and dependency graph

One SwiftPM package, zero third-party dependencies. Reason: everything needed is in Foundation, AppKit, SwiftUI, PDFKit, Security and CryptoKit; no dependency fetch means builds work offline and agents never contend on package resolution.

| Target | Kind | Imports | Responsibility |
|---|---|---|---|
| `RefereeCore` | library | Foundation, CoreGraphics, os | All shared value types, protocols and error types (Appendix A); default settings and prompts; `LineSplitter`, `Log`, `ProviderRegistry`. No behaviour beyond trivial helpers. |
| `TestSupport` | library | RefereeCore, CryptoKit | `MockLLMProvider`, in-memory stores, `StubURLProtocol`, fixture locator, simple fakes of every protocol. Used by tests, the snapshot mode and `referee-cli --provider mock`. CryptoKit gives `makeSamplePaper` the real SHA-256 of its PDF. |
| `PaperText` | library | RefereeCore | Pure text algorithms: line classification, margin line-number removal, quote matching, LLM-facing rendering, chunking. No PDFKit. |
| `PDFBridge` | library | RefereeCore, PDFKit, CryptoKit | Everything that touches PDFKit outside the UI: loading, raw extraction, geometry for spans, link annotations, outline. |
| `CitationKit` | library | RefereeCore | Pure: reference-list segmentation and parsing, in-text citation detection, link-target matching. |
| `LLMKit` | library | RefereeCore, Security | HTTP providers (Anthropic, OpenAI, xAI, Gemini, Ollama), SSE/NDJSON parsing, retry, model listing, Keychain secret store. |
| `CLIProviders` | library | RefereeCore, CoreGraphics, ImageIO | Subscription providers that drive vendor CLIs (Claude Code, Codex, Antigravity, Grok Build): binary resolution, process runner, per-CLI adapters with tripwires, page images for one delivery mode. |
| `ReviewEngine` | library | RefereeCore | Prompt assembly, streaming comment parser, chunk planning, review / discussion / question / report orchestration, report lint. |
| `ScholarKit` | library | RefereeCore | Reference resolution (OpenAlex, Crossref), rate limiting, per-document lookup cache, PDF download. |
| `Persistence` | library | RefereeCore | Session and settings files, paths. |
| `Composition` | library | all libraries above | The one place that constructs real implementations: `LiveDependencies.make()`, including the HTTP session and the snapshot-mode stand-ins. |
| `AppCore` | library | RefereeCore, AppKit (for export only), Observation | `ReviewSessionModel`, `SettingsModel`, selection normalisation, report export. Depends on protocols only. No SwiftUI, no PDFKit. |
| `RefereeUI` | library | AppCore, RefereeCore, PDFBridge, TestSupport (snapshot mode only), SwiftUI, AppKit, PDFKit, CryptoKit and ImageIO (snapshot runner) | Views, window management, menus, snapshot mode. |
| `Referee` | executable | RefereeUI, Composition | `main.swift`: one call to `AppMain.run` (§9.1). |
| `referee-cli` | executable | Composition, RefereeCore, PDFBridge, PaperText | Command-line entry point to the same pipeline (§10.2); it calls `RawExtractor` and `PaperRenderer` directly, hence the two extra dependencies. |

```
RefereeCore ◄── TestSupport
     ▲
     ├── PaperText ─────┐
     ├── PDFBridge ─────┤
     ├── CitationKit ───┤
     ├── LLMKit ────────┤
     ├── CLIProviders ──┼──► Composition ──► Referee (app)   referee-cli
     ├── ReviewEngine ──┤          ▲
     ├── ScholarKit ────┤          │
     ├── Persistence ───┘          │
     └── AppCore ──► RefereeUI ────┘
```

Rules that keep the graph this shape:

- Implementation libraries (`PaperText` … `Persistence`) import **only** `RefereeCore`. They never import each other. They meet through protocols in `RefereeCore`, wired in `Composition`. This is what lets nine agents build them at once.
- `AppCore` never names a concrete implementation type.
- Only `PDFBridge`, `RefereeUI` and `referee-cli` (for `dump-raw`) import PDFKit. Only `LLMKit` imports Security. Only `RefereeUI` imports SwiftUI.

### 2.2 Data flow

```
PDF file ──read once──► Data ──► PDFBridge.PDFPaperService (actor, private PDFDocument)
                          │           │ raw pages, lines, links
                          │           ▼
                          │      PaperText.PaperTextBuilder ──► PaperText (lines classified, margin numbers stripped)
                          │           │                               │
                          │           ▼                               ▼
                          │   CitationKit.CitationIndexer      PaperText.QuoteMatcher / PaperRenderer
                          │           │                               │
                          ▼           ▼                               ▼
                 RefereeUI PDFView   CitationIndex            ReviewEngine ──► LLMProvider.stream()
                 (its own PDFDocument      │                        │               │ text deltas
                  from the same Data)      │                        ▼               ▼
                          ▲                │               CommentStreamParser ──► ReviewEvent stream
                          │                ▼                        │
                          └──── AppCore.ReviewSessionModel ◄────────┘
                                 │   (single source of truth per window, @MainActor)
                                 ├──► Persistence.FileSessionStore (debounced autosave)
                                 └──► ScholarKit.ReferenceResolver (on citation click)
```

### 2.3 Concurrency model

- Swift language mode 5 for every target (`swiftLanguageModes: [.v5]`) [V]. Reason: PDFKit and AppKit types are not `Sendable`; strict Swift 6 checking would cost agents time without making this app safer. Conventions below replace it.
- `@MainActor`: `ReviewSessionModel`, `SettingsModel`, every view, every use of `PDFView` and the `PDFDocument` it displays.
- Actors: `PDFPaperService` (owns a second, private `PDFDocument` per open file; PDFKit model calls inside an actor off the main thread work [V]), `ReferenceResolver`, `FileSessionStore`, `FileSettingsStore`.
- Everything crossing a boundary is a `Sendable` value type from Appendix A.
- Long operations return `AsyncThrowingStream`. Streams are cold: work starts when the stream is iterated, and cancelling the consuming `Task` cancels the work (HTTP request, child process).
- `ReviewSessionModel` runs at most one job in each of two lanes: the **review lane** (review, report, voice revision) and the **reply lane** (discussion, question). A reviewer can discuss an early comment while the review or the report is still streaming; the two lanes stream into separate properties (`streamingReportText`, `streamingReplyText`).
- No Combine, no `DispatchQueue` in new code except where an AppKit API requires it, no detached tasks that outlive their owner.

### 2.4 State management

One `ReviewSessionModel` per open manuscript window, `@Observable`. Views read its properties and call its methods; they hold no review state of their own beyond transient UI state (text being typed, hover). Engine events are applied on the main actor in arrival order. Every mutation of `session` schedules an autosave (1 s debounce) and bumps `updatedAt`. The model drives the PDF view through a serial-numbered `readerCommand` property and hears back through its `reader…` methods (Appendix A.9), so it never references PDFKit. Find and zoom do not pass through the model: the menu calls `ReaderController` (§7.4).

### 2.5 Error handling

- Every thrown error is a type conforming to `RefereeError` (`userMessage`, `recoverySuggestion`, `isRetryable`). Providers throw only `LLMError`; the paper layer `PaperError`; stores `StoreError`; secret stores `SecretError`; the resolver returns status values and throws `ResolverError` only from `fetchPDF`.
- Engines never throw away partial work: comments parsed before a failure stay; the run is recorded as failed with the error's `userMessage`.
- The model output is untrusted input. No parser may crash or loop on any byte sequence; all parsers have tests that feed them garbage.
- The UI shows failures as a non-modal banner with at most one action (Retry, Open Settings). Nothing in v1 presents a modal alert except destructive confirmations.
- `fatalError`, `try!` and force-unwraps are allowed only in tests and for programmer errors on literals (for example a regex literal).

---

## 3. Toolchain & build

This is the only section that depends on the toolchain. Nothing else in the plan changes if it moves.

### 3.1 Facts

- Command Line Tools 26.6: Swift 6.3.3, macOS 26.5 SDK. No Xcode, no `xcodebuild`, no XCTest [V].
- A manifest with `// swift-tools-version:6.2`, `platforms: [.macOS(.v26)]`, `swiftLanguageModes: [.v5]` builds with plain `swift build`; a SwiftUI + PDFKit + `@Observable` executable builds and runs [V].
- Tests: Swift Testing (`import Testing`, `@Test`, `#expect`, `@Suite`). Plain `swift test` fails under Command Line Tools with "no such module 'Testing'". It passes with extra flags **on the command line** [V]. Putting the flags in `Package.swift` as `unsafeFlags` builds but then runs zero tests and exits 0 [V, coordinator]; therefore **the flags must never go in the manifest**.
- Under a full Xcode (`xcode-select -p` not ending in `CommandLineTools`) Swift Testing needs no extra flags; `scripts/test.sh` detects this and passes none. That is the only toolchain variation the project supports; there is no fallback to the old Swift 5.10 toolchain and no custom test runner.
- `scripts/test.sh` below was run against a real package: all tests pass → exit 0; a failing `#expect` → exit 1; a `--filter` that matches nothing → exit 3; `--filter <TestTargetName>` runs exactly that target's tests [V].
- A test function marked `@Test @MainActor` runs on the main thread, and AppKit text layout and `NSPrintOperation` work there with no `NSApplication` running; an unmarked `@Test` runs off the main thread [V]. Every test that touches AppKit or a `@MainActor` type is marked `@MainActor`.
- SwiftPM refuses a target that has two source files with the same base name, even in different sub-folders ("multiple producers") [V]. This matters for `RefereeUI`, `AppCore` and their test targets, where several agents add files to sub-folders of one target (rule in §3.7).
- A public memberwise initialiser cannot be added to a struct in an extension of the same module: it collides with the synthesised one ("invalid redeclaration of synthesized initializer") [V]. Appendix A therefore prints every public initialiser inside its struct.
- A hand-assembled `.app` (binary + hand-written `Info.plist`), signed with `codesign --force -s -`, verifies and runs; from inside such a bundle `http://127.0.0.1:11434` is reachable without any App Transport Security exception [V].
- Known machine defect, now fixed: an in-place Command Line Tools update left `*.private.swiftinterface` files that broke every manifest. They have been deleted. `scripts/build.sh` prints a hint if they ever reappear.

### 3.2 Package manifest

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Referee",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Referee", targets: ["Referee"]),
        .executable(name: "referee-cli", targets: ["referee-cli"]),
    ],
    targets: [
        .target(name: "RefereeCore"),
        .target(name: "TestSupport", dependencies: ["RefereeCore"]),
        .target(name: "PaperText", dependencies: ["RefereeCore"]),
        .target(name: "PDFBridge", dependencies: ["RefereeCore"]),
        .target(name: "CitationKit", dependencies: ["RefereeCore"]),
        .target(name: "LLMKit", dependencies: ["RefereeCore"]),
        .target(name: "CLIProviders", dependencies: ["RefereeCore"]),
        .target(name: "ReviewEngine", dependencies: ["RefereeCore"]),
        .target(name: "ScholarKit", dependencies: ["RefereeCore"]),
        .target(name: "Persistence", dependencies: ["RefereeCore"]),
        .target(name: "Composition", dependencies: ["RefereeCore", "TestSupport", "PaperText", "PDFBridge", "CitationKit", "LLMKit", "CLIProviders", "ReviewEngine", "ScholarKit", "Persistence"]),
        .target(name: "AppCore", dependencies: ["RefereeCore"]),
        .target(name: "RefereeUI", dependencies: ["RefereeCore", "AppCore", "PDFBridge", "TestSupport"]),
        .executableTarget(name: "Referee", dependencies: ["RefereeUI", "Composition"]),
        .executableTarget(name: "referee-cli", dependencies: ["RefereeCore", "Composition", "PDFBridge", "PaperText"]),

        .testTarget(name: "RefereeCoreTests", dependencies: ["RefereeCore", "TestSupport"]),
        .testTarget(name: "PaperTextTests", dependencies: ["PaperText", "RefereeCore", "TestSupport"]),
        .testTarget(name: "PDFBridgeTests", dependencies: ["PDFBridge", "RefereeCore", "TestSupport"]),
        .testTarget(name: "CitationKitTests", dependencies: ["CitationKit", "RefereeCore", "TestSupport"]),
        .testTarget(name: "LLMKitTests", dependencies: ["LLMKit", "RefereeCore", "TestSupport"]),
        .testTarget(name: "CLIProvidersTests", dependencies: ["CLIProviders", "RefereeCore", "TestSupport"]),
        .testTarget(name: "ReviewEngineTests", dependencies: ["ReviewEngine", "RefereeCore", "TestSupport"], exclude: ["Fixtures"]),
        .testTarget(name: "ScholarKitTests", dependencies: ["ScholarKit", "RefereeCore", "TestSupport"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "RefereeCore", "TestSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "RefereeCore", "TestSupport"]),
        .testTarget(name: "RefereeUITests", dependencies: ["RefereeUI", "RefereeCore", "AppCore", "PDFBridge", "TestSupport"]),
        .testTarget(name: "IntegrationTests", dependencies: ["Composition", "RefereeCore", "AppCore", "TestSupport", "PaperText", "PDFBridge", "CitationKit", "LLMKit", "CLIProviders", "ReviewEngine", "ScholarKit", "Persistence"]),
    ],
    swiftLanguageModes: [.v5]
)
```

Manifest rules: no `resources:` anywhere (reason: `Bundle.module` does not resolve inside a hand-assembled `.app`; prompts and templates are Swift string literals, tests find fixtures by path, see §3.6); no `unsafeFlags`; no dependencies; a test target that keeps data files in `Tests/<Target>Tests/Fixtures/` lists `exclude: ["Fixtures"]`, and only such a target (today `ReviewEngineTests`; rule in §3.7). A target imports only modules it declares: an undeclared transitive `import` happens to compile on this toolchain [V, reviewer] and must not be relied on. That is why every test target declares `RefereeCore` (no test can avoid naming the shared types), `RefereeUITests` declares `AppCore` and `PDFBridge`, and `IntegrationTests` declares every library (Appendix G.4). This manifest, with every declaration of §11.3 as a stub, builds from clean [V].

### 3.3 Repository layout

```
Referee/
  Package.swift   Makefile   README.md   plan.md   .gitignore
  scripts/        build.sh  test.sh  run.sh  bundle.sh  snapshots.sh  make-fixtures.sh  make-icon.sh  e2e-ollama.sh  fetch-optional-fixtures.sh
  docs/           plan-review.md   contract-notes/<WP>.md      (notes for the integrator)
  Fixtures/
    tex/          LaTeX sources of the synthetic manuscripts (Appendix C)
    pdf/          the generated PDFs, committed
    raw/          <name>.raw.json: RawDocument dumps of each PDF, committed (PDFKit-free tests read these)
    sessions/     sample ReviewSession JSON for snapshots
    llm/          model outputs for parser tests and the mock provider
    private/      git-ignored; real PDFs: public papers fetched by scripts/fetch-optional-fixtures.sh, and any journal-system PDFs the user adds
  Sources/<Target>/…
  Tests/<Target>Tests/…          (a test target may keep its own data files under Tests/<Target>Tests/Fixtures/, excluded in the manifest: §3.7)
  build/          git-ignored output: Referee.app, snapshots, icon
```

`.gitignore`: `.build/`, `build/`, `Fixtures/private/`, `*.local.json`, `.env`, `.DS_Store`, `*.xcuserstate`, `.swiftpm/`, `__pycache__/`.

### 3.4 Commands (the only ones agents and the user run)

| Purpose | Command |
|---|---|
| Build everything (debug) | `scripts/build.sh` |
| Build one product | `scripts/build.sh --product referee-cli` |
| Run all tests | `scripts/test.sh` |
| Run one test target | `scripts/test.sh --filter PaperTextTests` |
| Run the app unbundled | `scripts/run.sh [app arguments]` |
| Assemble and sign the app | `scripts/bundle.sh` → `build/Referee.app`; then `open build/Referee.app` |
| Render UI snapshots | `scripts/snapshots.sh [--out dir] [--scene name]…` |
| Real local-LLM end-to-end | `scripts/e2e-ollama.sh [model]` |
| Regenerate fixture PDFs | `scripts/make-fixtures.sh` (needs MacTeX) |
| Fetch optional real papers | `scripts/fetch-optional-fixtures.sh` (network; public arXiv PDFs into `Fixtures/private/`) |

Never run bare `swift test`. Never put results of `swift build` anywhere but the default `.build` of your own checkout.

`scripts/build.sh`

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
STALE=(/Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface)
if [[ -e "${STALE[0]}" ]]; then
  echo "build.sh: stale SwiftPM interface files from an old Command Line Tools install will break every Package.swift. Remove them:" >&2
  echo "  sudo rm /Library/Developer/CommandLineTools/usr/lib/swift/pm/{ManifestAPI/PackageDescription,PluginAPI/PackagePlugin}.swiftmodule/*.private.swiftinterface" >&2
fi
exec swift build "$@"
```

`scripts/test.sh` (verified as written [V])

```bash
#!/bin/bash
# The ONLY supported way to run tests. Usage: scripts/test.sh [extra `swift test` arguments, e.g. --filter PaperTextTests]
# - adds the Swift Testing search paths when the active developer directory is the Command Line Tools (no Xcode)
# - fails if zero tests ran, so a mistyped --filter or a mis-built runner can never look green
set -uo pipefail
cd "$(dirname "$0")/.."
FLAGS=()
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  FW="$DEV_DIR/Library/Developer/Frameworks"
  FLAGS=(-Xswiftc -F -Xswiftc "$FW"
         -Xswiftc -plugin-path -Xswiftc "$DEV_DIR/usr/lib/swift/host/plugins/testing"
         -Xlinker -F -Xlinker "$FW"
         -Xlinker -rpath -Xlinker "$FW"
         -Xlinker -rpath -Xlinker "$DEV_DIR/Library/Developer/usr/lib")
fi
LOG="$(mktemp -t referee-test)"
trap 'rm -f "$LOG"' EXIT
swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
RAN="$(grep -Eo 'Test run with [0-9]+ tests?' "$LOG" | tail -1 | grep -Eo '[0-9]+' || true)"
if [[ "$STATUS" -ne 0 ]]; then echo "test.sh: FAILED (swift test exit $STATUS)" >&2; exit "$STATUS"; fi
if [[ -z "$RAN" || "$RAN" -lt 1 ]]; then echo "test.sh: FAILED (zero tests ran; check the --filter and the Swift Testing flags)" >&2; exit 3; fi
echo "test.sh: OK ($RAN tests)"
```

`scripts/run.sh`

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh --product Referee
exec "$(swift build --show-bin-path)/Referee" "$@"
```

`scripts/bundle.sh`

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${REFEREE_VERSION:-0.1.0}"
scripts/build.sh -c release --product Referee
BIN="$(swift build -c release --show-bin-path)/Referee"
APP="build/Referee.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Referee"
[[ -f build/AppIcon.icns ]] || scripts/make-icon.sh || echo "bundle.sh: no icon (continuing)"
[[ -f build/AppIcon.icns ]] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.referee.app</string>
  <key>CFBundleName</key><string>Referee</string>
  <key>CFBundleDisplayName</key><string>Referee</string>
  <key>CFBundleExecutable</key><string>Referee</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>PDF Document</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
  </dict></array>
</dict></plist>
EOF
plutil -lint "$APP/Contents/Info.plist"
if strings -a "$APP/Contents/MacOS/Referee" | grep -q "$HOME/"; then
  echo "bundle.sh: the binary contains a path under your home directory (a #filePath or #file in a release build?). Remove it before the app is shared." >&2
  exit 1
fi
codesign --force --sign "${REFEREE_SIGN_IDENTITY:--}" "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $APP"
```

`scripts/make-icon.sh` renders a 1024-pixel PNG with a small Swift script run through `swift -` (CoreGraphics: a rounded square and a serif "R"), resizes it with `sips` into `build/AppIcon.iconset/` at the ten standard sizes and runs `iconutil -c icns`. The bundle works without it.

`scripts/snapshots.sh` (verified as written: `--scene x` alone no longer becomes the output directory [V])

```bash
#!/bin/bash
# Usage: scripts/snapshots.sh [--out <dir>] [--scene <name>]... [--dark] [--size WxH]     (default output: build/snapshots)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="build/snapshots"; ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
scripts/build.sh --product Referee
mkdir -p "$OUT"
"$(swift build --show-bin-path)/Referee" --ui-snapshot "$OUT" ${ARGS[@]+"${ARGS[@]}"}
ls -1 "$OUT"/*.png
```

`Makefile`: phony targets `build`, `test`, `run`, `app`, `snapshots`, `e2e`, `fixtures` that call the scripts with no extra logic.

### 3.5 Test strategy

| Layer | What | How |
|---|---|---|
| Unit | pure algorithms, parsers, request builders, stores, view-model logic | Swift Testing in `Tests/<Target>Tests`, fakes from `TestSupport`, fixture files |
| Provider streams | every provider's stream format and error mapping | recorded bodies (Appendix D) served by `StubURLProtocol`; fake CLI shell scripts for the CLI providers |
| Integration | real PDF → extraction → clean text → anchoring → citations; review pipeline with the mock provider | `Tests/IntegrationTests`, real implementations from `Composition` (Gate 1, §11.4) |
| Live local | Ollama end to end | `scripts/e2e-ollama.sh`; tests tagged live are skipped unless `http://127.0.0.1:11434/api/version` answers |
| Live remote | real vendor APIs | never in the default run; enabled per provider by `REFEREE_KEY_<PROVIDER>` in the environment |
| Live CLI | one-line smoke prompt through each installed, signed-in subscription CLI | only with `REFEREE_CLI_SMOKE=1`, and only at the two moments §11.6 names |
| UI | what the screen looks like, and three behaviours (document loads, citation click, triage keys) | `--ui-snapshot` PNGs that the agent opens and inspects, and scenes with a `verify` step (§10.1); pure UI helpers unit-tested |

Rules: tests never read or write the user's Keychain item, `~/Library/Application Support/Referee`, or real CLIs' state; they set `REFEREE_HOME` to a temporary directory. The default test run never sends a prompt to a subscription CLI or a paid API; §11.6 lists the only real prompts allowed in this project and who may send them. No prompt ever contains a file of the user's. A test that needs something absent (Ollama, a key, an optional fixture) must skip visibly (`try #require` on a condition with a clear comment, or `.enabled(if:)`), not pass silently.

### 3.6 Fixtures

- **Synthetic manuscripts** are written in LaTeX (`Fixtures/tex`, sources in Appendix C), compiled with `pdflatex`, and the PDFs are committed so tests never need TeX. `scripts/make-fixtures.sh` produces all seven on this machine in about five seconds [V]. They contain invented text and invented or public references only; no real manuscript and no personal name of the user may ever be added to `Fixtures/` outside `private/`. A rebuilt PDF differs in a few bytes from the previous build (timestamps), so nothing may depend on a fixture's hash (§10.1).

| File | Pages | What it exercises |
|---|---|---|
| `ay_nolinks.pdf` | 4 | The `lineno` journal case: line numbers 1–54 on the text lines, double spacing, a diagonal "CONFIDENTIAL" watermark, author–year citations in square brackets, **no link annotations**. Also: a displayed fraction, a table, sentence-initial citations ("In Banerjee [1992]", "The Avery and Zemsky [1998] model", "See Lee [2021]", "Following Smith and Sørensen [2000]"), a book entry that wraps to the line "A Course in Game Theory. MIT Press.", and a Springer-style entry whose second line is "J Polit Econ 108(1):34–55". |
| `s1_ruler.pdf` | 4 | The ScholarOne-style journal case, same text: a ruler of the numbers 1–60 down the left margin of every page at a fixed 12 pt spacing, unrelated to the text baselines and restarting on each page; a "Page N of 4" header beside a journal name; a footer line that is a URL; a diagonal "For Peer Review" watermark; round-bracket citations; no links. |
| `ay_round_nolinks.pdf` | 4 | Same text with no journal stamps: round brackets and semicolons ("(Avery and Zemsky, 1998; Smith and Sørensen, 2000)"), citations and surnames broken across lines. The economics working-paper case, and the default document for engine tests. |
| `ay_links.pdf` | 4 | Same text with hyperref: 36 internal links, of which 34 are citation pieces (author and year linked separately, links split at line breaks) and 2 point at the table and the equation [V]. |
| `num_links.pdf` | 4 | Single column, numeric citations with hyperref: 10 internal citation links and 2 URL links for one DOI that is broken across two lines [V]. |
| `num_twocol_links.pdf` | 2 | Two columns, numeric, hyperref (12 links). Smoke test only: PDFKit emits page 2 as top of the left column, the whole right column, then the rest of the left column [V]. |
| `scanned.pdf` | 1 | Image only, zero characters [V]. Built by `sips -s format png` then `sips -s format pdf`. |

What PDFKit actually returns for these files is part of the specification; the samples in §6.7 and §7.2 are copied from its output.

- **Raw dumps.** `referee-cli dump-raw <pdf>` prints the `RawDocument` JSON; `scripts/make-fixtures.sh` writes one per PDF into `Fixtures/raw`. The pure libraries test against these.
- **Fixture access.** `TestSupport.Fixtures` (§11.3) resolves the repository root in this order: the environment variable `REFEREE_REPO_ROOT` when set; in debug builds (`#if DEBUG`), from `#filePath` of its own source file; in release builds, the current directory. No `Bundle.module`. Reason for the split: `TestSupport` is linked into the app, and a `#filePath` in a release build would put the build machine's home-directory path into the bundled binary; `scripts/bundle.sh` fails if it finds one. Fixtures are only needed by a release binary in snapshot mode, which is run from the repository root.
- **Real papers.** `scripts/fetch-optional-fixtures.sh` downloads three public arXiv PDFs into `Fixtures/private/` (git-ignored; one request every three seconds, as arXiv's terms ask). Tests that use them skip when absent. They matter: running the prototypes on one real 15-page paper exposed three errors that the synthetic files did not (§8.2). Journal-system PDFs the user supplies go in the same folder (Q7).
- **Model outputs and provider streams** are text files (Appendix D and `Fixtures/llm`).

### 3.7 Conventions for all code

- Four-space indentation, one type per file where practical, `public` only for what another target uses.
- **File names are unique within a target** (§3.1). In `Sources/RefereeUI/<Area>/` and `Tests/RefereeUITests/<Area>/` every file name starts with its area: `Reader…`, `Sidebar…`, `Shell…`, `Common…`. In `Sources/AppCore/Export/` and `Tests/AppCoreTests/Export/` every file name starts with `Export`.
- Every public struct in `RefereeCore` has the explicit public memberwise initialiser printed in Appendix A (parameters in declaration order, optionals default to `nil`, collections to empty).
- No `print` in libraries; use `Log.event`. `referee-cli` and tests may print.
- No file outside your owned paths may be edited (§11.2).
- Dates are encoded ISO 8601 in whole seconds (`JSONEncoder.DateEncodingStrategy.iso8601`); JSON written to disk uses `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`. A value read back from a file therefore equals the saved one except that its dates are cut to the second; nothing compares a reloaded session with the unsaved one by `==` (tests compare after a round trip, or use whole-second dates).
- UTF-16 offsets into `PDFPage.string` are the only text coordinates (`TextRange`); never store `String.Index` or grapheme offsets.
- **`TextRange` needs one alias per module.** `import Foundation` also brings the Apple Events C struct `TextRange` (CoreServices), so outside `RefereeCore` the bare name is "ambiguous for type lookup" in a type annotation (an initialiser call such as `TextRange(location:length:)` still resolves). Every module that names the type, library or test target, has exactly one file with `typealias TextRange = RefereeCore.TextRange` (internal); a declaration in the module shadows both imports, and also an alias that `@testable import` brings in. The file is `TextRangeAlias.swift`, in `RefereeUI` and `RefereeUITests` `Common/CommonTextRangeAlias.swift` (Gate 1 wrote them all); a second alias in the same module is a redeclaration error, so Wave 2 adds none. A public declaration cannot use an internal alias: write `RefereeCore.TextRange` there. Qualified uses elsewhere may stay.
- **Test data.** A test target keeps its data either as Swift string literals in ordinary source files, or as data files in `Tests/<Target>Tests/Fixtures/`, which the manifest then excludes (`exclude: ["Fixtures"]`, §3.2) and which holds no Swift file; tests find those files by path from `Fixtures.root`. A data file anywhere else in a target's folder, or in a target without that exclusion, makes SwiftPM warn "found N file(s) which are unhandled", which the acceptance of every package forbids. Hidden files and folders are not used to get round the warning. Today `ReviewEngineTests` has data files; `LLMKitTests`, `CLIProvidersTests` and `ScholarKitTests` keep theirs as literals. A Wave 2 test target uses literals, since the manifest is frozen for Wave 2.

---

## 4. Data model & persistence

### 4.1 Types

All types are in Appendix A (they compile as printed [V]). The ones that are persisted:

| Type | Meaning |
|---|---|
| `ReviewSession` | Everything about the review of one PDF: comments, question threads, report, audit trail of runs, consents. One per document. |
| `DocumentRef` | Identity of the PDF: SHA-256 of its bytes (the key), file name, last known path, size, page count. |
| `ReviewComment` | One referee comment: `origin` (AI run or user), `status` (pending / approved / rejected), `kind` (major / minor / question / strength), `category` (rubric slug), title, body, optional suggestion, `anchor`, discussion `thread`, optional `proposedRevision`, `previousVersions`, `includeInReport`, optional `similarTo` (an earlier comment on the same passage). |
| `Anchor` | Where a comment or question points: the quote, `spans` (page + UTF-16 range in `PDFPage.string`, one per text line touched), cached highlight `rects` in page space, confidence (`exact`, `fuzzy(score)`, `pageOnly`, `none`), display label ("p. 4, lines 14–16"). |
| `Conversation` | A question thread started from a selection (or about the whole paper). |
| `ReportDraft` | Markdown text, parsed recommendation, provenance, up to ten earlier versions. |
| `RunRecord` | Audit entry for each time content was sent to a model: provider, model, destination host or CLI, whether the PDF file itself was sent, request count, token usage, outcome. |
| `AppSettings` | Providers, defaults, prompts, rubric, privacy, reference lookup, UI. Separate file; no secrets. |

### 4.2 Where things are stored, and why

```
~/Library/Application Support/Referee/        (or $REFEREE_HOME when set: tests, CLI, snapshots)
    settings.json
    sessions/<sha256>/session.json
    sessions/<sha256>/session.json.bak        previous good version
    sessions/<sha256>/references.json         reference lookups made for this manuscript (written by ScholarKit)
~/Library/Caches/Referee/papers/<sha256(url)>.pdf     downloaded open-access PDFs (LRU, default cap 500 MB)
Keychain: one generic-password item, service "local.referee.app", account "secrets-v1"
```

- Keyed by content hash, in Application Support, not beside the PDF. Reasons: manuscripts arrive in Downloads and get moved or renamed; a sidecar file would be lost or left behind; and one private folder per review is easy to wipe when the review is finished.
- Everything derived from one manuscript lives in its folder, including the reference lookups, whose keys are the manuscript's reference strings. "Delete Review Data…" (`ReviewSessionModel.deleteReviewData()`) removes the folder and tells the resolver to forget that document, so nothing about a finished review outlives it.
- The list of past reviews is built by scanning `sessions/*/session.json` (`SessionStoring.listSessions`); there is no separate index to go stale.
- The PDF is never copied into the store. If the file has moved, the app asks for it and verifies the hash.

### 4.3 `session.json`

Encoded with `JSONEncoder` (ISO-8601 dates; `prettyPrinted`, `sortedKeys`, `withoutEscapingSlashes`). Enums with associated values use Swift's synthesised encoding: `{"exact":{}}`, `{"fuzzy":{"score":0.82}}`, `{"ai":{"runID":"…"}}`, `{"failed":{"_0":"message"}}`. Optionals that are `nil` are omitted. Real output of the types in Appendix A, reformatted for width [V]:

```json
{
  "comments" : [
    {
      "anchor" : {
        "confidence" : { "exact" : { } },
        "locationLabel" : "p. 1, lines 13–14",
        "pageIndex" : 0,
        "quote" : "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one",
        "rects" : [
          { "height" : 10.6, "pageIndex" : 0, "width" : 111, "x" : 384.2, "y" : 189.2 },
          { "height" : 10.6, "pageIndex" : 0, "width" : 281, "x" : 110.9, "y" : 165.2 }
        ],
        "spans" : [ { "pageIndex" : 0, "range" : { "length" : 18, "location" : 676 } },
                    { "pageIndex" : 0, "range" : { "length" : 59, "location" : 697 } } ]
      },
      "body" : "The text calls the effect robust, but Table 2 reports 0.91 with an interval that crosses one.",
      "category" : "claims",
      "createdAt" : "2026-11-18T11:06:40Z",
      "id" : "22222222-2222-4222-8222-222222222222",
      "includeInReport" : true,
      "kind" : "major",
      "origin" : { "ai" : { "runID" : "11111111-1111-4111-8111-111111111111" } },
      "previousVersions" : [ ],
      "proposedRevision" : { "body" : "…", "kind" : "minor", "title" : "State the interval", "withdraw" : false },
      "status" : "approved",
      "suggestion" : "Report the interval in the abstract and drop 'robust'.",
      "thread" : [
        { "createdAt" : "2026-11-18T11:06:40Z", "id" : "33333333-3333-4333-8333-333333333333", "role" : "user",
          "text" : "Is the interval in the text or only in the table?" }
      ],
      "title" : "Confidence interval includes one",
      "updatedAt" : "2026-11-18T11:06:40Z"
    }
  ],
  "consents" : [ { "grantedAt" : "2026-11-18T11:06:40Z", "providerID" : "anthropic-api" } ],
  "conversations" : [ ],
  "createdAt" : "2026-11-18T11:06:40Z",
  "document" : { "byteCount" : 183964, "fileName" : "manuscript.pdf", "lastKnownPath" : "/path/to/manuscript.pdf", "pageCount" : 4, "sha256" : "9f2c…" },
  "id" : "55555555-5555-4555-8555-555555555555",
  "meta" : { "reviewerNotes" : "", "title" : "Information Aggregation in Sequential Markets" },
  "runs" : [
    { "destination" : "127.0.0.1:11434", "finishedAt" : "2026-11-18T11:06:40Z", "id" : "11111111-1111-4111-8111-111111111111",
      "kind" : "review", "provider" : { "model" : "gemma4:e4b", "providerID" : "ollama" }, "requestCount" : 1, "sentPDF" : false,
      "startedAt" : "2026-11-18T11:06:40Z", "status" : { "completed" : { } }, "usage" : { "inputTokens" : 21000, "outputTokens" : 1800 } }
  ],
  "schemaVersion" : 1,
  "updatedAt" : "2026-11-18T11:06:40Z"
}
```

The location label uses an en dash (U+2013).

### 4.4 Versioning

- `schemaVersion` is 1. `FileSessionStore.currentSchemaVersion = 1`.
- Loading: read the file as `[String: Any]` and look at `schemaVersion`. Greater than supported → throw `StoreError.newerSchema` (the UI opens the PDF with an empty in-memory session and a banner; it does not overwrite the file). Otherwise decode. There is no migration code in v1 because there is nothing to migrate from.
- A field may be added without a version bump only if it is `Optional` in the Swift type: a file written before the field existed then still decodes [V]. Anything else needs a version bump, and the migration is written then.
- `settings.json` follows the same rule. When a known provider id is missing from `providers`, the store fills in that provider's default settings on load.

### 4.5 Saving

- `ReviewSessionModel` schedules a save 1.0 s after the last mutation; it flushes immediately when the window closes, the app deactivates or terminates, and before any run starts.
- `FileSessionStore.save` writes to `session.json.tmp`, moves the current `session.json` to `session.json.bak`, then renames the temp file into place (`FileManager.replaceItemAt`), all inside the actor.
- A file that fails to decode is renamed to `session.corrupt-<timestamp>.json`; the `.bak` is tried next; a banner reports what happened.

### 4.6 The PDF is never modified

- The file is read once: `Data(contentsOf:options: .mappedIfSafe)`. Both `PDFDocument` instances (the display one and the extraction one) are created with `PDFDocument(data:)`, so they have no `documentURL` and nothing can save back to the path [V].
- No code calls `PDFDocument.write(to:)`, `write(toFile:)` or `dataRepresentation()` on a manuscript. (`PDFBridgeTests` uses `write(to:withOptions:)` on a temporary copy to make an encrypted test file; that is the only call.)
- Highlights are `PDFAnnotation` objects added to the in-memory display document only (§7.3).
- When a provider gets the PDF natively, it gets the original `Data`, never a re-serialised document.
- The check is behavioural: an integration test compares the fixture file's bytes before and after a full open, review and report.

---

## 5. LLM layer

### 5.1 One contract for nine back ends

`LLMProvider` (Appendix A.5): `availability()`, `listModels()`, `stream(LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>`.

An `LLMRequest` is **one system prompt and one user turn**, made of parts (`.text`, `.pdf`, `.cacheBoundary`). There is no message-history API. Discussions and question threads are flattened by the review engine into that single user turn as a transcript. Reasons: four of the nine back ends are CLIs that take one prompt; and replaying assistant turns is where the HTTP APIs differ most and break most easily (Gemini requires resending signed "thought" steps unchanged [D]; Anthropic and OpenAI have their own rules for reasoning blocks). A flat transcript behaves identically everywhere, and the paper stays at the front of the prompt where provider-side prompt caching can reuse it.

The stream yields `.textDelta` any number of times, optional `.status`, then exactly one `.finished(StopReason, Usage?)`. Failures are thrown as `LLMError`, including after some deltas.

### 5.2 Provider roster

| id | Shown as | Auth | Transport | Receives the PDF itself | Stream granularity | Model list | Context window known from |
|---|---|---|---|---|---|---|---|
| `anthropic-api` | Anthropic API | API key | `POST https://api.anthropic.com/v1/messages` | yes | token | `GET /v1/models` | `max_input_tokens` in the model list [D] |
| `openai-api` | OpenAI API | API key | `POST https://api.openai.com/v1/responses` | yes | token | `GET /v1/models` | not exposed [D]; override or 128,000 assumed |
| `gemini-api` | Gemini API | API key | `POST https://generativelanguage.googleapis.com/v1/interactions` | yes | token | `GET /v1/models` | `inputTokenLimit` [D] |
| `xai-api` | xAI API | API key | `POST https://api.x.ai/v1/chat/completions` | no | token | `GET /v1/models` | `context_length` [D] |
| `ollama` | Ollama (local) | none | `POST http://127.0.0.1:11434/api/chat` | no | token | `GET /api/tags` | `details.context_length` [V] |
| `claude-cli` | Claude Code (subscription) | CLI login | `claude -p` | decided by experiment (§5.6.6); until then no | token | fixed aliases + free text | 200,000 assumed, editable |
| `codex-cli` | Codex (ChatGPT plan) | CLI login | `codex exec` | decided by experiment (§5.6.6); until then no | message (§5.6.4) | `codex debug models` [V] | `context_window` from that list [V] |
| `antigravity-cli` | Antigravity (Google AI plan), experimental | CLI login | `agy` print mode | no | token | `agy models` [D] | 200,000 assumed, editable |
| `grok-cli` | Grok Build, experimental | CLI login | `grok agent stdio` | no | token | `grok models` [D] | 200,000 assumed, editable |
| `mock` | Mock | none | in-process | accepts | token | fixed | 1,000,000 |

`isLocal` is true only for `ollama` when its base URL host is `127.0.0.1`, `localhost` or `::1`, and for `mock`. `isExperimental` is true for `antigravity-cli` and `grok-cli`: both adapters are built from documentation, because neither CLI is installed on this machine. Settings shows "Experimental — not yet verified against the real CLI on this machine" on such a row until a test prompt has succeeded there (`ProviderSettings.verifiedAt`, §9.6).

No code branches on a model id. Defaults: for API providers the settings pane fetches the live list and preselects the first entry the vendor returns; the user can change it or type any id. For CLI providers the default is "CLI default" (`model == nil`: no model flag is passed, so the CLI uses whatever the user configured there). Claude Code has no command that lists models, so this is the one provider whose list is not fetched live: it offers the documented aliases `default`, `opus`, `sonnet`, `haiku`, `fable` [D] (aliases, not version ids; the CLI resolves them) plus free text.

### 5.3 Shared HTTP machinery (`LLMKit`)

```swift
struct HTTPFailure: Error { let status: Int; let headers: [String: String]; let body: Data }   // non-2xx response

struct HTTPStreamClient {
    let session: URLSession
    /// Sends the request; on 2xx yields each line of the body (empty lines included); otherwise throws HTTPFailure
    /// carrying at most 64 KB of body. Translates URLError into LLMError.network / .cancelled.
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error>
    func json(for request: URLRequest) async throws -> Data           // non-streaming calls (model lists)
}

protocol HTTPProviderAdapter {                // one small type per vendor
    func makeRequest(_ request: LLMRequest, settings: ProviderSettings, secret: String?) throws -> URLRequest
    func parse(line: String, state: inout StreamState) throws -> [LLMEvent]   // may throw LLMError for in-stream errors
    func mapFailure(_ failure: HTTPFailure) -> LLMError
    func finish(state: StreamState) throws -> [LLMEvent]                      // called at end of body
}
```

- Lines come from `URLSession.bytes(for:)` through `LineSplitter`. `AsyncBytes.lines` is not used: it drops empty lines [V].
- **SSE rule (all four SSE vendors):** process each line on its own. A line starting with `data:` carries one complete JSON object (strip the prefix and one optional space); `data: [DONE]` ends the stream; lines starting with `event:`, `id:`, `:` and empty lines are ignored. The event kind is read from the JSON (`type` or `event_type`), never from the `event:` line. This works for Anthropic, OpenAI and Gemini (named events) and for xAI (data-only events [D]).
- **End of body without the vendor's terminal event** → throw `LLMError.malformedResponse("stream ended early")` after the deltas already yielded.
- **Timeouts, in two places.** A model can be silent for minutes before its first byte: `phi4` on this machine sent its first byte 95.5 s after a seven-page request, and a default `URLSession` gave up at 61 s with `NSURLErrorTimedOut` [V, reviewer]. (1) The one `URLSession` every provider uses is built by `Composition.LiveDependencies.makeURLSession()`: `URLSessionConfiguration.ephemeral` with `timeoutIntervalForRequest = 600` (the longest tolerated silence between bytes), `timeoutIntervalForResource = 3600`, `waitsForConnectivity = false`, `httpCookieStorage = nil`, `urlCache = nil`, `httpShouldSetCookies = false`. (2) Every adapter also sets `URLRequest.timeoutInterval = 600` on each streaming request and 30 on model-list requests, so that a provider behaves the same when a test injects `StubURLProtocol.session()` through `ProviderEnvironment.urlSession`.
- `ProviderSettings.extraBodyJSON`, when it parses as a JSON object, is merged into the request body last (top-level keys overwrite). This is the escape hatch for vendor knobs the app does not model (reasoning effort, service tier, Ollama's `think`), so API drift does not require a release.
- `ProviderSettings.baseURL` replaces the scheme/host/port part of the endpoint for any HTTP provider.
- Request bodies are never logged. `Log.event("llm.request", ["provider": .id(id), "bytes": .int(n), "pdf": .bool(b)])` is the whole record.

### 5.4 HTTP providers

#### 5.4.1 Anthropic — Messages API [D]

```
POST https://api.anthropic.com/v1/messages
x-api-key: <key>      anthropic-version: 2026-10-21      content-type: application/json

{ "model": "<id>", "max_tokens": <n>, "stream": true,
  "system": [ { "type": "text", "text": "<system>" } ],
  "messages": [ { "role": "user", "content": [
      { "type": "document", "source": { "type": "base64", "media_type": "application/pdf", "data": "<base64, no newlines>" },
        "cache_control": { "type": "ephemeral" } },
      { "type": "text", "text": "<task>" } ] } ] }
```

- Parts map in order: `.pdf` → `document` block; `.text` → `text` block; `.cacheBoundary` → add `"cache_control": {"type":"ephemeral"}` to the block before it (at most one boundary per request is honoured).
- `max_tokens` is required: `request.maxOutputTokens ?? min(model.maxOutputTokens ?? 16_000, 32_000)`.
- **Never send `temperature`, `top_p` or `top_k`**: API version 2026-10-21 rejects them with 400 on every model [D]. Do not send `thinking`; the model default applies.
- Stream (JSON `type`): `content_block_delta` with `delta.type == "text_delta"` → `.textDelta(delta.text)`; other delta types ignored; `message_delta` → remember `delta.stop_reason` (`end_turn`/`stop_sequence` → `.endOfTurn`, `max_tokens` → `.maxTokens`, `refusal` → `.refusal`, else `.other`) and `usage.output_tokens`; `message_start` → `message.usage.input_tokens`; `message_stop` → `.finished`; `error` → throw mapped from `error.type`; `ping` and unknown types ignored.
- Limits used by the engine: request ≤ 128 MB; PDF ≤ 600 pages, or ≤ 100 pages when the model's context window is under 1,000,000 tokens; no encrypted or password-protected PDFs [D]. App cap: 30 MB file.
- Models: `GET /v1/models?limit=1000` (follow `has_more` with `after_id`); per item `id`, `display_name`, `max_input_tokens`, `max_tokens`, `capabilities.pdf_input.supported` [D].
- Headers on 429: `retry-after` (seconds), not always present [D].

#### 5.4.2 OpenAI — Responses API [D]

"Responses is recommended for all new projects" [D]; Chat Completions is not used for OpenAI.

```
POST https://api.openai.com/v1/responses
Authorization: Bearer <key>      Content-Type: application/json

{ "model": "<id>", "instructions": "<system>", "stream": true, "store": false,
  "input": [ { "role": "user", "content": [
      { "type": "input_file", "filename": "manuscript.pdf", "file_data": "data:application/pdf;base64,<base64>" },
      { "type": "input_text", "text": "<task>" } ] } ] }
```

- `store: false` always: the default stores responses for at least 30 days [D].
- `filename` is always the literal `manuscript.pdf`; the real file name is not sent.
- `max_output_tokens` only when `request.maxOutputTokens` is set (it counts reasoning tokens [D], so the API default is safer).
- `.cacheBoundary` is ignored (prefix caching is automatic).
- Stream (JSON `type`): `response.output_text.delta` → `.textDelta(delta)`; `response.refusal.delta` → collected; `response.completed` → `.finished(.endOfTurn or .refusal, usage)` with `response.usage.input_tokens/output_tokens`; `response.incomplete` → `.finished(.maxTokens)` when `response.incomplete_details.reason == "max_output_tokens"`, `.refusal` when `content_filter`, else `.other`; `response.failed` → throw from `response.error`; `error` → throw from `code`/`message`; everything else ignored.
- Limits: each file under 50 MB and 50 MB per request [D]. App cap: 30 MB file.
- Models: `GET /v1/models` returns only `id`, `created`, `owned_by` [D]. Sort by `created` descending; hide ids containing any of `embedding`, `whisper`, `tts`, `dall-e`, `image`, `audio`, `realtime`, `transcribe`, `moderation`, `sora`, `search`, `computer-use` (a "Show all" toggle disables the filter). `contextWindow` and `supportsPDFInput` are `nil`.
- Headers on 429/503: `Retry-After` (seconds) [D].

#### 5.4.3 xAI — Chat Completions [D]

```
POST https://api.x.ai/v1/chat/completions
Authorization: Bearer <key>      Content-Type: application/json

{ "model": "<id>", "stream": true,
  "messages": [ { "role": "system", "content": "<system>" }, { "role": "user", "content": "<all text parts joined by blank lines>" } ] }
```

- Why this endpoint and not xAI's Responses API: its stream format is printed in xAI's documentation, and it keeps nothing on the server ("No storage"), whereas Responses stores for 30 days unless told otherwise and its stream events are not documented [D]. The cost: xAI labels Chat Completions "deprecated … legacy endpoint, limited updates" [D]. When it is retired, `xai-api` switches to the OpenAI Responses adapter with base URL `https://api.x.ai/v1` and `store: false`: one line in `LLMKitFactory` (R12).
- Text only. xAI accepts files only by public URL or by uploading to its Files API [D]; uploading a confidential manuscript to a file store is not worth it. `supportsNativePDF = false`; a `.pdf` part → `.invalidRequest`.
- `max_tokens` only when `request.maxOutputTokens` is set [D: the parameter's name on this endpoint].
- Stream: data-only SSE. Each `data:` object is a `chat.completion.chunk`: `choices[0].delta.content` → `.textDelta` when non-empty; `choices[0].delta.reasoning_content` ignored; remember the last `usage` (`prompt_tokens`, `completion_tokens`), which arrives on every chunk [D]; `choices[0].finish_reason` when present: `stop` → `.endOfTurn`, `length` → `.maxTokens`, `content_filter` → `.refusal`, else `.other` **[A: the documented sample ends before a finish reason]**; `data: [DONE]` → `.finished` with the remembered stop reason (default `.endOfTurn`) and usage.
- Errors are told apart by HTTP status [D]: 401, 403 → `.auth`; 429 → `.rateLimited`; 404 → `.modelNotFound`; 400, 415, 422 → `.invalidRequest` (`.contextTooLong` when the message mentions "context", "token" or "too long"); 5xx → `.server`.
- Models: `GET /v1/models` → `data[].id`, `context_length` [D].

#### 5.4.4 Gemini — Interactions API [D]

```
POST https://generativelanguage.googleapis.com/v1/interactions
x-goog-api-key: <key>      Content-Type: application/json

{ "model": "<id>", "system_instruction": "<system>", "stream": true, "store": false,
  "input": [ { "type": "document", "data": "<base64>", "mime_type": "application/pdf" },
             { "type": "text", "text": "<task>" } ] }
```

- `store: false` always: by default interactions are stored (55 days on the paid tier, 1 day on the free tier) [D].
- `generation_config: {"max_output_tokens": n}` only when set.
- Stream (JSON `event_type`): `step.delta` with `delta.type == "text"` → `.textDelta(delta.text)`; other delta types (`thought_signature`, `thought_summary`, …) ignored; `interaction.completed` → `.finished` with usage from `interaction.usage.total_input_tokens/total_output_tokens` and the stop reason from `interaction.status` [D]: `completed` → `.endOfTurn`, `incomplete` ("hitting max_tokens") → `.maxTokens`, `failed` → throw `.server`, anything else → `.other`; `error` → throw from `error.code`; unknown events ignored [D: "handle unknown events"].
- Limits: 50 MB per file, 1,000 pages per PDF [D]. App cap: 30 MB.
- Models: `GET /v1/models?pageSize=1000` (follow `nextPageToken`); `name` minus the `models/` prefix, `displayName`, `inputTokenLimit`, `outputTokenLimit` [D]. Hide names containing `embedding`, `tts`, `image`, `live`, `transcribe`, `omni`, `banana`, `robotics`, `veo`, `lyria` (same "Show all" toggle).
- **[A]** If `POST /v1/interactions` answers 404 with code `not_found` (not `model_not_found`), retry once on `/v1beta/interactions` and remember that for the session.

#### 5.4.5 Ollama [V]

```
POST {base}/api/chat          base default http://127.0.0.1:11434
{ "model": "<name>", "stream": true, "keep_alive": "10m", "think": false,
  "options": { "num_ctx": <contextWindow>, "num_predict": <maxOutputTokens>, "temperature": 0.2 },
  "messages": [ { "role": "system", "content": "<system>" }, { "role": "user", "content": "<all text parts joined by blank lines>" } ] }
```

- Body is NDJSON: each line `{"message":{"role":"assistant","content":"…"},"done":false}` → `.textDelta(content)` when non-empty (`message.thinking` is ignored); the last line has `"done":true`, `done_reason` (`stop` → `.endOfTurn`, `length` → `.maxTokens`), `prompt_eval_count`, `eval_count` → `.finished`. A line `{"error":"…"}` → throw `.server(status: 500, message:)` [V].
- **`"think": false` by default.** It is not in the adapter: it comes from the default `extraBodyJSON` of the `ollama` provider (`{"think": false}`), so the user can remove it or set `true` in Settings ▸ Providers ▸ Ollama ▸ Advanced. Reason: `gemma4` thinks by default and thinking tokens count against `num_predict`; in the reviewer's runs roughly 1,400 of 3,107 output tokens of one answer were thinking, and a whole-paper answer was cut at exactly 4,096 tokens [V, reviewer]. Ollama accepts the field for models that cannot think (`gemma:2b`) as well as for those that can [V].
- **`num_ctx` must be set on every request.** Ollama otherwise allocates a default context by available memory (4k below 24 GiB VRAM, 32k up to 48 GiB [D]) and silently truncates longer prompts. The engine supplies `request.contextWindow` (§6.4).
- If `prompt_eval_count + eval_count >= num_ctx - 16` the adapter emits `.status("context window full; input may have been truncated")` before `.finished`.
- `availability()`: `GET /api/version` with a 2 s timeout → `.ready("Ollama <version>")`; connection refused → `.needsSetup("Ollama is not running", hint: "Start the Ollama app or run `ollama serve`.")`.
- Models: `GET /api/tags` → `models[].name`, `details.context_length`, `capabilities` [V on 0.40.17]. If `context_length` is absent, `POST /api/show {"model": name}` and read `model_info["<general.architecture>.context_length"]` [V]. Models whose `capabilities` lack `"completion"` are hidden.
- `.pdf` parts are a programming error for this provider: throw `.invalidRequest`.
- Installed here: `gemma4:e4b` (context 131,072), `gemma4:26b` (262,144), `phi4` (16,384), `gemma:2b` (8,192), `phi` (2,048); 24 GiB RAM [V].

### 5.5 Error mapping

| Condition | Anthropic | OpenAI | Gemini | Ollama | `LLMError` |
|---|---|---|---|---|---|
| bad or missing key | 401 `authentication_error`, 403 `permission_error` | 401, 403 | `authentication`, `permission_denied` | — | `.auth` |
| no key stored | — | — | — | — | `.notConfigured` (thrown before any request) |
| rate limit | 429 `rate_limit_error` | 429 (other codes) | `rate_limit_exceeded`, `too_many_requests` | 429 | `.rateLimited(retryAfter: header)` |
| out of credit or quota | 402 `billing_error`; 400 mentioning "spend limit" | 429 with code `credit_balance_exhausted`, `insufficient_quota`, `*_spend_limit_exceeded`, `organization_usage_limit_exceeded` | `payment_required`, `quota_exceeded` | — | `.quotaExhausted` |
| overloaded | 529 `overloaded_error` (also as a stream `error` event) | 503 `server_is_overloaded` | `service_unavailable` | — | `.overloaded` |
| input too long | 413; 400 whose message contains "too long", "too large", "context" or "token" | 400 code `context_length_exceeded` or message containing "context" | `invalid_request` whose message contains "token" | — | `.contextTooLong` |
| unknown model | 404 | 404, code `model_not_found` | `model_not_found` | 404 | `.modelNotFound` |
| other client error | 400, 409, 422 | 400, 422 | `invalid_request`, `parameter_unknown`, `failed_precondition` | 400 | `.invalidRequest` |
| safety block | `stop_reason: refusal` (as `StopReason`) | `response.incomplete` with `content_filter` (as `StopReason`) | codes `safety`, `recitation`, `prohibited_content`, `blocklist`, `spii`, `content_blocked`, `language` | — | `.refused` or `.finished(.refusal)` |
| server fault | 500, 504 | 500 | `api_error`, `deadline_exceeded`, `aborted`, `gateway_timeout`, and **any code not listed in this column** | 500, in-stream `error` | `.server` |
| transport | `URLError` except `.cancelled` | same | same | connection refused → `.notConfigured("Ollama is not running")` | `.network` |
| task cancelled | | | | | `.cancelled` |

xAI is mapped by HTTP status only (§5.4.3). A CLI that exposes or uses a tool → `.toolUseBlocked` (§5.6.3).

### 5.6 CLI providers (`CLIProviders`)

Subscription access means running the vendor's own, unmodified CLI in its documented non-interactive mode, as the user who installed and signed in to it. The app never reads, copies or stores a vendor's OAuth token and never performs a login flow; when a CLI is not signed in, the settings pane shows the command to run in Terminal.

These CLIs are coding agents. They have tools (shell, file edits, web, MCP servers) and the text they are given here is somebody else's manuscript, which can contain instructions. The design rule: **remove every tool the CLI lets us remove, contain the rest, and never rely on either: read the CLI's own event stream and kill the run when a tool appears** (§5.6.3).

#### 5.6.1 Finding and validating the binary

```swift
struct CLISpec {                      // one constant per CLI
    let name: String                  // "claude"
    let candidates: [String]          // absolute paths or globs, ~ expanded, in priority order
    let versionArguments: [String]    // ["--version"]
    let helpArguments: [[String]]     // [["--help"]]; for the flag check below
    let environmentOverride: String   // "REFEREE_CLI_PATH_CLAUDE": tests and power users
}
actor BinaryResolver {
    func resolve(_ spec: CLISpec, explicitPath: String?) async -> Result<ResolvedBinary, LLMError>
}
struct ResolvedBinary { let path: String; let version: String; let helpText: String }
```

Order: (1) `ProviderSettings.executablePath`; (2) the environment override; (3) `spec.candidates`; (4) `command -v <name>` run in a login shell. The first candidate that exists, is executable and **answers its version command within 20 s with exit code 0** wins; the result is cached with the file's modification date and revalidated when that changes.

| CLI | Candidates, in order | Install [D] |
|---|---|---|
| `claude` | `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, newest of `~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude` (also `~/.vscode-insiders/…`, `~/.cursor/…`) | `curl -fsSL https://claude.ai/install.sh \| bash` → `~/.local/bin/claude` |
| `codex` | `~/.local/bin/codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` | `npm install -g @openai/codex`, or `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` → `~/.local/bin/codex` |
| `agy` | `~/.local/bin/agy`, `/opt/homebrew/bin/agy`, `/usr/local/bin/agy` | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` → `~/.local/bin/agy` (the only documented installer) |
| `grok` | `~/.local/bin/grok`, `~/.grok/bin/grok`, `/opt/homebrew/bin/grok`, `/usr/local/bin/grok` | `npm install -g @xai-official/grok`, or `curl -fsSL https://x.ai/cli/install.sh \| bash` |

The app installs nothing; Settings shows the command. Why validation with a timeout is mandatory: on this machine `/opt/homebrew/bin/codex` exists and is unusable (§0.1, item 6) [V]. The VS Code extension's bundled `claude` (2.1.330) and the ChatGPT app's bundled `codex` (0.167.0-alpha.3.2) are the only working copies here [V], which is why those two locations are candidates.

**Flag check.** After a binary validates, the resolver runs each of `spec.helpArguments` (20 s cap, exit code 0 required) and keeps the output. Every adapter lists its *protected* arguments (§5.6.4). If the help text does not contain a protected flag's name as a whole word, `availability()` returns `.unavailable("<CLI> <version> does not list the option <flag>, which Referee needs in order to run it safely")` and the provider cannot be selected. Reason: two of the four invocations were written from documentation for a binary nobody here has run, and every CLI's flags drift; a missing safety flag must stop the provider, not be discovered as a confusing failure or, worse, be ignored. For Claude Code and Codex every protected flag is in the help text of the installed versions [V].

#### 5.6.2 Environment and working directory

An app launched from Finder has a minimal `PATH`. The child environment is built from scratch:

- `PATH` = output of `/bin/zsh -l -c 'printf %s "$PATH"'` run once with a 5 s timeout (0.12 s here [V]; non-interactive, so `.zshrc` is not read and nothing can prompt), followed by `~/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` for anything missing. npm-installed CLIs are `#!/usr/bin/env node` scripts and need this.
- Copied from the app's environment when present: `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `TMPDIR`, `SHELL`, `SSH_AUTH_SOCK`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CONFIG_HOME`, `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`. Added: `TERM=dumb`, `NO_COLOR=1`, and for `grok` `GROK_SANDBOX=strict`.
- **Never copied**, so that the subscription login is what authenticates: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_PROFILE`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `GOOGLE_GEMINI_BASE_URL`, `XAI_API_KEY`. (Claude Code uses an `ANTHROPIC_API_KEY` in the environment ahead of the subscription login in `-p` mode [D].)
- Working directory: a new directory `<TMPDIR>/referee-cli-<uuid>` (mode 0700), deleted when the run ends. It is empty except for what the adapter puts there (a system-prompt file; in the delivery modes of §5.6.6 a copy of the manuscript or its page images). The agent inside the CLI has nothing else to read or edit.
- stdin is always a pipe; stdout and stderr are pipes. Never a TTY, never inherited.
- **The manuscript never travels as a process argument** (arguments are visible to every process of the user through `ps`). It goes on stdin, or into a file in the working directory.

#### 5.6.3 Process runner, arguments and the tripwire

```swift
enum CLIInput { case data(Data)        // written by a separate task, then stdin is closed
                case interactive }     // the adapter writes with send(_:) and closes with closeInput()  (Grok Build)
struct CLIInvocation {
    var executable: String
    var arguments: [String]
    var input: CLIInput
    var workingDirectory: URL
    var environment: [String: String]
    var firstOutputTimeout: Duration = .seconds(300)   // spawn → first stdout byte
    var idleTimeout: Duration = .seconds(300)          // between stdout lines
    var totalTimeout: Duration = .seconds(3600)
}
enum CLIOutput { case line(String); case exit(code: Int32, stderrTail: String) }   // stderrTail: last 4 KB
final class CLIProcess {
    let output: AsyncThrowingStream<CLIOutput, Error>
    func send(_ line: Data) async throws
    func closeInput()
    func kill()                                        // SIGKILL at once
}
struct CLIRunner { func start(_ invocation: CLIInvocation) throws -> CLIProcess }
```

- `Foundation.Process`. With `.data`, stdin is written from a separate task and then closed (a 1 MB prompt must not deadlock against a full stdout pipe). stdout is read with `FileHandle.bytes` through `LineSplitter`. stderr is drained continuously into a 64 KB ring buffer.
- Timeouts throw `LLMError.cliTimeout(phase: "start" | "idle" | "total")`.
- Cancellation or timeout: `SIGINT`, wait 2 s, `SIGTERM`, wait 3 s, `SIGKILL`; then remove the working directory. (Claude Code ends the turn on SIGINT and exits 143 on SIGTERM [D].)
- `SIGKILL`, here and in `kill()`, goes to the **whole process tree**: the child and every descendant, collected with `proc_listchildpids` (libproc, through `import Darwin`) before the first signal is sent [V]. npm-installed CLIs are Node wrappers that run the real program as a child; killing the wrapper alone would leave the agent running.
- Spawn failure → `.cliLaunchFailed`. Non-zero exit without a parsed result → `.cliExited(code, stderrTail)` after the adapter has had a chance to classify stderr (auth and quota patterns below).
- stderr text may contain fragments of the prompt; it is shown to the user in the error banner but never logged.

**Arguments.** Each adapter builds its list from a table in which every element is marked *protected* or not. `ProviderSettings.extraArguments` are appended after the table. An element of `extraArguments` that starts with `!` is not passed; instead it removes the unprotected default argument equal to the rest of the element (for example `!--print-timeout`), so the user can drop a cosmetic flag that a new CLI version renamed. A `!` that names a protected argument is ignored and the run starts with `.status("ignored: <flag> cannot be removed")`. Protected arguments are the ones that remove tools, select a sandbox or permission mode, isolate the CLI from the user's own configuration, or keep the manuscript out of session files.

**Tripwire.** All four CLIs report what the agent does in a structured stream. Every adapter has a rule, given per CLI below, that recognises a tool in that stream. When it fires the adapter calls `kill()`, stops reading, removes the working directory, and throws `LLMError.toolUseBlocked(<tool name>)`. Text deltas emitted before that moment stay with the engine (they were produced before any tool result existed); nothing after it is read. The engine ends the run as failed with the error's message: "The command-line tool tried to use a tool (…); the run was stopped and nothing it produced after that point was used." The rule is fail-closed: a stream line that should prove tools are off and does not (a missing field, an unknown item type) trips it too. What the tripwire cannot do is stated in §12.5: for Antigravity and Codex the stream reports a tool when it has run, not before.

Prompt delivery: CLIs without a system-prompt option get `system` and the user parts joined as

```
<<SYSTEM INSTRUCTIONS>>
{system}
<<END SYSTEM INSTRUCTIONS>>

{user text}
```

#### 5.6.4 Per-CLI invocation and output

Timeouts (first output / idle, seconds): `claude-cli` 300 / 300; `codex-cli` 300 / 900 (its answer may arrive in one piece); `antigravity-cli` 300 / 600; `grok-cli` 300 / 600. Total 3,600 for all.

`ProviderDescriptor.maxPromptBytes`: `claude-cli` 9,000,000 (stdin is capped at 10 MB [D]); the other three 4,000,000 (our own cap); `nil` for HTTP providers.

Each block is followed by its list of protected arguments (§5.6.3); the flag check of §5.6.1 looks for exactly those flag names.

**Claude Code** — flags verified against `claude --help` 2.1.330 and the CLI reference [V][D].

```
claude -p "The complete task is in the piped input. Follow it exactly."
  --safe-mode --tools "" --disallowedTools "mcp__*" --strict-mcp-config --disable-slash-commands
  --no-session-persistence --permission-prompts none
  --system-prompt-file <workdir>/system.txt
  --output-format stream-json --verbose --include-partial-messages
  [--model <alias or id>]  [extraArguments…]
stdin: the user text (cap 10 MB [D])
```

Protected: `--safe-mode`, `--tools ""`, `--disallowedTools "mcp__*"`, `--strict-mcp-config`, `--disable-slash-commands`, `--no-session-persistence`, `--permission-prompts none`. The flag check looks for those seven flag names in `claude --help`. (`--system-prompt-file` is in the CLI reference but not in the help text [V], which is one reason it is not protected.)

- `--safe-mode` disables CLAUDE.md, skills, plugins, hooks, MCP servers and memory but keeps normal authentication. **Do not use `--bare`**: bare mode never reads the subscription login [D].
- `--tools ""` is documented as "none"; `--strict-mcp-config` with no `--mcp-config` loads no MCP server; `--no-session-persistence` keeps the manuscript out of `~/.claude` transcripts [V help text].
- stdout is JSON Lines. The first line is `{"type":"system","subtype":"init",…,"tools":[…],"mcp_servers":[…]}`.
- **Tripwire.** (1) The first `system`/`init` line must have `tools` equal to `[]` and `mcp_servers` equal to `[]`; a missing key counts as a failure. No text delta is forwarded before this line has been checked. (2) Any `stream_event` whose `event.type` is `content_block_start` with `content_block.type` other than `text`, `thinking` or `redacted_thinking`, and any `assistant` line whose `message.content` contains a block of type `tool_use`, `server_tool_use` or `mcp_tool_use`, trips it. (In the read-tool mode of §5.6.6 the allowed values differ; they are stated there.)
- `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}}` → `.textDelta`. `{"type":"system","subtype":"api_retry",…}` → `.status("retrying (attempt n)")`. `{"type":"result","subtype":…,"is_error":bool,"result":"…","api_error_status":n?,"usage":{…}}` is the last line: `is_error == false` → `.finished(.endOfTurn, usage)`; otherwise classify `result` text and `api_error_status`: contains "Not logged in", "Failed to authenticate", "Login expired", "/login" → `.auth`; contains "hit your" and "limit" → `.quotaExhausted(result)`; 429 → `.rateLimited`; 529 → `.overloaded`; else `.server(status, result)`. If no text deltas were seen but `result` succeeded, emit `result` as one delta (older versions without partial messages).
- `availability()`: `claude auth status` prints JSON and exits 0 when logged in, 1 when not [D]; fields seen here: `loggedIn`, `authMethod` ("claude.ai" for a subscription), `subscriptionType`, `loginExpiresAt`, plus account identifiers that the app must ignore [V]. `authMethod` other than `claude.ai`/`oauth_token` → `.needsSetup("Claude Code is signed in with an API key, not a subscription", hint: "Run `claude` and use /login")`.
- Models: `[default, opus, sonnet, haiku, fable]` as `ModelInfo` with `contextWindow: nil`.

**Codex** — flags verified against `codex exec --help` 0.167.0-alpha.3.2; the effect of the tool-removing ones verified with `codex debug prompt-input`, which renders the model-visible tool list locally without sending anything [V].

```
codex exec - --json --skip-git-repo-check
  --ephemeral --ignore-user-config --ignore-rules --strict-config --sandbox read-only -C <workdir>
  -c web_search="disabled" -c history.persistence="none" -c agents.enabled=false
  --disable shell_tool --disable view_image --disable sleep_tool
  [-m <model>]  [extraArguments…]
stdin: system and user text in the inline form above ("-" = read the whole prompt from stdin [V])
```

Protected: everything on the second, third and fourth lines except `-C <workdir>`. The flag check looks for `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `--strict-config`, `--sandbox` and `--disable` in `codex exec --help`.

- What each protected flag removes, measured by rendering the tool list with an empty configuration directory [V]: nothing removed → `exec_command`, `write_stdin`, `view_image`, `apply_patch`, three MCP-resource tools, `sleep`, and a six-tool agent family (`spawn_agent` …). `--disable shell_tool` removes `exec_command` and `write_stdin`; `--disable view_image` removes `view_image`; `--disable sleep_tool` removes `sleep`; `-c agents.enabled=false` removes the agent family. An unknown feature name fails at once ("Unknown feature flag", exit 1 [V]), so a renamed feature cannot silently restore a tool. **What remains and cannot be removed by any flag found:** a JavaScript `exec` orchestrator through which the model can call `apply_patch` and the MCP-resource listing tools, plus `wait` and `request_user_input`. `--sandbox read-only` is what stands between `apply_patch` and the disk **[A: its effect on `apply_patch` was not exercised]**; the tripwire is what stops the run.
- `--ignore-user-config` skips `~/.codex/config.toml`, and with it the user's MCP servers and plugins; "auth still uses `CODEX_HOME`" [V help text]. On this machine the user's configuration enables a plugin that lets the model operate the desktop's UI [V, reviewer]; with the configuration ignored it is not in the tool list. Whether plugins recorded elsewhere under `~/.codex` can still load is not known **[A]**. `--strict-config` makes an unrecognised configuration key an error [V help text] **[A: that it applies to `-c` overrides]**.
- `--ephemeral` and `history.persistence="none"` keep the manuscript out of `~/.codex` session files; whether Codex's own log database records prompt text is not known (§12.4). `web_search` defaults to `"cached"`, so it is disabled explicitly [D]. No system-prompt flag is used: replacing Codex's built-in instructions has been rejected by the ChatGPT-plan back end in the past, so the instructions go in the prompt **[A]**.
- stdout is JSON Lines: `thread.started`, `turn.started`, `item.started` / `item.updated` / `item.completed` with `item: {id, type, text?}`, `turn.completed {usage: {input_tokens, output_tokens}}`, `turn.failed {error: {message}}`, `error {message}` [D + source].
- **Tripwire.** Any `item.*` event whose `item.type` is not one of `agent_message`, `reasoning`, `todo_list`, `error`. The types that mean a tool are `command_execution`, `file_change`, `mcp_tool_call`, `collab_tool_call`, `web_search` [D: `exec_events.rs`]; a type not in either list also trips it.
- For items with `type == "agent_message"`, `text` is treated as cumulative per `item.id`: emit the suffix beyond what was already emitted for that id (if the new text does not extend the old, emit it whole on a new line). `turn.completed` → `.finished(.endOfTurn, usage)`. `turn.failed` / `error` → classify `message`: "401", "Unauthorized", "login", "logged in" → `.auth`; "usage limit", "quota" → `.quotaExhausted`; "rate limit", "429" → `.rateLimited`; else `.server(500, message)`. Whether `item.updated` carries partial text is unverified, hence "message" granularity in the roster.
- `availability()`: `codex login status` exits 0 when credentials exist and prints "Logged in using ChatGPT" for a plan login [V]. Any other first line → `.needsSetup("Codex is not signed in with ChatGPT", hint: "Run `codex login`")`.
- Models: `codex debug models` prints `{"models":[{"slug","display_name","context_window","visibility","priority",…}]}` [V]; keep `visibility == "list"`, sort by `priority`. On failure fall back to `codex debug models --bundled`.

**Antigravity** — experimental; from documentation only [D]; `agy` is not installed here and WP5 does not install it.

```
agy --input-format stream-json --output-format stream-json --mode=accept-edits --sandbox --disable-slash-commands --print-timeout 60m
  [--model <slug>]  [extraArguments…]
stdin: one line  {"event":"user","message":{"content":"<system and user text, inline form>"}}  then EOF
```

Protected: `--input-format stream-json`, `--output-format stream-json`, `--mode=accept-edits`, `--sandbox`, `--disable-slash-commands`. The flag check looks for `--input-format`, `--output-format`, `--mode`, `--sandbox` and `--disable-slash-commands` in `agy --help`.

- `agy` has no flag that removes tools [D]. What limits them: (1) `--mode=accept-edits` pins the execution mode. Without it, print mode has run in `auto` since v1.5.7, which runs "safe, reversible" commands without asking; in `accept-edits`, file edits inside the workspace are approved and terminal commands ask. `--mode` accepts `accept-edits`, `auto` and `plan` only; `plan` rewrites the prompt, so `accept-edits` is the strictest usable value [D]. (2) In print mode nobody can answer, so "any tool action that requires approval it can't obtain … is soft-denied": commands, web access, MCP tools and files outside the workspace [D]. (3) The workspace is our temporary directory. (4) `--sandbox` confines any command that does run: unmounted paths are invisible and the network is off [D]. The user's own allow rules in `~/.gemini/antigravity-cli/settings.json` still apply and cannot be overridden from the command line [D].
- stdout is NDJSON: `{"event":"init","init":{"cwd","tools":[…],"permission_mode":"request-review",…}}`; `{"event":"step_update","step_update":{"step_type":"agent_response","state":"ACTIVE"|"DONE","text_delta":"…"}}` → `.textDelta(text_delta)` for `agent_response` steps only; `{"event":"result","result":{"status":"SUCCESS"|"ERROR"|…,"response":"…","error":"…","usage":{"input_tokens","output_tokens"}}}` → `SUCCESS` → `.finished(.endOfTurn, usage)`; otherwise classify `error`: contains "authentication required" → `.auth` [D wording]; "quota", "limit" → `.quotaExhausted`; "not recognized as a known model" → `.modelNotFound`; else `.server(500, error)`. The process exits after stdin closes and the turn completes [D].
- **Tripwire.** (1) The `init` line's `permission_mode` must be `request-review` or `strict`; `always-proceed` (the user's settings auto-approve everything) or a missing value trips it before any text is forwarded. (2) Any `step_update` whose `step_type` is `tool`, or that carries `tool_name`, `tool_info` or `subagent_info`. A tool step is reported with its output, so a tool that needed no approval has already run when the tripwire fires.
- `availability()`: `agy --version` and the flag check; the docs give no auth-status command, so the result is `.ready("installed; sign-in is checked on first use")`.
- Models: `agy models` prints lines of `slug`, two or more spaces, display name [D].

**Grok Build** — experimental; from documentation only [D]. WP5 may install it with `npm install -g @xai-official/grok` to read its help text (§11.6).

```
grok --no-auto-update --sandbox strict --permission-mode dontAsk --disallowed-tools "Bash,Edit,Read,Grep,WebFetch,WebSearch"
  --disable-web-search --no-subagents --no-memory --no-plan  [-m <model>]  [extraArguments…]  agent stdio
environment: GROK_SANDBOX=strict
stdin and stdout: Agent Client Protocol, version 1: JSON-RPC 2.0, one message per line
```

Protected: every argument except `--no-auto-update` and `-m`. The flag check looks for `--sandbox`, `--permission-mode`, `--disallowed-tools`, `--disable-web-search`, `--no-subagents`, `--no-memory` and `--no-plan` in `grok --help`, and requires `grok agent stdio --help` to exit 0.

- Why the Agent Client Protocol (ACP) and not `grok -p`: `-p` takes the prompt as an argument, its JSON stream format is not documented, and plain output cannot show tool use. `grok agent stdio` is documented with a worked client [D], takes the prompt on stdin, and reports every tool call.
- Three layers, strongest first. (1) **Protocol, ours:** the client announces no capabilities (no file access, no terminal), passes no MCP servers, and answers every permission request with "cancelled". (2) **Environment, documented:** `GROK_SANDBOX=strict` limits the process to reading the working directory and system paths and writing the working directory, `~/.grok` and temp [D]. (3) **Flags, documented for `grok` but not confirmed together with `agent stdio`:** `--permission-mode dontAsk` "silently den[ies] anything without an explicit allow rule" and no allow rule is given; `--disallowed-tools` removes the built-in tools named by xAI's permission filters; the four feature switches turn off web search, sub-agents, memory and planning [D] **[A: list separator and placement before the subcommand]**. The flag check of §5.6.1 uses `grok --help` and `grok agent stdio --help`.
- Session, in order (`id` increases; every line is one JSON object):

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},"clientInfo":{"name":"referee","version":"<app version>"}}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{…},"authMethods":[{"id":"cached_token",…},…]}}
→ {"jsonrpc":"2.0","id":2,"method":"authenticate","params":{"methodId":"cached_token","_meta":{"headless":true}}}
→ {"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"<workdir>","mcpServers":[]}}
← {"jsonrpc":"2.0","id":3,"result":{"sessionId":"<sid>"}}
→ {"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"<sid>","prompt":[{"type":"text","text":"<system and user text, inline form>"}]}}
← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"<sid>","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"…"}}}}     (many)
← {"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}
```

- `authMethods` without `cached_token`, or an error answer to `authenticate` → `.auth("Run `grok login` in Terminal")`. `agent_message_chunk` → `.textDelta(content.text)`. `agent_thought_chunk`, `plan`, `usage_update`, `available_commands_update`, `current_mode_update`, `session_info_update` and unknown update kinds are ignored. The answer to request 4 ends the turn: `end_turn` → `.endOfTurn`, `max_tokens` → `.maxTokens`, `refusal` → `.refusal`, others → `.other` [D: ACP]; because chunks can arrive after that answer [D: xAI's example waits for them], keep reading until 500 ms pass with no line, then emit `.finished` (usage `nil`), close stdin and terminate the process. A JSON-RPC `error` answer → `.server(500, message)`, or `.auth` when the message mentions "auth" or "login".
- **Tripwire.** Any `session/update` whose `sessionUpdate` is `tool_call`, `tool_call_update` or `subagent_update`; and any message from the agent that has both `id` and `method` (a request to the client: `session/request_permission`, `fs/…`, `terminal/…`). Before killing the process, a permission request is answered `{"outcome":{"outcome":"cancelled"}}`.
- **Local copy of the conversation.** Grok Build saves every conversation under `~/.grok/sessions`, "the same in the TUI, headless mode, and over ACP", and can sync sessions to the user's xAI account [D]. After every run the adapter deletes it: `session/delete` when `initialize` advertised `agentCapabilities.sessionCapabilities.delete` [D: ACP], otherwise `grok sessions delete <sid>` with a 20 s cap [D] **[A: the ACP session id is the id that command takes]**. Failure to delete is reported once as `.status`, and the provider's retention note says the copy may remain.
- `availability()`: `grok --version`, the flag check, and nothing else (no documented status command); `.ready("installed; sign-in is checked on first use")`.
- Models: `grok models`, first whitespace-delimited token of each non-empty line **[A]**.

#### 5.6.5 Policy note for the Claude subscription route

Anthropic's Claude Code terms say OAuth sign-in is for "ordinary use of Claude Code and other native Anthropic applications", that developers must not "offer Claude.ai login into their own applications, or … route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users", and that nothing prevents "an end user from signing in to the unmodified Claude Code binary with their own Claude subscription" [D: legal-and-compliance]. Referee launches the unmodified binary the user installed and signed in to, on the user's own machine, for the user's own work, and touches no credentials. That is within those terms for personal use. If the app is ever given to other people, this provider must be reviewed against those terms first; it is one file plus one registry line, so it can be removed cleanly. The settings pane labels these providers "Use my installed <CLI>" and never "Sign in".

#### 5.6.6 Handing the manuscript itself to a CLI

Text extracted by PDFKit garbles mathematics and tables: the posterior-belief fraction of the fixtures arrives as the four lines `µi =`, `πf(si |H)`, `πf(si |H) + (1−π)f(si |L).`, `(1)` [V]. API-key providers get the PDF file instead. Whether the two installed subscription CLIs can is not documented, so WP5 finds out by experiment, within the prompt budget of §11.6, using only `Fixtures/pdf/ay_round_nolinks.pdf`.

The question, in every variant (no extracted text is sent, so a right answer proves the model saw the page):

```text
Answer in exactly two lines and nothing else.
Line 1: the right-hand side of equation (1), written in LaTeX.
Line 2: the estimate in the row "Staggered rollout" of Table 2.
```

**Pass** = the run ends without error, the tripwire did not fire, and the answer contains `\frac` and `0.87`.

| # | CLI | Variant | Invocation (differences from §5.6.4) |
|---|---|---|---|
| C1 | Claude Code | document block on stdin | no prompt argument; add `--input-format stream-json`; stdin is one line `{"type":"user","message":{"role":"user","content":[{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"<base64>"}},{"type":"text","text":"<question>"}]}}` then EOF |
| C2 | Claude Code | one Read tool, confined (only if C1 fails) | copy the PDF to `<workdir>/manuscript.pdf` (0600); replace `--tools ""` by **`--tools "Read" --restricted`**; stdin: "The manuscript is the file manuscript.pdf in the current directory. Read all of it with the Read tool, in page ranges of at most 20 pages, before answering." + the question. `--restricted` "confines the file tools to the working directories" [V help text]. |
| X1 | Codex | page images attached | render every page to `<workdir>/p001.png`, … at 110 dpi with CoreGraphics (`CGPDFDocument`, no PDFKit); add `-i <png>` once per page [V: `-i` is in `codex exec --help`]; stdin: "The attached images are the pages of a manuscript, in order." + the question |

The third prompt allowed per CLI is a single retry of a variant that failed for a reason unrelated to delivery (network, rate limit). No other variant is tried.

**Outcome → what is built.** Each adapter has one constant, set by WP5 from the result and recorded with the full output in `docs/contract-notes/wp5-cli.md`:

```swift
enum CLIPDFDelivery { case none, documentBlock, readTool, pageImages }
```

| Result | Constant | `supportsNativePDF` | `pdfDeliveryNote` | Tripwire in PDF mode |
|---|---|---|---|---|
| C1 passes | `claude-cli`: `.documentBlock` | true | `nil` | as §5.6.4: no tools at all |
| C1 fails, C2 passes | `claude-cli`: `.readTool` | true | "read from a private temporary copy by Claude Code's own Read tool" | `init.tools` must equal `["Read"]` and `mcp_servers` `[]`; every `tool_use` block must be named `Read` with `input.file_path` resolving to `<workdir>/manuscript.pdf`; anything else trips it |
| X1 passes | `codex-cli`: `.pageImages` | true | "sent as page images" | as §5.6.4 (attachments are not tools) |
| otherwise, or the CLI is not installed or not signed in when WP5 runs | `.none` | false | `nil` | as §5.6.4 |

With a delivery other than `.none`, the adapter accepts a `.pdf` part: it writes the file or the page images into the working directory and invokes the CLI as in the passing variant, with the engine's task text in place of the question. With `.none` a `.pdf` part is `.invalidRequest`, the engine plans text mode (§6.2), and the destination indicator and the consent card say in plain words that this route sends extracted text only and that equations and tables may be garbled (§9.7). Limits used by planning: `.documentBlock` and `.readTool` 100 pages, `.pageImages` 40 pages **[A]**.

### 5.7 Retry and rate limits

Implemented once, in `LLMKit`, as a wrapper every HTTP provider's `stream` goes through:

- Retry only if **no text delta has been yielded yet**. After the first delta a failure is thrown to the engine, which keeps the partial result (§6.6).
- `.rateLimited(retryAfter: t)`: wait `min(t, 60)` s plus 0–1 s jitter when `t` is given; otherwise use the backoff below. `.overloaded`, `.server`, `.network`: backoff 2 s, 6 s, 18 s (each ±25%).
- At most 3 attempts in total. Before each wait, yield `.status("Retrying in N s (reason)")`.
- Never retried: a `.network` error that is a timeout (`URLError.timedOut`: the request already waited ten minutes), `.auth`, `.notConfigured`, `.quotaExhausted`, `.contextTooLong`, `.invalidRequest`, `.modelNotFound`, `.refused`, `.cancelled`, `.malformedResponse`, `.toolUseBlocked`, and all other CLI errors (Claude Code retries internally and reports `api_retry` events).
- The app sends at most one request at a time per provider from the review lane and one from the reply lane; there is no fan-out, so client-side rate limiting beyond this is unnecessary.

### 5.8 Secrets

- `KeychainSecretStore` (`LLMKit`): one generic-password item (`kSecClassGenericPassword`, service `local.referee.app`, account `secrets-v1`) whose value is a UTF-8 JSON object mapping key names to secrets. Keys: `anthropic-api`, `openai-api`, `gemini-api`, `xai-api`. One item rather than four because an ad-hoc-signed app gets a new code identity on every rebuild and macOS then asks before releasing each item.
- **Read-modify-write must not destroy keys.** Measured with two builds of one probe [V, reviewer]: after a rebuild, reading the item fails with −25293 (`errSecAuthFailed`) until the user approves, but `SecItemUpdate` from the rebuilt binary **succeeds without approval**. A `setSecret` that treated a failed read as "no keys yet" would therefore overwrite all stored keys with one. Rule: `setSecret` proceeds only if `SecItemCopyMatching` returned the item (then modify and `SecItemUpdate`) or `errSecItemNotFound` (then `SecItemAdd`); on any other status it throws `SecretError.unreadable(status:)` and writes nothing. The Keychain calls sit behind an internal `KeychainBackend` protocol so that a test can make reads fail.
- The prompt after each rebuild disappears if the app is signed with a stable identity: `REFEREE_SIGN_IDENTITY="<name of a self-signed code-signing certificate>" scripts/bundle.sh`. The item's access rule is then the certificate, not the hash of one build **[A: reasoning from how the designated requirement is formed; not tried in a bundle]**. The README explains how to create the certificate in Keychain Access.
- `EnvironmentSecretStore` (`Composition`) wraps it: `REFEREE_KEY_<KEY in upper case, non-alphanumerics as _>` (for example `REFEREE_KEY_ANTHROPIC_API`) wins over the Keychain. With `REFEREE_NO_KEYCHAIN=1`, `LiveDependencies` leaves the Keychain out altogether (environment keys over an empty in-memory store). `referee-cli` sets that for itself unless `--use-keychain` is given, and the snapshot mode and the default test run never construct a `KeychainSecretStore`, so automated runs never touch the Keychain or trigger its prompt. The one test that talks to the real Keychain is opt-in: it runs only when `REFEREE_TEST_KEYCHAIN=1`, under a unique service name that it deletes afterwards.
- Keys are sent only to their own vendor's host, only in the header that vendor documents, and appear in no log, file, error message or snapshot. Settings shows "•••• stored" and offers Replace and Remove; it cannot display a stored key.

### 5.9 Mock provider (`TestSupport`)

`MockResponse`, `MockScript`, `MockLLMProvider`, `StaticProvider` and `SnapshotSupport` are declared in §11.3. Behaviour:

- A `MockLLMProvider` answers each request with the next `MockResponse` scripted for the request's `purpose` (the last one repeats), cut into deltas of `chunkSize` characters, `delayPerChunk` apart. Same script, same deltas, same order. `recordedRequests` keeps every request it received.
- `failAfterChunks: n` with a `failure`: after n deltas the stream throws that error. `stallAfterChunks: n`: after n deltas it emits nothing and never finishes until the consuming task is cancelled.
- `MockScript.sample` is built from `Fixtures/llm` (Appendix D.9). `.failsAfterTwoComments` and `.stallsAfterTwoComments` answer a review with the first two blocks of `review_clean.txt` and the third block up to its quote line, then throw `.overloaded` or fall silent. The cut is counted in lines: the first half of the third block's lines (five of nine: `@@COMMENT`, kind, category, page and quote), so the third block has neither title nor body. The parser drops such a block when the stream ends (§6.5, rule 5), so a review through either script keeps exactly two comments; while `mock-stall` is silent, the third block is a draft that shows its kind, category, page and quote.
- `SnapshotSupport.providers()` returns four mocks, `mock` (local), `mock-remote` (not local, destination `mock.example.org`), `mock-fail`, `mock-stall`, followed by one `StaticProvider` per real provider id with a scripted status and model list for the settings scenes.
- `Composition` registers `MockLLMProvider()` under the id `mock` when `REFEREE_ENABLE_MOCK=1` and for `referee-cli --provider mock`, and uses `SnapshotSupport.providers()` as the whole registry when `REFEREE_SNAPSHOT=1` (§10.1).

---

## 6. Review engine

### 6.1 Surface

`ReviewEngine` (target `ReviewEngine`; protocol in Appendix A.6; initialiser in §11.3) is built from a provider registry, the paper service, a matcher factory, a renderer and the machine's memory size. Jobs: `plan`, `review`, `discuss`, `ask`, `generateReport`, `reviseVoice`, `lint`. Each LLM job returns a cold stream of events, records a `RunRecord`, and obeys cancellation. Everything a job needs besides the paper arrives in `EngineContext`: provider, provider settings, the chosen model's `ModelInfo` (or `nil`), prompts, rubric, manuscript metadata and the paper digest.

### 6.2 How the paper reaches the model

Two modes. **PDF mode** sends the original file; the provider extracts text and renders page images itself, so the model sees equations, tables and figures. **Text mode** sends text extracted locally with page markers. PDF mode is preferred when available because referee work depends on tables and mathematics; text mode is the universal fallback and the only mode for local models, xAI and any CLI that failed the delivery experiment (§5.6.6).

`sendsPDF` is true iff all hold: `providerSettings.inputMode != .text`; `descriptor.supportsNativePDF`; `context.model?.supportsPDFInput != false`; the paper is not encrypted (`LoadedPaper.isEncrypted == false`: vendors reject protected PDFs [D]); file ≤ 30 MB; page count within the provider's limit (§6.4); `pages × pdfTokensPerPage ≤ inputBudget`. If `inputMode == .pdf` but a condition fails, the engine uses text mode and puts the reason in `SendPlan.warnings`. If the paper has no text layer and PDF mode is unavailable, the review cannot run: `plan` returns `blockingReason = "This PDF has no text layer; choose a provider that accepts PDF files."`

The PDF always travels inline (base64) in the request. No vendor's file-upload API is used (Anthropic Files, OpenAI `file_id`, Gemini Files, xAI Files): inline data covers the 30 MB cap, and an uploaded copy of a confidential manuscript would stay on the vendor's side until deleted.

Automatic fallback: in PDF mode, a `.contextTooLong`, or an `.invalidRequest` whose message mentions "pdf", "file", "document" or "image", restarts the job once in text mode with a `.notice`.

**Text mode content** is `PaperRendering.render` output: prose joined into paragraph-like lines, with headings, table rows and equation fragments left on lines of their own. Real output for the top of page 2 of `ay_nolinks.pdf` [V, prototype]:

```
[[page 2]]
In Banerjee [1992], agents observe only the actions of their predecessors. The Avery and Zemsky [1998] model adds a market maker who updates prices. See Lee [2021] for heterogeneous priors. …
2 Model
Consider a sequence of agents i= 1,2,... who each observe a private signal si and the history of actions hi. The posterior belief satisfies
µi =
πf(si |H)
πf(si |H) + (1−π)f(si |L).
(1)
Proposition 1 states that an information cascade begins with positive probability. …
```

Rules (pure, deterministic, text and vertical positions only):

1. Only `.body` lines are rendered, pages in order, lines in `PageText.lines` order.
2. A body line is *full* if its length is at least 0.75 × the median length of that page's body lines of 25 or more characters (a page with fewer than five such lines has no full lines).
3. A line is joined to the line before it, with one space, iff the line before is full **and** the two are at normal pitch: both have bounds and the vertical distance between them is positive and at most 1.3 × the page's median distance between consecutive body lines (when bounds are missing the pitch test is skipped). Otherwise it starts a new output line. So a heading, a table row, an equation fragment, the last line of a paragraph and the last line of a reference entry each end a run.
4. De-hyphenation when joining: if the run ends in a hyphen preceded by a letter and the next line starts with a lower-case letter, the hyphen is dropped and no space is added ("predeces-" + "sors" → "predecessors"), unless the hyphenated word occurs unbroken elsewhere in the document and the joined word does not.
5. Page marker: one line `[[page N]]` (1-based index of the page in the file) before the first output line that starts on page N. A run that is still open at a page break continues onto the next page; it is cut after the first sentence end (`.`, `?` or `!`, optional closing quote or bracket, then a space and an upper-case letter or opening bracket) found within 400 characters after the break, the marker follows, and the rest of the run starts a new line. With no such sentence end, the marker goes after the whole run. A sentence is thus never interrupted by a marker (a small model commented "sentence ends abruptly" on exactly that in the reviewer's run).

The matcher never sees this text. It works on the lines (§6.7), and because it ignores spaces and hyphens, a quote copied from the rendered text is found whichever way it was joined.

### 6.3 Prompt assembly

Texts are in Appendix B. `PromptSet` fields are user-editable; the **format specification is a constant in code**, appended by the engine, so editing the rubric cannot break parsing.

| Job | `system` | User turn parts, in order |
|---|---|---|
| review, one pass | `reviewSystem` + rubric block + `FORMAT_REVIEW` | paper (`.pdf` or `.text`), `.cacheBoundary`, task text (`TASK_REVIEW` + reviewer notes + titles of existing comments) |
| review, part *i* of *n* | same | one text: `TASK_PART` with the part's pages, the notes so far and the text of the part filled in where its placeholders stand |
| review, whole-paper pass | same | task text (`TASK_WHOLE` with final notes and titles so far) |
| discuss | `discussionSystem` + `FORMAT_REVISION` | paper context, `.cacheBoundary`, the comment, the transcript, the new message |
| ask | `questionSystem` | paper context, `.cacheBoundary`, the selected passage with its location label, the transcript, the question |
| report | `reportSystem` | paper context, `.cacheBoundary`, venue and notes, approved comments, `reportTemplate` |
| voice revision | `voiceRevisionSystem` | the report Markdown, the lint findings |

The rubric block lists enabled `RubricCategory` entries as `- <id>: <name>. <guidance>` and tells the model to use exactly those ids in `category:`.

**Paper context** for discuss, ask and report: the same content as a one-pass review (PDF or full text) when that fits within 60% of the input budget. Otherwise: `context.paperDigest` when it is not `nil`, followed by the rendered text of the pages around the anchor (the anchor's page and its two neighbours; for a question with no selection and for the report, page 1 and its neighbour). `AppCore` copies `session.paperDigest` into `EngineContext.paperDigest` for every job; a review read in parts is what produces it (§6.4).

### 6.4 Planning: one pass or in parts

Constants (in `ReviewEngine/Planning.swift`):

```
charsPerToken         = 3.5      // measured 4.3–4.5 on these prompts with local models [V, reviewer]; 3.5 leaves room for mathematics
promptOverheadTokens  = 3_000    // system prompt, rubric, format, task
cliOverheadTokens     = 30_000   // a coding CLI's own instructions (agy reports about 10k input tokens for a one-line prompt [D])
safetyTokens          = 1_024
unknownContextWindow  = 128_000
cliContextWindow      = 200_000
ollamaContextCap      = physicalMemoryBytes ≥ 24 GiB ? 32_768 : 16_384     // Ollama's own default for this much memory [D]
pdfTokensPerPage      = ["anthropic-api": 4_500, "claude-cli": 4_500, "openai-api": 3_500, "gemini-api": 1_500, "codex-cli": 1_500]
pdfPageLimit          = ["anthropic-api": 600 (100 when context < 1_000_000), "gemini-api": 1_000, "claude-cli": 100, "codex-cli": 40]
outputReserve         = review 16_000, reply 4_000, report 8_000
notesBudgetChars      = 2_400
```

```
context      = settings.contextWindowOverride ?? ctx.model?.contextWindow ?? (isCLI ? cliContextWindow : unknownContextWindow)
if provider is ollama:   context = min(context, settings.contextWindowOverride ?? ollamaContextCap)
                         reserve = min(4_096, context / 4)          // replaces outputReserve
inputBudget  = context − reserve − promptOverheadTokens − safetyTokens − (isCLI ? cliOverheadTokens : 0)
if inputBudget < 1_500 → blockingReason = "This model's context window is too small."
textFits     = paperChars / charsPerToken ≤ inputBudget  &&  paperUTF8Bytes + 20_000 ≤ (descriptor.maxPromptBytes ?? .max)
```

- **Where `ctx.model` comes from.** `AppCore` fills `EngineContext.model` with the entry for the chosen model id in that provider's model list: `settings.providers[id].cachedModels` (written by the Settings pane's refresh), or the list `ReviewSessionModel` fetches itself with `listModels()` once per provider per window when the cached list is empty or more than a day old. Until a list arrives `model` is `nil`, the fallbacks above apply, and `sendPlan` is recomputed when it does. Without this, an Anthropic model's real window is unknown and a 34-page PDF is refused PDF mode (34 × 4,500 = 153,000 tokens against a 128,000 fallback).
- `sendsPDF` or `textFits` → one request.
- Otherwise read in parts: `renderer.chunkPageRanges(paper, maxCharacters: min(inputBudget × charsPerToken, (maxPromptBytes ?? .max) − 20_000) − notesBudgetChars)`, pages never split; `requestCount = parts + 1` (the whole-paper pass).
- For Ollama every request sets `LLMRequest.contextWindow = context` and `maxOutputTokens = reserve`. At 32,768 the input budget is 24,648 tokens, about 86,000 characters: a 15-page paper is read in one pass, which took 231 s here against two 155 s parts plus a third pass at 16,384 [V, reviewer]; and one pass is what the user's rubric asks for ("read the paper fully before writing anything").
- `plan(paper:context:)` returns exactly this decision as a `SendPlan` (mode, request count, estimated input tokens, destination, warnings, `blockingReason`) with no network use. The consent card and the toolbar indicator show it, and `ReviewSessionModel.canStartReview` is false while `blockingReason` is not `nil`.

Reading in parts is a sequential refine: each part's request carries the model's own running notes from the earlier parts and asks for (a) comments on this part in the normal format and (b) updated notes after a line `@@NOTES` (at most 350 words, including up to eight verbatim quotes with page numbers). The final whole-paper pass gets the notes and the titles so far and asks only for comments that need the whole paper; its quotes come from the notes. The final notes are emitted as `ReviewEvent.digest` and stored by the model as `session.paperDigest`. Two local models followed this format, `@@NOTES` included, without error [V, reviewer].

### 6.5 Output format and the streaming parser

The model writes blocks, not JSON. Reason: small local models routinely break JSON (unescaped quotes inside quoted passages, trailing commas, code fences), and JSON cannot be shown to the user while half-written; a line-oriented block format needs no escaping and can be parsed as it arrives.

```
@@COMMENT
kind: major
category: claims
page: 4
quote: The effect is statistically significant but economically small.
title: Abstract claims more than Table 2 supports
body:
The abstract calls the effect robust. Table 2, column 3, reports 0.91 with a 95% interval of [0.78, 1.06], which includes one.
suggestion:
Report the interval in the abstract and drop "robust".
@@END
…
@@DONE
```

`CommentStreamParser` (`ReviewEngine`) is a line-driven state machine fed with text deltas:

```swift
struct CommentStreamParser {
    enum Output { case draftStarted(UUID); case draftUpdated(DraftComment); case blockClosed(DraftComment)
                  case notes(String); case done }
    mutating func feed(_ delta: String) -> [Output]     // any chunking; emits draftUpdated for the unfinished last line too
    mutating func finish() -> [Output]                   // end of stream: closes an open block
    var sawAnyBlock: Bool { get }
    var sawDone: Bool { get }
    var rawText: String { get }                          // everything received, for the fallbacks
}
```

Line patterns, all case-insensitive, all tolerant of leading Markdown decoration:

```
MARK(x)  = ^\s*[>#*`\-\s]*@@\s*x\b.*$              x ∈ COMMENT, END, DONE, NOTES, REVISED, WITHDRAW
FIELD    = ^\s*(?:[-*•]\s+|\d+[.)]\s+)?[*_`]{0,3}(kind|type|severity|category|page|pages|quote|title|body|comment|suggestion|fix|resolution)[*_`]{0,3}\s*[:：][*_`]{0,3}\s*(.*)$
```

`FIELD` accepts a list marker before the name and emphasis on either side of the colon, so `- kind: major` and `* **Quote:** …` are fields; small models that drift into Markdown write exactly that.

Rules:

1. `MARK(COMMENT)` closes any open block and opens a new draft. `MARK(END)` closes the open block. `MARK(DONE)` closes it and sets `sawDone`. `MARK(NOTES)` closes it; all following text up to `MARK(DONE)` or end of stream is the notes.
2. Inside a block, before `body` has started, a `FIELD` line sets that field (synonyms: `type`, `severity` → kind; `pages` → page; `comment` → body; `fix`, `resolution` → suggestion). Any other line continues the field that was set last (so a wrapped quote or title still works).
3. After `body` has started, only a `FIELD` line for suggestion (or its synonyms) or a `MARK` line ends it; every other line, including ones that look like fields, is body text. The same holds inside `suggestion`.
4. Outside a block, lines are ignored (but kept in `rawText`).
5. Value clean-up when the block closes: `kind` → first of `major`, `minor`, `question`, `strength` contained in the lower-cased value (`critical` → major, `query` → question, `praise`/`positive` → strength; none → minor); `page` → first integer in the value; `quote` → trimmed, surrounding straight or curly quotation marks and backticks removed; `category` → lower-cased slug, unknown → `other`; `title` → one line, Markdown emphasis stripped, at most 120 characters; empty title → first ten words of the body; `suggestion` → `nil` when its folded form (§6.7) is empty or one of `na`, `none`, `nosuggestion`, `nothing` (both local models wrote "N/A" or "No suggestion."). A block with neither title nor body is dropped.
6. Nothing in the parser depends on chunk boundaries: feeding the same text one byte at a time or in one piece gives the same closed blocks (tested both ways).

Fallbacks when the stream ends and `sawAnyBlock` is false:

1. **JSON.** Strip code fences; find the first balanced `[`…`]` or `{`…`}`; if `JSONSerialization` parses it into an object, an array of objects, or an object with one array value, map each object's keys case-insensitively with the same synonyms.
2. **Unstructured.** One comment: kind minor, category `other`, title "Unstructured model output", body = the raw text (first 6,000 characters), no anchor; plus `.notice("The model ignored the output format; its answer is shown as a single comment.")`. (`gemma:2b` needed this [V, reviewer].)

Continuation: if the stream ends with `StopReason.maxTokens`, or without `@@DONE` while the last block was left open, the engine sends a follow-up request with the same paper context and `TASK_CONTINUE` (titles so far). At most two continuations per request. A stream that ends normally without `@@DONE` and with its last block closed is treated as complete.

### 6.6 Running a review

```
emit .started(run)                         (RunRecord with status .running)
emit .phase(.preparing)                    resolve provider and model, plan, build the matcher
for each request (one pass, or parts then the whole-paper pass):
    emit .phase(.reading(part:of:)) or .phase(.wholePaperPass)
    for each LLMEvent:
        .textDelta → parser.feed → .draft(DraftComment) for started/updated drafts
                     on blockClosed: validate, anchor (§6.7), fill rects, apply the rules below → .comment(c, replacesDraft:)
        .status    → .notice (deduplicated)
        .finished  → continuation check (§6.5)
emit .digest(notes)                        only after a review read in parts
emit .finished(run)                        status .completed, usage summed, requestCount set
```

- A new `ReviewComment` has `origin: .ai(runID:)`, `status: .pending`, `includeInReport: true`.
- Running a review again keeps every existing comment and adds only new ones: the titles of existing non-rejected comments go into the task text and the two rules below apply against them too. The Comments header's ⋯ menu offers "Clear undecided AI comments" (`deletePendingAIComments()`) for a clean second run.
- **Repeat → dropped.** A comment whose folded quote and folded title both equal those of an existing non-rejected comment (from this run or passed in `existing`) is dropped.
- **Same passage → kept, marked.** A comment whose spans overlap at least 80% of their characters with the spans of an existing non-rejected comment of the same kind gets `similarTo = <that comment's id>` and is emitted. The sidebar shows it collapsed under "Similar to: <title>" (§9.3). Titles are not compared: a local model wrote two comments on one quoted equation under different titles [V, reviewer], and deciding which to keep is the referee's call.
- **At most two `strength` comments per run.** Later ones are dropped; one `.notice` at the end says how many. The format text asks for the same limit; in the reviewer's run six of sixteen comments were generic praise despite "use it sparingly".
- Any `LLMError`: close the parser (`finish()`), emit what it yields, then `.finished(run)` with `.failed(error.userMessage)`. The stream itself ends normally; the caller reads the failure from the run status. Comments already emitted stay.
- Cancellation: `.finished(run)` with `.cancelled`; open drafts are discarded.
- `StopReason.refusal`: `.notice("The model declined to continue.")`, run completes with what exists.

### 6.7 Anchoring a quote to the PDF

Implemented by `PaperText.QuoteMatcher` (pure; built once per paper) and `PDFBridge` (geometry). The lines it works on come from §7.2, where margin numbers and page furniture have already been classified.

**What PDFKit's text looks like** on a line-numbered, double-spaced, watermarked manuscript [V, fixture `ay_nolinks.pdf`, pages 1 and 2]:

```
HerdinghasbeenstudiedextensivelysinceBanerjee[1992]andBikhchandani9
et al. [1992]. Later work extends the framework to markets [Avery and Zem-10
sky, 1998, Smith and Sørensen, 2000]. As shown by Acemoglu et al. [2011],11
…
Table 2 is 0.91 with a confidence interval that crosses one, which is difficult to14
reconcile with the claim of a robust effect. We define the office-specific iden-15
tification threshold and afterwards verify the differentiability of the payoff16
1
17
function.
In Banerjee [1992], agents observe only the actions of their predeces-18
```

So: margin numbers are glued to the **end** of most lines with no space, and stand on a line of their own before some others ("17", then "function."); tightly justified lines lose all their spaces; words are hyphenated across lines with the line number in between; the page number ("1") and, elsewhere, a watermark line sit in the middle of the text. A matcher that only collapses whitespace finds none of the test quotes [V]. The design below finds all of them [V, prototype], and a literal implementation of the folding located 42 of 43 quotes written by two local models, the 43rd being a quote the model invented [V, reviewer].

**Folding.** `fold(scalar)` maps one Unicode scalar to zero or more: apply compatibility decomposition (NFKD: `String.decomposedStringWithCompatibilityMapping`), which expands the ligatures ﬀ ﬁ ﬂ ﬃ ﬄ, maps µ (U+00B5) to μ, and turns superscript digits, full-width forms and the mathematical alphanumerics that Word-made PDFs use for italic variables into plain letters and digits; then keep each resulting scalar only if it is a letter or a digit, lower-cased. Combining marks, whitespace, hyphens and dashes of every kind, quotation marks, punctuation, symbols, soft hyphens and zero-width characters map to nothing. "office-specific", "office- specific" and "officespecific" fold to the same string; so do "identi-\nfication" and "identification".

**Index** (built in `QuoteMatcher.init(paper:)`):

- `stream`: the folded characters of every `.body` line's `contentRange` text, pages in order and lines in `PageText.lines` order, with parallel arrays giving for each folded unit its `(pageIndex, utf16Offset)` in the page string and the index of its line. Line breaks, page breaks and non-body lines contribute nothing, which is what lets a quote that crosses a page be found exactly.
- `tokens`: maximal runs of folded letters/digits with their `(pageIndex, range)`; a token that ends a line whose last non-space character is a hyphen is merged with the first token of the next line.

**`locate(quote:pageHint:)`**, first success wins:

1. If the quote contains `…`, `...` or `[...]`, split on it; treat the first and last pieces (each at least 12 folded units) as head and tail in step 3.
2. *Exact.* `q = fold(quote)`. If `q.count ≥ 12` (or `≥ 6` when a `pageHint` is given, searching only that page and its neighbours), find all occurrences of `q` in `stream`. One → match. Several → the one on the hinted page, else the one nearest to it, else the first. Confidence `.exact`.
3. *Head and tail.* If `q.count > 160` (or step 1 produced pieces): find the first 80 and last 80 units separately; choose the nearest pair with tail after head and distance at most `3 × q.count`; the match runs from head start to tail end. Confidence `.fuzzy(score: 0.9)`.
4. *Fuzzy on tokens.* Needs at least 6 quote tokens (shorter quotes are too easy to match by accident). Take the five quote tokens that are rarest in the document (length ≥ 4, not all digits, present in the document). For each occurrence of each (at most 200 candidates), form the window of document tokens that would contain the whole quote with a slack of 3 tokens before and `3 + n/4` after; score = LCS(quote tokens, window tokens) / n. Best score ≥ 0.75 with at least 5 matched tokens → match trimmed to the first and last matched tokens. Confidence `.fuzzy(score:)`. Prefer candidates on the hinted page when scores tie within 0.05.
5. Otherwise `nil`.

The match is an interval of `stream`; converting through the parallel arrays gives `spans`: **one per text line touched**, from the first to the last matched character on that line. A span never covers text between two lines.

**From spans to highlight rectangles** — `PaperService.rects(for:in:)`: for each span, for each `TextLine` of that page whose `contentRange` intersects the span (normally exactly one; a span from a user selection may cover several), take the intersection and ask PDFKit for `page.selection(for: intersection)?.bounds(for: page)`. One rectangle per line. Never pass a range that includes margin-number characters: the bounds then stretch across the page (x from −2 to 495 in the fixture) [V]; sub-ranges that exclude them are exact (x = 110.9) [V].

**Label** — `locationLabel(for:)`. Let the first and last lines touched be on pages A and B (1-based) with margin numbers a and b (`TextLine.marginNumber`, which is the line's own printed number or the ruler number level with it, §7.2).

| Case | Label |
|---|---|
| A = B, both numbers known, a = b | `p. A, line a` |
| A = B, both known, a ≠ b | `p. A, lines a–b` |
| A = B, a number unknown | `p. A` |
| A ≠ B, both known | `pp. A–B (p. A line a to p. B line b)` |
| A ≠ B otherwise | `pp. A–B` |

Dashes are en dashes. On the fixtures the Table 2 quote is "p. 1, lines 13–14" in `ay_nolinks` (its own line numbers), "p. 1, lines 47–49" in `s1_ruler` (the ruler), and "p. 1" in `ay_links` [V, prototype]. This is the form a referee writes in a report for a journal that numbers lines.

**In the engine**: `matcher.locate(quote, pageHint: page − 1)` → `Anchor(confidence: .exact/.fuzzy)` with rects and label. No match but a valid page → `.pageOnly` (label "p. N", no highlight). No match and no usable page → `.none` (the card shows "Passage not found" and a button "Attach to selection"). The quote text is always kept and shown, so the reviewer can find the passage by eye or with ⌘F. The display order of comments is defined once, on `ReviewSessionModel.visibleComments` (Appendix A.9).

Two-column pages are not re-ordered (§1.3): a quote inside one column anchors normally; one that runs from the bottom of a column into the top of the next is not contiguous in `stream` and ends up `.fuzzy` or `.pageOnly` [V, prototype: `nil` from the matcher].

### 6.8 Discussion threads

Request: paper context; then

```
The comment under discussion (location: p. 4, lines 14–16):
kind: major | category: claims
quote: …
title: …
body: …
suggestion: …

Discussion so far:
Referee: …
Assistant: …

Referee: <new message>
```

The reply streams as plain text (`ReplyEvent.textDelta`). It may end with one block, parsed by the same line rules:

```
@@REVISED
kind: minor
title: …
body:
…
suggestion:
…
@@END
```

or a line `@@WITHDRAW`. Everything before the marker is the visible reply; the block becomes `CommentRevision` (`withdraw: true` for the latter) delivered in `.finished(reply:proposal:run:)` and stored as `comment.proposedRevision`. Accepting it pushes the current version onto `previousVersions`, applies kind/title/body/suggestion, keeps the anchor and status; accepting a withdrawal sets status `.rejected`. Discarding clears it. A proposal never changes the comment by itself.

### 6.9 Questions about a selection

`ask(paper:conversation:question:context:)`. A new conversation's `anchor` is built by the model from its normalised selection (§7.4): quote = the selection's text, spans and rects as normalised, confidence `.exact`, label from the matcher. Request: paper context; "Selected passage (p. 4, lines 14–16): «…»"; transcript; the question. The reply is plain text. `ReviewSessionModel.convertReplyToComment` turns an answer into a pending user-origin comment anchored to the same selection. A question asked with no selection has `anchor == nil` and is about the whole paper.

### 6.10 The report

**Generation.** Inputs: comments with `status == .approved && includeInReport`, in the order major, minor, question, strength, each group in document order; `meta.targetVenue`; `meta.reviewerNotes`; the template. Each comment is rendered as

```
[M1] major | claims | p. 4, lines 14–16
quote: …
title: …
body: …
suggestion: …
```

with prefixes M, m, Q, S. The system prompt (Appendix B.4) fixes structure and voice: summary assessment, recommendation, publication probability, numbered major concerns, numbered minor concerns, questions for the authors; first person; no summary of the paper; no praise without content; the banned words and patterns from the user's rubric. Location labels in the report come from the app, so page and line references are real.

With zero approved comments the job does not run; the Report tab says "Approve at least one comment first."

**After generation.** `ReportDraft.recommendation` is parsed from the text under the "Recommendation" heading (first of "reject", "major revision", "minor revision", "accept", case-insensitive). The previous draft, if any, is pushed to `versions` with a note.

**Lint** (`lint(reportMarkdown:)`, deterministic, runs after generation and on every edit, debounced 0.5 s). Rules and patterns are in Appendix B.7: banned vocabulary, em dashes, "not only … but also", "serves as / stands as", trailing "-ing" clauses, "this reviewer", sycophantic opener, optimistic closer, hedge stacks, a "Strengths and Weaknesses" heading, missing required headings, and a consistency check between the recommendation and the number of major concerns. Findings are ranges in the Markdown with a rule id and message.

**Voice revision.** Optional LLM pass: sends the report and the findings with `voiceRevisionSystem`; the result replaces the draft after pushing the old one to `versions`.

**Editing.** Plain Markdown in a text editor, with a rendered preview. Edits set `userEdited`; "Regenerate" asks for confirmation when `userEdited` is true.

**Export** (`AppCore.ReportExporter`, `@MainActor`):

| Format | How |
|---|---|
| Markdown `.md` | the text as is |
| Plain text `.txt` and "Copy as plain text" | headings become their text on a line of their own followed by a blank line; emphasis markers removed; numbered lists kept; for pasting into a journal's web form |
| Word `.docx` | `NSAttributedString` built from the Markdown (headings as bold larger runs, paragraphs, numbered items), written with `documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]`. Round-trips with bold headings [V, reviewer]. |
| PDF `.pdf` | the same attributed string printed to a file with `NSPrintOperation`. Economists upload referee reports as PDFs, so this stays. |

PDF details, each verified by a test that ran through `scripts/test.sh` [V]:

1. Build the text system by hand, in TextKit 1: `NSTextStorage(attributedString:)` → `NSLayoutManager` → `NSTextContainer(size: (paperWidth − 144, .greatestFiniteMagnitude))`; `NSTextView(frame:textContainer:)`; `layoutManager.ensureLayout(for: container)`; then set the view's frame height to `ceil(layoutManager.usedRect(for: container).height)`.
2. `NSPrintInfo()`: `paperSize` = Letter (612 × 792) or A4 (595 × 842) from `PaperSize.current`, 72 pt margins, `horizontalPagination = .fit`, `verticalPagination = .automatic`, not centred, `jobDisposition = .save`, `dictionary()[NSPrintInfo.AttributeKey.jobSavingURL]` = a temporary file URL.
3. `NSPrintOperation(view:printInfo:)` with `showsPrintPanel = false`, `showsProgressPanel = false`; `run()`; read the file, delete it.

Do **not** print a plain `NSTextView(frame:)`: it lays out only what a window would show, and the resulting PDF has the right number of pages with text on the first page only (six pages, 2,077 characters on page 1, none after [V]; the reviewer's sample output has the same defect). `dataWithPDF(inside:)` gives one tall page and is not used. The print operation must run on the main thread, hence `@MainActor`; no `NSApplication` needs to be running [V].

---

## 7. PDF layer

### 7.1 Two documents per manuscript

Both are `PDFDocument(data:)` from the same bytes. The **display document** lives on the main actor inside the window's `PDFView` and carries the highlight annotations. The **extraction document** lives inside the `PDFPaperService` actor and is used for text, geometry and links off the main thread [V]. They never share objects.

### 7.2 Text extraction

**PDFKit calls that are safe to use** (index-consistent with `PDFPage.string` on macOS 26 [V]):

- `page.string`, `page.numberOfCharacters`
- `page.selection(for: NSRange)`, `PDFSelection.bounds(for:)`, `selectionsByLine()`, `numberOfTextRanges(on:)`, `range(at:on:)`, `string`
- `page.selection(for: CGRect)`, `page.selectionForLine(at:)`
- `page.annotations`, `annotation.action as? PDFActionGoTo` / `PDFActionURL`, `annotation.destination`, `annotation.url`

**Do not use** `page.characterBounds(at:)` or `page.characterIndex(at:)`: on this OS their indices do not correspond to `page.string` (24 of 25 sampled characters disagreed) [V, also reviewer].

**Raw extraction** (`PDFBridge.RawExtractor`, per page): `string = page.string ?? ""`; `whole = page.selection(for: NSRange(0, utf16Length))`; `lines = whole.selectionsByLine()`; each line's range is `range(at: 0, on: page)` with trailing newline characters trimmed, its text the substring at that range, its bounds `bounds(for: page)`. Guaranteed on every fixture and on a real 15-page paper [V]: each line selection has exactly one range, ranges increase and never overlap, and each line's text equals the substring at its range. **Not** guaranteed: the number of line selections is unrelated to the number of newline characters in `string` (a displayed equation becomes several line selections; `s1_ruler` differs on every page; the real paper on 10 of 15 pages [V]). Never pair lines with `string.split("\n")` by index.

Links: every annotation of type `Link` → `RawLink` with target from `action` (GoTo → page index and point; URL → string), falling back to `destination` / `url`; `text` = `page.selection(for: annotation.bounds)?.string ?? ""`. Outline: preorder walk of `document.outlineRoot`.

`load` fails with `PaperError.encrypted` when `isLocked` (a password is needed to open; no password UI in v1), `.empty` for zero pages, `.notAPDF` when the data does not start with `%PDF-` within the first 1,024 bytes. A PDF with an owner password and copying or printing disabled is not locked: it opens, `isEncrypted` is true, and `page.string` returns its text [V]. Such a file loads normally with `LoadedPaper.isEncrypted = true`, which only stops the file itself from being sent to a provider (§6.2).

**Cleaning** (`PaperText.PaperTextBuilder.build(from:)`, pure). Two journal styles must both work [V, prototype on both fixtures]: numbers that belong to text lines (`lineno`, Editorial Manager) and a ruler of numbers that ignores the text (ScholarOne). One rule set handles both, because PDFKit turns either into the same two things: digits glued to a text line, or a line that is only a number.

Rule for the whole builder: of a raw line's bounds use only `y` and `height`. `x` and `width` are wrong for every line that has margin digits glued to it (§6.7).

1. **Margin numbers.** For each page and each of two modes, collect candidates per non-empty line. *Trailing* mode: the run of digits at the end of the line; every suffix of that run of length 1–4 not starting with 0 is a candidate (so "…199213" can yield 13, and a line that is only "17" yields 17). *Leading* mode: a run of 1–4 digits at the start of the line that is followed by whitespace, a letter or the end of the line (not by "." or ")", which would be a list or reference number). Walk the lines in order keeping, for each value v, the longest chain ending at v where each step goes from v−1 on an earlier line to v on a later line; a line contributes at most one value to a chain. A page *qualifies* in a mode if its best chain has at least max(5, 40% of its non-empty lines) members. The document has margin numbers in a mode if at least half of its pages with ten or more lines qualify; if both modes do, take the one with more chained lines. For every chained line: `marginNumber = v`, `contentRange` = the line range without those digits and adjacent whitespace; a line left empty becomes `.marginNumberOnly`.
2. **Journal-system boilerplate**, by pattern → `.watermark`: lines matching `^(for peer review( only)?|confidential|manuscript (id|number)\b.*|click here to (download|view|access).*|powered by editorial manager.*|.*scholarone.*|electronic copy available at.*)$` (case-insensitive).
3. **Page numbers** → `.pageNumber`: the first or last remaining body line of a page that is only a number (or "Page N", "N of M", "– N –") and whose number increases by one from the previous page; and any line that is exactly "Page N of M".
4. **Repeated lines.** Normalise each remaining body line (lower-case, digits → `#`, whitespace collapsed). In documents of three or more pages, a normalised line found on at least max(3, 60% of pages) is `.runningHeader` if its vertical centre is in the top 15% of the page height, `.runningFooter` if in the bottom 15%, otherwise `.watermark` (without bounds: `.watermark`).
5. Whitespace-only lines → `.empty`; everything else `.body`.
6. **Number for lines that have none.** On each page that has `.marginNumberOnly` lines with bounds: for every `.body` line whose `marginNumber` is `nil`, find the `.marginNumberOnly` line whose vertical centre is nearest to its own; assign that line's number if the distance is at most max(0.75 × the body line's height, 0.55 × the median vertical step between the page's `.marginNumberOnly` lines when there are at least three). On a ruler page every text line thereby gets the ruler number level with it; on a `lineno` page the few lines whose number PDFKit emitted separately get theirs; table rows and equation fragments far from any number stay `nil`.
7. `hasMarginLineNumbers` = step 1 found a mode. `hasTextLayer` = at least 200 letters in the whole document. `titleGuess` = among the first 15 body lines of page 1, the consecutive lines with the tallest bounds (joined with a space); `nil` when bounds are missing.

Results on the fixtures [V, prototype]:

| Fixture | Step 1 | Other kinds | Step 6 |
|---|---|---|---|
| `ay_nolinks` | trailing mode; numbers 1–16, 17–33, 34–48, 49–54 on pages 1–4; 4 + 1 + 3 + 2 number-only lines | 4 × "CONFIDENTIAL" `.watermark`; "1" … "4" `.pageNumber` | every text line has a number except the 4 equation lines and the 5 table lines; "function." gets 17, "A Course in Game Theory. MIT Press." gets 52 |
| `s1_ruler` | 1–60 on each page, 60 number-only lines per page | "Journal of Synthetic Economics" `.runningHeader`; "Page N of 4" `.pageNumber`; the URL line `.runningFooter`; "For Peer Review" `.watermark` | "ficient in Table 2 is 0.91 …" gets 49; the abstract's first line gets 28 |
| `ay_round_nolinks`, `ay_links`, `num_links`, `num_twocol_links`, a real 15-page arXiv paper | nothing found | page numbers only | — |

`PDFPaperService` then replaces `bounds` for every line whose `contentRange` differs from `range` with `page.selection(for: contentRange)?.bounds(for: page)`. Code that needs a line's `x` (the reference list's hanging indent, §8.2) therefore runs on the finished `PaperText`, never inside the builder.

The builder is a heuristic over real-world variety. No real Editorial Manager or ScholarOne PDF has been examined (Q7): in particular, where PDFKit puts a real ruler's numbers in the text is not known. Three safety nets exist: the fuzzy matcher (§6.7 step 4) tolerates leftover digits; Settings ▸ Advanced has "Remove margin line numbers: Automatic / Never"; and `referee-cli extract --stats` shows what was detected.

### 7.3 Highlights without touching the file

Highlights are `PDFAnnotation(bounds:forType: .highlight, withProperties: nil)` objects added to pages of the **display** document, one per `PageRect`, with `userName = "referee:" + commentID.uuidString` for hit-testing (`page.annotation(at:)` returns it [V]). They exist only in memory; the document has no URL and is never written (§4.6). PDFKit draws, scrolls and zooms them, and they appear in window captures [V]. Reason for annotations over a custom overlay: correct drawing and hit-testing for free, verified to work.

`HighlightController` (main actor, `RefereeUI/Reader`) diffs the desired set against what is on the pages whenever comments, filter or selection change:

| Comment state | Colour (`Theme`) | Alpha |
|---|---|---|
| pending | yellow | 0.35 |
| approved | green | 0.30 |
| rejected | none (grey 0.15 only when "Show rejected highlights" is on) | |
| user-authored | blue | 0.30 |
| selected comment | same hue | 0.60 |
| question (conversation) anchor | purple | 0.25 |
| fuzzy anchor | same as its state, plus a 1-pt dashed border | |

Citations are **not** annotated; they are hit-tested from their rectangles (§8.6).

### 7.4 PDFKit inside SwiftUI

`ReaderController` is the only object other UI code uses to reach the PDF view; its surface is in §11.3 and is the same for every work package: `init(model:)`, `pdfView`, `attach()`, `isDocumentLoaded`, `showFind()`, `findNext()`, `findPrevious()`, `zoom(_:)`.

- **Who calls what.** `ReviewWindowController` (Shell) creates one `ReaderController` per window and calls `attach()` at once; the snapshot runner does the same for review scenes. `attach()` starts observing the model and sets `pdfView.document = PDFDocument(data: paper.data)` as soon as `model.paper` appears. The Edit menu's Find…, Find Next and Find Previous and the View menu's zoom items call the controller of the key window. Nothing else reaches into the reader.
- `RefereePDFView: PDFView` overrides `mouseDown(with:)`: convert the point to page space (`page(for:nearest:)`, `convert(_:to:)`); if it hits one of our highlight annotations → `model.readerClickedComment(id)` and continue to `super` (so selection still works); else if it lies in a citation rectangle → `model.readerClickedCitation(mentionID:)` and **do not** call `super`; else `super.mouseDown`. Returning without `super` on a hyperref link stops PDFKit's jump to the bibliography [V, reviewer]. Mouse events arrive at an internal `PDFPageView` and are forwarded to the subclass [V, reviewer].
- Cursor: override `areaOfInterest(for:)` and return `super`'s value with `.linkArea` added when the point is in a citation rectangle. PDFKit picks its cursor from that value; a cursor set in `mouseMoved` would be overridden.
- Configuration: `autoScales = true`, `displayMode = .singlePageContinuous`, `displaysPageBreaks = true`, `backgroundColor` from `Theme`.
- **Selection.** Observe `PDFViewSelectionChanged`; build a raw `SelectionInfo` with `PDFBridge.SelectionInfoBuilder.make(from:in:)` (per page: `selectionsByLine()`, one span from `range(at:on:)` and one rectangle per line); debounce 150 ms; call `model.readerSelectionChanged`. The raw selection is not fit for use: dragging from the middle of one line of `ay_nolinks` to the middle of the next gives the text `" As shown by Acemoglu et al. [2011],11\nnetwork structure determines wheth"` and a first rectangle as wide as the page (x = −2.2, width 498.4) [V, reviewer; reproduced]. The view has no `PaperText`, so the **model normalises** every selection with `SelectionNormalizer.normalize(_:in:)` (`AppCore`, pure): intersect each span with the `contentRange` of every `.body` line it touches, drop everything on lines of any other kind, rebuild `text` from the pieces (joined by a space, with the hyphen rule of §6.2), and return spans one per line. The model then asks `PaperService.rects(for:in:)` for rectangles and publishes the result as `selection`. The example becomes "As shown by Acemoglu et al. [2011], network structure determines wheth" with two rectangles that start at the text block's left edge. Ask AI, own comments, re-anchoring and the selection bar all use the normalised value.
- Commands: observe `model.readerCommand` (serial number changes): `.reveal(rects, flash)` → `go(to: rect, on: page)` with the first rectangle about one third from the top, then if `flash` add a temporary underline annotation for 0.8 s; `.goToPage`; `.clearSelection`.
- Overlays (find bar, selection bar, citation card) are SwiftUI views layered over the PDF inside `ReaderPane`, positioned from page rectangles. `pdfView.convert(_:from: page)` returns AppKit coordinates with the origin at the bottom left (`PDFView.isFlipped` is false [V, reviewer]); SwiftUI needs `y = pdfView.bounds.height − rect.maxY`. They are dismissed on scroll, page change, Esc, or a click elsewhere. Overlays rather than `NSPopover` because a popover is a separate window and the snapshot mode captures only the main window; overlays are present in the capture [V, reviewer]. The banner and the consent card are **not** in `ReaderPane`: they belong to the window's overlay, built by the Shell (§9.2).

### 7.5 Navigation both ways

- Comment → passage: selecting a card (click, J/K, Return) calls `model.revealSelectedCommentInPDF()`, which issues `.reveal(rects: anchor.rects, flash: true)`; page-only anchors issue `.goToPage`.
- Passage → comment: clicking a highlight selects its card and scrolls the sidebar to it (`ScrollViewReader`), switching the sidebar to the Comments tab. Where highlights overlap, the smallest rectangle wins.
- Window title: set `window.title` and `window.representedURL` directly; `.navigationTitle` does not reach a window created around `NSHostingController` [V].

### 7.6 Search, thumbnails, outline, zoom

- Find: `showFind()` shows a find bar over the top of `ReaderPane` and focuses its field. `PDFDocument.findString(_:withOptions: [.caseInsensitive])` on the display document for up to 5,000 results; `pdfView.highlightedSelections` shows all, `setCurrentSelection(_:animate:)` + `go(to:)` step through with `findNext()` / `findPrevious()`; the bar shows "3 of 17".
- Navigator (left column), three tabs: **Pages** (`PDFThumbnailView` bound to `controller.pdfView`, wrapped in `NSViewRepresentable`), **Outline** (`model.paper.outline` as an indented list; hidden when empty), **References** (the parsed reference list with a status icon per entry; click → `model.lookUpEntry(entryID:)`, which shows the citation card for that entry at the top of the PDF pane).
- Zoom: `zoom(.zoomIn)` / `.zoomOut` / `.fitWidth` (`zoomIn`, `zoomOut`, `autoScales = true`); pinch works natively.

### 7.7 Several documents

- Each manuscript opens in its own window with its own `ReviewSessionModel`, `ReaderController` and display document. Opening a file whose hash is already open brings that window forward.
- A cited paper opens in a **reference viewer window**: `ReferenceViewerView` (PDF, thumbnails, find, zoom; no sidebar, no AI, no session), an ordinary window whose title is the reference's title.

---

## 8. Citations

### 8.1 Model

`CitationIndex` (Appendix A.3): `style`, `entries: [BibEntry]` (the reference list, each with raw text, spans, first-line bounds and parsed surnames / year / title / DOI / arXiv id / URL), `mentions: [CitationMention]` (each in-text citation with its click rectangles and candidate entry ids). Built once per document by `CitationKit.CitationIndexer.buildIndex(paper:links:)`, pure, from the finished `PaperText` (clean line bounds) and the raw link annotations. Both detection paths below produce the same types and are merged.

Everything in §8.2–§8.5 was prototyped in Python on the real PDFKit output of the fixtures and of a real 15-page paper with 40 numeric references and hyperref links [V, prototype]. Results are in §8.5. The first version of these rules, written without a prototype, lost sentence-initial citations and could cut the list at "A Course in Game Theory. MIT Press."; the rules below replace it.

Two facts about the input shape every rule [V]. First, tightly set lines arrive **without spaces**: `TheprooffollowsBikhchandanietal.(1992)withminormodifications.` in the text and `DekelE,PiccioneM(2000)Sequentialvotingproceduresinsymmetricbinary` in the list. Second, a label or number can be a line of its own. Rules that split on spaces fail on the first; the rules below compare folded text (§6.7) wherever a name has to be recognised.

**Entry text** is built per entry from its lines: joined by single spaces, except (a) a line ending in a hyphen after a letter followed by a line starting with a lower-case letter is joined without the hyphen ("Bikhchan-" + "dani"); (b) when the last token of the text so far contains `://` or matches `^(doi:)?10\.\d{4,9}/` and ends in one of `/ - _ . = &`, the next line is appended without a space (a DOI broken at a slash: "https://doi.org/10.3115/v1/" + "D14-1179" [V]).

### 8.2 Finding and splitting the reference list

1. **Heading.** The last body line in the document that matches `^\s*(\d+\.?\s+)?(references|bibliography|works cited|literature cited|reference list)\s*\d{0,4}\s*$` (case-insensitive; the trailing digits tolerate a margin number that was not stripped). None → an empty index with `style = .unknown`; the app then intercepts no clicks, and PDFKit's own handling of link annotations still works.
2. **Style.** `NUM = ^\s*(\[(\d{1,3})\]|(\d{1,3})\.)(\s|$)`. Numeric if the first body line after the heading matches `NUM`, or at least three of the first ten do; otherwise author–year.
3. **Left edge.** Per page, `x0` = the 10th percentile of `bounds.x` over the lines after the heading on that page; a line is *at the left edge* if `x ≤ x0 + 2`. The list is *hanging* if at least 20% of the first 40 lines after the heading are not at the left edge.
4. **Entry starts**, walking the lines in order. Numeric: a line matching `NUM` whose number is the next in sequence, starting from 1 (the label may be a line of its own, with the entry's text on the next line at the same height: `[25] ` in the real paper). Author–year, hanging: every line at the left edge. Author–year, not hanging: a line that begins with an upper-case letter, follows a line ending in `.`, `)`, a digit or a URL, and is *entry-like*. A candidate start is **entry-like** if the first 240 characters of it and its next two lines contain a year `(1[89]|20)\d{2}` or one of `forthcoming`, `in press`, `n.d.`, `working paper`, `mimeo`, `unpublished`, `manuscript`.
5. **End.** Checked at every line once three entries have started; the first rule that fires ends the list before that line. Ending too early loses every later entry and with it every citation of them, so each rule needs positive evidence of a non-reference.
   - (a) *A heading.* A line of at most 60 characters, not the next numbered entry, for which one of these holds. (a1) It is set taller than the list (height at least 1.15 × the median height of the list's lines so far) **and** at least one of: it is not entry-like; it is a *keyword line* (matches `KEY` and contains no year and no comma); it matches `^[A-Z](\.\d+)?\.?\s+[A-Z]` (a lettered appendix heading). (a2) It is a keyword line **and** at least one of: it is at the left edge; the list is not hanging; heights are unknown. `KEY = ^(online |web |internet )?(appendix|appendices|supplementa(ry|l)\b.*|tables?|figures?|footnotes|endnotes)\b`. A lettered heading ("A Proofs") therefore counts only when it is visibly a heading; "A Course in Game Theory. MIT Press." and "J Polit Econ 108(1):34–55" are continuation lines in the list's own size and end nothing.
   - (b) *Back to an earlier column.* A line whose left edge is more than 40 pt to the left of the leftmost list line so far on that page. On page 2 of the two-column fixture this is where PDFKit returns to the left column after the list.
   - (c) *Ordinary text* (hanging lists only). A line at the left edge that is not an entry (numeric: not the next number; author–year: not entry-like), followed by another line at the left edge that is not an entry either. This is what ends the real paper's list at the page break before its appendix.
   - (d) The end of the document.
6. Fewer than three entries → an empty index, `style = .unknown`.
7. Per entry: `rawText` (entry text as in §8.1), `spans` per line, `firstLineBounds` from the first line, `label` = the number for numeric lists.

### 8.3 Parsing an entry

Heuristic and deliberately modest; it only has to support matching and lookup.

- `doi`: `10\.\d{4,9}/[^\s"<>]+` with trailing `.,;)` removed, lower-cased; also from a URL link annotation inside the entry (`RawLink` whose rectangle lies inside one of the entry's line bounds and whose URL contains `doi.org/`).
- `arxivID`: `arXiv:\s*(\d{4}\.\d{4,5})(v\d+)?` or `arxiv\.org/abs/([\w.\-/]+)`.
- `url`: first `https?://\S+` (text or link annotation).
- `year`, `yearSuffix`: first blank out URLs, DOIs and arXiv ids, and ignore year-like numbers that touch a page range (`\d–` before or `–\d` after) or are followed by `(` (a volume). Author–year lists: the first remaining `(1[89]|20)\d{2}` plus optional letter. Numeric lists: the last. (Without the blanking, "arXiv:1810.04805" yields the year 1810 [V, prototype].)
- `authorSurnames`: the text before the year (author–year) or before the first period that follows a lower-case letter or closing quotation mark (numeric), with "et al." and what follows removed. Split on `,`, `;`, ` and `, ` & `. For each piece, in this order: only initials (`^([A-Z]\.?[\s-]*){1,4}$`) → drop; a capitalised word followed, with or without a space, by one to three capitals ("Dekel E", "Lee J.", and the space-less "DekelE") → the word (Springer style); otherwise the last word, joined with a preceding particle (`van`, `von`, `de`, `del`, `della`, `di`, `da`, `la`, `le`, `ten`, `ter`, `der`, `den`).
- `title`: author–year → the sentence after the year; numeric → the sentence after the authors. Stripped of quotation marks.

### 8.4 In-text citations from text patterns

Searched in the body text outside the reference list: the body lines before the heading and after the list's end, as one character sequence with a line break between lines and a map from every character to `(pageIndex, utf16Offset)`.

**Numeric.** `\[(\d{1,3}(\s*[-–]\s*\d{1,3})?(\s*[,;]\s*\d{1,3}(\s*[-–]\s*\d{1,3})?)*)\]`. Accept only if the list is numeric and every number is at most the entry count. **One mention per number or range inside the brackets**, so that each number is its own click target, as it is in a hyperref PDF: "[1, 5, 3]" gives three mentions; a range gives one mention whose `entryIDs` are expanded ("[3–5]" → 3, 4, 5).

**Author–year: the reference list decides.** A citation is recognised by a year that an entry has, preceded by that entry's authors. Nothing is assumed about the words before the authors, so "In Banerjee (1992)", "The Avery and Zemsky (1998) model", "See Lee (2021)" and "Following Smith and Sørensen (2000)" need no special case.

1. **Author keys** per entry, from its folded surnames s1 … sn: one author → `s1`; two → `s1` + `and` + `s2`, and `s1` + `s2` (for "&"); three or more → `s1` + `etal`, `s1 s2 … and sn`, and `s1 s2 … sn`. If s1 has a lower-case particle, also every key without it.
2. Find every year `(?<!\d)(1[89]|20)\d{2}[a-z]?(?!\d)` in the text. Entries with that year are the candidates (when the year has a letter suffix and some candidate has one, the suffixes must match).
3. **Left context.** Walk left from the year, folding as you go and skipping everything that folds to nothing (brackets, commas, spaces, line breaks, hyphens), for up to 120 folded characters. Then strip any trailing years from the folded string (so "Smith (2019, 2021)" gives the second year the same authors). If the raw text just before the year ends in `'s` or `’s` ("Banerjee's (1992)"), also try the string without its final `s`.
4. A candidate **matches** if the folded left context ends with one of its keys **and** the raw character where the key begins is an upper-case letter or follows a non-letter. The second condition is what keeps "employee (2021)" from matching Lee (2021) while still accepting `followsBikhchandanietal.(1992)`, where no space precedes the name.
5. The longest matching key wins; entries that tie are all candidates (`entryIDs`). The mention runs from the raw character where the key begins to the end of the year; its `spans` are one per line touched, its `text` the characters in between with line breaks as spaces. No match → not a citation of this list.

Both bracket styles and both separators work without separate rules: "(Smith et al., 2020; Lee, 2021)", "[Avery and Zemsky, 1998, Smith and Sørensen, 2000]", and "(Smith and Sørensen, 2000, p. 12)".

Text-pattern mentions come back with `spans` and empty `rects`; `ReviewSessionModel` fills `rects` with `PaperService.rects(for:in:)` right after indexing.

### 8.5 In-text citations from link annotations

For every `RawLink` with `.internalDestination(pageIndex, x, y)`:

- It is a citation link only if the destination page holds lines of the reference list and `y` lies between the bottom of the lowest and 30 pt above the top of the highest list line on that page. Other internal links (equations, tables, sections, footnotes) are ignored; PDFKit handles them as usual because they are not in our hit-test set.
- Target entry: among the entries whose first line is on the destination page, keep those whose `firstLineBounds.x` is within 60 pt of the destination `x` (this separates the columns of a two-column list; if none qualifies, keep all). Of those, choose the entry whose first-line top edge (`y + height`) is the highest one that is still at or below `y + 4`; if no top edge is below the destination, choose the nearest. Reason: a hyperref destination sits at, or a few points above, the first line of its entry. `selectionForLine(at:)` at the destination found the right line for a single-spaced numeric list but returned nothing for a double-spaced author–year list, so a point lookup is not enough [V].
- Mention rectangle = the annotation bounds; text = the link's text.
- **Merging pieces** (author–year lists only; in a numeric list every link is a whole citation). natbib links author and year separately and splits links at line breaks: "Avery and Zem-" / "sky" / "1998" [V]. Consecutive links with the same target on the same page are one mention while each new piece continues the last (same line with a gap under 12 pt, or the next line down starting further left) **and the mention is not closed**; a piece whose text is just a year closes it. So "Kogan [2020], Lee [2021]" and two citations of one paper on consecutive lines stay separate.

**Merge of the two paths.** Per page and per entry, the k-th link mention of that entry is paired with the k-th text mention that lists it as a candidate; the pair becomes one mention with the link's target and rectangles and the text mention's `text` and `spans`. Unpaired mentions of either kind are kept. Result sorted by page and position (text offset when known, else top-to-bottom, left-to-right of the first rectangle), ids reassigned 0…n−1.

Prototype results [V, prototype]:

| Document | Style, entries | Text mentions | Link mentions | The two paths |
|---|---|---|---|---|
| `ay_round_nolinks`, `s1_ruler` | author–year, 9 | 15 | — | — |
| `ay_nolinks` (clean bounds) | author–year, 9 | 15 | — | — |
| `ay_links` | author–year, 9 | 15 | 15 (from 34 pieces; 2 other internal links ignored) | same targets, same order |
| `num_links` | numeric, 5 | 10 | 10 | same |
| `num_twocol_links` | numeric, 5 | 10 | 10 | same |
| real arXiv paper, 15 pages | numeric, 40 | 76 | 76 (19 other internal links ignored) | same |

### 8.6 Clicking a citation

`RefereePDFView.mouseDown` hit-tests the mention rectangles of the clicked page (expanded by 2 pt). A hit calls `model.readerClickedCitation(mentionID:)`, which sets `citationLookup = .resolving(target: .mention(id))` and starts resolution of each candidate entry; the reader shows the **citation card** overlay next to the mention (for `.entry` targets, chosen in the References list: at the top of the PDF pane):

- header: the mention text; for each candidate entry: the raw reference text (up to four lines), then resolved title, authors, year, venue when available, a badge "Open access" when a PDF URL was found, and "year differs: the list says 2019, this record 2022" when the two years are both known and unequal;
- buttons: **Open PDF** (enabled when `openAccessPDFURL != nil`; downloads then opens the reference viewer), **Open in Browser** (`landingURL`, else the DOI URL, else the entry's URL), **Copy DOI**, **Search Google Scholar** (always available; `ReferenceResolving.searchURL(for:)`), **Show in References** (selects the entry in the navigator);
- states: resolving (spinner beside the raw text, which is shown immediately), resolved, not found ("No match found" with Search Google Scholar), failed ("Lookup failed: <reason>", Retry).

A mention with no candidate entries shows its text and Search Google Scholar only.

### 8.7 Resolving a reference (`ScholarKit.ReferenceResolver`)

Lookups happen **only when the user clicks** (default). Reason: each lookup discloses one reference string of a confidential manuscript to a third party; a click is a deliberate act. Settings ▸ References offers "Look up all references when a document opens" (off).

Order, stopping at the first step that yields a DOI, arXiv id or PDF URL and passes validation:

| Step | Condition | Request | Notes |
|---|---|---|---|
| 0 | cache hit | — | `sessions/<sha256>/references.json` of the document being reviewed; key = SHA-256 of the folded `rawText`; resolved entries kept 180 days, `notFound` 30 days, `failed` never cached. Deleted with the review (§4.2). |
| 1 | entry has an arXiv id | none | `landingURL = https://arxiv.org/abs/<id>`, `openAccessPDFURL = https://arxiv.org/pdf/<id>`; confidence 1.0 |
| 2 | entry has a DOI | `GET https://api.openalex.org/works/doi:<doi>?select=id,doi,title,publication_year,authorships,primary_location,open_access,best_oa_location` | free, no key, no email [V: `x-ratelimit-cost-usd: 0`]; PDF from `best_oa_location.pdf_url`, else `open_access.oa_url` when it ends in `.pdf`; landing `https://doi.org/<doi>`; 404 → keep the DOI, no metadata |
| 3 | no identifier | `GET https://api.crossref.org/works?query.bibliographic=<rawText, first 300 chars>&rows=3&select=DOI,title,author,issued,container-title,score,type` (+ `&mailto=<address>` only if the user set one) | validate (below); on success continue with step 2 for open-access data [V: returns the right DOI for a test reference] |
| 4 | still nothing | none | `notFound`; the card offers Search Google Scholar |

Open-access PDF links come from OpenAlex and, by construction, from arXiv ids. Crossref is used for identification only. Nothing else is called: Semantic Scholar answers keyless requests with HTTP 429 [V, reviewer], OpenAlex's search endpoint is budgeted per day [V], and Unpaywall needs an email address and now serves the same data as OpenAlex [D].

**Validation of a Crossref candidate**: the folded first-author surname equals the entry's, and at least 60% of the candidate title's words (length ≥ 4) occur in the entry's `rawText`. If the years differ by more than one, the title share must be at least 85%: in economics the working paper an author cites and the published version are often three to five years apart, and a strong title match with the right first author is the same paper. Confidence = 0.5 + 0.5 × the title share. A candidate that fails is discarded; if all fail → `notFound`.

**Politeness and limits** (one token bucket per host inside the actor):

| Host | Limit used | Source |
|---|---|---|
| api.crossref.org | 1 request/s, 1 at a time; with `mailto` 3 requests/s, 3 at a time | public pool: `x-rate-limit-limit: 1`, `x-rate-limit-interval: 1s`, `x-concurrency-limit: 1` [V]; polite pool [D] |
| api.openalex.org | 5 requests/s | 10/s without a key [D] |

A 429 or 5xx is retried once after `Retry-After` (or 2 s); a second failure makes the lookup `failed`. `User-Agent: Referee/<version>`; the address is appended as `(mailto:<address>)` only when the user set one. No request carries anything but the reference text or identifier.

**Fetching the PDF** (`fetchPDF`): `https` only (an `http` URL is offered as "Open in Browser" instead); follow redirects; stop at 100 MB; accept only if the body starts with `%PDF-`; store as `~/Library/Caches/Referee/papers/<sha256(url)>.pdf`; evict least-recently-used files beyond the cache limit. arXiv's terms allow retrieving e-prints for personal use and forbid re-serving them [D]; the cache is local and private.

**Manual fallback**: `searchURL(for:)` = `https://scholar.google.com/scholar?q=<percent-encoded title, or first 200 characters of rawText>`, opened in the default browser. No API involved. On an actor it is declared `nonisolated` (the protocol requirement is synchronous).

---

## 9. UI/UX specification (first version; a designer will refine it)

### 9.1 App shell

AppKit owns the lifecycle and the windows; every window's content is SwiftUI in an `NSHostingController`. Reason: the snapshot mode that lets agents see the UI was verified with exactly this construction, including a three-column layout with a trailing inspector, toolbar items, PDF highlights and overlays [V, also reviewer]; and opening files from Finder, several document windows and explicit window titles are direct in AppKit.

`AppMain.run` (declared in §11.3) is the one entry point. It is not `@MainActor`: top-level code in `main.swift` is not main-actor-isolated in Swift 5 mode, so a `@MainActor` entry point does not compile there [V]. Its body is `MainActor.assumeIsolated { start(makeDependencies) }`; `environmentOverrides` are merged over the process environment (the snapshot mode passes `REFEREE_HOME`, `REFEREE_SNAPSHOT` and `REFEREE_NO_KEYCHAIN`).

`Sources/Referee/main.swift` is exactly this (compiles and runs in this shape [V]):

```swift
import Foundation
import RefereeUI
import Composition
AppMain.run { overrides in
    await LiveDependencies.make(environment: ProcessInfo.processInfo.environment.merging(overrides) { _, new in new })
}
```

Panes never reach into the shell. What they need from it is passed down through the SwiftUI environment (compiles as printed [V]):

```swift
// RefereeUI/Common/CommonUIActions.swift (Wave 0, frozen)
public struct UIActions {
    public var openReferenceViewer: @MainActor (_ fileURL: URL, _ title: String) -> Void = { _, _ in }
    public var openSettings: @MainActor () -> Void = {}
    public var openInBrowser: @MainActor (URL) -> Void = { _ in }
    public init() {}
}
private struct UIActionsKey: EnvironmentKey { static let defaultValue = UIActions() }
public extension EnvironmentValues {
    var uiActions: UIActions { get { self[UIActionsKey.self] } set { self[UIActionsKey.self] = newValue } }
}
```

The shell sets real closures with `.environment(\.uiActions, …)` on every window's root view; the defaults do nothing, which is what the snapshot mode uses. Everything else flows through `ReviewSessionModel` and, for find and zoom, `ReaderController`.

- `AppDelegate`: builds the main menu; at launch creates the `SettingsModel`, hands it to `WindowManager`, and calls `applyFirstRunDefaultsIfNeeded()` once; `application(_:open:)` forwards file URLs to `WindowManager.openReview(url:)`; `applicationShouldTerminateAfterLastWindowClosed` → false; on terminate, flushes every model's pending save.
- `WindowManager` (main actor): `openReview(url:)` (one window per document hash; brings an existing one forward), `openReferenceViewer(fileURL:title:)`, `showSettings()`, `showWelcome()`. It holds the app's one `SettingsModel`, observes `Notification.Name.refereeSettingsDidChange`, and on each notification calls `reloadSettings(settingsModel.settings)` on every open `ReviewSessionModel`. Review windows: 1280 × 800 default, 1000 × 640 minimum, `styleMask` titled, closable, resizable, miniaturizable, `fullSizeContentView`; frame autosaved per document hash.
- `ReviewWindowController`: owns one `ReviewSessionModel` and one `ReaderController` per window, calls `reader.attach()` right after creating it, installs the key monitor (§9.4), sets the title, and flushes on close.
- **Main menu** (built in code with `NSMenu`; SwiftUI `.commands` is not used):

| Menu | Items (key) | Calls |
|---|---|---|
| Referee | About, Settings… (⌘,), Hide, Quit (⌘Q) | `WindowManager.showSettings()` |
| File | Open… (⌘O), Open Recent ▸, Close (⌘W), Export Report… (⇧⌘E), Delete Review Data… | `openReview(url:)`; `model.exportReport`; after confirmation `model.deleteReviewData()`, then the window closes |
| Edit | Undo, Redo, Cut, Copy, Paste, Select All (standard selectors, so text fields work); Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G) | `reader.showFind()`, `findNext()`, `findPrevious()` of the key window |
| Review | Run Review (⌘R), Cancel (⌘.), Generate Report (⇧⌘R), Approve, Reject, Discuss, Edit, Next Comment, Previous Comment, New Comment (the single-key shortcuts of §9.4 are shown as hints but handled by the key monitor) | model methods |
| View | Comments (⌘1), Chat (⌘2), Report (⌘3), Toggle Navigator (⌃⌘S), Toggle Sidebar (⌥⌘0), Zoom In (⌘+), Zoom Out (⌘−), Fit Width (⌘0) | `model.sidebarTab`; `reader.zoom(_:)` |
| Window | standard | |
| Help | Referee Help (opens README) | |

- **Welcome window** (shown at launch when no document is opened): "Open PDF…" button, drop target, list of recent reviews from `SessionStoring.listSessions()` (title, file name, date, "12 comments · 3 pending"), and a provider status line ("AI: Local · gemma4:e4b" or "No AI provider set up — Open Settings").

### 9.2 Review window

```
┌ toolbar ───────────────────────────────────────────────────────────────────────────────────────────────┐
│ [navigator]   <file name>      ( ⌂ Local · gemma4:e4b ▾ )                 [▶ Review] [Report] [sidebar] │
├──────────────┬───────────────────────────────────────────────┬─────────────────────────────────────────┤
│ Pages|Outline│  banner (Shell)                               │  Comments | Chat | Report               │
│ |References  │   PDF  (highlights; Reader overlays: find     │  filter chips · "12 of 31 decided"      │
│              │   bar, selection bar, citation card)          │  comment cards …                        │
│ thumbnails   │                                               │                                         │
│ 160–240 pt   │   flexible, no minimum                        │  320–520 pt, ideal 380                  │
└──────────────┴───────────────────────────────────────────────┴─────────────────────────────────────────┘
        consent card and destination menu: Shell overlays over the whole window
```

Structure (verified to render in a hosted window [V]):

```swift
// ReviewWindowView (RefereeUI/Shell):
// NavigationSplitView { NavigatorPane(controller: reader) }
//   detail: { VStack(spacing: 0) { BannerView(model: model); ReaderPane(controller: reader) } }
//   .inspector(isPresented: $showSidebar) { ReviewSidebar(model: model).inspectorColumnWidth(min: 320, ideal: 380, max: 520) }
//   .toolbar { … }
//   .overlay { ConsentCard(model: model) }          // and the destination menu
```

Who draws what: the **Reader** draws the PDF and the three overlays tied to positions in it (find bar, selection bar, citation card). The **Shell** draws everything tied to the window: toolbar, banner (above the PDF, inside the detail column), consent card and destination menu (over the whole window). The **Sidebar** draws the inspector's content. No pane draws another's parts.

Widths: `ReaderPane` declares no minimum width, and nothing else in the detail column does either. With `.inspector` attached to the `NavigationSplitView`, SwiftUI on macOS 26 adds the inspector's width to whatever minimum the detail column declares: `.frame(minWidth: 480)` on the PDF makes the smallest possible window 1448 pt wide, so a review window could be neither 1280 nor 1000 pt wide [V, WP0b]. The window's 1000 × 640 minimum (§9.1) is what keeps the PDF readable; at that size the three columns are 208, 412 and 380 pt. A snapshot scene whose window does not keep the size it was given fails (§10.1), so a pane that brings the problem back is caught.

Toolbar, left to right: navigator toggle; the **destination indicator** (principal position, §9.7); Review button (label "Review", becomes "Cancel" with a spinner and the phase text "Reading part 2 of 5…" while running; disabled with a tooltip when `model.canStartReview` is false, the tooltip being `sendPlan.blockingReason` when there is one); Report button (switches the sidebar to Report); sidebar toggle. Toolbar buttons that must show their word use `.labelStyle(.titleAndIcon)`: on macOS 26 a `Button("Review", systemImage:)` in a toolbar shows the icon alone [V, reviewer].

### 9.3 Sidebar: Comments tab

Header: filter chips `All · Pending · Approved · Rejected · Major · Minor · Questions`; a thin progress bar with "12 of 31 decided"; a "+" button (new own comment). List: `ScrollView` + `LazyVStack` of cards in the order of `model.visibleComments` (defined once, in Appendix A.9). While a review streams, drafts appear at the end under "Writing…" and move into place when finished.

Card anatomy:

```
┌───────────────────────────────────────────────────────┐
│▌MAJOR  Claims vs. evidence            p. 4, lines 14–16 │   kind badge · category · location (click → reveal)
│ Abstract claims more than Table 2 supports              │   title
│ “The effect is statistically significant but …”         │   quote: italic, secondary colour, 2 lines
│ The abstract calls the effect robust. Table 2 reports … │   body: 6 lines, then "more"
│ Suggestion: report the interval in the abstract.        │
│ [✓ Approve] [✕ Reject] [Discuss] [Edit]            ⋯    │   ⋯: change kind, exclude from report, delete, attach to selection
└───────────────────────────────────────────────────────┘
```

| State | Appearance and behaviour |
|---|---|
| draft (streaming) | title and body grow as text arrives; badge shows once `kind` is known; no buttons; pulsing left bar |
| pending | yellow left bar; all four buttons |
| approved | green left bar and check mark; buttons become Undo, Discuss, Edit |
| rejected | collapsed to one grey line (kind, title); Undo on hover or selection |
| similar (`similarTo` set, still pending) | collapsed to two lines: kind and title, then "Similar to: <title of the other comment>" (click selects that one); expands on click or selection into the normal pending card |
| selected | accent-colour outline; PDF scrolled to the passage; highlight at higher opacity |
| editing | title field, body editor, suggestion editor, kind picker, category picker; Save (⌘↩) / Cancel (Esc) |
| discussion open | thread under the card: messages (reviewer right-aligned, assistant left), streaming reply, input field with Send (⌘↩); while a reply streams, Send is disabled and a Stop button shows |
| proposed revision | box under the thread: "Proposed revision" with the new kind, title, body (or "Proposes withdrawing this comment"); Accept / Discard |
| fuzzy anchor | "≈" beside the location, tooltip "Approximate match" |
| page-only anchor | location "p. 4" with a dotted underline; tooltip "Passage not located on the page" |
| unanchored | warning glyph, "Passage not found"; button "Attach to selection" (enabled when the PDF has a selection) |
| own comment | blue left bar, "You" badge instead of the category when category is `other` |
| AI comment in category `literature` | a small "verify" tag beside the category: the model cannot look references up, so any paper it names must be checked |
| reply failed | red inline line under the thread with the error message and Retry |

New own comment ("+", N, or Comment in the selection bar → `model.beginComposingComment()`): while `model.composing != nil` an editing card sits at the top of the list, anchored to the selection captured in `composing.selection` (shown as its quote), kind default minor; Save calls `addUserComment(…)` (status approved), Cancel calls `cancelComposing()`.

### 9.4 Keyboard triage

A local `NSEvent` key-down monitor installed by `ReviewWindowController` handles these keys **only when** the window is key and the first responder is not a text-editing view (`NSTextView`, field editor). The mapping and its application to the model are two functions (`TriageKeymap.intent`, `TriageKeymap.apply`, §11.3), unit-tested, and exercised together by an integration scene (§10.1).

| Key | Action |
|---|---|
| J | next comment in the visible list (selects, scrolls sidebar and PDF) |
| K | previous comment |
| A | approve; then, if "Advance after decision" is on (default), select the next pending comment |
| R or X | reject; then advance |
| U | back to pending |
| D | open the discussion and focus its input |
| E | edit |
| Return | reveal the passage in the PDF again |
| N | new own comment |
| 1 2 3 4 | set kind: major, minor, question, strength |
| Esc | close the open overlay, editor or thread; then clear the selection |

Intent → model call (`TriageKeymap.apply`): `next` → `selectNextComment(pendingOnly: false)`; `previous` → `selectPreviousComment()`; `approve` / `reject` / `resetStatus` → `setStatus(_:for: selectedCommentID)`; `discuss` → `openThreadCommentID = selectedCommentID`; `edit` → `editingCommentID = selectedCommentID`; `reveal` → `revealSelectedCommentInPDF()`; `newComment` → `beginComposingComment()`; `setKind(k)` → `setKind(k, for:)`; `dismiss` → `dismissTransientUI()`. The sidebar reacts to those properties (expands the thread and focuses its input, shows the editor, shows the composing card).

Modified keys go through the menu: ⌘R, ⌘., ⇧⌘R, ⌘F, ⌘G, ⌘1–3, ⌘+, ⌘−, ⌘0. In any text input ⌘↩ sends or saves.

### 9.5 Selection bar, Chat tab, citation card

- **Selection bar**: appears 6 pt above the first rectangle of `model.selection` (the normalised selection, §7.4) when its text has at least three characters, 200 ms after it settles: `[Ask AI] [Comment] [Copy]  [▾ quick questions]`. Ask AI expands the bar into a text field (placeholder "Ask about this passage…", Return sends); the question and its streaming answer then live in the Chat tab, which opens. Quick questions come from `PromptSet.quickQuestions` and send immediately. Comment calls `model.beginComposingComment()` and switches the sidebar to Comments. Copy puts the normalised text on the pasteboard.
- **Chat tab**: conversations newest first. Each: the quoted passage (click → reveal), location label, messages, streaming answer, a follow-up field, and per answer "Make comment ▾" (kind) and Copy. At the bottom of the tab a field "Ask about the paper…" starts a conversation with no selection. Empty state: "Select text in the PDF and choose Ask AI."
- **Citation card**: §8.6. Anchored below the mention, or at the top of the PDF pane for an entry chosen in the References list; 360 pt wide.

### 9.6 Settings window (780 × 560, tabs)

- **Providers.** Three groups: *API key* (Anthropic, OpenAI, Gemini, xAI), *Subscription through an installed CLI* (Claude Code, Codex, Antigravity, Grok Build), *Local* (Ollama). Each row: enable switch; status from `availability()` with a coloured dot (green ready, yellow needs setup with the hint, red unavailable with the reason, which for a CLI can be a missing safety flag, §5.6.1); for API providers a secure key field that only accepts input ("•••• stored" when set, Replace, Remove); model picker filled from `listModels()` with a refresh button, "Show all" where a filter applies, and "Custom…" for a typed id; for CLIs the detected path and version, a path override field, the install command with a Copy button and the sign-in command to run in Terminal. An experimental provider with no `verifiedAt` shows, in orange under its name, "Experimental — not yet verified against the real CLI on this machine". Advanced disclosure per provider: base URL, context window override, max output tokens, input mode (Automatic / Text / PDF), extra arguments (CLI) or extra body JSON (API; for Ollama it holds `{"think": false}` by default). "Send test prompt" button with the note "sends 'Reply with exactly: OK'; uses a few tokens"; success stores `verifiedAt` and removes the experimental warning. Below the list: default provider pickers for Review, Chat and Report (Chat and Report default to "Same as Review").
- **Prompts.** Editors for `reviewSystem`, `discussionSystem`, `questionSystem`, `reportSystem`, `reportTemplate`, `voiceRevisionSystem`; the rubric table (enabled, id, name, guidance; add, remove); the quick questions list; the fixed output-format text (`FormatSpec.review`) shown read-only with the note "The app parses this format; it cannot be edited"; "Restore defaults".
- **Privacy.** "Local only" switch; "Ask before the first send of each document" (on); the data folder path with Reveal in Finder; "Delete all review data…"; a plain-language summary of §12.3 and §12.5.
- **References.** "Look up references only when I click them" (on); Crossref contact email (empty; note: "optional; gives faster lookups"); PDF cache size and Clear.
- **Advanced.** "Remove margin line numbers from extracted text: Automatic / Never" (applies to documents opened afterwards); "Advance to the next comment after a decision"; "Show highlights of rejected comments".

### 9.7 The destination indicator and consent

The indicator is always visible in the toolbar and is the only place the destination is chosen per document.

| Situation | Icon and text | Tint |
|---|---|---|
| local provider | laptop, "Local · gemma4:e4b" | green |
| API provider | cloud, "Anthropic API · <model>" | orange |
| CLI provider | terminal, "Claude Code · default" | orange |
| any provider when `sendPlan.sendsPDF` is false and the provider is not local | the above plus " · text only" | orange |
| experimental provider without `verifiedAt` | the above plus " · experimental" | orange |
| nothing ready | slashed circle, "No AI provider" (click opens Settings) | grey |
| Local-only is on and a remote provider is selected | lock, "Remote blocked (Local only)" | red |

Clicking it opens a menu-style overlay: the enabled providers (choose one; stored as `session.preferredProvider`); the current `SendPlan` in words; the provider's `retentionNote`; the "Local only" switch; "Privacy settings…". The plan sentence is built from `SendPlan` and the descriptor:

- PDF: "A review will send the PDF file in 1 request, about 153,000 tokens, to api.anthropic.com." followed by `descriptor.pdfDeliveryNote` in brackets when it is set ("(sent as page images)").
- Text: "A review will send the extracted text in 3 requests, about 61,000 tokens, to 127.0.0.1:11434. **Extracted text only: equations and tables may reach the model garbled.**" The second sentence is fixed and appears whenever `sendsPDF` is false, for every provider.
- `warnings` follow, one per line; `blockingReason`, if any, replaces all of it in red.

**Consent card** (Shell overlay that blocks the window until answered), shown before the first request of any kind that would send this document to a non-local provider not yet in `session.consents`, when "Ask before the first send" is on:

```
Send this manuscript to Anthropic?
The PDF file (2.1 MB, 34 pages) will be sent to api.anthropic.com in 1 request (about 153,000 tokens).
Later questions, discussions and the report will send it again to the same provider.
Check the journal's policy on AI tools before sending a manuscript under review.
[ ] Ask again next time                                   [Cancel]  [Send]
```

For a text-mode plan the second line reads "The extracted text (34 pages) will be sent to … Extracted text only: equations and tables may reach the model garbled." For a CLI provider one more line states what §12.5 says about that CLI in a sentence (`retentionNote`). Send records a `ConsentRecord` (unless "Ask again" is ticked) and starts the job; Cancel leaves everything untouched. With "Local only" on, non-local providers cannot be selected and any job addressed to one fails immediately with a banner.

`retentionNote` texts: Anthropic API "Sent to Anthropic under your API account's data terms."; OpenAI "Sent with store=false; not kept for retrieval by the API."; Gemini "Sent with store=false."; xAI "Sent to an endpoint that does not store requests."; Ollama "Processed on this Mac; nothing is sent." (or "Sent to <host> on your network." for a non-loopback base URL); Claude Code "Runs through your Claude Code login with its tools switched off; no session transcript is saved."; Codex "Runs through your ChatGPT plan with shell and agent tools switched off; session files are not kept."; Antigravity "Runs through your Google account. Its tools cannot be switched off: Referee stops the run if it uses one. The CLI may keep a local conversation record."; Grok Build "Runs through your xAI account with tools denied. The CLI saves each conversation in ~/.grok and may sync it to your account; Referee deletes the local copy after each run."

### 9.8 Report tab

Top: Target venue field (`meta.targetVenue`), "Notes for the report" field (`meta.reviewerNotes`), the count "8 approved comments (3 major, 4 minor, 1 question)". Buttons: Generate (or Regenerate), Revise voice, Versions ▾, Export ▾ (Copy as plain text, Copy Markdown, Markdown file…, Text file…, Word document…, PDF…). Body: a plain-text Markdown editor (13-pt system font, comfortable line spacing) with a Preview toggle (rendered with `AttributedString(markdown:)`); while a report or voice revision streams it shows `model.streamingReportText`, read-only. Under it a collapsible "Style check" list of lint findings (rule, message; clicking selects the range) and the recommendation picker (Accept / Minor revision / Major revision / Reject) prefilled from the text, with the consistency warning when it disagrees with the concerns.

### 9.9 States

| Area | Empty | Loading / streaming | Error |
|---|---|---|---|
| Window, no document | welcome content inside the window | "Opening <file>…" with a progress indicator | "This file could not be opened: <reason>" and "Open another…" |
| PDF with no text layer | — | — | yellow banner: "This PDF has no text layer. Comments can be tied to pages only, and only providers that accept PDF files can review it." |
| Protected PDF | — | — | info banner: "This PDF is protected. Its text is readable, so reviews send the text, not the file." |
| Comments tab | "No comments yet. Run a review (⌘R) or add your own (N)." | drafts under "Writing…"; phase text in the toolbar | banner "Review stopped: <message>" with Retry; comments received so far stay |
| Comment thread | — | streaming reply bubble | inline error with Retry |
| Chat tab | hint text (§9.5) | streaming answer | inline error with Retry |
| Report tab | "Approve at least one comment, then generate the report." | text streams into the editor (read-only until finished) | banner with Retry; previous draft kept |
| Citation card | — | raw reference text + spinner | "No match found" / "Lookup failed" with Search Google Scholar and Retry |
| Provider row | "Not set up" + hint | "Checking…" | red dot + reason |
| Any job, provider missing or blocked | — | — | banner "Set up an AI provider" (Open Settings) or "Remote providers are blocked by Local only" |

The banner (`BannerView`, Shell) sits above the PDF in the detail column, one at a time, dismissible; errors stay until dismissed, notices fade after 6 s.

### 9.10 Shared theme (`RefereeUI/Common/CommonTheme.swift`, written in Wave 0, frozen)

Kind colours: major red, minor grey, question purple, strength teal. Status colours: pending yellow, approved green, rejected grey, own blue. Highlight colours and alphas as in §7.3. Card corner radius 8, card padding 10, list spacing 10, sidebar padding 10. Fonts: system; card title `.headline`, body `.callout`, quote `.callout.italic()`, metadata `.caption`. Light and dark appearance both supported through semantic colours. The public surface of `Theme` is printed in §11.3.

---

## 10. Self-verification hooks

The building agents cannot see the screen and may lack screen-recording permission. These hooks are how they check their own work.

### 10.1 UI snapshot mode

```
Referee --ui-snapshot <outDir> [--scene <name>]… [--dark] [--size 1280x800]
```

Mechanism, verified end to end on this machine without any Screen Recording permission [V, also reviewer], as `RefereeUI/Common/CommonSnapshotRunner.swift` implements it (Wave 0b; the comment at the top of that file lists the same decisions):

1. `NSApplication.shared.setActivationPolicy(.accessory)`; create a fresh temporary directory for the run, removed at its end. **Each scene gets a data folder of its own** in it (named after the scene) and a dependency graph of its own, so that no scene sees what an earlier one saved and no picture depends on which scenes ran before it. For each scene: write `SnapshotSupport.settings()` into its folder as `settings.json` (the four mock providers enabled, `mock` the review default) and build the dependencies with the overrides `REFEREE_HOME=<that folder>`, `REFEREE_SNAPSHOT=1` and `REFEREE_NO_KEYCHAIN=1`; the same settings are also saved through `dependencies.settings`, and the scene's models are created with them. `LiveDependencies.make` sees `REFEREE_SNAPSHOT` and builds the whole graph, **the engine included**, on `SnapshotSupport.providers()` and `FakeResolver()` (§11.3). A snapshot run therefore starts no process and makes no network request, and the engine and the model agree on which providers exist. Nothing of the user's is read or written.
2. If the scene names a `fixtureSession` (it must then name a `fixturePDF` too), copy that file to `<home>/sessions/<sha256>/session.json`, where the hash and `byteCount` are computed from the fixture PDF as it is on disk right now and written into the copy's `document` (a rebuilt fixture has a different hash). Create the window as the app does, with an `NSHostingController(rootView: …)` as its content view controller; `window.appearance` forced to aqua (or dark aqua); content, size, style and title as in the table below; then `orderFrontRegardless()`. The window is a private subclass of `NSWindow` that overrides one method, `constrainFrameRect(_:to:)`, to return the frame unchanged: a plain window is cut down to the visible part of the screen when it is shown (a scene of 1500 × 1000 came out 1500 × 828 on a display with 828 points between menu bar and Dock), and a scene must have its size on any display. It is placed where AppKit puts a plain window sent to (−6000, −6000): only its top right corner, 40 × 74 points, lies inside the bottom left of the main screen, and the capture is complete [V, reviewer; WP0b], so a snapshot run does not flash windows over the user's work. In a review scene the runner then calls `reader.attach()`, opens the `fixturePDF` with `model.open(url:)`, and waits until the reader shows the display document (three seconds at most), so that `prepare` can use the PDF view at once.

   | Kind | Window content | Content size (points) | Style mask | Title |
   |---|---|---|---|---|
   | `review` | `ReviewWindowView` on a new `ReviewSessionModel` and its `ReaderController` | 1280 × 800, or `--size` | titled, closable, resizable, miniaturizable, full-size content view (§9.1) | the `fixturePDF` file name, or "Referee" |
   | `referenceViewer` | `ReferenceViewerView(fileURL:title:)` on the `fixturePDF`, which this kind requires | 900 × 700, or `--size` | as `review` | the file name without its extension |
   | `settings` | `SettingsRootView` on a new `SettingsModel` | 780 × 560 | titled, closable, miniaturizable | "Settings" |
   | `welcome` | `WelcomeView` with two sample summaries of recent reviews (fixtures, their paths relative to the repository root) and an `open` that does nothing | what the view asks for, or 640 × 440 when that is under 300 × 200 in either direction | titled, closable, miniaturizable | "Referee" |

3. Run the scene's `prepare` closure with a `SnapshotContext`: the window, plus the model and the attached reader in a review scene, or the settings model in a settings scene; welcome and reference-viewer scenes get the window alone. `prepare` drives the models through their public methods; a scene that needs another provider calls `model.setActiveProvider(ProviderRef(providerID: "mock-remote", model: nil))`, abbreviated in the table below. Then keep the main run loop turning for the scene's settle time (default 2.0 s; PDF pages render asynchronously).
4. Capture the app's own window: resolve `CGWindowListCreateImage` with `dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")` (the symbol is marked unavailable in the macOS 15+ Swift SDK), cast to `@convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?`, call with `(.null, 8 /* including window */, UInt32(window.windowNumber), 1 | 8 /* ignore framing, best resolution */)`.
5. Check that the window still has the content size it was given (a view whose minimum size is larger makes the window grow, in the app as here; §9.2), then run the scene's `verify` closure, if any, with the same context; it returns the expectations that failed.
6. Write `<outDir>/<scene>.png`; append one JSON line to stdout and to `<outDir>/manifest.jsonl` (appended to and never emptied, so it keeps the lines of earlier runs): `{"scene":"review-pending","file":"…","width":2560,"height":1600,"nonBlank":true,"failures":[]}`. `file` is `<outDir>/<scene>.png` with the directory spelled as it was given; `width` and `height` are pixels of the display the run happens on (2560 × 1600 for 1280 × 800 points on a Retina display). `nonBlank` is true when at least 2% of pixels differ from the top-left pixel by more than 8/255 in any channel. `failures` holds what `verify` returned and any of these: the fixture PDF did not open; the window did not keep its size; the scene's data folder could not be prepared (a `fixtureSession` without a `fixturePDF` is one such case); a reference-viewer scene names no `fixturePDF`; the window could not be captured; the PNG could not be written.
7. Close the window. After the last scene exit 0 if every scene was captured, non-blank and without failures, else 1. Exit 1 also when a name given with `--scene` matches no scene (the known names are printed to stderr) or there is no scene to run, and 2 when the arguments are wrong: an unknown argument, an option without its value, or a `--size` that is not `<width>x<height>` with both between 200 and 8000 points. `--size` applies to review and reference-viewer scenes only. The arguments may start with the program name.

Things that do **not** work and must not be tried again: `NSView.cacheDisplay(in:to:)` and `CALayer.render(in:)` capture empty frames for SwiftUI and PDF content [V]. Known cosmetics: the window is drawn in its inactive look. Child windows (popovers, sheets) are not captured, which is why transient UI is built as in-window overlays (§7.4, §9.7).

`SnapshotContext`, `SnapshotScene` (with `prepare` and `verify`) and `SnapshotRunner` are declared in §11.3. The runner runs `ShellScenes.all + ReaderScenes.all + SidebarScenes.all + IntegrationScenes.all`; each UI work package fills its own list.

Required scenes:

| Scene | Owner | Shows |
|---|---|---|
| `placeholder` | Shell | Wave 0's check of the runner, kept as it is in every wave (a test in `Tests/RefereeUITests/Common` checks it): `ay_round_nolinks.pdf` in the review window; `verify`: the display document has 4 pages |
| `welcome` | Shell | welcome window with two recent reviews |
| `review-empty` | Shell | `ay_round_nolinks.pdf` open, no comments, destination indicator "Local · mock" |
| `consent` | Shell | `setActiveProvider("mock-remote")`, `startReview()`: the consent card, with the text-only sentence |
| `banner-error` | Shell | `setActiveProvider("mock-fail")`, review: banner "Review stopped: …" with Retry, two comments kept |
| `settings-providers`, `settings-prompts`, `settings-privacy` | Shell | settings panes; provider rows in each status, one with the experimental warning |
| `reader-highlights` | Reader | `ay_nolinks.pdf` with the sample session: yellow, green and blue highlights on page 1, none of them reaching into the margin, navigator on Pages |
| `reader-selection` | Reader | `ay_nolinks.pdf`, page 1: `pdfView.setCurrentSelection` on the raw range of `" As shown by Acemoglu et al. [2011],11\nnetwork structure determines wheth"`, with the selection bar; `verify`: `model.selection?.text == "As shown by Acemoglu et al. [2011], network structure determines wheth"` and both rectangles start at x ≥ 100 |
| `reader-citation` | Reader | citation card open on "Acemoglu et al." with a resolved reference (fake resolver) |
| `reader-find` | Reader | find bar with a count and highlighted matches |
| `reader-references` | Reader | navigator on References |
| `reader-ruler` | Reader | `s1_ruler.pdf` with a comment on the Table 2 sentence; `verify`: its label is "p. 1, lines 47–49" |
| `reference-viewer` | Reader | viewer window showing `num_twocol_links.pdf` |
| `sidebar-pending` | Sidebar | six comments, one selected, mixed kinds |
| `sidebar-streaming` | Sidebar | `setActiveProvider("mock-stall")`, review: two finished cards, one draft still being written |
| `sidebar-states` | Sidebar | approved, rejected, similar, fuzzy, page-only and unanchored cards |
| `sidebar-discussion` | Sidebar | open thread with two messages and a proposed revision |
| `sidebar-editing` | Sidebar | a card in edit mode |
| `sidebar-chat` | Sidebar | Chat tab with one conversation |
| `sidebar-report` | Sidebar | Report tab with generated text and three lint findings |
| `check-document-loaded` | Wave 3 | the real window on `ay_round_nolinks.pdf`; `verify`: `reader.isDocumentLoaded`, page count 4 |
| `check-citation-click` | Wave 3 | `ay_links.pdf`; `verify` as below |
| `check-triage-keys` | Wave 3 | the sample session; `verify` as below |

The last three check behaviour, not appearance; they are how the project knows that the panes are connected.

- `check-citation-click`: take the first rectangle of the mention "Acemoglu et al. [2011]" from `model.citations`, convert its centre to window coordinates, find the view there with `window.contentView.hitTest`, build a left-mouse-down `NSEvent` at that point (`NSEvent.mouseEvent(with: .leftMouseDown, location:…, windowNumber:…, clickCount: 1, pressure: 1)`), post the matching mouse-up with `NSApp.postEvent(_:atStart:)`, and call `mouseDown(with:)` on the hit view. Expect `model.citationLookup` to leave `.idle` with `target == .mention(<that id>)` and the PDF view's current page to be unchanged. Calling the hit view directly reaches `RefereePDFView` through PDFKit's internal page view without activating the app; events sent with `window.sendEvent` to a window that is not key are not delivered [V, reviewer].
- `check-triage-keys`: set the first two visible comments to pending and turn "advance after decision" off (`model.reloadSettings` with a modified copy of `model.settings`). For the key sequence J, A, J, R build key-down `NSEvent`s and pass each through `TriageKeymap.intent` and `TriageKeymap.apply`; expect the first comment approved and the second rejected and selected. Then U, K: expect the second pending again and the first selected.

How an agent uses the mode: run `scripts/snapshots.sh --out build/snapshots --scene <name>`, open the PNG with its file-reading tool, and compare against §9. An agent must look at every scene it owns before declaring its work package done, and list in `docs/contract-notes/<WP>.md` anything that looks wrong but is outside its files.

### 10.2 `referee-cli`

Same pipeline as the app, no UI. Hand-written argument parsing. Eight subcommands: the ones agents use to verify the pipeline.

```
referee-cli providers [--json]                                   availability of every provider (no tokens spent)
referee-cli dump-raw <pdf>                                       RawDocument JSON
referee-cli extract <pdf> [--pages A-B] [--stats]                the text a model would receive; --stats prints line-kind counts per page,
                                                                 margin-number ranges, and how many lines got a number in step 6 of §7.2
referee-cli anchor <pdf> --quote <text> [--page N] [--json]      confidence and label; exit 0 found, 1 not found
referee-cli citations <pdf> [--json]                             style, entries, mentions (text and link counts)
referee-cli plan <pdf> --provider <id> [--model <m>]             the SendPlan
referee-cli review <pdf> --provider <id> [--model <m>] [--mode auto|text|pdf] [--context <tokens>] [--json]
referee-cli ask <pdf> --provider <id> [--model <m>] --question <text> [--quote <text>]
global:  --home <dir>   (sets REFEREE_HOME; default: a temporary directory, so the CLI never touches the user's data unless asked)
         --use-keychain (read API keys from the Keychain as the app does; default: environment variables only)
```

- `review` prints each comment as it completes (`[major] p. 1, lines 13–14 (exact)  Title` then the body) and ends with one machine-readable line: `SUMMARY comments=7 anchored=6 pageOnly=1 unanchored=0 similar=0 requests=1 status=completed seconds=41.2`. `--json` prints one JSON object per event instead.
- Keys come only from `REFEREE_KEY_*` environment variables (§5.8) unless `--use-keychain` is given. `--provider mock` works with no setup.
- Exit codes: 0 success; 1 job failed; 2 usage error; 3 provider not configured or not available.
- Consent prompts do not apply to the CLI; choosing a remote provider on the command line is the consent. It prints one line to stderr: `sending <text|PDF> to <destination>`.
- The model for `plan` and `review` is looked up with `listModels()` so that `EngineContext.model` is filled as in the app.

### 10.3 Deterministic stand-ins

All in `TestSupport`, declared in §11.3.

- `MockLLMProvider` and the mock scripts (§5.9) for engines, the model, snapshots and the CLI; `StaticProvider` and `SnapshotSupport` for the snapshot mode.
- `StubURLProtocol`: a handler maps a request to a status, headers and a body delivered in chunks with optional delays, so stream parsers see realistic chunk boundaries; `StubURLProtocol.session()` returns a `URLSession` wired to it.
- Fake CLIs (`claude`, `codex`, `agy`, `grok`): shell scripts kept as Swift string literals in `Tests/CLIProvidersTests/FakeCLIScripts.swift` and installed once per test process into a temporary folder by `FakeCLIHarness` (a new executable is assessed by macOS on its first run, which took up to 8 s under load), selected through `REFEREE_CLI_PATH_<NAME>`; a test chooses a fake's behaviour through `$HOME/fake.env` in a home folder of its own, and the harness's host never searches the built-in candidate locations or the PATH, so a fake that fails can never let a real CLI run (WP5, Gate 1). They answer `--version` and `--help` (printing the protected flags, or omitting one when `FAKE_HELP=missing-flag`), read stdin, and print canned stream lines (Appendix D). `FAKE_MODE` selects `ok`, `auth`, `quota`, `garbage`, `hang` (sleep 600), `slow` (one line per second), `tool` (a stream in which a tool appears), `tools-on` (an init line that does not show tools off), `echo-bytes` (print the stdin byte count) and `print-env` (print the environment and argument list, for the scrubbing and no-manuscript-in-arguments tests). The fake `grok` speaks enough JSON-RPC to answer the four requests of §5.6.4 in order.
- In-memory `SessionStoring`, `SettingsStoring`, `SecretStoring` (with `failReads`); `FakePaperService`, `FakeQuoteMatcher`, `FakeResolver`, `ScriptedReviewEngine` for `AppCore` and UI tests.
- `Log.addTestSink` and `Log.removeTestSink` (Appendix A.8) let a test see every logged event. The tests of all targets run in parallel in one process, so several sinks can be active at once and a sink sees the events of every test running at that moment: a test filters by its own event names, or asserts only what must hold for every event, and removes only its own sink.

### 10.4 End-to-end with a real local model

`scripts/e2e-ollama.sh [model]` (default `gemma4:e4b`): exits 3 if `http://127.0.0.1:11434/api/version` does not answer; builds `referee-cli`; runs `review Fixtures/pdf/ay_round_nolinks.pdf --provider ollama --model <model>`; requires exit 0, `status=completed` and `comments>=1` in the SUMMARY line; prints `anchored=`. Then runs `ask … --question "Is the claim in the abstract supported?" --quote "The effect is statistically significant but economically small."` and requires non-empty output. A local model's content is not asserted, only that the pipeline completes. Zero cost. Gate 1 runs it before any UI work starts (§11.4); it is the proof that the pieces work together.

### 10.5 Debug transcript (off by default)

`REFEREE_DEBUG_DUMP=<dir>` makes `ReviewEngine` write each request's prompt and the raw model output to `<dir>/<timestamp>-<purpose>.txt`. This is the only way manuscript text can reach a file other than the session, it is never enabled by the app's UI, and the destination indicator shows a red "debug dump on" tag while it is set.

### 10.6 Environment variables

| Variable | Read by | Effect |
|---|---|---|
| `REFEREE_HOME` | `AppPaths` | data directory (settings, sessions; caches under `Caches/`) instead of the user's Library; tests, CLI and snapshots always set it |
| `REFEREE_KEY_<NAME>` | `EnvironmentSecretStore` | a secret that takes precedence over the Keychain: `REFEREE_KEY_ANTHROPIC_API`, `REFEREE_KEY_OPENAI_API`, `REFEREE_KEY_GEMINI_API`, `REFEREE_KEY_XAI_API` |
| `REFEREE_ENABLE_MOCK=1` | `LiveDependencies` | adds the provider `mock` to the real registry |
| `REFEREE_REPO_ROOT` | `TestSupport.Fixtures` | the repository root, for finding `Fixtures/`; needed only when a release binary runs the snapshot mode from another directory (§3.6) |
| `REFEREE_SNAPSHOT=1` | `LiveDependencies` | snapshot graph: mock and static providers only, fake resolver, in-memory secrets (§10.1) |
| `REFEREE_NO_KEYCHAIN=1` | `LiveDependencies` | the Keychain is never read or written (secrets come from `REFEREE_KEY_*` only) |
| `REFEREE_TEST_KEYCHAIN=1` | `LLMKitTests` | runs the one test that uses the real Keychain (§5.8) |
| `REFEREE_CLI_PATH_CLAUDE`, `_CODEX`, `_AGY`, `_GROK` | `BinaryResolver` | explicit CLI binary (fake CLIs in tests) |
| `REFEREE_CLI_SMOKE=1` | `CLIProvidersTests` | runs the one-line smoke prompt through each installed, signed-in real CLI (§11.6) |
| `REFEREE_DEBUG_DUMP=<dir>` | `ReviewEngine` | writes prompts and raw model output there (§10.5) |
| `REFEREE_LIVE_NET=1` | tests | enables tests that call the public reference services |
| `REFEREE_SIGN_IDENTITY`, `REFEREE_VERSION` | `scripts/bundle.sh` | signing identity (default ad hoc) and version string |

---

## 11. Work breakdown for parallel coding agents

### 11.1 Isolation: one git worktree per agent, in waves with two gates

**The hazard.** Agents building at once in one checkout fight over the `.build` lock, and one agent's half-written target breaks `swift build` and `swift test` for everyone.

**The procedure.**

1. **Wave 0** is one agent at a time, alone in the repository root on `main`, in two consecutive sessions (0a, 0b). It commits a package in which every target exists, compiles and passes smoke tests (real contracts, stub implementations, real test support).
2. **Gate 0**: a second agent, who did not write Wave 0, checks it and fixes what it finds, on `main`. Only then are the shared paths frozen.
3. For every Wave 1 and Wave 2 work package the coordinator creates a worktree on its own branch from the tip of `main`, for example `git worktree add ../Referee-worktrees/wp1-papertext -b wp/1-papertext main` (the Agent tool's worktree isolation does the same). The agent works only inside that directory, builds into that directory's own `.build`, and commits on its branch. It never pushes, never touches `main`, another worktree, or `git stash`.
4. **Gate 1**, after Wave 1: one integrator, alone on `main`, merges the nine branches, reads every notes file, changes contracts where the notes show they are wrong, and then proves the pipeline end to end from the command line. Wave 2 worktrees are cut from that tip.
5. **Wave 3**: one integrator merges the three UI branches and verifies the whole.

**Why this and not separate local packages per module.** A local path dependency is compiled from source by every package that uses it, so a half-written module still breaks its dependants, and each package would need its own manifest and test set-up. A worktree gives each agent a private copy of the sources *and* a private build directory: nothing an agent does can be seen by another until merge. One manifest stays the single description of the build. (The reviewer checked this procedure; the private `.build` per worktree is what matters.)

**Why merges do not conflict.** Ownership of paths is disjoint (§11.2), file names are unique within a target (§3.7), shared code is frozen after Gate 0, and implementation targets do not import each other (§2.1).

**Why two gates.** Wave 0 is the code nine agents build against; an error there is multiplied by nine, so someone other than its author checks it before the freeze. And a contract that turns out wrong during Wave 1 must be fixed once, by one agent who has seen every package's notes, before the UI is built on it; otherwise the UI is built on nine private workarounds.

**Consequences every agent must respect.**

- Your branch must build and pass `scripts/test.sh` on its own: other packages are still stubs in your worktree, and that is expected.
- Do not pass `--scratch-path` or `--build-path`; do not run `swift package clean`, `reset` or `update`.
- Frozen paths (below) are read-only. If a contract is wrong or missing something: implement what you need inside your own target (an extension, an internal helper), keep the public shape, and write the problem and your workaround in `docs/contract-notes/<WP>.md` under a heading "Contract problems". Gate 1 or Wave 3 resolves these.
- Commit early and often on your branch; the last commit must have the acceptance commands passing. Put the commands you ran and their final lines in `docs/contract-notes/<WP>.md`.
- Never drive the screen: no `osascript`, AppleScript or System Events, no `screencapture`, no synthetic input sent to another process. They hang or raise macOS permission prompts on the user's desktop. What the UI looks like is checked through the app's own snapshot mode (§10.1); whether the app runs, through exit codes and `log show`.
- Nothing in the tree may contain a personal name, an email address or an absolute path under a home directory. Paths are relative or computed at run time.

### 11.2 Steps and ownership

| Step | Runs | Name | Owns (may create and edit) |
|---|---|---|---|
| WP0a | alone, on `main` | Scaffold and contracts | everything |
| WP0b | alone, on `main`, after 0a | Test support, fixtures, composition, snapshot runner | everything |
| Gate 0 | alone, on `main`, a different agent | Review of Wave 0 | everything; afterwards **frozen**: `Package.swift`, `Makefile`, `scripts/`, `.gitignore`, `Sources/RefereeCore/`, `Sources/TestSupport/`, `Sources/Composition/`, `Sources/Referee/`, `Sources/RefereeUI/Common/`, `Tests/RefereeCoreTests/`, `Tests/RefereeUITests/Common/`, `Fixtures/` |
| WP1 | Wave 1 | PaperText | `Sources/PaperText/`, `Tests/PaperTextTests/` |
| WP2 | Wave 1 | PDFBridge | `Sources/PDFBridge/`, `Tests/PDFBridgeTests/` |
| WP3 | Wave 1 | CitationKit | `Sources/CitationKit/`, `Tests/CitationKitTests/` |
| WP4 | Wave 1 | LLMKit (HTTP providers) | `Sources/LLMKit/`, `Tests/LLMKitTests/` |
| WP5 | Wave 1 | CLIProviders | `Sources/CLIProviders/`, `Tests/CLIProvidersTests/` |
| WP6 | Wave 1 | ReviewEngine | `Sources/ReviewEngine/`, `Tests/ReviewEngineTests/` |
| WP7 | Wave 1 | ScholarKit | `Sources/ScholarKit/`, `Tests/ScholarKitTests/` |
| WP8a | Wave 1 | Persistence and report export | `Sources/Persistence/`, `Tests/PersistenceTests/`, `Sources/AppCore/Export/`, `Tests/AppCoreTests/Export/` |
| WP8b | Wave 1 | The two models | the rest of `Sources/AppCore/` and `Tests/AppCoreTests/` |
| Gate 1 | alone, on `main` | Merge, contract fixes, command line, end to end | merges; `Sources/referee-cli/`, `Tests/IntegrationTests/`, `scripts/e2e-ollama.sh`, `scripts/fetch-optional-fixtures.sh`; may change frozen paths |
| WP9 | Wave 2 | Reader UI | `Sources/RefereeUI/Reader/`, `Tests/RefereeUITests/Reader/` |
| WP10 | Wave 2 | Sidebar UI | `Sources/RefereeUI/Sidebar/`, `Tests/RefereeUITests/Sidebar/` |
| WP11 | Wave 2 | Shell and settings | `Sources/RefereeUI/Shell/`, `Tests/RefereeUITests/Shell/`, `Fixtures/sessions/` (additions only) |
| WP13 | Wave 3, alone, on `main` | Final integration | everything |

Every step also owns `docs/contract-notes/<its id>-<name>.md`. Test data private to a target is a Swift literal, or a data file in `Tests/<Target>Tests/Fixtures/`, which the manifest then excludes (§3.7). There is no WP12: its work is Gate 1.

Wave 1 has nine agents, Wave 2 three.

### 11.3 Fixed public surface of each target

Wave 0 creates these exact declarations; owners fill them in and may add anything `internal`. This block, together with Appendix A, was compiled as one package: every declaration below as a stub, the `Composition` code as printed, and the manifest of §3.2 [V]. It is the single description of each target's surface; where prose elsewhere in the plan seems to differ, this block wins.

```swift
// ====== RefereeCore, besides Appendix A (Wave 0a) =====================================================================
public enum DefaultSettings {
    /// Prompts, rubric and quick questions of Appendix B; the nine real provider ids of section 5.2 (not "mock"), all disabled
    /// except "ollama", which is enabled and whose extraBodyJSON is {"think": false}; no default provider chosen;
    /// privacy: localOnly false, confirm on, background lookups off.
    public static func make() -> AppSettings
}
public enum FormatSpec {                                  // Appendix B.2: constants in code, never settings
    public static var review: String { get }            // FORMAT_REVIEW
    public static var revision: String { get }          // FORMAT_REVISION
    public static var taskReviewText: String { get }    // TASK_REVIEW, text mode
    public static var taskReviewPDF: String { get }     // TASK_REVIEW, PDF mode
    public static var taskPart: String { get }
    public static var taskWhole: String { get }
    public static var taskContinue: String { get }
}

// ====== TestSupport (Wave 0b; frozen) =================================================================================
public enum Fixtures {
    public static var root: URL { get }                                           // repository root: REFEREE_REPO_ROOT, else #filePath (debug builds only), else the current directory (section 3.6)
    public static func url(_ relativePath: String) -> URL                 // "pdf/ay_nolinks.pdf" -> <root>/Fixtures/pdf/ay_nolinks.pdf
    public static func rawDocument(_ name: String) throws -> RawDocument  // "ay_nolinks" -> Fixtures/raw/ay_nolinks.raw.json
    public static func text(_ relativePath: String) throws -> String      // "llm/review_clean.txt"
}
/// Every raw line becomes a .body line with contentRange == range. Clean for every fixture except ay_nolinks and s1_ruler.
public func identityPaperText(from raw: RawDocument) -> PaperText
/// A LoadedPaper built from a raw dump with identityPaperText (no PDFKit); data = the fixture file's bytes.
public func makeSamplePaper(fixture: String = "ay_round_nolinks") throws -> LoadedPaper

public struct MockResponse: Sendable {
    public var text: String
    public var chunkSize: Int                 // characters per delta
    public var delayPerChunk: Duration
    public var failAfterChunks: Int?          // then throw `failure`
    public var failure: LLMError?
    public var stallAfterChunks: Int?         // then emit nothing more and never finish, until the consumer cancels
    public var stop: StopReason
    public init(text: String, chunkSize: Int = 7, delayPerChunk: Duration = .zero, failAfterChunks: Int? = nil, failure: LLMError? = nil,
                stallAfterChunks: Int? = nil, stop: StopReason = .endOfTurn)
}
public struct MockScript: Sendable {
    public var responses: [RequestPurpose: [MockResponse]]       // consumed in order per purpose; the last one repeats
    public init(responses: [RequestPurpose: [MockResponse]])
    public static var sample: MockScript { get }                    // Fixtures/llm: review_clean, discussion_revise, question_answer, report_sample
    public static var failsAfterTwoComments: MockScript { get }     // review: two complete blocks of review_clean, the third up to its quote line, then .overloaded
    public static var stallsAfterTwoComments: MockScript { get }    // review: the same text, then silence
}
public final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    public init(id: ProviderID = "mock", script: MockScript = .sample, isLocal: Bool = true, supportsNativePDF: Bool = false)
    public var recordedRequests: [LLMRequest] { get }               // lock-protected; a request is recorded when stream(_:) is called, before it is read
}
/// Scripted availability and model list; `stream` throws .notConfigured.
public struct StaticProvider: LLMProvider {
    public init(descriptor: ProviderDescriptor, availability: ProviderAvailability, models: [ModelInfo])
}
public enum SnapshotSupport {
    /// "mock" (local), "mock-remote" (non-local, destination "mock.example.org"), "mock-fail" (.failsAfterTwoComments),
    /// "mock-stall" (.stallsAfterTwoComments), then one StaticProvider per provider id of section 5.2 in mixed states.
    public static func providers() -> [any LLMProvider]
    /// DefaultSettings.make() with the four mocks enabled and "mock" as the review default.
    public static func settings() -> AppSettings
}
public final class StubURLProtocol: URLProtocol {
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var chunks: [Data]             // delivered one by one, so parsers see real chunk boundaries
        public var delayPerChunk: Duration
        public init(status: Int = 200, headers: [String: String] = [:], chunks: [Data], delayPerChunk: Duration = .zero)
    }
    /// The handler and the recorded requests belong to the calling test's task, because tests run in parallel: call setHandler,
    /// session() and recordedRequests in the test function itself (not in a child task), and start every test that uses the stub
    /// with setHandler, nil included. The type's doc comment has the details.
    public static func setHandler(_ handler: (@Sendable (URLRequest) -> Response?)?)   // nil response = connection refused
    public static func session() -> URLSession                                          // a URLSession that only talks to the handler
    public static var recordedRequests: [URLRequest] { get }                                   // bodies included (httpBodyStream is read)
}
public final class InMemorySessionStore: SessionStoring, @unchecked Sendable {
    public init()
    public var saveCount: Int { get }         // calls of save(_:) so far, whatever was saved (WP8b: several changes within the debounce, one save)
}
public final class InMemorySettingsStore: SettingsStoring, @unchecked Sendable { public init(_ settings: AppSettings = DefaultSettings.make()) }
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    public init(_ secrets: [String: String] = [:])
    public var failReads: Bool { get set }   // true: secret(for:) and setSecret throw SecretError.unreadable
}
/// load returns `paper`; rects(for:in:) returns one rectangle per span (x 100, width 200, on the span's page).
public final class FakePaperService: PaperService, @unchecked Sendable { public init(paper: LoadedPaper) }
/// Exact substring search inside single lines of the body text; label "p. N".
public struct FakeQuoteMatcher: QuoteMatching { public init(paper: PaperText) }
/// Returns `index` whatever the input; nil = an index with style .unknown, no entries and no mentions.
public struct FakeCitationIndexer: CitationIndexing { public init(index: CitationIndex? = nil) }
/// The simplest rendering, stable for ever (ReviewEngine's tests depend on it, not on PaperText's real renderer): for each page in
/// range the line "[[page N]]" (1-based), then the text of each .body line on a line of its own; a final newline.
/// chunkPageRanges adds consecutive pages to a range while its rendering stays within maxCharacters (a single page may exceed it).
public struct FakePaperRenderer: PaperRendering { public init() }
/// Every entry resolves at once: status .resolved, title "Resolved: " + first 30 characters, an example.org open-access URL.
public final class FakeResolver: ReferenceResolving, @unchecked Sendable {
    public init()
    public var forgottenDocuments: [String] { get }   // documentSHA256 of every forget call, in order (WP8b: delete review data)
}
/// Plays the given events; `calls` lists the jobs requested, in order ("plan", "review", "discuss", "ask", "report", "revise").
public final class ScriptedReviewEngine: ReviewEngineProtocol, @unchecked Sendable {
    public init(plan: SendPlan, review: [ReviewEvent] = [], reply: [ReplyEvent] = [], report: [ReportEvent] = [], lint: [LintFinding] = [],
                delayPerEvent: Duration = .zero)
    public var calls: [String] { get }
    public var contexts: [EngineContext] { get }                    // the EngineContext of each call, for assertions on model and digest
}

// ====== PaperText (WP1) ===============================================================================================
public struct PaperTextBuilder: PaperTextBuilding {
    public init(stripMarginLineNumbers: @escaping @Sendable () -> Bool = { true })
}
public struct QuoteMatcher: QuoteMatching { public init(paper: PaperText) }
public struct PaperRenderer: PaperRendering { public init() }

// ====== PDFBridge (WP2) ===============================================================================================
public actor PDFPaperService: PaperService { public init(builder: any PaperTextBuilding) }
public enum RawExtractor { public static func extract(from document: PDFDocument) -> RawDocument }
@MainActor public enum SelectionInfoBuilder {
    /// The selection exactly as PDFKit reports it: one span and one rectangle per line. Not normalised (section 7.4).
    public static func make(from selection: PDFSelection, in document: PDFDocument) -> SelectionInfo?
}

// ====== CitationKit (WP3) =============================================================================================
public struct CitationIndexer: CitationIndexing { public init() }

// ====== LLMKit (WP4) ==================================================================================================
public enum LLMKitFactory {
    /// ids, in order: anthropic-api, openai-api, gemini-api, xai-api, ollama
    public static func makeProviders(environment: ProviderEnvironment) -> [any LLMProvider]
}
public final class KeychainSecretStore: SecretStoring {
    public init(service: String = "local.referee.app", account: String = "secrets-v1")
}

// ====== CLIProviders (WP5) ============================================================================================
public enum CLIProviderFactory {
    /// ids, in order: claude-cli, codex-cli, antigravity-cli, grok-cli
    public static func makeProviders(environment: ProviderEnvironment) -> [any LLMProvider]
}

// ====== ReviewEngine (WP6) ============================================================================================
public final class ReviewEngine: ReviewEngineProtocol {
    public init(providers: any ProviderResolving, paperService: any PaperService,
                matcherFactory: @escaping @Sendable (PaperText) -> any QuoteMatching, renderer: any PaperRendering,
                physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory)
}

// ====== ScholarKit (WP7) ==============================================================================================
public actor ReferenceResolver: ReferenceResolving {
    /// dataDirectory = AppPaths.dataDirectory: a document's lookups are cached in <dataDirectory>/sessions/<sha256>/references.json.
    /// cacheDirectory = AppPaths.cacheDirectory: downloaded PDFs go to <cacheDirectory>/papers/.
    public init(settings: @escaping @Sendable () -> ReferenceSettings, urlSession: URLSession, dataDirectory: URL, cacheDirectory: URL)
}

// ====== Persistence (WP8a) ============================================================================================
public enum AppPaths {                                   // honours REFEREE_HOME: data = $REFEREE_HOME, caches = $REFEREE_HOME/Caches
    public static func dataDirectory(environment: [String: String]) -> URL
    public static func cacheDirectory(environment: [String: String]) -> URL
}
public actor FileSessionStore: SessionStoring { public init(directory: URL) }     // <dataDirectory>/sessions
public actor FileSettingsStore: SettingsStoring { public init(fileURL: URL) }     // <dataDirectory>/settings.json

// ====== AppCore, besides Appendix A.9 (ReportExporter, PaperSize: WP8a; SelectionNormalizer: WP8b) ====================
public enum PaperSize: Sendable {
    case letter, a4
    public static var current: PaperSize { get }       // letter when the locale's region is US, CA or MX, otherwise A4
}
@MainActor public enum ReportExporter {
    public static func plainText(fromMarkdown markdown: String) -> String
    /// .markdown and .plainText -> UTF-8; .docx; .pdf (paginated, text on every page; section 6.10). Main actor because of AppKit text layout and printing.
    public static func data(markdown: String, format: ExportFormat, paper: PaperSize = .current) throws -> Data
}
public enum SelectionNormalizer {
    /// Clips every span to the contentRange of the .body lines it touches, drops what lies on other lines, and rebuilds
    /// `text` from the clipped pieces. `rects` come back empty (the model fills them with PaperService.rects). nil when nothing is left.
    public static func normalize(_ selection: SelectionInfo, in text: PaperText) -> SelectionInfo?
}

// ====== RefereeUI/Common (Wave 0b; frozen) ============================================================================
@MainActor public struct SnapshotContext {
    public let window: NSWindow
    public let model: ReviewSessionModel?         // review scenes
    public let reader: ReaderController?          // review scenes; the runner has already called attach()
    public let settings: SettingsModel?           // settings scenes
    public init(window: NSWindow, model: ReviewSessionModel? = nil, reader: ReaderController? = nil, settings: SettingsModel? = nil)
}
@MainActor public struct SnapshotScene {
    public enum Kind { case review, settings, welcome, referenceViewer }
    public var name: String
    public var kind: Kind
    public var fixturePDF: String?                // under Fixtures/pdf (review and referenceViewer scenes)
    public var fixtureSession: String?            // under Fixtures/sessions; copied into the temporary REFEREE_HOME with document.sha256
                                                  // and byteCount rewritten to those of the fixture PDF as it is on disk
    public var settleSeconds: Double
    public var prepare: @MainActor (SnapshotContext) async -> Void        // drive the models through their public API
    public var verify: (@MainActor (SnapshotContext) async -> [String])?  // after capture: failed expectations; [] = pass
    public init(name: String, kind: Kind, fixturePDF: String? = nil, fixtureSession: String? = nil, settleSeconds: Double = 2.0,
                prepare: @escaping @MainActor (SnapshotContext) async -> Void = { _ in },
                verify: (@MainActor (SnapshotContext) async -> [String])? = nil)
}
@MainActor public enum SnapshotRunner {
    /// Runs ShellScenes.all + ReaderScenes.all + SidebarScenes.all + IntegrationScenes.all (or the named ones) and returns the exit code.
    public static func run(arguments: [String], makeDependencies: @escaping @Sendable ([String: String]) async -> AppDependencies) async -> Int32
}
@MainActor public enum IntegrationScenes { public static var all: [SnapshotScene] { get } }    // empty until Wave 3
/// The look the three panes share (section 9.10; highlights of section 7.3). Every colour is a system colour, so light and dark both work.
public enum Theme {
    public static func kindColor(_ kind: CommentKind) -> Color             // major red, minor grey, question purple, strength teal
    public static func statusColor(_ status: CommentStatus) -> Color       // pending yellow, approved green, rejected grey
    public static let ownColor: Color                                      // blue: the reviewer's own comments, whatever their status
    /// own: a comment the reviewer wrote, whatever its status; question: the passage a conversation of the Chat tab started from.
    public enum Highlight: Sendable, Equatable, CaseIterable { case pending, approved, rejected, own, question }
    public static func highlightHue(_ highlight: Highlight) -> NSColor     // opaque: yellow, green, grey, blue, purple
    public static func highlightAlpha(_ highlight: Highlight, selected: Bool = false) -> CGFloat    // 0.35, 0.30, 0.15, 0.30, 0.25; selected 0.60
    public static func highlightColor(_ highlight: Highlight, selected: Bool = false) -> NSColor    // the hue at that alpha
    public static let fuzzyBorderWidth: CGFloat                            // 1: a fuzzy anchor's highlight also gets a dashed border in its hue
    public static let fuzzyBorderDash: [CGFloat]                           // [3, 2]
    public static var pdfBackground: NSColor { get }                       // around the pages: .underPageBackgroundColor
    public static let cardCornerRadius: CGFloat                            // 8
    public static let cardPadding: CGFloat                                 // 10
    public static let listSpacing: CGFloat                                 // 10
    public static let sidebarPadding: CGFloat                              // 10
    public static let cardTitleFont: Font                                  // .headline
    public static let bodyFont: Font                                       // .callout
    public static let quoteFont: Font                                      // .callout.italic()
    public static let metadataFont: Font                                   // .caption
}

// ====== RefereeUI/Reader (WP9) ========================================================================================
public final class RefereePDFView: PDFView {}             // overrides mouseDown(with:) and areaOfInterest(for:) (section 7.4)
public enum ZoomStep { case zoomIn, zoomOut, fitWidth }
/// The only object other UI code uses to reach the PDF view. One per review window.
@MainActor public final class ReaderController {
    public init(model: ReviewSessionModel)
    public let pdfView: RefereePDFView                    // created in init, lives as long as the window
    /// Starts observing the model and loads the display document as soon as model.paper is set. Idempotent.
    /// Called by ReviewWindowController right after it creates the controller, and by the snapshot runner.
    public func attach()
    public var isDocumentLoaded: Bool { get }    // pdfView.document != nil
    public func showFind()               // Edit ▸ Find…
    public func findNext()
    public func findPrevious()
    public func zoom(_ step: ZoomStep)   // View ▸ Zoom In / Zoom Out / Fit Width
}
public struct ReaderPane: View { public init(controller: ReaderController) }          // PDF, find bar, selection bar, citation card
public struct NavigatorPane: View { public init(controller: ReaderController) }       // Pages / Outline / References
public struct ReferenceViewerView: View { public init(fileURL: URL, title: String) }  // read-only viewer for a cited paper
@MainActor public enum ReaderScenes { public static var all: [SnapshotScene] { get } }

// ====== RefereeUI/Sidebar (WP10) ======================================================================================
public struct ReviewSidebar: View { public init(model: ReviewSessionModel) }
@MainActor public enum SidebarScenes { public static var all: [SnapshotScene] { get } }

// ====== RefereeUI/Shell (WP11) ========================================================================================
public enum AppMain {
    /// Parses arguments. "--ui-snapshot <dir> …" runs the snapshot mode (section 10.1) and exits; otherwise starts the app.
    /// Not @MainActor: top-level code in main.swift is not main-actor-isolated in Swift 5 mode. The body is
    /// MainActor.assumeIsolated { start(makeDependencies) }.
    public static func run(makeDependencies: @escaping @Sendable (_ environmentOverrides: [String: String]) async -> AppDependencies) -> Never
}
public struct ReviewWindowView: View { public init(model: ReviewSessionModel, reader: ReaderController) }
public struct SettingsRootView: View { public init(model: SettingsModel) }
public struct WelcomeView: View { public init(recent: [SessionSummary], open: @escaping (URL?) -> Void) }   // nil = show the open panel
public enum TriageIntent: Equatable { case next, previous, approve, reject, resetStatus, discuss, edit, reveal, newComment, setKind(CommentKind), dismiss }
public enum TriageKeymap {
    public static func intent(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> TriageIntent?
    @MainActor public static func apply(_ intent: TriageIntent, to model: ReviewSessionModel)
}
@MainActor public enum ShellScenes { public static var all: [SnapshotScene] { get } }
```

**`Composition`, complete.** Wave 0b copies this file; it compiles as printed against the declarations above [V]. It is the only place where concrete types meet.

```swift
import Foundation
import RefereeCore
import TestSupport
import PaperText
import PDFBridge
import CitationKit
import LLMKit
import CLIProviders
import ReviewEngine
import ScholarKit
import Persistence

/// The settings in force, readable from any thread. Updated whenever settings are loaded or saved.
final class CurrentSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppSettings
    init(_ value: AppSettings) { self.value = value }
    func get() -> AppSettings { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: AppSettings) { lock.lock(); value = newValue; lock.unlock() }
}
/// AppDependencies.settings: the file store, plus keeping CurrentSettings up to date so that edits apply without a restart.
struct TrackingSettingsStore: SettingsStoring {
    let base: any SettingsStoring
    let current: CurrentSettings
    func load() async -> AppSettings { let s = await base.load(); current.set(s); return s }
    func save(_ settings: AppSettings) async throws { try await base.save(settings); current.set(settings) }
}
/// REFEREE_KEY_<KEY in upper case, non-alphanumerics as _> wins over the wrapped store; writes go to the wrapped store.
struct EnvironmentSecretStore: SecretStoring {
    let environment: [String: String]
    let base: any SecretStoring
    func secret(for key: String) throws -> String? {
        let name = "REFEREE_KEY_" + String(key.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        if let v = environment[name], !v.isEmpty { return v }
        return try base.secret(for: key)
    }
    func setSecret(_ value: String?, for key: String) throws { try base.setSecret(value, for: key) }
}

public enum LiveDependencies {
    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment) async -> AppDependencies {
        let data = AppPaths.dataDirectory(environment: environment)
        let caches = AppPaths.cacheDirectory(environment: environment)
        let snapshot = environment["REFEREE_SNAPSHOT"] == "1"      // snapshot mode: no process, no connection, no Keychain

        let fileStore = FileSettingsStore(fileURL: data.appendingPathComponent("settings.json"))
        let current = CurrentSettings(await fileStore.load())
        let settings = TrackingSettingsStore(base: fileStore, current: current)
        let stored: any SecretStoring = (snapshot || environment["REFEREE_NO_KEYCHAIN"] == "1") ? InMemorySecretStore() : KeychainSecretStore()
        let secrets = EnvironmentSecretStore(environment: environment, base: stored)
        let session = makeURLSession()
        let defaults = DefaultSettings.make()
        let providerEnvironment = ProviderEnvironment(
            settings: { id in current.get().providers[id] ?? defaults.providers[id] ?? ProviderSettings(enabled: false, inputMode: .auto) },
            secrets: secrets, urlSession: session, processEnvironment: environment)

        var providers: [any LLMProvider]
        if snapshot {
            providers = SnapshotSupport.providers()
        } else {
            providers = LLMKitFactory.makeProviders(environment: providerEnvironment) + CLIProviderFactory.makeProviders(environment: providerEnvironment)
            if environment["REFEREE_ENABLE_MOCK"] == "1" { providers.append(MockLLMProvider()) }
        }
        let registry = ProviderRegistry(providers)

        let paperService = PDFPaperService(builder: PaperTextBuilder(stripMarginLineNumbers: { current.get().ui.stripMarginLineNumbers }))
        let matcherFactory: @Sendable (PaperText) -> any QuoteMatching = { QuoteMatcher(paper: $0) }
        let engine = ReviewEngine(providers: registry, paperService: paperService, matcherFactory: matcherFactory, renderer: PaperRenderer())
        let resolver: any ReferenceResolving = snapshot
            ? FakeResolver()
            : ReferenceResolver(settings: { current.get().references }, urlSession: session, dataDirectory: data, cacheDirectory: caches)
        return AppDependencies(paperService: paperService, matcherFactory: matcherFactory, citationIndexer: CitationIndexer(), engine: engine,
                               resolver: resolver, sessions: FileSessionStore(directory: data.appendingPathComponent("sessions")),
                               settings: settings, providers: registry, secrets: secrets)
    }

    /// The one URLSession for providers and reference lookups (section 5.3).
    public static func makeURLSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600          // longest tolerated silence between bytes
        c.timeoutIntervalForResource = 3600
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }
}
```

### 11.4 Work packages

Each lists what to read, what to build, and the commands that must pass. "Tests" are the minimum; add more. Test names are suggestions; behaviours are required. Expected values marked ● were measured on the real fixtures, by probe or by prototype (Appendix F).

#### WP0a — Scaffold and contracts (Wave 0, first session, on `main`)

Read: §2, §3, §11, Appendix A, Appendix B.

Build:

1. Repository files of §3.3; `scripts/build.sh`, `test.sh`, `run.sh`, `bundle.sh`, `snapshots.sh`, `make-icon.sh` and the `Makefile` exactly as printed in §3.4; `Package.swift` of §3.2 exactly as printed.
2. `RefereeCore`: Appendix A.1–A.8 verbatim (the initialisers are printed; add none), plus `DefaultSettings.make()` (prompts, rubric and quick questions from Appendix B; the nine real provider ids of §5.2, all disabled except `ollama`, which is enabled and whose `extraBodyJSON` is `{"think": false}`; privacy defaults: `localOnly` false, confirm on, background lookups off; `ui.stripMarginLineNumbers` true) and the `FormatSpec` constants (Appendix B.2).
3. Every other target with the declarations of §11.3 and harmless bodies, no `fatalError`: `PaperTextBuilder.build` copies raw lines to `.body` lines with `contentRange == range`; `PaperRenderer` in its simplest form (one marker line per page, one text line per body line; WP1 replaces it); `QuoteMatcher.locate` returns `nil`; `CitationIndexer` returns an empty index; providers report `.needsSetup("not implemented", …)` and throw `.notConfigured` from `stream`; `ReviewEngine` streams finish with a failed run; `ReferenceResolver.resolve` returns `notFound`; stores work in memory; `ReviewSessionModel` and `SettingsModel` have every member of Appendix A.9; views are `EmptyView`; `TestSupport` types exist with trivial bodies; `Composition` as printed.
4. `main.swift` of §9.1, a smoke test in each of the twelve test targets, `README.md` (commands of §3.4), `docs/contract-notes/README.md`, initial commit.

Acceptance:

```
scripts/build.sh                                         # no errors, no warnings
scripts/test.sh                                          # OK, at least 12 tests
scripts/bundle.sh && codesign --verify build/Referee.app
git status --porcelain | wc -l                           # 0
```

#### WP0b — Test support, fixtures, composition, snapshot runner (Wave 0, second session, on `main`)

Read: §3.6, §5.3 (the session), §5.9, §7.2 (raw extraction only), §10.1, §10.3, §11.3, Appendices C and D, Appendix G.4, and `docs/contract-notes/wp0a-scaffold.md`.

Build:

0. The amendments of Appendix G.4 that WP0a's code does not have yet: the manifest and `scripts/bundle.sh` as now printed, `.gitignore`, `DefaultSettings` without `mock`, `Fixtures.root`, the two new fakes, and the four public initialisers.
1. `TestSupport` for real, with the behaviour §11.3's comments, §5.9 and §10.3 give. `RefereeCoreTests` gets a test for each fake's documented behaviour.
2. `PDFBridge.RawExtractor.extract` and `PDFPaperService.load` in their simplest working form (§7.2 "Raw extraction"; WP2 owns and completes them), and a seed `referee-cli` with only `dump-raw <pdf>` (Gate 1 completes it), because fixtures need them.
3. Fixtures: LaTeX sources from Appendix C; `scripts/make-fixtures.sh`; run it and commit the seven PDFs and their raw dumps; `Fixtures/llm/*` from Appendix D.9; `Fixtures/sessions/sample.json` (seven comments quoting sentences that occur in all `ay_*` fixtures, in the states the scenes of §10.1 need, one of them with `similarTo`; anchors may be empty, the model re-anchors on load).
4. `RefereeUI/Common`: `CommonTheme.swift`, `CommonUIActions.swift`, `CommonSnapshotScene.swift`, `CommonSnapshotRunner.swift` (the full mechanism of §10.1, including `verify`, the hash rewrite and the off-screen window), `CommonIntegrationScenes.swift` (an empty list). Placeholder views composed as in §9.2 (`ReviewWindowView` really uses `NavigationSplitView` + `.inspector`), a minimal `AppMain` that opens a review window for a PDF path argument and dispatches `--ui-snapshot`, a `ReaderController` whose `attach()` really loads the display document into a plain `PDFView` subclass, and one scene `placeholder` in `ShellScenes`.
5. `scripts/make-fixtures.sh` as printed in Appendix C.

Acceptance:

```
scripts/build.sh
scripts/test.sh                                          # OK, at least 30 tests
scripts/test.sh --filter RefereeCoreTests                # round-trip of the §4.3 sample; DefaultSettings sanity; LineSplitter; Log sink and id filter;
                                                         # mock determinism, mock-fail yields two closed blocks then throws, mock-stall never finishes until cancelled;
                                                         # StubURLProtocol chunking; SnapshotSupport ids; every fixture PDF and raw dump present and decodable
"$(swift build --show-bin-path)"/referee-cli dump-raw Fixtures/pdf/ay_nolinks.pdf | head -c 200
scripts/snapshots.sh --scene placeholder                 # exit 0, PNG non-blank; open it: three columns and a PDF page are visible
scripts/bundle.sh && codesign --verify build/Referee.app # bundle.sh now also fails if the binary contains a home-directory path
git status --porcelain | wc -l                           # 0
```

#### Gate 0 — Review of Wave 0 (a different agent, on `main`)

Read: §2, §3, §10.1, §10.3, §11.1–§11.3, Appendix A; then the code of Wave 0.

Do, and record each result in `docs/contract-notes/gate0.md`:

1. **Every protocol has a consumer.** Add `Tests/RefereeCoreTests/ContractConsumers.swift`: for each protocol of Appendix A a minimal conforming type written from the protocol alone (an actor for `PaperService`, `ReferenceResolving`, `SessionStoring`, `SettingsStoring`; a class for `SecretStoring`, `LLMProvider`, `ReviewEngineProtocol`; structs for the rest) and a function that calls every requirement. It must compile and run.
2. **§11.3 against the code.** Add two files, each a function, never called, that names declarations of §11.3 with their printed argument labels: `Tests/RefereeUITests/Common/CommonSurfaceCheck.swift` for `RefereeUI`, `AppCore`, `PDFBridge` and `TestSupport`, and `Tests/IntegrationTests/SurfaceCheck.swift` for every other target (`IntegrationTests` does not depend on `RefereeUI`). Together they name every declaration; both must compile. Any difference between §11.3 and the code is fixed in the code.
3. **The fakes.** Read all of `TestSupport` against §5.9, §10.3 and the comments in §11.3; add a test wherever a documented behaviour has none.
4. **The snapshot path.** Run `scripts/snapshots.sh --scene placeholder` and look at the PNG. Then confirm that the engine of the snapshot graph finds the snapshot providers (this is the failure the first plan had). A scene cannot start a review before WP8b, so do it in a test that stays: `Tests/IntegrationTests/SnapshotGraphTests.swift` builds `LiveDependencies.make` with `REFEREE_SNAPSHOT=1` and a temporary `REFEREE_HOME`, calls `engine.review` for `mock-remote`, and asserts that the run's destination is `mock.example.org` and that its message does not say the provider is missing. Write the assertions so that they hold for the placeholder engine and for the real one.
5. **The fixtures.** Run `scripts/make-fixtures.sh --pdf-only` into a scratch copy and compare page counts and the first lines of each raw dump with the committed ones; confirm the facts marked ● in WP1's and WP2's tables for two rows of your choice with `referee-cli dump-raw`.
6. Fix what is wrong directly; this is the last moment anything in the frozen paths changes without a gate.

Acceptance: `scripts/build.sh`, `scripts/test.sh`, `scripts/snapshots.sh --scene placeholder`, a clean `git status`, and `gate0.md` listing what was checked, what was changed and what, if anything, is left for the coordinator.

#### WP1 — PaperText (Wave 1)

Read: §6.2 (rendering), §6.7, §7.2 (cleaning), Appendix A.2.

Build: `PaperTextBuilder` (§7.2 steps 1–7), `QuoteMatcher` (§6.7), `PaperRenderer` (`render` per §6.2, `chunkPageRanges`). Pure Foundation; inputs for tests are `Fixtures/raw/*.raw.json` through `Fixtures.rawDocument`. Use only `y` and `height` of raw bounds.

Acceptance: `scripts/build.sh` and `scripts/test.sh --filter PaperTextTests` with at least these behaviours:

| Test | Requirement |
|---|---|
| line numbers on text lines ● | `ay_nolinks`: `hasMarginLineNumbers`; numbers 1…16, 17…33, 34…48, 49…54 on pages 1–4, of which 4, 1, 3 and 2 are `.marginNumberOnly` lines; the line starting "Table 2 is 0.91" has `marginNumber == 14` and `text` ending "difficult to"; "function." has 17 and "A Course in Game Theory. MIT Press." has 52 (both from step 6); the five table lines and the four equation lines have `nil` |
| ruler ● | `s1_ruler`: `hasMarginLineNumbers`; 60 `.marginNumberOnly` lines on every page; the line starting "ficient in Table 2 is 0.91" has `marginNumber == 49` and the first line of the abstract 28; no `.body` line's text is only digits |
| no false positives ● | `hasMarginLineNumbers == false` for `ay_links`, `ay_round_nolinks`, `num_links`, `num_twocol_links`; and for any PDF dump made from `Fixtures/private` (skipped when absent) |
| setting respected | `PaperTextBuilder(stripMarginLineNumbers: { false })` leaves every `contentRange == range` |
| page furniture ● | `ay_nolinks`: the four "CONFIDENTIAL" lines are `.watermark`; the last line of each page is `.pageNumber`. `s1_ruler`, every page: "Journal of Synthetic Economics" `.runningHeader`, "Page N of 4" `.pageNumber`, the URL line `.runningFooter`, "For Peer Review" `.watermark` |
| numbered lists are not line numbers | a synthetic page of 30 reference lines "1. …", "2. …" is not treated as leading margin numbers |
| exact anchors ● | on `ay_nolinks` and again on `s1_ruler`, each of these is found with `.exact` on the stated page, with one span per text line touched: "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one" (p. 1), "Herding has been studied extensively since Banerjee" (p. 1), "office-specific identification threshold" (p. 1), "an information cascade begins with positive probability" (p. 2), "It is easy to see that the inequality is preserved when both sides are multiplied by the likelihood ratio." (p. 2) |
| across a page ● | "verify the differentiability of the payoff function" → `.exact` with one span on page 1 and one on page 2, on `ay_nolinks` and on `s1_ruler` (it works only if page numbers, header, footer and ruler lines are out of the stream) |
| two columns, smoke ● | `num_twocol_links`: "column of this page contains the sentence that must be anchored before the second column begins" (p. 1) and "Table 1 reports a BLEU score of 28.4 for the base model" (p. 2) are `.exact`; "Aliquam vestibulum fringilla lorem. Sed neque lectus, consectetuer at", which crosses the column break, returns `nil` or a match on page 2 and does not crash |
| fuzzy ● | on `ay_nolinks`: "The coefficient in Table 2 equals 0.91 with a confidence interval which crosses one, which is difficult to reconcile" (two words changed) → `.fuzzy` with score ≥ 0.85 on p. 1; a five-token quote with one word changed is not matched by the fuzzy stage |
| ellipsis | "The coefficient in Table 2 is 0.91 … reconcile with the claim of a robust effect" → found on p. 1 |
| absent ● | "this sentence is not in the paper at all whatsoever" → `nil` |
| short quotes | "Table 2" → `nil` without a hint; found with `pageHint: 0` |
| repeated text | a quote occurring on two pages returns the hinted page |
| folding | a synthetic line with "ﬁ", a superscript digit and a mathematical italic letter (U+1D44E) is found by a quote written with "fi", the plain digit and "a" |
| labels ● | Table 2 quote → "p. 1, lines 13–14" (`ay_nolinks`), "p. 1, lines 47–49" (`s1_ruler`), "p. 1" (`ay_links`); "Herding has been studied extensively since Banerjee" → "p. 1, line 9" (`ay_nolinks`); the across-a-page quote → "pp. 1–2 (p. 1 line 16 to p. 2 line 17)" (`ay_nolinks`) and "pp. 1–2 (p. 1 line 53 to p. 2 line 8)" (`s1_ruler`), "pp. 1–2" (`ay_round_nolinks`); "Staggered rollout 0.87" → "p. 3" (`ay_nolinks`) and "p. 3, line 12" (`s1_ruler`) |
| rendering ● | `ay_nolinks`, `s1_ruler` and `ay_round_nolinks` each render to 37 lines and a final newline: starts "[[page 1]]\n"; one marker per page; "2 Model" is a line by itself; "µi =" is a line by itself; the four table rows are four lines; contains "difficult to reconcile with the claim of a robust effect" and "predecessors"; "the payoff function." comes before "[[page 2]]" and the line after that marker starts "In Banerjee"; contains none of "CONFIDENTIAL", "to14", "Journal of Synthetic", "mc.example.org", "For Peer Review", and no line that is only digits |
| chunking | ranges are contiguous, cover all pages, and each rendered chunk is within the limit unless it is a single page |
| robustness | builder, matcher and renderer terminate on empty documents, one-character pages, lines without bounds, and 200 KB of random Unicode |
| speed | building the matcher for a 60-page synthetic document and 50 `locate` calls take under 1 s in a debug build |

#### WP2 — PDFBridge (Wave 1)

Read: §4.6, §6.7 ("From spans to highlight rectangles"), §7.1, §7.2, §7.4 (selection), Appendix A.2.

Build: complete `RawExtractor` (pages, lines, links, outline), `PDFPaperService` (`load(url:)`, `load(data:fileName:)`, SHA-256 with CryptoKit, `isEncrypted`, `PaperError` cases, bounds recomputation for stripped lines, `rects(for:in:)`, `unload`), `SelectionInfoBuilder`. Follow the allowed and forbidden PDFKit calls of §7.2 exactly.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter PDFBridgeTests`:

| Test | Requirement |
|---|---|
| raw consistency ● | for every fixture and page: each `RawLine.text` equals the substring of `string` at `range`; ranges are increasing and non-overlapping. No assertion relates the number of lines to newlines; page 2 of `ay_round_nolinks` has 22 lines and 21 newline-separated pieces |
| links ● | `num_links`: 12 links, 10 with `.internalDestination` into page indices 2 and 3, 2 with `.url` containing `doi.org/10.3115/v1/D14-1179`; `num_twocol_links`: 12; `ay_links`: 36, all internal; `ay_nolinks`, `ay_round_nolinks`, `s1_ruler`: none |
| load ● | page counts 4 (`ay_nolinks`, `ay_round_nolinks`, `ay_links`, `s1_ruler`, `num_links`), 2 (`num_twocol_links`), 1 (`scanned`); `DocumentRef.sha256` equals `shasum -a 256` of the file; two loads give equal `PaperText`; `isEncrypted == false` |
| protected PDFs ● | a temporary copy written in the test with `PDFDocument.write(to:withOptions:)`, owner password set and copying disabled → loads, `isEncrypted == true`, page 1 text equal to the original's; a copy with a user password → `PaperError.encrypted` |
| failures | data not starting with `%PDF-` → `.notAPDF`; `scanned.pdf` loads with `hasTextLayer == false` |
| equation and table | page 2 (the displayed fraction) and page 3 (the table) of `ay_round_nolinks`: `rects` for a span covering each line returns one rectangle per line |
| rects exclude margin numbers ● | with a test builder that marks the trailing digits of `ay_nolinks` lines as margin numbers, `rects` for the "Table 2 … crosses one" spans returns two rectangles, each with `x ≥ 100` and `width < 400` |
| selection info | a `PDFSelection` made from a known range gives the same `TextSpan` and non-empty rects; a selection over two lines gives two spans |
| file untouched | bytes of the fixture file are identical before and after `load` + `rects` |
| off-main | `load` and `rects` called from a detached task complete (they run inside the actor) |

#### WP3 — CitationKit (Wave 1)

Read: §8.1–§8.5, §6.7 (folding), Appendix A.3. Input in tests: `PaperTextBuilder` is still a stub in your worktree, so build `PaperText` with `identityPaperText(from:)` (all lines `.body`); that is clean for every fixture except `ay_nolinks` and `s1_ruler`, which are covered at Gate 1.

Build: `CitationIndexer` with internal pieces `BibliographyLocator`, `EntryParser`, `TextMentionFinder`, `LinkMentionFinder`, `MentionMerger`.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter CitationKitTests`:

| Test | Requirement |
|---|---|
| reference list, author–year ● | `ay_round_nolinks`: style `.authorYear`; 9 entries; first surnames in order Acemoglu, Avery, Banerjee, Bikhchandani, Dekel, Kogan, Lee, Osborne, Smith; years 2011, 1998, 1992, 1992, 2000, 2020, 2021, 1994, 2000; Acemoglu has 4 surnames; Dekel has [Dekel, Piccione] although its first line has no spaces; the Dekel entry's text ends "J Polit Econ 108(1):34–55" and the Osborne entry's "A Course in Game Theory. MIT Press." |
| the list ends only on evidence | synthetic lists: followed by a taller line "A Proofs" → ends there; followed by "Appendix" at the left edge in the list's own size → ends there; containing the continuation lines "A Course in Game Theory. MIT Press." and "Tables of Integrals, Series, and Products. Academic Press." → does not end; a heading line "References 12" is accepted as the heading |
| mentions, round brackets ● | `ay_round_nolinks` (links: []): exactly 15 mentions, with these first authors in order. Page 1: Banerjee, Bikhchandani (broken by a hyphen across lines), Avery, Smith, Acemoglu (across a line break), Smith ("…, 2000, p. 12)"), Kogan, Lee. Page 2: Banerjee ("In Banerjee (1992)"), Avery ("The Avery and Zemsky (1998) model"), Lee ("See Lee (2021)"), Smith ("Following Smith and Sørensen (2000)"), Osborne, Dekel, Bikhchandani (on the line that has no spaces). No mention inside the list; none for "Table 2", "Proposition 1" or "(1)" |
| mentions, square brackets ● | `ay_links` with `links: []`: the same 15 targets in the same order |
| not citations | synthetic: with Lee (2021) in the list, "the employee (2021) survey" gives no mention; "Banerjee's (1992) model" gives one; "Smith (2019, 2021)" with both in the list gives two |
| link path ● | `ay_links` with its links: 15 link mentions from 34 pieces; "Avery and Zem-", "sky", "1998" merge into one mention with three rectangles; "Kogan [2020], Lee [2021]" stays two; the links to the table and the equation give none; after the merge: 15 mentions, each with text spans and link rectangles |
| numeric ● | `num_links` with `links: []`: style `.numeric`; 5 entries labelled 1–5; ten mentions whose entry labels are 4, 2, 1, 1, 5, 3, 4, 2, 1, 5; the entry labelled 2 has `doi == "10.3115/v1/d14-1179"` (joined across a line break); the entry labelled 3 has `arxivID == "1810.04805"` and `year == 2019`; a synthetic "[3–5]" is one mention with three entries; "[99]" is ignored |
| numeric links ● | `num_links` with its links: ten link mentions with the same labels, merged one-to-one with the ten text mentions; the "1" that ends one line and the "1" that starts the next stay two mentions |
| two columns, smoke ● | `num_twocol_links`: 5 entries (the list ends where the text returns to the left column), 10 mentions |
| parser table | at least 15 reference strings in economics, APA, numeric and "et al." styles, with particles ("van der Berg"), initials before and after surnames, Springer style with and without spaces, a label on a line of its own, a DOI at the end, and an arXiv id that looks like a year → expected first surname, year, DOI |
| no list | a document without a reference heading → empty entries, `.unknown`, no crash |
| robustness | random text and a 5,000-line document complete in under 2 s |

#### WP4 — LLMKit (Wave 1)

Read: §5.1–§5.5, §5.7, §5.8, Appendix A.5, Appendix D.1–D.4.

Build: `HTTPStreamClient`, the retry wrapper, the five adapters and providers, model listing with the filters of §5.4, `KeychainSecretStore` over an internal `KeychainBackend`. Tests use `StubURLProtocol.session()` passed through `ProviderEnvironment.urlSession`; stream bodies come from Appendix D, saved under `Tests/LLMKitTests/Fixtures/`.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter LLMKitTests`:

| Test | Requirement |
|---|---|
| request shape, per provider | URL, method, headers and JSON body exactly as in §5.4 for (text only) and, where the provider takes one, (PDF + text + cache boundary); Anthropic body has no `temperature`, `top_p`, `top_k`, `thinking`; OpenAI and Gemini bodies have `"store": false`; the OpenAI file part's `filename` is `manuscript.pdf`; the xAI request goes to `/v1/chat/completions` with `messages`; `extraBodyJSON` keys are merged, and with `DefaultSettings.make()` the Ollama body has `"think": false`; `baseURL` override is honoured; every streaming `URLRequest` has `timeoutInterval == 600`; no key → `.notConfigured` without a request |
| stream parsing, per provider | the Appendix D body, delivered in 1-byte chunks and again in one chunk, yields the same deltas whose concatenation equals the expected text, then exactly one `.finished` with the expected stop reason and usage |
| unknown events | bodies with extra unknown event types and extra JSON fields parse identically |
| in-stream errors | Anthropic `error` event → `.overloaded`; OpenAI `response.failed` → mapped error; Gemini `error` event with code `gateway_timeout` → `.server`, with `rate_limit_exceeded` → `.rateLimited`; Ollama `{"error":…}` line → `.server` |
| truncation | Gemini `interaction.completed` with `status: "incomplete"` → `.finished(.maxTokens, …)`; xAI chunk with `finish_reason: "length"` → `.maxTokens`; Ollama `done_reason: "length"` → `.maxTokens` |
| early end | a body cut before the terminal event → the deltas so far, then `.malformedResponse` |
| HTTP errors | one case per cell of the §5.5 table, including `Retry-After` parsing; the xAI status mapping of §5.4.3 |
| retry | two 529/503 responses then a good stream → one successful stream and two `.status` events (use an injected sleep function so the test is instant); failure after the first delta is not retried; `.auth` is not retried; `URLError.timedOut` is not retried |
| cancellation | cancelling the consuming task stops the stub (its `stopLoading` is called) and the stream ends with `.cancelled` or silently, never hangs |
| models | each vendor's list JSON → expected `ModelInfo` (context window, PDF support, filters, pagination across two pages) |
| Ollama context | `num_ctx` equals `LLMRequest.contextWindow`; the "context full" status is emitted when the counts say so |
| secrets never lost | with a fake `KeychainBackend`: read fails with −25293 → `setSecret` throws `SecretError.unreadable` and performs no write; item not found → add; item read → update keeps the other keys |
| real Keychain | only with `REFEREE_TEST_KEYCHAIN=1`: set, get, replace and delete under a unique test service name, cleaned up afterwards. Run it once and record the result in your notes |
| live Ollama | enabled only if `/api/version` answers: a 16-token chat with the smallest installed model streams at least one delta |

#### WP5 — CLIProviders (Wave 1)

Read: §5.6 entirely, §5.5, §11.6, §12.5, Appendix A.5, Appendix D.5–D.8. The only real prompts you may send are the ones §11.6 gives you; everything else is `--version`, `--help`, `auth status`, `login status`, `debug models`, `debug prompt-input`, `features list`, `models`.

Build: `BinaryResolver` with the flag check, login-shell `PATH` lookup, environment builder, `CLIRunner` / `CLIProcess`, the argument tables with protected arguments, the four adapters with their tripwires, the ACP client for Grok Build, page rendering with CoreGraphics for `.pageImages`, the fake CLIs of §10.3. Then, in this order:

1. If `npm` is on the `PATH`: `npm install -g @xai-official/grok` (xAI's documented npm distribution). If it fails or asks for elevated rights, skip it. Do not install `agy`: its only documented installer is a script piped from the web. With `grok` installed, run `grok --version`, `grok --help`, `grok agent --help`, `grok agent stdio --help`, `grok models --help`, save the output in `docs/contract-notes/wp5-grok-help.txt`, and check every argument of §5.6.4's Grok block against it. Correct the argument table to what the help says (a flag's spelling, the list separator of `--disallowed-tools`, whether the options go before `agent stdio`) and record each correction. If the binary has no `agent stdio`, or rejects a protected option there, leave the adapter as specified: the flag check will report the provider unavailable, which is the intended result.
2. The delivery experiment of §5.6.6 for Claude Code and Codex, and the constants that follow from it.
3. The smoke prompts of §11.6. If a real CLI trips the tripwire (for example Claude Code's init line lists a tool although `--tools ""` was passed), do not loosen the rule: copy the offending line into your notes with account fields removed, leave the provider failing closed, and stop for the coordinator.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter CLIProvidersTests`:

| Test | Requirement |
|---|---|
| argument lists | for each CLI, the exact argument array of §5.6.4 for (default model) and (explicit model), with `extraArguments` appended; `!--print-timeout` removes that argument; `!--sandbox` and `!--tools` remove nothing and produce the "cannot be removed" status |
| no manuscript in arguments | for each CLI, a prompt containing a marker string: the fake's `print-env` shows the marker in none of its arguments |
| resolver order | explicit path beats environment override beats candidates beats `PATH`; a candidate whose `--version` hangs (fake `hang`) is skipped after the timeout (use a 1 s timeout in the test) and the next one is chosen; nothing found → `.needsSetup` carrying the install command |
| flag check | a fake whose `--help` omits a protected flag (`FAKE_HELP=missing-flag`) → `availability()` is `.unavailable` naming the flag, and `stream` throws without starting the process |
| environment | with `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CODEX_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY` set in the injected process environment, the fake `print-env` shows none of them and shows `HOME`, a `PATH` containing `/opt/homebrew/bin`, `TERM=dumb`, `NO_COLOR=1`; the fake `grok` also sees `GROK_SANDBOX=strict` |
| working directory | the fake reports a current directory that holds only what the adapter put there and no longer exists after the run |
| stdin | a 2 MB prompt reaches the fake intact (`echo-bytes`) without deadlock |
| stream parsing | for each CLI the Appendix D lines → expected deltas and `.finished`; Codex cumulative `item.updated` text produces only the new suffix; the Grok ACP exchange of Appendix D.8 → expected deltas, stop reason, and a delete request for the session |
| tripwire, tool used | fake `tool` for each CLI (Claude: an `assistant` line with a `tool_use` block; Codex: an `item.started` of type `command_execution`, and one of an unknown type; Antigravity: a `step_update` with `step_type: "tool"`; Grok: a `tool_call` update, and a `session/request_permission` request) → `.toolUseBlocked`, the process is gone within 2 s, and no delta that came after the tool line is delivered |
| tripwire, tools not off | fake `tools-on` (Claude: init line with `"tools":["Bash"]`, and one with no `tools` key; Antigravity: init with `"permission_mode":"always-proceed"`) → `.toolUseBlocked` before any delta |
| failures | fake `auth` → `.auth`; `quota` → `.quotaExhausted`; `garbage` (non-JSON lines) is ignored and the run still ends with `.cliExited` or `.malformedResponse`, never a crash; non-zero exit → `.cliExited` with the stderr tail |
| timeouts and cancel | fake `hang` → `.cliTimeout(phase: "start")` with a 1 s test timeout; cancelling the consumer kills the fake within 6 s (verify the PID is gone); a fake that starts a child `sleep 600` and prints its PID: after cancellation, and after a tripwire, the child is gone too |
| model lists | recorded `codex debug models` JSON → models with `visibility == "list"` ordered by priority with context windows; recorded `agy models` text → slugs and names |
| availability | fake `claude auth status` JSON for logged-in subscription, logged-in API key, logged out → `.ready`, `.needsSetup`, `.needsSetup` |
| page images | the four pages of `ay_round_nolinks.pdf` rendered with CoreGraphics at 110 dpi give `p001.png` … `p004.png` in the working directory, each more than 900 px wide and not blank |
| real binaries (skipped when absent) | `claude --version` through the resolver; `claude auth status` parses; `codex login status` parses; the resolver does not pick a `codex` whose `--version` fails; the flag check passes for the installed `claude` and `codex` |
| Codex tool list (skipped when absent) | run `codex debug prompt-input` with the adapter's `-c` and `--disable` arguments and `CODEX_HOME` set to an empty temporary directory (that subcommand has no `--ignore-user-config`). In the output's `additional_tools` item: no tool or namespace named `exec_command`, `write_stdin`, `view_image`, `sleep`, `spawn_agent` or starting with `mcp__`, and the `exec` tool's description contains none of the headings `### \`exec_command\``, `### \`write_stdin\``, `### \`view_image\``. (Do not search the whole output for these words: Codex's own instructions mention `exec_command` and `mcp__` in prose even when the tools are gone ●.) |
| smoke (only with `REFEREE_CLI_SMOKE=1`) | for each installed, signed-in real CLI: the prompt "Reply with exactly: OK" → the concatenated text, trimmed of whitespace and a final period, equals "OK" ignoring case; `.finished`; the tripwire did not fire |

#### WP6 — ReviewEngine (Wave 1)

Read: §6 entirely, §5.1, Appendices A.4–A.6, B, D.9, and the doc comment of `FormatSpec` in `Sources/RefereeCore/FormatSpec.swift` (the rule for placeholders). Dependencies in tests: `MockLLMProvider`, `FakePaperService`, `FakeQuoteMatcher`, `FakePaperRenderer` (all from `TestSupport`; `ReviewEngineTests` cannot import `PaperText`).

Build: `Planning`, `PromptBuilder`, `CommentStreamParser`, `ReplyParser` (revision / withdraw), `ReviewEngine` jobs, `ReportLinter`, the debug dump (§10.5). Author `review_sloppy.txt`, `review_json.txt`, `review_prose.txt` and `review_dupes.txt` as Appendix D.9 describes, under `Tests/ReviewEngineTests/Fixtures/`.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter ReviewEngineTests`:

| Test | Requirement |
|---|---|
| parser, clean | `Fixtures/llm/review_clean.txt` → 6 comments with the expected kinds, categories, pages, quotes, titles; `sawDone` |
| parser, chunking | the same text fed in chunks of 1, 7 and 4,096 characters gives identical closed blocks; drafts only grow |
| parser, sloppy | `review_sloppy.txt` (decorated markers, bold field names, list markers before field names, `* **Quote:** …`, missing `@@END`, quoted quotes, prose between blocks, numbered comments, "Type:" and "Severity:" synonyms, a body containing a line that starts "Title:", `suggestion: N/A`) → the expected 5 comments, the last with `suggestion == nil` |
| parser, fallbacks | `review_json.txt` → comments via the JSON path; `review_prose.txt` → one "Unstructured model output" comment and a notice |
| parser, garbage | random bytes and a 5 MB line do not crash or hang |
| planning | table-driven: (provider, `EngineContext.model`, pages, characters, file size, input mode, encrypted, memory) → expected `SendPlan`, including: Anthropic with a model whose window is 200,000 and a 34-page PDF → PDF, 1 request; the same with `model == nil` → text mode with a warning (153,000 > the 128,000 fallback); the same with `inputMode == .text` → text; an encrypted PDF → text with the "protected" warning; Ollama with 24 GiB and a 131,072 model → context 32,768, and 80,000 characters → 1 request; with 16 GiB → 16,384 and several parts + 1; `contextWindowOverride` wins over both; a CLI with `supportsNativePDF == false` → text, `sendsPDF == false`; context 2,048 → `blockingReason`; scanned PDF with a text-only provider → `blockingReason` |
| prompts | review system prompt contains the rubric ids and `FormatSpec.review`; PDF mode puts the `.pdf` part first and a `.cacheBoundary` after it; reviewer notes and existing titles appear in the task; text mode's task contains the extraction-artefact sentence; no prompt contains the document's file name |
| review, one pass | mock script → events in the order of §6.6 (no phase other than `.preparing`, `.reading`, `.wholePaperPass`); comments carry anchors from the fake matcher, labels, `.pending`; `RunRecord` has `requestCount == 1`, usage, `.completed` |
| review, in parts | 3 parts → 4 requests; request 2 contains the notes returned by request 1; the final notes are emitted once as `.digest` before `.finished` |
| continuation | first response ends with `.maxTokens` mid-block → a second request listing the titles so far; at most two continuations |
| repeats and similar | `review_dupes.txt`: an exact repeat (same quote and title) is dropped; a second comment of the same kind on the same quote with a different title is emitted with `similarTo` set to the first one's id; one of a different kind on the same quote has `similarTo == nil` |
| strength cap | a response with four `strength` blocks → two comments of that kind and one notice naming the two that were left out |
| failure mid-stream | mock fails after 3 chunks → comments so far, then `.finished` with `.failed`; the stream does not throw; a `.toolUseBlocked` failure gives the run that error's message |
| PDF fallback | mock throws `.contextTooLong` on a PDF request → one retry in text mode and a notice |
| cancellation | cancelling during streaming ends with `.finished` `.cancelled` promptly |
| discussion | reply text before `@@REVISED` is the visible reply; the block becomes a `CommentRevision`; `@@WITHDRAW` → `withdraw == true`; no block → `nil` |
| paper context | with a paper too large for 60% of the budget: `discuss` and `ask` requests contain `context.paperDigest` and the anchor's page; `ask` with no anchor and `generateReport` contain the digest and page 1; with `paperDigest == nil` they contain the pages alone |
| ask | the selected passage and its label appear in the request; a general question has no passage section |
| report | the request lists only approved, included comments in the order major, minor, question, strength with prefixes and labels; zero approved → the job fails without a request; the recommendation is parsed from four sample reports |
| lint | a table of sentences → expected rule ids (Appendix B.7), including a clean report with no findings and the recommendation/severity mismatch |
| privacy | with a sink added by `Log.addTestSink` before a full review and removed with `Log.removeTestSink` after it: among the engine's events (pick them by the engine's own event names, since the sink also sees the events of every other test running at the time), no value contains any 12-character substring of the paper text or of a prompt, and no `.id` value is "invalid-id" |

#### WP7 — ScholarKit (Wave 1)

Read: §8.7, §4.2, Appendix A.3, Appendix D.10.

Build: `ReferenceResolver` with clients for OpenAlex (DOI lookup) and Crossref (bibliographic query), host token buckets with an injectable clock, the per-document JSON cache, `forget`, the PDF cache with LRU eviction, `searchURL`.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter ScholarKitTests` (HTTP stubbed; JSON bodies recorded from the real services are in Appendix D.10):

| Test | Requirement |
|---|---|
| identifier short-circuits | an entry with an arXiv id makes no request and returns the abs and pdf URLs; an entry with a DOI makes exactly one request, to `api.openalex.org/works/doi:…` |
| Crossref path | an entry without identifiers → Crossref request with `query.bibliographic`, `rows=3`, the `select` list, and **no** `mailto` and no email in `User-Agent` by default; with a configured address both appear; the Hochreiter fixture resolves to DOI `10.1162/neco.1997.9.8.1735` and then calls OpenAlex |
| validation | a top hit with a different first author is rejected; a year off by 4 with all title words matching is accepted; a year off by 4 with 70% of title words is rejected; a title sharing under 60% of words is rejected; all rejected → `.notFound` |
| nothing else is called | no request ever goes to a host other than `api.crossref.org`, `api.openalex.org` and the host of a PDF being fetched |
| rate limits | with the test clock, two Crossref calls are at least 1 s apart and never concurrent |
| transient failures | 429 with `Retry-After: 1` is retried once; a second 429 → `.failed`, which is not cached |
| cache per document | a second `resolve` of the same entry for the same document makes no request and the file is `sessions/<sha>/references.json`; the same entry for another document makes a request; `forget(documentSHA256:)` removes that file and the next `resolve` makes a request; expiry rules of §8.7 |
| open access | `best_oa_location.pdf_url` is preferred; `oa_url` is used only if it ends in `.pdf`; none → `openAccessPDFURL == nil` |
| PDF fetch | stubbed PDF body → file in the cache directory whose bytes start with `%PDF-`; HTML body → `.notAPDF`; `http` URL → `.noOpenAccessPDF`; eviction keeps the directory under the limit |
| search URL | percent-encoding of a title with quotes, ampersands and non-ASCII letters |
| live (only with `REFEREE_LIVE_NET=1`) | the Hochreiter entry resolves against the real services |

#### WP8a — Persistence and report export (Wave 1)

Read: §4, §6.10 (export), §3.1 (main-actor tests), Appendix A.4, A.7.

Build: `AppPaths`, `FileSessionStore` (atomic save, backup, corrupt-file handling, version check, listing, delete), `FileSettingsStore` (defaults, filling in missing providers), and in `Sources/AppCore/Export/` the `ReportExporter` and `PaperSize` of §11.3 (file names start with `Export`).

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter PersistenceTests`, `scripts/test.sh --filter AppCoreTests` (in your worktree that target holds only your export tests and the Wave 0 smoke test):

| Test | Requirement |
|---|---|
| store round trip | save then load equals; the file is pretty-printed with sorted keys; a second save leaves a `.bak` with the first content |
| atomicity | a simulated failure between temp write and rename leaves the old file readable |
| corrupt file | garbage in `session.json` → the `.bak` is loaded, the bad file is renamed `session.corrupt-*.json`; both bad → `StoreError.corrupt` |
| versions | `schemaVersion: 2` → `StoreError.newerSchema(found: 2, supported: 1)` and the file is untouched; the §4.3 sample decodes; a session file without `similarTo` and a settings file without `verifiedAt` decode |
| listing and delete | three sessions → three summaries with correct counts, newest first; `deleteSession` removes the whole `sessions/<sha>/` folder, including a `references.json` placed there by the test |
| settings | missing file → `DefaultSettings.make()`; a file lacking a provider id gains it on load; unknown keys are ignored |
| paths | `REFEREE_HOME=/x` → data `/x`, caches `/x/Caches`; unset → the Application Support and Caches paths |
| export, text | Markdown → the text; plain text conversion of `report_sample.txt` (headings, numbered lists, emphasis) |
| export, Word (`@MainActor`) | `.docx` data starts with `PK`; read back with `NSAttributedString(data:options:)` it contains the six headings in bold |
| export, PDF (`@MainActor`) ● | a report of four headings with fourteen long items each: the data starts with `%PDF-`; `PDFDocument(data:)` has at least 3 pages; page 1's media box is 612 × 792 for `.letter` and 595 × 842 for `.a4`; **every page's `string` has more than 200 characters**; the last heading's text is found in the document |

#### WP8b — The two models (Wave 1)

Read: §2.3–§2.5, §4.5, §6.3–§6.10 (behaviour seen from the model), §7.4 (selection), §9.3–§9.8 (what the views will ask of the model), Appendix A.9.

Build: `ReviewSessionModel`, `SettingsModel`, `SelectionNormalizer`. All dependencies in tests are fakes from `TestSupport`; use an injected clock for debounces; every test is `@MainActor`.

Behaviour to implement in `ReviewSessionModel` beyond what the member names say:

- `open(url:)`: `.loading` → `paperService.load` → load or create the session by hash (update `lastKnownPath`, `fileName`) → for every comment and conversation whose anchor has a non-empty quote but no spans, re-anchor with the matcher (this is how sample sessions and older sessions heal) → build the citation index off the main actor and fill text-mention rects → `.ready`. Errors → `.failed(message:)`. An encrypted paper raises the "protected" info banner (§9.9).
- Provider for a job: `session.preferredProvider ?? settings.defaults.<job> ?? settings.defaults.review`; none or not enabled → banner "Set up an AI provider" with the action "Open Settings".
- `EngineContext` for every job: `model` = the entry for the chosen model id in the provider's list, taken from `settings.providers[id].cachedModels`, or from a list the model fetches itself with `listModels()` once per provider per window when the cached one is empty or older than a day; `paperDigest` = `session.paperDigest`. `sendPlan` is recomputed when the paper, provider, model list or settings change.
- `canStartReview` as its comment in Appendix A.9 says.
- Consent and Local-only as in §9.7; every job goes through one private gate `authorize(job:) async -> Bool`.
- Lanes as in §2.3; starting a job in a busy lane is ignored (the UI disables the buttons). Report and voice-revision text streams into `streamingReportText`; discussion and chat text into `streamingReplyText`.
- Review events: `.draft` → upsert in `drafts`; `.comment` → remove the draft, append to `session.comments`; `.notice` → info banner; `.digest` → `session.paperDigest`; `.finished` → append the `RunRecord`, `runState = .idle`, failed → error banner with Retry.
- `readerSelectionChanged`: `SelectionNormalizer.normalize` against `paper.text`; publish the result at once with empty rects, then fill `rects` from `paperService.rects(for:in:)`; a selection that normalises to nothing becomes `nil`.
- `setStatus`: updates the comment; approving sets `includeInReport = true`; then, when `settings.ui.autoAdvanceAfterTriage`, selects the next pending comment in visible order.
- `editComment`, `acceptProposedRevision`: push the old version to `previousVersions` (cap 20).
- `visibleComments` ordering exactly as its comment in Appendix A.9; `triage` counts decided (approved or rejected) over all.
- Report: `generateReport` replaces `session.report` at the end (old draft → `versions`, cap 10); `updateReportMarkdown` sets `userEdited` and re-lints after 0.5 s.
- Citations: `lookUpCitation(mentionID:)` and `lookUpEntry(entryID:)` → `.resolving(target:)` → resolve each candidate entry concurrently with `resolver.resolve(_:documentSHA256:)` → `.resolved(target:…)`.
- `deleteReviewData()`: cancel both lanes, `sessions.deleteSession`, `resolver.forget`, `close()`.
- Autosave as in §4.5.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter AppCoreTests`:

| Test | Requirement |
|---|---|
| open | fake paper → `.ready`, session created, comments with quotes get anchors, citations present |
| engine context | with `cachedModels` holding the chosen model, `ScriptedReviewEngine.contexts.last?.model` is that entry; with an empty cache the model calls `listModels()` once and the next plan carries it; after a review that emitted `.digest`, a discussion's context has that `paperDigest` |
| can start | `sendPlan.blockingReason != nil` → `canStartReview == false` |
| consent | non-local provider: `startReview` sets `consentRequest` and sends nothing; `answerConsent(granted: true)` records consent and starts; a second job does not ask; `granted: false` leaves state unchanged; local provider never asks; `localOnly` blocks with a banner |
| review flow | scripted events → drafts appear and are replaced; comments appended in order; run recorded; failure → banner and comments kept |
| triage | approve/reject/reset transitions; auto-advance picks the next pending in visible order; counts |
| ordering | a synthetic session with comments on two pages, one `.pageOnly`, one `.none`, two on one line → the order of Appendix A.9 |
| editing and revisions | edit pushes history; accept revision applies fields and clears the proposal; accept withdrawal rejects; discard clears |
| selection normalised | on a synthetic `PaperText` with margin digits, a watermark line and a number-only line: a two-line raw selection whose text is "…[2011],11\nnetwork…" becomes "…[2011], network…" with two spans inside the lines' `contentRange`; a selection that crosses the watermark and the number-only line contains neither; a selection only on a watermark line becomes `nil`; "iden-" + "tification" joins without the hyphen |
| own comments | with and without a selection (the anchor's quote is the normalised text); `reanchorComment` |
| lanes | a discussion can start while a review runs; a second review cannot; a report streaming does not write to `streamingReplyText` |
| report | generate → draft, recommendation, lint findings; edit → `userEdited`, re-lint; regenerate pushes a version; restore version |
| citations | `lookUpCitation` → `.resolved(target: .mention(id), …)`; `lookUpEntry` → `.resolved(target: .entry(id), …)` |
| delete | `deleteReviewData()` → the in-memory store has no session for the hash and `FakeResolver` saw `forget` |
| autosave | several mutations within the debounce → one save; `flushPendingSave` saves at once |
| settings model | `update` saves and posts the notification; `setSecret` updates `storedSecrets` and never exposes values, and with `InMemorySecretStore.failReads` leaves `storedSecrets` unchanged and reports the error; `refreshModels` fills `models` or `modelErrors` and writes `cachedModels`; `sendTestPrompt` success sets `verifiedAt`; `applyFirstRunDefaultsIfNeeded` selects Ollama only when its fake reports ready with a model, and never a remote provider |

#### Gate 1 — Merge, contract fixes, command line, end to end (one integrator, on `main`)

Read: §3.5, §3.6, §10.2, §10.4, §11.1, every `docs/contract-notes/*.md`, and the plan sections the notes point to.

Do, in this order:

1. Merge the nine Wave 1 branches (`git merge --no-ff wp/…`; order does not matter). After each: `scripts/build.sh`. After the last: `scripts/test.sh`.
2. Read every notes file's "Contract problems". For each: change `RefereeCore`, `TestSupport`, `Composition` or the plan's surface as needed, remove the workaround, fix call sites, and record the decision in `docs/contract-notes/gate1.md`. Update `plan.md` §11.3 and Appendix A in the same commit, so the plan stays the single source of truth for Wave 2.
3. Build the full `referee-cli` (§10.2), `scripts/e2e-ollama.sh`, `scripts/fetch-optional-fixtures.sh`, and `Tests/IntegrationTests` on the real implementations:

| Test | Requirement |
|---|---|
| pipeline on every fixture | load → `PaperText` → matcher → citations completes; all WP1 rows marked ● for `ay_nolinks` and `s1_ruler` hold through the real `PDFPaperService`, with highlight rectangles starting at x ≥ 100 |
| citations with line numbers ● | `ay_nolinks` and `s1_ruler` (real builder, real bounds): 9 entries with the first surnames of WP3's table and the same 15 mention targets |
| selection on a real page ● | `ay_nolinks`: a `SelectionInfo` whose spans are the raw ranges of `" As shown by Acemoglu et al. [2011],11"` and `"network structure determines wheth"` on page 1 → after `readerSelectionChanged`, `model.selection.text == "As shown by Acemoglu et al. [2011], network structure determines wheth"`, two rectangles, each with `x ≥ 100` and `width < 400`. A second one built from the raw ranges of `"Bikhchandani, S., Hirshleifer, D., and Welch, I. (1992). A theory of fads,41"` through `"fashion, custom, and cultural change as informational cascades. Journal"` on page 3 (which crosses the watermark line and the number-only line "42") → text without "CONFIDENTIAL", "41" or "42" |
| mock review end to end | `LiveDependencies.make` with `REFEREE_ENABLE_MOCK=1` and a temporary `REFEREE_HOME`: review of `ay_round_nolinks` yields 6 comments, at least 5 anchored `.exact`, session saved and reloadable |
| model end to end | `ReviewSessionModel` with live dependencies and the mock provider: open, review, approve all, generate report → a report with the six headings; export it as PDF and find text on every page |
| snapshot graph | `LiveDependencies.make` with `REFEREE_SNAPSHOT=1`: a review through `mock-remote` runs; `mock-fail` ends failed with two comments; no `URLSession` task and no process is started |
| file safety | fixture bytes are unchanged after a full open, review and report; `sessions/<sha>/` is gone after `deleteReviewData()` |
| no secrets in the tree | no file listed by `git ls-files` contains a match of `\bsk-(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Z])[A-Za-z0-9_-]{32,}`, `\bxai-[A-Za-z0-9]{32,}\b` or `\bAIza[0-9A-Za-z_-]{35}\b`. (The word boundary, the length and the required digit and capital keep ordinary hyphenated words such as "task-specific-identification-threshold" from matching.) |
| real papers (skipped when `Fixtures/private` is empty) | for each PDF there: the pipeline completes within 10 s; if the document has link annotations into its reference list, the sequence of entry ids from text mentions equals the sequence from link mentions |
| CLI | run the built binary `<repository root>/.build/debug/referee-cli` as a subprocess (root found from `#filePath`; the test requires the file to exist and fails with a clear message otherwise): `providers --json` parses; `review … --provider mock` prints `SUMMARY … status=completed`; `anchor` exit codes; `extract --stats` reports margin numbers 1–54 for `ay_nolinks` and a ruler of 1–60 per page for `s1_ruler` |

4. Run `scripts/fetch-optional-fixtures.sh` once and re-run the "real papers" test; run `REFEREE_TEST_KEYCHAIN=1 scripts/test.sh --filter LLMKitTests`.

Acceptance:

```
scripts/build.sh
scripts/test.sh                                                                                             # everything
"$(swift build --show-bin-path)"/referee-cli review Fixtures/pdf/ay_round_nolinks.pdf --provider mock      # ends with SUMMARY … status=completed
"$(swift build --show-bin-path)"/referee-cli extract Fixtures/pdf/s1_ruler.pdf --stats                     # ruler 1–60 on 4 pages
scripts/e2e-ollama.sh                                                                                       # exit 0 with gemma4:e4b
scripts/e2e-ollama.sh phi4                                                                                  # exit 0; exercises reading in parts
```

Wave 2 does not start until all of these pass. If `e2e-ollama.sh` cannot pass because of a model's behaviour and not the pipeline's, say so in `gate1.md` with the output and stop for the coordinator.

#### WP9 — Reader UI (Wave 2)

Read: §7, §8.6, §9.2, §9.5, §9.9, §9.10, §10.1, §11.3 (Reader and Common).

Build: `ReaderController` with the surface of §11.3, `RefereePDFView` (`mouseDown`, `areaOfInterest`), `ReaderPDFViewRepresentable`, `ReaderHighlightController`, `ReaderPane` (PDF, find bar, selection bar, citation card; no banner; no minimum width: the window's 1000 × 640 minimum is what keeps the PDF readable, and a declared minimum makes every review scene fail, §9.2), `NavigatorPane` (Pages / Outline / References), `ReferenceViewerView`, `ReaderScenes` (seven scenes of §10.1). Every file name starts with `Reader`. Pure helpers with unit tests: desired-highlight computation (comments + filter + selection → list of `(rect, colour, alpha, id)`), hit-testing (point + rect lists → comment id or mention id; smallest rectangle wins), overlay placement (page rect in bottom-left coordinates + view bounds → top-left SwiftUI origin that stays inside the view).

Acceptance:

```
scripts/build.sh
scripts/test.sh --filter RefereeUITests
scripts/snapshots.sh --scene reader-highlights --scene reader-selection --scene reader-citation --scene reader-find --scene reader-references --scene reader-ruler --scene reference-viewer     # exit 0, no failures
```

and, by looking at each PNG: highlights lie exactly on the quoted lines in the right colours and none reaches into the margin; the selected comment's highlight is stronger; the selection bar sits just above the selection; the citation card shows the reference text and its buttons and does not leave the window; the find bar shows a count and matches are marked; thumbnails show pages; the ruler scene shows the ruler page with its highlight; the reference viewer shows the two-column paper. Describe what you saw for each scene in your notes file.

#### WP10 — Sidebar UI (Wave 2)

Read: §9.3–§9.5, §9.8–§9.10, §6.8–§6.10, §10.1, §11.3 (Sidebar and Common).

Build: `ReviewSidebar` (tab switch bound to `model.sidebarTab`), `SidebarCommentsTab`, `SidebarCommentCard` and its states including "similar", `SidebarCommentEditor`, `SidebarThreadView`, `SidebarChatTab`, `SidebarReportTab` (editor showing `streamingReportText` while a report streams, preview, lint list, recommendation, versions, export menu using `NSSavePanel` and `model.exportReport`), `SidebarScenes` (seven scenes). Every file name starts with `Sidebar`. Pure helpers with unit tests: card view-state derivation (comment + model state → what the card shows), filter chips counts, Markdown preview conversion.

Acceptance:

```
scripts/build.sh
scripts/test.sh --filter RefereeUITests
scripts/snapshots.sh --scene sidebar-pending --scene sidebar-streaming --scene sidebar-states --scene sidebar-discussion --scene sidebar-editing --scene sidebar-chat --scene sidebar-report     # exit 0
```

and, by looking at each PNG: every state of §9.3 is distinguishable; no text is clipped at 380 pt width; buttons match the state; the streaming scene shows two finished cards and a draft; the report scene shows headings, lint findings and the export menu button. Describe each scene in your notes file.

#### WP11 — Shell and settings (Wave 2)

Read: §9.1, §9.2, §9.4, §9.6, §9.7, §9.9, §10.1, §11.3 (Shell and Common), §3.4 (bundle).

Build: `AppMain`, `ShellAppDelegate`, `ShellWindowManager` (settings notification → `reloadSettings`), `ShellMainMenu` (Find and zoom items call the key window's `ReaderController`), `ShellReviewWindowController` (creates the model and the reader, calls `attach()`, key monitor with `TriageKeymap`, title, close → flush), `ReviewWindowView` (composition of §9.2, toolbar, destination indicator and its menu, consent card, `BannerView`), `WelcomeView`, the settings window and panes on `SettingsModel`, drag-and-drop of PDFs onto windows, Open Recent, `ShellScenes` (seven scenes), `Fixtures/sessions/*` needed by scenes. Every file name starts with `Shell`. Unit tests: `TriageKeymap.intent` table; `TriageKeymap.apply` against a model on fakes; destination indicator state derivation including "text only" and "experimental"; the plan sentence and the consent text from a `SendPlan` and a descriptor.

Acceptance:

```
scripts/build.sh
scripts/test.sh --filter RefereeUITests
scripts/snapshots.sh                        # all scenes that exist in this worktree; exit 0
scripts/bundle.sh && codesign --verify build/Referee.app
build/Referee.app/Contents/MacOS/Referee --ui-snapshot build/snapshots-bundle --scene review-empty     # the bundled binary also works
```

and, by looking at the PNGs: three columns with toolbar, the Review button showing its word; the indicator text and colour for local and remote mock providers; the consent card wording of §9.7 including the text-only sentence; the error banner with Retry above the PDF; each settings pane complete and unclipped, one provider row with the experimental warning. Describe each scene in your notes file.

### 11.5 Final integration (Wave 3, one agent, on `main`)

1. Merge the three UI branches; `scripts/build.sh` after each, `scripts/test.sh` after the last. Read their notes; resolve "Contract problems" as Gate 1 did.
2. Write the three integration scenes of §10.1 (`check-document-loaded`, `check-citation-click`, `check-triage-keys`) in `CommonIntegrationScenes.swift`.
3. `scripts/snapshots.sh`: every scene, exit 0, no failures; look at every PNG now that all panes are real.
4. `scripts/e2e-ollama.sh`; `scripts/bundle.sh`; launch `build/Referee.app` once with `open -n build/Referee.app --args <fixture pdf>` and confirm from `/usr/bin/log show --info --last 1m --predicate 'subsystem == "local.referee.app"'` that the document reached `.ready` (`Log.event` writes at info level, which `log show` leaves out without `--info`; in zsh `log` is a builtin, hence the full path); run the bundled binary's snapshot mode.
5. The smoke prompts of §11.6: `REFEREE_CLI_SMOKE=1 scripts/test.sh --filter CLIProvidersTests`. Record which CLIs ran and the result.
6. Final `README.md`: install, first run, provider set-up (including what "experimental" means and the test-prompt button), privacy summary (§12.3, §12.5), troubleshooting (Codex reinstall, the Keychain prompt after a rebuild and the self-signed identity that removes it, Ollama not running), and a checklist of checks that need the user's accounts and are not run unasked: one real review per configured API provider and per installed CLI on a non-confidential PDF.

### 11.6 Real prompts allowed in this project

Subscription CLIs draw on the user's plan, so prompts to them are rationed. This table is complete: no agent sends any other prompt to a subscription CLI or to a paid API, and none ever contains a file of the user's.

| Who | When | To | What | How many |
|---|---|---|---|---|
| WP5 | acceptance | each installed, signed-in CLI (here: Claude Code, Codex) | "Reply with exactly: OK" through the adapter (`REFEREE_CLI_SMOKE=1`) | 1 each |
| WP5 | §5.6.6 | Claude Code | the delivery experiment with `Fixtures/pdf/ay_round_nolinks.pdf` | at most 3 |
| WP5 | §5.6.6 | Codex | the delivery experiment with the same file | at most 3 |
| Wave 3 | step 5 | each installed, signed-in CLI | the same smoke prompt | 1 each |

Local Ollama models are free and are used wherever a real model is needed. A CLI that is installed but not signed in is skipped, never signed in by an agent.

---

## 12. Security & privacy

### 12.1 Secrets

- API keys live only in the Keychain item of §5.8, or in `REFEREE_KEY_*` environment variables for the CLI and tests. They are never written to `settings.json`, session files, logs, snapshots, crash output or the repository.
- The app never reads or stores subscription credentials. CLI providers run the vendor's binary, which reads its own credential store.
- `.gitignore` (§3.3) covers build output, `Fixtures/private/`, `.env` and `*.local.json`. The repository contains only synthetic manuscripts. An integration test fails if any tracked file contains a string shaped like a vendor key (patterns in Gate 1's table: anchored at word boundaries, and applied to `git ls-files`, not to `.build/`).
- Nothing personal (name, email, institution) is in source, defaults or requests. The Crossref contact email is a user setting, empty by default.

### 12.2 No manuscript text in logs

- `Log.event(name, [String: LogValue])` is the only logging call in libraries. A `LogValue` is a number, a boolean, or an `.id`, and an `.id` that is longer than 64 characters or contains anything but letters, digits and `. _ : / -` is written as `invalid-id` (Appendix A.8). A sentence of a manuscript cannot pass that filter; a test with a sink from `Log.addTestSink` checks a whole review (WP6, "privacy").
- File names are treated as manuscript content (they often contain manuscript numbers or author names): never logged, never sent to a provider (`manuscript.pdf` is sent instead).
- Error messages shown to the user may quote a provider's message; they are not logged. CLI stderr is shown, not logged.
- The only switch that writes prompts or model output outside the session file is `REFEREE_DEBUG_DUMP` (§10.5).

### 12.3 What leaves the machine, and when

| Data | Goes to | When |
|---|---|---|
| The PDF file, or its extracted text | the selected AI provider (shown in the toolbar) | only when the user starts a review, sends a discussion message, asks a question, or generates or revises a report; first time per document and provider needs explicit consent |
| Approved comments, discussion text, reviewer notes | the same provider | with those same actions |
| One reference's text or identifier | Crossref, OpenAlex | when the user clicks that citation (or for all references if the user turned on background lookups) |
| A request for an open-access PDF | the host of that PDF | when the user clicks Open PDF |
| An API key | its own vendor's API host | with each request to that vendor, including listing models when a provider is selected |
| Nothing else | | no telemetry, no update checks, no crash reporting |

With an Ollama provider on loopback and no citation clicked, the app makes no network connection other than to `127.0.0.1`. "Local only" enforces that for AI providers; reference lookups are a separate, visible choice.

Provider-side retention is reduced where the API offers a switch: `store: false` for OpenAI and Gemini; an endpoint that stores nothing for xAI; no session persistence for Claude Code; ephemeral session and no history for Codex. Antigravity may keep a local conversation record; Grok Build does keep one, which the adapter deletes after each run and which may already have been synced to the user's xAI account (§5.6.4). Their rows and the consent card say so.

### 12.4 Local data

- Review data: `~/Library/Application Support/Referee/sessions/<hash>/`. It contains quotes from the manuscript, the reviewer's comments, and the reference lookups made for it. "Delete Review Data…" removes one review's folder; Settings ▸ Privacy removes all.
- Downloaded papers: `~/Library/Caches/Referee/papers/`, clearable in Settings.
- Temporary files: the per-run CLI working directory (the system prompt file; in the delivery modes of §5.6.6 a copy of the manuscript or its page images), mode 0700, removed after each run and on next launch if a crash left one.
- What the vendors' CLIs write on their own account is outside the app's control and not fully known: Codex keeps a log database under `~/.codex` whose contents were not examined; Grok Build keeps sessions under `~/.grok` (deleted by the adapter); Antigravity keeps conversations that can be resumed by id. The README says this.
- The app is not sandboxed (it must launch CLIs and read PDFs anywhere). It requests no entitlements, no Accessibility, no Screen Recording, no Full Disk Access.

### 12.5 Untrusted input, and what each provider can do with it

A manuscript is somebody else's text and can contain instructions aimed at a model ("ignore your instructions and …"). What such text can achieve depends on the route.

| Route | Can the model act on the machine? | Basis |
|---|---|---|
| API-key providers, Ollama | No. Requests declare no tools; the model can only return text. | by construction |
| Claude Code | No tools are available: `--tools ""`, safe mode, no MCP servers. The adapter refuses to proceed unless the CLI's first line confirms empty tool and MCP lists. | flags [V help text]; runtime list confirmed on every run by the tripwire |
| Codex | Shell, image, sleep and agent tools are removed [V, rendered tool list]. A code-orchestration tool with file patching and MCP-resource listing remains and cannot be removed; the sandbox is read-only. If the model uses any tool the adapter kills the run, but it learns of a tool when Codex reports it, which can be after it ran. | flags [V]; sandbox effect on patches [A] |
| Antigravity (experimental) | Tools cannot be removed. Commands, web access and MCP calls need an approval nobody can give, so the CLI denies them; file writes are allowed inside an empty temporary folder; a sandbox confines anything that runs. The user's own allow rules still apply. The adapter kills the run on the first reported tool step, which can be after it ran. | documentation only [D]; never run here |
| Grok Build (experimental) | The app's protocol client grants no file or terminal access and approves nothing; the process runs in the vendor's strict sandbox with permission mode "deny unless allowed" and the built-in tools disallowed. The adapter kills the run on the first reported tool call. | protocol behaviour and flags from documentation [D]; never run here |
| Claude Code in read-tool mode (only if §5.6.6 ends there) | One tool, Read, confined to a temporary folder that holds only the manuscript copy. | flag [V help text]; checked per call by the tripwire |

In every route, what the model writes is treated as untrusted text: parsers are total and bounded (WP1, WP3, WP6 robustness tests); model output is rendered as plain text or through `AttributedString(markdown:)` with links disabled in comment cards; nothing a model writes is executed, fetched or opened automatically. The worst a successful injection can do through an API provider is distort comments that the reviewer then reads and triages.

The honest summary for the user, shown in Settings ▸ Privacy: API-key and local providers cannot touch the machine. Subscription CLIs are agents; Referee switches their tools off where the CLI allows it, runs them in an empty folder, and stops them if they try to use a tool. For Antigravity and Grok Build none of this has been tested against the real program on this Mac until the test prompt succeeds.

Downloaded PDFs are `https` only, size-limited, and checked for the PDF signature before PDFKit opens them.

---

## 13. Risks and open questions

Each item has a default so that nothing waits for the user.

### 13.1 Risks

| # | Risk | Mitigation | Default if unresolved |
|---|---|---|---|
| R1 | **Antigravity and Grok Build adapters are written from documentation.** Neither CLI has been run here; Grok's flags may not combine with its protocol mode; plan coverage of non-interactive Grok use is not stated by xAI. | The flag check stops a provider whose binary lacks a safety option; the tripwire stops a run that uses a tool; WP5 reads Grok's real help text if npm can install it; both rows carry the experimental warning until a test prompt succeeds. | Ship both as experimental. If the flag check fails on the real binary, the provider stays unavailable with the reason shown; that is a correct outcome, not a bug. |
| R2 | **Claude Code may change headless defaults.** The docs say `--bare` "will become the default for `-p`", and bare mode ignores the subscription login. | `availability()` plus clear `.auth` mapping make the failure obvious; the fix would be one flag in one argument table; the API-key provider is the fallback. | Keep the invocation of §5.6.4; revisit when a Claude Code release note announces the change. |
| R3 | **Subscription use from a third-party app** is governed by Anthropic's terms (§5.6.5) and by the other vendors' plans. | The app only launches the user's own installed binary for the user's own work; no credentials are touched; wording in the UI avoids "sign in". | Personal use only. Before giving the app to anyone else, re-read the terms and consider disabling the CLI providers. |
| R4 | **Real journal-system PDFs have not been examined.** Both journal styles are covered by synthetic fixtures; where PDFKit puts a real ScholarOne ruler's numbers, and how Editorial Manager stamps pages, is unknown. | One rule set for glued and stand-alone numbers; nearest-number labels; fuzzy anchoring; page-only fallback; an off switch; `extract --stats`; `Fixtures/private` and the "real papers" test. | Ship with synthetic fixtures; ask the user for two real files (Q7) and tune at Gate 1 or after. |
| R5 | **PDFKit text quirks**: missing spaces in tight lines, garbled mathematics, unusable per-character geometry. | Matching and citation detection ignore whitespace and punctuation; geometry only through selections; PDF mode sends the real file to capable providers; the text-mode prompt tells the model not to comment on extraction artefacts. | As designed. |
| R6 | **Anchoring in PDF mode**: the provider's own text extraction (or, for page images, its reading of the image) may differ from PDFKit's, lowering exact matches. | Folded matching and the fuzzy stage; page hint from the model; page-only fallback; the SUMMARY line and run records expose the anchoring rate. | Accept; if under 80% of comments anchor on real papers, add the extracted text of the quoted page to a follow-up "locate" request. |
| R7 | **Small local models ignore the format or write poor comments.** | Tolerant parser, JSON and prose fallbacks, continuation; one pass at 32k on this machine; thinking off by default; the strength cap and the "similar" mark. Quality itself is the model's limit. | Recommend `gemma4:e4b` or larger in the README; keep `phi4` working through parts. |
| R8 | **Context estimates are rough** (3.5 characters per token; assumed windows for OpenAI and CLIs). | Model lists feed real windows where vendors publish them; per-provider override; automatic text-mode fallback on "too long"; Ollama full-context warning. | As designed. |
| R9 | **Keychain after a rebuild**: an ad-hoc-signed app gets a new identity, reads need approval, and writes do not. | One item; `setSecret` refuses to write when it could not read (§5.8); a self-signed identity removes the prompt; CLI and tests use environment keys. | Ad-hoc signing; document the prompt and the identity option. |
| R10 | **Stale or broken CLI binaries** (seen with Codex here). | Validation with timeout, several candidate locations, clear install hints. | As designed; the user reinstalls Codex. |
| R11 | **Snapshot capture depends on a symbol hidden from the Swift SDK** (`CGWindowListCreateImage` via `dlsym`) and a logged-in GUI session. | Verified today by three parties; used only in a developer mode, never in normal operation. | If a future OS removes it, switch the snapshot mode to ScreenCaptureKit (needs Screen Recording permission). |
| R12 | **xAI calls Chat Completions deprecated.** | It is the endpoint whose stream xAI documents and the one that stores nothing; the OpenAI Responses adapter already exists. | When xAI retires it, point `xai-api` at the Responses adapter with `store: false` (one line) and verify its stream with a real key. |
| R13 | **Gemini `v1` Interactions path** may not be enabled for every key or region. | One automatic retry on `v1beta` after a path-level 404. | As designed. |
| R14 | **References the two services do not know** (working papers, books) end in "No match found". | Printed DOIs and arXiv ids need no search; the year rule accepts published versions of working papers; Search Google Scholar is always one click away. | As designed; add a title search only if the user misses it. |
| R15 | **Journals may forbid AI tools for manuscripts under review.** | Local-only mode; per-document consent with a reminder; the audit trail of runs in the session. | The reviewer decides per manuscript. |
| R16 | **Cost surprises** with large PDFs on premium models. | The consent card and indicator show request count and token estimate; text mode is one click away. | No price table (prices change); tokens only. |
| R17 | **A model invents references** in "missing literature" comments. | Prompt forbids citing unless sure; such comments carry a "verify" tag in the card when category is `literature`. | Tag only. |
| R18 | **Agents diverge from the contracts.** | Appendix A and §11.3 were compiled together; Gate 0 checks Wave 0 against them; frozen paths; notes files; Gate 1 fixes contracts once, before the UI. | As designed. |
| R19 | **Multi-column manuscripts** read in PDFKit's order: some quotes anchor to the page only, and a reference list in the middle of a page is ended by the column rule. | The smoke fixture; fuzzy and page-only fallbacks; PDF mode is unaffected. | Accept in v1 (the user's field is single-column); reading-order repair is the first candidate for v1.1. |
| R20 | **The tripwire is detective for Codex and Antigravity**: a tool that needs no approval can run before its step is reported. | Flags and sandbox remove or confine the tools first; the working folder is empty; the run is killed and its later output discarded; §12.5 says this plainly. | Accept for Codex (read-only sandbox). For Antigravity it is one more reason for the experimental label. |
| R21 | **Subscription routes may stay text-only** if the delivery experiment fails for both CLIs. | The indicator and consent card say "text only: equations and tables may be garbled"; API-key providers and PDF mode remain. | Whatever the experiment finds; no workaround beyond the three variants. |
| R22 | **Citation heuristics meet a reference style they have not seen.** | Bibliography-driven matching fails safe (no match → no click target, PDFKit's own links still work); the end-of-list rules need positive evidence; the real-papers test compares the two detection paths wherever a PDF has links. | As designed. |

### 13.2 Open questions for the user (defaults in force until answered)

| # | Question | Default |
|---|---|---|
| Q1 | Name and identifier: "Referee", `local.referee.app`? | Yes. |
| Q2 | Which provider should be preselected on first run? | Ollama, if it is running and has a model (`SettingsModel.applyFirstRunDefaultsIfNeeded`). Otherwise none: the Welcome window points to Settings. The app never enables a remote provider by itself. |
| Q3 | May the README tell you to install Antigravity CLI and Grok Build and to reinstall Codex CLI? The app itself installs nothing. (WP5 installs Grok Build through npm to read its help text, as agreed.) | Yes; hints only. |
| Q4 | Reference lookups only on click, or all at open? | Only on click. |
| Q5 | Review data in Application Support (keyed by file hash) rather than next to the PDF? | Yes. |
| Q6 | Export formats: Markdown, plain text, Word, PDF. Any journal need another? | Those four. |
| Q7 | Can you provide two real journal-system PDFs that are not confidential (for example your own past submissions as built by Editorial Manager and by ScholarOne) for `Fixtures/private`? This is the largest remaining unknown (R4). | Proceed without. |
| Q8 | Will anyone else use the app? | No (see R3). |
| Q9 | Should approving a comment include it in the report automatically? | Yes. |
| Q10 | Do you want an optional "Confidential comments to the editor" section in the report template? | Not in the default template; add it by editing the template. |
| Q11 | Should the model be allowed web search for the "missing literature" question in a later version? | Not in v1. |
| Q12 | Do you want a self-signed code-signing certificate set up, so that rebuilding the app never triggers the Keychain prompt? | No; ad-hoc signing, and the README explains the option. |

---

## Appendix A. Contracts (Swift)

These files are the shared language of the project. A.1–A.8 are the complete contents of `Sources/RefereeCore/` apart from `DefaultSettings` and `FormatSpec` (§11.3); they compile exactly as printed (Swift 5 language mode, no warnings) [V]. Wave 0a copies them verbatim. Every public struct carries its public memberwise initialiser inside the struct: parameters in declaration order, optionals defaulting to `nil`, arrays to `[]`, dictionaries to `[:]`. A.9 lists the public members of the two application models in `AppCore` (declarations only; it compiles with stub bodies [V]).

### A.1 `Basics.swift`

```swift
import Foundation
import CoreGraphics

public typealias ProviderID = String

/// UTF-16 range into `PageText.string` (== `PDFPage.string`). The only text coordinate system in the app.
public struct TextRange: Codable, Sendable, Hashable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public init(_ r: NSRange) { self.location = r.location; self.length = r.length }
    public var upperBound: Int { location + length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

public struct TextSpan: Codable, Sendable, Hashable {
    public var pageIndex: Int          // 0-based PDF page index
    public var range: TextRange
    public init(pageIndex: Int, range: TextRange) { self.pageIndex = pageIndex; self.range = range }
}

/// Rectangle in PDF page space (origin bottom-left, points), as returned by PDFSelection.bounds(for:).
public struct PageRect: Codable, Sendable, Hashable {
    public var pageIndex: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(pageIndex: Int, x: Double, y: Double, width: Double, height: Double) {
        self.pageIndex = pageIndex; self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct PageSize: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// Every error type in the app conforms to this so the UI can render any failure uniformly.
public protocol RefereeError: Error, Sendable {
    var userMessage: String { get }          // one sentence, no manuscript text, safe to log
    var recoverySuggestion: String? { get }
    var isRetryable: Bool { get }
}
```

### A.2 `Paper.swift`

```swift
import Foundation

public struct DocumentRef: Codable, Sendable, Hashable {
    public var sha256: String            // lowercase hex of the PDF file bytes; primary key of a session
    public var fileName: String
    public var lastKnownPath: String?
    public var byteCount: Int
    public var pageCount: Int
    public init(sha256: String, fileName: String, lastKnownPath: String? = nil, byteCount: Int, pageCount: Int) {
        self.sha256 = sha256; self.fileName = fileName; self.lastKnownPath = lastKnownPath; self.byteCount = byteCount; self.pageCount = pageCount
    }
}

// ---- Raw extraction (produced by PDFBridge straight from PDFKit) ----

public struct RawLine: Codable, Sendable, Equatable {
    public var range: TextRange          // range in page string, excluding the trailing newline
    public var text: String              // == page string substring(range)
    public var bounds: PageRect?         // PDFSelection bounds of the whole line; x and width are wrong when margin digits are glued to it
    public init(range: TextRange, text: String, bounds: PageRect? = nil) { self.range = range; self.text = text; self.bounds = bounds }
}

public struct RawPage: Codable, Sendable, Equatable {
    public var index: Int
    public var label: String?
    public var size: PageSize            // mediaBox size
    public var string: String            // PDFPage.string ?? ""
    public var lines: [RawLine]          // from page.selection(for: whole).selectionsByLine(): ranges increase and never overlap.
                                         // Their number is NOT the number of newline-separated lines of `string`.
    public init(index: Int, label: String? = nil, size: PageSize, string: String, lines: [RawLine] = []) {
        self.index = index; self.label = label; self.size = size; self.string = string; self.lines = lines
    }
}

public enum RawLinkTarget: Codable, Sendable, Equatable {
    case internalDestination(pageIndex: Int, x: Double, y: Double)   // PDFActionGoTo / annotation.destination
    case url(String)                                                 // PDFActionURL / annotation.url
    case other
}

public struct RawLink: Codable, Sendable, Equatable {
    public var pageIndex: Int
    public var bounds: PageRect
    public var text: String              // text under the annotation (page.selection(for: bounds)), may be empty
    public var target: RawLinkTarget
    public init(pageIndex: Int, bounds: PageRect, text: String, target: RawLinkTarget) {
        self.pageIndex = pageIndex; self.bounds = bounds; self.text = text; self.target = target
    }
}

public struct OutlineItem: Codable, Sendable, Equatable, Identifiable {
    public var id: Int                   // preorder index
    public var title: String
    public var pageIndex: Int?
    public var depth: Int
    public init(id: Int, title: String, pageIndex: Int? = nil, depth: Int) { self.id = id; self.title = title; self.pageIndex = pageIndex; self.depth = depth }
}

public struct RawDocument: Codable, Sendable, Equatable {
    public var pages: [RawPage]
    public var links: [RawLink]
    public var outline: [OutlineItem]
    public init(pages: [RawPage] = [], links: [RawLink] = [], outline: [OutlineItem] = []) { self.pages = pages; self.links = links; self.outline = outline }
}

// ---- Clean text model (produced by PaperText.PaperTextBuilder; bounds finalised by PDFBridge) ----

public enum LineKind: String, Codable, Sendable {
    case body, marginNumberOnly, pageNumber, runningHeader, runningFooter, watermark, empty
}

public struct TextLine: Codable, Sendable, Equatable {
    public var pageIndex: Int
    public var range: TextRange          // the raw line
    public var contentRange: TextRange   // raw line minus the margin line number; == range when there is none
    public var text: String              // page string substring(contentRange)
    public var kind: LineKind
    public var marginNumber: Int?        // the printed line number of this line, or the margin (ruler) number level with it; nil when there is none
    public var bounds: PageRect?         // bounds of contentRange (clean geometry)
    public init(pageIndex: Int, range: TextRange, contentRange: TextRange, text: String, kind: LineKind, marginNumber: Int? = nil, bounds: PageRect? = nil) {
        self.pageIndex = pageIndex; self.range = range; self.contentRange = contentRange; self.text = text; self.kind = kind; self.marginNumber = marginNumber
        self.bounds = bounds
    }
}

public struct PageText: Codable, Sendable, Equatable {
    public var index: Int
    public var label: String?
    public var size: PageSize
    public var string: String            // raw PDFPage.string: the coordinate system for every TextRange on this page
    public var lines: [TextLine]         // in string order (PDFKit's order). Multi-column pages are not re-ordered in v1.
    public init(index: Int, label: String? = nil, size: PageSize, string: String, lines: [TextLine] = []) {
        self.index = index; self.label = label; self.size = size; self.string = string; self.lines = lines
    }
}

public struct PaperText: Codable, Sendable, Equatable {
    public var pages: [PageText]
    public var hasTextLayer: Bool            // false => scanned PDF (fewer than 200 letters in total)
    public var hasMarginLineNumbers: Bool    // lineno-style numbers on the text lines, or a ruler of numbers down the margin
    public var titleGuess: String?
    public init(pages: [PageText] = [], hasTextLayer: Bool, hasMarginLineNumbers: Bool, titleGuess: String? = nil) {
        self.pages = pages; self.hasTextLayer = hasTextLayer; self.hasMarginLineNumbers = hasMarginLineNumbers; self.titleGuess = titleGuess
    }
}

public struct LoadedPaper: Sendable, Equatable {
    public var ref: DocumentRef
    public var data: Data                    // the original, unmodified file bytes
    public var isEncrypted: Bool             // owner-password or permission-restricted PDF that opened without a password: its text is readable,
                                             // but the file itself is never sent to a provider (vendors reject encrypted PDFs)
    public var text: PaperText
    public var links: [RawLink]
    public var outline: [OutlineItem]
    public init(ref: DocumentRef, data: Data, isEncrypted: Bool, text: PaperText, links: [RawLink] = [], outline: [OutlineItem] = []) {
        self.ref = ref; self.data = data; self.isEncrypted = isEncrypted; self.text = text; self.links = links; self.outline = outline
    }
}

/// What the user has selected in the PDF view (computed on the main actor from PDFSelection).
/// As delivered by the view it can contain margin numbers and watermark text; ReviewSessionModel.readerSelectionChanged
/// normalises it against PaperText before anything else uses it (plan section 7.4).
public struct SelectionInfo: Sendable, Equatable {
    public var text: String
    public var spans: [TextSpan]             // one per text line touched
    public var rects: [PageRect]
    public init(text: String, spans: [TextSpan] = [], rects: [PageRect] = []) { self.text = text; self.spans = spans; self.rects = rects }
}

// ---- Anchoring ----

public enum AnchorConfidence: Codable, Sendable, Equatable {
    case exact
    case fuzzy(score: Double)   // 0.75 ... 1.0
    case pageOnly
    case none
}

public struct AnchorMatch: Sendable, Equatable {
    public var spans: [TextSpan]            // one per text line touched, in text order; never empty
    public var confidence: AnchorConfidence // .exact or .fuzzy
    public init(spans: [TextSpan] = [], confidence: AnchorConfidence) { self.spans = spans; self.confidence = confidence }
}

public protocol PaperTextBuilding: Sendable {
    /// Pure function of its input. Classifies lines, detects and strips margin line numbers, detects boilerplate.
    /// Leaves `TextLine.bounds` equal to the raw line bounds; PDFBridge recomputes bounds where contentRange != range.
    func build(from raw: RawDocument) -> PaperText
}

public protocol QuoteMatching: Sendable {
    /// `pageHint` is a 0-based page index. Returns nil when the quote cannot be located anywhere.
    func locate(quote: String, pageHint: Int?) -> AnchorMatch?
    /// "p. 4, lines 14–16", "p. 4, line 9", "p. 4", or across a page break "pp. 4–5 (p. 4 line 58 to p. 5 line 3)" / "pp. 4–5".
    /// Line numbers come from TextLine.marginNumber of the first and last lines touched.
    func locationLabel(for spans: [TextSpan]) -> String
}

public protocol PaperRendering: Sendable {
    /// LLM-facing text (plan section 6.2): body lines joined into paragraph-like lines, de-hyphenated, with one
    /// "[[page N]]" marker line (1-based) per page, placed at a sentence boundary.
    func render(_ paper: PaperText, pages: Range<Int>?) -> String
    /// Splits into consecutive page ranges whose rendered size is <= maxCharacters each (a single page may exceed it).
    func chunkPageRanges(_ paper: PaperText, maxCharacters: Int) -> [Range<Int>]
}

public protocol PaperService: Sendable {
    func load(url: URL) async throws -> LoadedPaper
    func load(data: Data, fileName: String) async throws -> LoadedPaper
    /// Highlight rectangles for spans: one rect per text line touched, margin numbers excluded.
    func rects(for spans: [TextSpan], in document: DocumentRef) async -> [PageRect]
    func unload(_ document: DocumentRef) async
}

public enum PaperError: RefereeError, Equatable {
    case unreadable(String)
    case notAPDF
    case encrypted
    case empty
    public var userMessage: String {
        switch self {
        case .unreadable(let why): return "The file could not be read (\(why))."
        case .notAPDF: return "This file is not a PDF."
        case .encrypted: return "This PDF is password-protected."
        case .empty: return "This PDF has no pages."
        }
    }
    public var recoverySuggestion: String? { nil }
    public var isRetryable: Bool { false }
}
```

### A.3 `Citations.swift`

```swift
import Foundation

public enum CitationStyle: String, Codable, Sendable { case numeric, authorYear, unknown }

public struct ParsedReference: Codable, Sendable, Equatable {
    public var authorSurnames: [String]      // in printed order
    public var year: Int?
    public var yearSuffix: String?           // "a", "b"
    public var title: String?
    public var doi: String?                  // bare, lowercased, no URL prefix
    public var arxivID: String?
    public var url: String?
    public init(authorSurnames: [String] = [], year: Int? = nil, yearSuffix: String? = nil, title: String? = nil, doi: String? = nil, arxivID: String? = nil,
                url: String? = nil) {
        self.authorSurnames = authorSurnames; self.year = year; self.yearSuffix = yearSuffix; self.title = title; self.doi = doi; self.arxivID = arxivID
        self.url = url
    }
}

public struct BibEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int                       // 0-based position in the reference list
    public var label: String?                // "13" for numeric lists
    public var rawText: String               // entry lines joined by a space, margin numbers removed
    public var spans: [TextSpan]
    public var firstLineBounds: PageRect?
    public var parsed: ParsedReference
    public init(id: Int, label: String? = nil, rawText: String, spans: [TextSpan] = [], firstLineBounds: PageRect? = nil, parsed: ParsedReference) {
        self.id = id; self.label = label; self.rawText = rawText; self.spans = spans; self.firstLineBounds = firstLineBounds; self.parsed = parsed
    }
}

public enum MentionSource: String, Codable, Sendable { case linkAnnotation, textPattern }

public struct CitationMention: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var pageIndex: Int
    public var text: String                  // "Smith and Jones (2019)", "12"
    public var spans: [TextSpan]             // one per text line touched; empty when only the link rectangle is known
    public var rects: [PageRect]             // click targets
    public var entryIDs: [Int]               // candidate BibEntry ids; empty = unresolved
    public var source: MentionSource
    public init(id: Int, pageIndex: Int, text: String, spans: [TextSpan] = [], rects: [PageRect] = [], entryIDs: [Int] = [], source: MentionSource) {
        self.id = id; self.pageIndex = pageIndex; self.text = text; self.spans = spans; self.rects = rects; self.entryIDs = entryIDs; self.source = source
    }
}

public struct CitationIndex: Codable, Sendable, Equatable {
    public var style: CitationStyle
    public var entries: [BibEntry]
    public var mentions: [CitationMention]
    public var bibliographyHeading: TextSpan?
    public init(style: CitationStyle, entries: [BibEntry] = [], mentions: [CitationMention] = [], bibliographyHeading: TextSpan? = nil) {
        self.style = style; self.entries = entries; self.mentions = mentions; self.bibliographyHeading = bibliographyHeading
    }
}

public protocol CitationIndexing: Sendable {
    /// Pure. Text-pattern mentions come back with `rects == []`; the caller fills them with PaperService.rects(for:in:).
    func buildIndex(paper: PaperText, links: [RawLink]) -> CitationIndex
}

// ---- Resolution ----

public enum ResolutionSource: String, Codable, Sendable { case entryText, linkAnnotation, crossref, openAlex }
public enum ResolutionStatus: String, Codable, Sendable { case resolved, notFound, failed }

public struct ResolvedReference: Codable, Sendable, Equatable {
    public var entryID: Int
    public var status: ResolutionStatus      // .failed = transient (network, rate limit); never cached
    public var title: String?
    public var authors: [String]
    public var year: Int?                    // may differ from the entry's year (working paper vs. published version); the card says so
    public var venue: String?
    public var doi: String?
    public var arxivID: String?
    public var landingURL: String?
    public var openAccessPDFURL: String?
    public var source: ResolutionSource?
    public var confidence: Double            // 1.0 when the identifier was printed in the entry itself
    public var resolvedAt: Date
    public init(entryID: Int, status: ResolutionStatus, title: String? = nil, authors: [String] = [], year: Int? = nil, venue: String? = nil,
                doi: String? = nil, arxivID: String? = nil, landingURL: String? = nil, openAccessPDFURL: String? = nil, source: ResolutionSource? = nil,
                confidence: Double, resolvedAt: Date) {
        self.entryID = entryID; self.status = status; self.title = title; self.authors = authors; self.year = year; self.venue = venue; self.doi = doi
        self.arxivID = arxivID; self.landingURL = landingURL; self.openAccessPDFURL = openAccessPDFURL; self.source = source; self.confidence = confidence
        self.resolvedAt = resolvedAt
    }
}

public enum ResolverError: RefereeError, Equatable {
    case noOpenAccessPDF
    case downloadFailed(String)
    case notAPDF
    case offline
    public var userMessage: String {
        switch self {
        case .noOpenAccessPDF: return "No open-access PDF was found for this reference."
        case .downloadFailed(let why): return "The PDF could not be downloaded (\(why))."
        case .notAPDF: return "The link did not return a PDF."
        case .offline: return "You appear to be offline."
        }
    }
    public var recoverySuggestion: String? { "Open the reference in your browser instead." }
    public var isRetryable: Bool { if case .downloadFailed = self { return true }; return self == .offline }
}

public protocol ReferenceResolving: Sendable {
    /// Never throws; inspect `status`. Reads and writes that document's lookup cache, sessions/<sha256>/references.json.
    func resolve(_ entry: BibEntry, documentSHA256: String) async -> ResolvedReference
    /// Drops every cached lookup made for that document, in memory and on disk. Called when a review is deleted.
    func forget(documentSHA256: String) async
    /// Returns a local file URL in the PDF cache. Throws ResolverError.
    func fetchPDF(for reference: ResolvedReference) async throws -> URL
    /// Manual fallback: a Google Scholar query URL built from the entry text.
    func searchURL(for entry: BibEntry) -> URL
}
```

### A.4 `Session.swift`

```swift
import Foundation

public enum CommentKind: String, Codable, Sendable, CaseIterable { case major, minor, question, strength }
public enum CommentStatus: String, Codable, Sendable { case pending, approved, rejected }
public enum CommentOrigin: Codable, Sendable, Equatable { case ai(runID: UUID), user }

public struct Anchor: Codable, Sendable, Equatable {
    public var quote: String                 // exactly as written by the model or selected by the user
    public var spans: [TextSpan]             // one per text line touched; empty for .pageOnly and .none
    public var rects: [PageRect]             // highlight rectangles (cached; derived from spans)
    public var pageIndex: Int?               // 0-based; set for everything except .none
    public var confidence: AnchorConfidence
    public var locationLabel: String         // "p. 4, lines 14–16" (en dash); "" when unanchored
    public init(quote: String, spans: [TextSpan] = [], rects: [PageRect] = [], pageIndex: Int? = nil, confidence: AnchorConfidence, locationLabel: String) {
        self.quote = quote; self.spans = spans; self.rects = rects; self.pageIndex = pageIndex; self.confidence = confidence; self.locationLabel = locationLabel
    }
}

public enum MessageRole: String, Codable, Sendable { case user, assistant }

public struct ThreadMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    public var provider: ProviderRef?        // set on assistant messages
    public init(id: UUID, role: MessageRole, text: String, createdAt: Date, provider: ProviderRef? = nil) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt; self.provider = provider
    }
}

public struct CommentRevision: Codable, Sendable, Equatable {
    public var kind: CommentKind
    public var title: String
    public var body: String
    public var suggestion: String?
    public var withdraw: Bool                // true = the assistant proposes dropping the comment
    public init(kind: CommentKind, title: String, body: String, suggestion: String? = nil, withdraw: Bool) {
        self.kind = kind; self.title = title; self.body = body; self.suggestion = suggestion; self.withdraw = withdraw
    }
}

public struct ReviewComment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var origin: CommentOrigin
    public var status: CommentStatus
    public var kind: CommentKind
    public var category: String              // RubricCategory.id; unknown ids display as "Other"
    public var title: String
    public var body: String
    public var suggestion: String?
    public var anchor: Anchor
    public var thread: [ThreadMessage]
    public var proposedRevision: CommentRevision?
    public var previousVersions: [CommentRevision]   // pushed on each accepted revision or manual edit (max 20)
    public var includeInReport: Bool
    public var similarTo: UUID?              // set by the engine: an earlier comment of the same kind on the same passage; the card starts collapsed
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID, origin: CommentOrigin, status: CommentStatus, kind: CommentKind, category: String, title: String, body: String,
                suggestion: String? = nil, anchor: Anchor, thread: [ThreadMessage] = [], proposedRevision: CommentRevision? = nil,
                previousVersions: [CommentRevision] = [], includeInReport: Bool, similarTo: UUID? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id; self.origin = origin; self.status = status; self.kind = kind; self.category = category; self.title = title; self.body = body
        self.suggestion = suggestion; self.anchor = anchor; self.thread = thread; self.proposedRevision = proposedRevision
        self.previousVersions = previousVersions; self.includeInReport = includeInReport; self.similarTo = similarTo; self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A comment while the model is still writing it. Fields fill in as lines arrive.
public struct DraftComment: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CommentKind?
    public var category: String?
    public var page: Int?                    // 1-based, as written by the model
    public var quote: String?
    public var title: String?
    public var body: String
    public var suggestion: String?
    public init(id: UUID, kind: CommentKind? = nil, category: String? = nil, page: Int? = nil, quote: String? = nil, title: String? = nil, body: String,
                suggestion: String? = nil) {
        self.id = id; self.kind = kind; self.category = category; self.page = page; self.quote = quote; self.title = title; self.body = body
        self.suggestion = suggestion
    }
}

public struct Conversation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var anchor: Anchor?               // the selection it started from; nil = question about the whole paper
    public var messages: [ThreadMessage]
    public var createdAt: Date
    public init(id: UUID, anchor: Anchor? = nil, messages: [ThreadMessage] = [], createdAt: Date) {
        self.id = id; self.anchor = anchor; self.messages = messages; self.createdAt = createdAt
    }
}

public enum Recommendation: String, Codable, Sendable, CaseIterable { case accept, minorRevision, majorRevision, reject }

public struct ReportVersion: Codable, Sendable, Equatable {
    public var markdown: String
    public var savedAt: Date
    public var note: String                  // "generated", "before regenerate", "before voice revision"
    public init(markdown: String, savedAt: Date, note: String) { self.markdown = markdown; self.savedAt = savedAt; self.note = note }
}

public struct ReportDraft: Codable, Sendable, Equatable {
    public var markdown: String
    public var recommendation: Recommendation?
    public var generatedAt: Date?
    public var provider: ProviderRef?
    public var basedOnCommentIDs: [UUID]
    public var userEdited: Bool
    public var versions: [ReportVersion]     // newest last, max 10
    public init(markdown: String, recommendation: Recommendation? = nil, generatedAt: Date? = nil, provider: ProviderRef? = nil,
                basedOnCommentIDs: [UUID] = [], userEdited: Bool, versions: [ReportVersion] = []) {
        self.markdown = markdown; self.recommendation = recommendation; self.generatedAt = generatedAt; self.provider = provider
        self.basedOnCommentIDs = basedOnCommentIDs; self.userEdited = userEdited; self.versions = versions
    }
}

public enum RunKind: String, Codable, Sendable { case review, discussion, question, report, revise }
public enum RunStatus: Codable, Sendable, Equatable { case running, completed, cancelled, failed(String) }

/// Audit trail: every time manuscript content was sent to a model.
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: RunKind
    public var provider: ProviderRef
    public var destination: String           // ProviderDescriptor.destination at the time
    public var sentPDF: Bool                 // true = the PDF file itself was uploaded, false = extracted text
    public var requestCount: Int
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var usage: Usage?
    public init(id: UUID, kind: RunKind, provider: ProviderRef, destination: String, sentPDF: Bool, requestCount: Int, startedAt: Date,
                finishedAt: Date? = nil, status: RunStatus, usage: Usage? = nil) {
        self.id = id; self.kind = kind; self.provider = provider; self.destination = destination; self.sentPDF = sentPDF; self.requestCount = requestCount
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.status = status; self.usage = usage
    }
}

public struct ConsentRecord: Codable, Sendable, Equatable {
    public var providerID: ProviderID
    public var grantedAt: Date
    public init(providerID: ProviderID, grantedAt: Date) { self.providerID = providerID; self.grantedAt = grantedAt }
}

public struct ManuscriptMeta: Codable, Sendable, Equatable {
    public var title: String?
    public var targetVenue: String?
    public var manuscriptID: String?
    public var reviewerNotes: String         // free text passed to review and report prompts
    public init(title: String? = nil, targetVenue: String? = nil, manuscriptID: String? = nil, reviewerNotes: String) {
        self.title = title; self.targetVenue = targetVenue; self.manuscriptID = manuscriptID; self.reviewerNotes = reviewerNotes
    }
}

public struct ReviewSession: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int            // 1
    public var id: UUID
    public var document: DocumentRef
    public var meta: ManuscriptMeta
    public var preferredProvider: ProviderRef?   // per-document choice; nil = AppSettings.defaults.review
    public var comments: [ReviewComment]     // stored in creation order; display order is computed
    public var conversations: [Conversation]
    public var report: ReportDraft?
    public var paperDigest: String?          // notes produced by a chunked review; reused for replies and the report
    public var runs: [RunRecord]
    public var consents: [ConsentRecord]
    public var createdAt: Date
    public var updatedAt: Date
    public init(schemaVersion: Int, id: UUID, document: DocumentRef, meta: ManuscriptMeta, preferredProvider: ProviderRef? = nil,
                comments: [ReviewComment] = [], conversations: [Conversation] = [], report: ReportDraft? = nil, paperDigest: String? = nil,
                runs: [RunRecord] = [], consents: [ConsentRecord] = [], createdAt: Date, updatedAt: Date) {
        self.schemaVersion = schemaVersion; self.id = id; self.document = document; self.meta = meta; self.preferredProvider = preferredProvider
        self.comments = comments; self.conversations = conversations; self.report = report; self.paperDigest = paperDigest; self.runs = runs
        self.consents = consents; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String                    // document sha256
    public var fileName: String
    public var title: String?
    public var lastKnownPath: String?
    public var updatedAt: Date
    public var commentCount: Int
    public var pendingCount: Int
    public var hasReport: Bool
    public init(id: String, fileName: String, title: String? = nil, lastKnownPath: String? = nil, updatedAt: Date, commentCount: Int, pendingCount: Int,
                hasReport: Bool) {
        self.id = id; self.fileName = fileName; self.title = title; self.lastKnownPath = lastKnownPath; self.updatedAt = updatedAt
        self.commentCount = commentCount; self.pendingCount = pendingCount; self.hasReport = hasReport
    }
}
```

### A.5 `LLM.swift`

```swift
import Foundation

public enum AuthMode: String, Codable, Sendable { case apiKey, subscriptionCLI, local, none }

public struct ProviderRef: Codable, Sendable, Hashable {
    public var providerID: ProviderID
    public var model: String?                // nil = the provider's own default (CLI providers)
    public init(providerID: ProviderID, model: String?) { self.providerID = providerID; self.model = model }
}

public enum StreamingGranularity: String, Codable, Sendable { case token, message }

public struct ProviderDescriptor: Codable, Sendable, Equatable {
    public var id: ProviderID
    public var displayName: String           // "Anthropic API", "Claude Code (subscription)"
    public var vendor: String                // "Anthropic", "OpenAI", "Google", "xAI", "Ollama", "Mock"
    public var authMode: AuthMode
    public var isLocal: Bool                 // true only if manuscript text never leaves this machine
    public var destination: String           // shown in the confidentiality indicator: host name or CLI name
    public var supportsNativePDF: Bool       // provider-level; ModelInfo.supportsPDFInput can still veto
    public var pdfDeliveryNote: String?      // how a CLI provider hands the file over, e.g. "sent as page images"; nil for HTTP providers
    public var streaming: StreamingGranularity
    public var maxPromptBytes: Int?          // transport limit (stdin/argv); nil = none
    public var retentionNote: String         // one line for the privacy popover
    public var isExperimental: Bool
    public init(id: ProviderID, displayName: String, vendor: String, authMode: AuthMode, isLocal: Bool, destination: String, supportsNativePDF: Bool,
                pdfDeliveryNote: String? = nil, streaming: StreamingGranularity, maxPromptBytes: Int? = nil, retentionNote: String, isExperimental: Bool) {
        self.id = id; self.displayName = displayName; self.vendor = vendor; self.authMode = authMode; self.isLocal = isLocal; self.destination = destination
        self.supportsNativePDF = supportsNativePDF; self.pdfDeliveryNote = pdfDeliveryNote; self.streaming = streaming; self.maxPromptBytes = maxPromptBytes
        self.retentionNote = retentionNote; self.isExperimental = isExperimental
    }
}

public enum ProviderAvailability: Sendable, Equatable {
    case ready(detail: String)                       // "Key set", "Logged in", "Ollama 0.40.17"
    case needsSetup(reason: String, hint: String)    // no key / not installed / not logged in
    case unavailable(reason: String)                 // binary blocked, server not running
}

public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var contextWindow: Int?           // input tokens; nil = unknown
    public var maxOutputTokens: Int?
    public var supportsPDFInput: Bool?       // nil = unknown
    public init(id: String, displayName: String, contextWindow: Int? = nil, maxOutputTokens: Int? = nil, supportsPDFInput: Bool? = nil) {
        self.id = id; self.displayName = displayName; self.contextWindow = contextWindow; self.maxOutputTokens = maxOutputTokens
        self.supportsPDFInput = supportsPDFInput
    }
}

public enum LLMPart: Sendable, Equatable {
    case text(String)
    case pdf(data: Data, fileName: String)
    case cacheBoundary                       // parts before this marker are identical across requests (prompt-cache hint)
}

public enum RequestPurpose: String, Codable, Sendable { case review, discussion, question, report, revise, ping }

/// One system prompt + one user turn -> streamed text. There is deliberately no multi-turn API (see plan section 5.1).
public struct LLMRequest: Sendable, Equatable {
    public var model: String?
    public var system: String
    public var parts: [LLMPart]
    public var maxOutputTokens: Int?         // nil = provider default (the Anthropic adapter substitutes min(model max, 32_000))
    public var contextWindow: Int?           // tokens to allocate (Ollama num_ctx); nil = provider default
    public var purpose: RequestPurpose
    public init(model: String? = nil, system: String, parts: [LLMPart] = [], maxOutputTokens: Int? = nil, contextWindow: Int? = nil, purpose: RequestPurpose) {
        self.model = model; self.system = system; self.parts = parts; self.maxOutputTokens = maxOutputTokens; self.contextWindow = contextWindow
        self.purpose = purpose
    }
}

public struct Usage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) { self.inputTokens = inputTokens; self.outputTokens = outputTokens }
}

public enum StopReason: String, Codable, Sendable { case endOfTurn, maxTokens, refusal, other }

public enum LLMEvent: Sendable, Equatable {
    case textDelta(String)
    case status(String)                      // human-readable progress, never model text
    case finished(StopReason, Usage?)        // exactly once, last, on success
}

public enum LLMError: RefereeError, Equatable {
    case notConfigured(String)
    case auth(String)
    case rateLimited(retryAfter: Double?, message: String)
    case quotaExhausted(String)
    case overloaded(retryAfter: Double?)
    case contextTooLong(String)
    case invalidRequest(String)
    case modelNotFound(String)
    case refused(String)
    case network(String)
    case server(status: Int, message: String)
    case cliLaunchFailed(String)
    case cliTimeout(phase: String)
    case cliExited(code: Int32, stderrTail: String)
    case toolUseBlocked(String)              // a CLI exposed or tried to use a tool the invocation does not allow; the run was killed
    case malformedResponse(String)
    case cancelled

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network, .server: return true
        default: return false
        }
    }
    public var userMessage: String {
        switch self {
        case .notConfigured(let m): return "Provider is not set up: \(m)"
        case .auth(let m): return "Authentication failed: \(m)"
        case .rateLimited(_, let m): return "Rate limited: \(m)"
        case .quotaExhausted(let m): return "Usage limit reached: \(m)"
        case .overloaded: return "The provider is overloaded."
        case .contextTooLong(let m): return "The input is too long for this model: \(m)"
        case .invalidRequest(let m): return "The provider rejected the request: \(m)"
        case .modelNotFound(let m): return "Model not found: \(m)"
        case .refused(let m): return "The model declined to answer: \(m)"
        case .network(let m): return "Network error: \(m)"
        case .server(let s, let m): return "Provider error \(s): \(m)"
        case .cliLaunchFailed(let m): return "Could not start the command-line tool: \(m)"
        case .cliTimeout(let p): return "The command-line tool timed out (\(p))."
        case .cliExited(let c, let t): return "The command-line tool exited with code \(c): \(t)"
        case .toolUseBlocked(let t): return "The command-line tool tried to use a tool (\(t)); the run was stopped and nothing it produced after that point was used."
        case .malformedResponse(let m): return "Unexpected response from the provider: \(m)"
        case .cancelled: return "Cancelled."
        }
    }
    public var recoverySuggestion: String? { nil }
}

public protocol LLMProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    /// Cheap, no model tokens spent. For CLI providers: resolve binary, run `--version` (20 s cap) and the auth-status command.
    func availability() async -> ProviderAvailability
    func listModels() async throws -> [ModelInfo]
    /// Cold stream: work starts when iterated; cancelling the consuming Task cancels the HTTP request / kills the process.
    /// Throws only LLMError.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

public protocol ProviderResolving: Sendable {
    var all: [any LLMProvider] { get }
    func provider(id: ProviderID) -> (any LLMProvider)?
}

public protocol SecretStoring: Sendable {
    func secret(for key: String) throws -> String?
    /// nil deletes. All secrets live in one stored item, so this is read-modify-write: it MUST throw SecretError.unreadable
    /// unless the existing item was read successfully or is known not to exist. Treating a failed read as "empty" would
    /// overwrite every other stored key (plan section 5.8).
    func setSecret(_ value: String?, for key: String) throws
}

public enum SecretError: RefereeError, Equatable {
    case unreadable(status: Int32)           // the item exists but could not be read (the user denied access, or the keychain is locked)
    case writeFailed(status: Int32)
    public var userMessage: String {
        switch self {
        case .unreadable: return "The saved keys could not be read from the Keychain, so nothing was changed."
        case .writeFailed(let s): return "The Keychain rejected the change (status \(s))."
        }
    }
    public var recoverySuggestion: String? { "Allow access when macOS asks for it, then try again." }
    public var isRetryable: Bool { true }
}
```

### A.6 `Engine.swift`

```swift
import Foundation

/// Everything an engine call needs besides the paper. Built by AppCore from AppSettings at call time.
public struct EngineContext: Sendable, Equatable {
    public var provider: ProviderRef
    public var providerSettings: ProviderSettings
    public var model: ModelInfo?             // the chosen model's entry in the provider's model list; nil = unknown (planning then assumes defaults)
    public var prompts: PromptSet
    public var rubric: [RubricCategory]
    public var meta: ManuscriptMeta
    public var paperDigest: String?          // ReviewSession.paperDigest; the paper context for replies and the report when the paper does not fit
    public init(provider: ProviderRef, providerSettings: ProviderSettings, model: ModelInfo? = nil, prompts: PromptSet, rubric: [RubricCategory] = [],
                meta: ManuscriptMeta, paperDigest: String? = nil) {
        self.provider = provider; self.providerSettings = providerSettings; self.model = model; self.prompts = prompts; self.rubric = rubric; self.meta = meta
        self.paperDigest = paperDigest
    }
}

public enum ReviewPhase: Sendable, Equatable {
    case preparing
    case reading(part: Int, of: Int)         // 1-based
    case wholePaperPass
}

public struct SendPlan: Sendable, Equatable {
    public var sendsPDF: Bool                // false = extracted text only (equations and tables may be garbled)
    public var requestCount: Int             // 1 = single pass
    public var estimatedInputTokens: Int
    public var destination: String
    public var isLocal: Bool
    public var warnings: [String]            // "Paper will be read in 6 parts", "This PDF is protected, so its text is sent instead of the file", ...
    public var blockingReason: String?       // non-nil = this job cannot run with this provider ("This PDF has no text layer; ..."); the UI disables Review
    public init(sendsPDF: Bool, requestCount: Int, estimatedInputTokens: Int, destination: String, isLocal: Bool, warnings: [String] = [],
                blockingReason: String? = nil) {
        self.sendsPDF = sendsPDF; self.requestCount = requestCount; self.estimatedInputTokens = estimatedInputTokens; self.destination = destination
        self.isLocal = isLocal; self.warnings = warnings; self.blockingReason = blockingReason
    }
}

public enum ReviewEvent: Sendable, Equatable {
    case started(RunRecord)
    case phase(ReviewPhase)
    case draft(DraftComment)                           // create-or-update by id while the model writes
    case comment(ReviewComment, replacesDraft: UUID)   // parsed, validated, anchored
    case notice(String)                                // user-visible, e.g. "The model ignored the output format."
    case digest(String)                                // the model's notes from a review read in parts; at most once, before .finished
    case finished(RunRecord)                           // last event; status is completed, cancelled or failed
}

public enum ReplyEvent: Sendable, Equatable {
    case started(RunRecord)
    case textDelta(String)
    case finished(reply: ThreadMessage, proposal: CommentRevision?, run: RunRecord)   // proposal only for discussions
}

public enum ReportEvent: Sendable, Equatable {
    case started(RunRecord)
    case textDelta(String)
    case finished(ReportDraft, run: RunRecord)
}

public struct LintFinding: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var range: TextRange              // UTF-16 range in the report Markdown
    public var rule: String                  // "banned-word", "em-dash", "not-only-but-also", ...
    public var message: String
    public init(id: Int, range: TextRange, rule: String, message: String) { self.id = id; self.range = range; self.rule = rule; self.message = message }
}

public protocol ReviewEngineProtocol: Sendable {
    /// No network. Used by the consent card, the toolbar indicator and ReviewSessionModel.canStartReview.
    func plan(paper: LoadedPaper, context: EngineContext) async -> SendPlan
    func review(paper: LoadedPaper, existing: [ReviewComment], context: EngineContext) -> AsyncThrowingStream<ReviewEvent, Error>
    func discuss(paper: LoadedPaper, comment: ReviewComment, message: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error>
    func ask(paper: LoadedPaper, conversation: Conversation, question: String, context: EngineContext) -> AsyncThrowingStream<ReplyEvent, Error>
    func generateReport(paper: LoadedPaper, session: ReviewSession, context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error>
    func reviseVoice(reportMarkdown: String, findings: [LintFinding], context: EngineContext) -> AsyncThrowingStream<ReportEvent, Error>
    func lint(reportMarkdown: String) -> [LintFinding]
}
```

### A.7 `Settings.swift`

```swift
import Foundation

public enum InputMode: String, Codable, Sendable { case auto, text, pdf }

public struct RubricCategory: Codable, Sendable, Equatable, Identifiable {
    public var id: String                    // slug used in the model output, e.g. "claims"
    public var name: String                  // "Claims vs. evidence"
    public var guidance: String              // one or two sentences inserted into the review prompt
    public var enabled: Bool
    public init(id: String, name: String, guidance: String, enabled: Bool) { self.id = id; self.name = name; self.guidance = guidance; self.enabled = enabled }
}

public struct PromptSet: Codable, Sendable, Equatable {
    public var reviewSystem: String          // rubric and referee stance (editable)
    public var discussionSystem: String
    public var questionSystem: String
    public var reportSystem: String          // voice and rules for the final report
    public var reportTemplate: String        // Markdown skeleton with the section headings
    public var voiceRevisionSystem: String
    public var quickQuestions: [String]      // presets in the selection popover
    public init(reviewSystem: String, discussionSystem: String, questionSystem: String, reportSystem: String, reportTemplate: String,
                voiceRevisionSystem: String, quickQuestions: [String] = []) {
        self.reviewSystem = reviewSystem; self.discussionSystem = discussionSystem; self.questionSystem = questionSystem; self.reportSystem = reportSystem
        self.reportTemplate = reportTemplate; self.voiceRevisionSystem = voiceRevisionSystem; self.quickQuestions = quickQuestions
    }
}

public struct ProviderSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var model: String?                // nil = provider default / not chosen yet
    public var baseURL: String?              // override, e.g. a remote Ollama host
    public var executablePath: String?       // CLI providers: explicit binary path
    public var contextWindowOverride: Int?   // tokens
    public var maxOutputTokens: Int?
    public var inputMode: InputMode
    public var extraArguments: [String]      // CLI providers: appended verbatim
    public var extraBodyJSON: String?        // HTTP providers: JSON object whose top-level keys are merged into the request body
    public var cachedModels: [ModelInfo]     // last result of listModels(); the source of EngineContext.model
    public var cachedModelsAt: Date?
    public var verifiedAt: Date?             // last successful "Send test prompt"; experimental providers show a warning until it is set
    public init(enabled: Bool, model: String? = nil, baseURL: String? = nil, executablePath: String? = nil, contextWindowOverride: Int? = nil,
                maxOutputTokens: Int? = nil, inputMode: InputMode, extraArguments: [String] = [], extraBodyJSON: String? = nil, cachedModels: [ModelInfo] = [],
                cachedModelsAt: Date? = nil, verifiedAt: Date? = nil) {
        self.enabled = enabled; self.model = model; self.baseURL = baseURL; self.executablePath = executablePath
        self.contextWindowOverride = contextWindowOverride; self.maxOutputTokens = maxOutputTokens; self.inputMode = inputMode
        self.extraArguments = extraArguments; self.extraBodyJSON = extraBodyJSON; self.cachedModels = cachedModels; self.cachedModelsAt = cachedModelsAt
        self.verifiedAt = verifiedAt
    }
}

public struct TaskDefaults: Codable, Sendable, Equatable {
    public var review: ProviderRef?
    public var chat: ProviderRef?            // nil = same as review
    public var report: ProviderRef?          // nil = same as review
    public init(review: ProviderRef? = nil, chat: ProviderRef? = nil, report: ProviderRef? = nil) { self.review = review; self.chat = chat; self.report = report }
}

public struct PrivacySettings: Codable, Sendable, Equatable {
    public var localOnly: Bool               // true = every non-local provider is disabled
    public var confirmFirstSendPerDocument: Bool
    public var resolveReferencesInBackground: Bool   // false = look references up only when clicked
    public init(localOnly: Bool, confirmFirstSendPerDocument: Bool, resolveReferencesInBackground: Bool) {
        self.localOnly = localOnly; self.confirmFirstSendPerDocument = confirmFirstSendPerDocument
        self.resolveReferencesInBackground = resolveReferencesInBackground
    }
}

public struct ReferenceSettings: Codable, Sendable, Equatable {
    public var crossrefMailto: String        // "" = public pool; never pre-filled
    public var pdfCacheLimitMB: Int
    public init(crossrefMailto: String, pdfCacheLimitMB: Int) { self.crossrefMailto = crossrefMailto; self.pdfCacheLimitMB = pdfCacheLimitMB }
}

public struct UISettings: Codable, Sendable, Equatable {
    public var autoAdvanceAfterTriage: Bool
    public var showRejectedHighlights: Bool
    public var sidebarWidth: Double
    public var stripMarginLineNumbers: Bool  // false = never remove margin line numbers from the text
    public init(autoAdvanceAfterTriage: Bool, showRejectedHighlights: Bool, sidebarWidth: Double, stripMarginLineNumbers: Bool) {
        self.autoAdvanceAfterTriage = autoAdvanceAfterTriage; self.showRejectedHighlights = showRejectedHighlights; self.sidebarWidth = sidebarWidth
        self.stripMarginLineNumbers = stripMarginLineNumbers
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var schemaVersion: Int            // 1
    public var providers: [ProviderID: ProviderSettings]
    public var defaults: TaskDefaults
    public var prompts: PromptSet
    public var rubric: [RubricCategory]
    public var privacy: PrivacySettings
    public var references: ReferenceSettings
    public var ui: UISettings
    public init(schemaVersion: Int, providers: [ProviderID: ProviderSettings] = [:], defaults: TaskDefaults, prompts: PromptSet, rubric: [RubricCategory] = [],
                privacy: PrivacySettings, references: ReferenceSettings, ui: UISettings) {
        self.schemaVersion = schemaVersion; self.providers = providers; self.defaults = defaults; self.prompts = prompts; self.rubric = rubric
        self.privacy = privacy; self.references = references; self.ui = ui
    }
}

public enum StoreError: RefereeError, Equatable {
    case corrupt(path: String)
    case newerSchema(found: Int, supported: Int)
    case io(String)
    public var userMessage: String {
        switch self {
        case .corrupt(let p): return "The saved review at \(p) is damaged; the previous backup was loaded if available."
        case .newerSchema(let f, let s): return "This review was saved by a newer version of Referee (format \(f); this version reads up to \(s))."
        case .io(let m): return "Could not read or write review data (\(m))."
        }
    }
    public var recoverySuggestion: String? { nil }
    public var isRetryable: Bool { false }
}

public protocol SettingsStoring: Sendable {
    func load() async -> AppSettings                  // returns defaults when the file is missing or unreadable
    func save(_ settings: AppSettings) async throws
}

public protocol SessionStoring: Sendable {
    func loadSession(sha256: String) async throws -> ReviewSession?
    func save(_ session: ReviewSession) async throws  // atomic; keeps one .bak
    func listSessions() async -> [SessionSummary]
    func deleteSession(sha256: String) async throws
}
```

### A.8 `Support.swift`

```swift
import Foundation
import os

/// Accumulates bytes and returns complete lines (without the line terminator). Keeps empty lines.
/// Used for SSE, NDJSON and CLI output. (URLSession.AsyncBytes.lines drops empty lines, so it is not used.)
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func push(_ byte: UInt8) -> String? {
        if byte == 0x0A {
            defer { buffer.removeAll(keepingCapacity: true) }
            if buffer.last == 0x0D { buffer.removeLast() }
            return String(decoding: buffer, as: UTF8.self)
        }
        buffer.append(byte)
        return nil
    }
    /// Call once at end of input; returns the unterminated last line, if any.
    public mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// What a provider needs from the app. Settings are read at call time so edits apply without restarting.
public struct ProviderEnvironment: Sendable {
    public var settings: @Sendable (ProviderID) -> ProviderSettings
    public var secrets: any SecretStoring
    public var urlSession: URLSession
    public var processEnvironment: [String: String]     // the app's own environment (tests inject fakes)
    public init(settings: @escaping @Sendable (ProviderID) -> ProviderSettings, secrets: any SecretStoring, urlSession: URLSession, processEnvironment: [String: String]) {
        self.settings = settings; self.secrets = secrets; self.urlSession = urlSession; self.processEnvironment = processEnvironment
    }
}

/// Everything the application layer needs, as protocols. Built once by Composition.LiveDependencies.
public struct AppDependencies: Sendable {
    public var paperService: any PaperService
    public var matcherFactory: @Sendable (PaperText) -> any QuoteMatching
    public var citationIndexer: any CitationIndexing
    public var engine: any ReviewEngineProtocol
    public var resolver: any ReferenceResolving
    public var sessions: any SessionStoring
    public var settings: any SettingsStoring
    public var providers: any ProviderResolving
    public var secrets: any SecretStoring
    public init(paperService: any PaperService, matcherFactory: @escaping @Sendable (PaperText) -> any QuoteMatching, citationIndexer: any CitationIndexing,
                engine: any ReviewEngineProtocol, resolver: any ReferenceResolving, sessions: any SessionStoring, settings: any SettingsStoring,
                providers: any ProviderResolving, secrets: any SecretStoring) {
        self.paperService = paperService; self.matcherFactory = matcherFactory; self.citationIndexer = citationIndexer; self.engine = engine
        self.resolver = resolver; self.sessions = sessions; self.settings = settings; self.providers = providers; self.secrets = secrets
    }
}

public final class ProviderRegistry: ProviderResolving {
    public let all: [any LLMProvider]
    public init(_ providers: [any LLMProvider]) { self.all = providers }
    public func provider(id: ProviderID) -> (any LLMProvider)? { all.first { $0.descriptor.id == id } }
}

/// The only logging API. Values are restricted so manuscript text, prompts, model output, quotes and file names
/// cannot be logged: numbers and booleans, plus `.id` for identifiers the code itself defines (provider ids, model ids,
/// error codes, scene names). An `.id` that is longer than 64 characters or contains anything outside
/// A-Z a-z 0-9 . _ : / - is replaced by "invalid-id" before it is written.
public enum LogValue: Sendable, Equatable {
    case int(Int), double(Double), bool(Bool)
    case id(String)
}
public enum Log {
    private static let logger = Logger(subsystem: "local.referee.app", category: "app")
    private static let sinkLock = NSLock()
    nonisolated(unsafe) private static var sinks: [UUID: @Sendable (String, [String: LogValue]) -> Void] = [:]
    /// Tests add a sink to inspect what is logged (it receives the sanitised fields) and remove it with the id returned.
    /// Tests of all targets run in parallel in one process, so several sinks can be active at once, and a sink sees the
    /// events of every test running at that moment: a test filters by its own event names, or asserts only what must
    /// hold for every event. A test removes only its own sink.
    public static func addTestSink(_ sink: @escaping @Sendable (String, [String: LogValue]) -> Void) -> UUID {
        let id = UUID()
        sinkLock.lock(); sinks[id] = sink; sinkLock.unlock()
        return id
    }
    public static func removeTestSink(_ id: UUID) {
        sinkLock.lock(); sinks[id] = nil; sinkLock.unlock()
    }
    static func sanitised(_ value: LogValue) -> LogValue {
        guard case .id(let s) = value else { return value }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/-")
        let ok = s.count <= 64 && s.unicodeScalars.allSatisfy { allowed.contains($0) }
        return ok ? value : .id("invalid-id")
    }
    public static func event(_ name: StaticString, _ fields: [String: LogValue] = [:]) {
        let clean = fields.mapValues(sanitised)
        let rendered = clean.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.info("\(name.description, privacy: .public) \(rendered, privacy: .public)")
        sinkLock.lock(); let current = Array(sinks.values); sinkLock.unlock()
        for sink in current { sink(name.description, clean) }
    }
}
```

### A.9 `AppCore`: `ReviewSessionModel` and `SettingsModel` (public declarations)

```swift
import Foundation
import Observation
import RefereeCore

public enum DocumentPhase: Sendable, Equatable { case empty, loading(fileName: String), ready, failed(message: String) }

public enum RunState: Sendable, Equatable {
    case idle
    case running(kind: RunKind, phase: ReviewPhase?, startedAt: Date)
}

public struct Banner: Sendable, Equatable, Identifiable {
    public enum Style: Sendable, Equatable { case info, warning, error }
    public enum Action: Sendable, Equatable { case retry, openSettings }
    public var id: UUID
    public var style: Style
    public var message: String
    public var action: Action?               // .retry -> model.retryLastFailedJob(); .openSettings is handled by the window
    public init(id: UUID = UUID(), style: Style, message: String, action: Action? = nil) {
        self.id = id; self.style = style; self.message = message; self.action = action
    }
}

public struct ConsentRequest: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var provider: ProviderDescriptor
    public var model: String?
    public var plan: SendPlan
    public init(id: UUID = UUID(), provider: ProviderDescriptor, model: String? = nil, plan: SendPlan) {
        self.id = id; self.provider = provider; self.model = model; self.plan = plan
    }
}

/// An own comment being written (N key, "+" button, or "Comment" in the selection bar).
public struct ComposingComment: Sendable, Equatable {
    public var selection: SelectionInfo?     // the passage it will be anchored to, captured when composing began
    public init(selection: SelectionInfo? = nil) { self.selection = selection }
}

public enum CommentFilter: Sendable, Equatable { case all, pending, approved, rejected, kind(CommentKind) }
public enum SidebarTab: String, Sendable, CaseIterable { case comments, chat, report }
public enum ExportFormat: String, Sendable, CaseIterable { case markdown, plainText, docx, pdf }

/// Model -> PDF view. Find and zoom are not here: the menu calls ReaderController directly (plan section 7.4).
public enum ReaderCommand: Sendable, Equatable {
    case reveal(rects: [PageRect], flash: Bool)
    case goToPage(Int)
    case clearSelection
}

public enum CitationLookup: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case mention(Int)                    // clicked in the PDF: the card is placed next to the mention
        case entry(Int)                      // chosen in the References list: the card is placed at the top of the PDF pane
    }
    case idle
    case resolving(target: Target)
    case resolved(target: Target, entries: [BibEntry], references: [ResolvedReference])
}

@MainActor @Observable
public final class ReviewSessionModel {
    // ---- state (read by views) ----
    public private(set) var phase: DocumentPhase = .empty
    public private(set) var paper: LoadedPaper?
    public private(set) var session: ReviewSession?
    public private(set) var citations: CitationIndex?
    public private(set) var settings: AppSettings
    public private(set) var runState: RunState = .idle
    public private(set) var drafts: [DraftComment] = []           // comments being streamed
    public private(set) var streamingReplyText: String = ""       // reply lane: discussion or chat answer in flight
    public private(set) var streamingTargetID: UUID?              // comment or conversation receiving the reply
    public private(set) var streamingReportText: String = ""      // review lane: report or voice revision in flight
    public private(set) var banner: Banner?
    public private(set) var consentRequest: ConsentRequest?
    public private(set) var activeProvider: ProviderDescriptor?   // nil = nothing usable is configured
    public private(set) var activeModel: String?                  // nil = the provider's own default
    public private(set) var sendPlan: SendPlan?                   // what a review would send now; refreshed when paper, provider, model list or settings change
    public private(set) var lintFindings: [LintFinding] = []
    public private(set) var citationLookup: CitationLookup = .idle
    public private(set) var readerCommand: (serial: Int, command: ReaderCommand)?
    public private(set) var selection: SelectionInfo?            // normalised: no margin numbers, watermarks, headers or footers
    public private(set) var composing: ComposingComment?
    public var selectedCommentID: UUID?
    public var openThreadCommentID: UUID?        // the comment whose discussion thread is expanded
    public var editingCommentID: UUID?           // the comment being edited in place
    public var filter: CommentFilter = .all
    public var sidebarTab: SidebarTab = .comments

    // ---- derived ----
    /// Filtered by `filter`, then ordered by page, then by the position of the first span's line in that page's
    /// PageText.lines, then by creation time. A comment with a page but no span (.pageOnly) comes first on its page;
    /// a comment with no page (.none) comes last. This is the only ordering rule; the sidebar and J/K use it.
    public var visibleComments: [ReviewComment]
    public var triage: (decided: Int, total: Int)
    public var canStartReview: Bool             // paper ready, review lane idle, a provider is active, and sendPlan?.blockingReason == nil
    public var selectableProviders: [ProviderDescriptor]   // enabled providers; non-local ones are left out when Local only is on

    public init(dependencies: AppDependencies, settings: AppSettings)

    // ---- document ----
    public func open(url: URL) async
    public func close() async
    /// "Delete Review Data…": cancels jobs, deletes sessions/<sha256>/ and that document's lookup cache, then closes.
    public func deleteReviewData() async

    // ---- provider & consent ----
    public func setActiveProvider(_ ref: ProviderRef)
    public func answerConsent(granted: Bool)
    public func reloadSettings(_ settings: AppSettings)   // called by WindowManager on .refereeSettingsDidChange

    // ---- review run ----
    public func startReview()                   // asks consent first when required
    public func cancelRun()                     // review lane: review, report, voice revision
    public func cancelReply()                   // reply lane: discussion, question
    public func retryLastFailedJob()

    // ---- triage ----
    public func setStatus(_ status: CommentStatus, for id: UUID)
    public func selectNextComment(pendingOnly: Bool)
    public func selectPreviousComment()
    public func revealSelectedCommentInPDF()
    public func setKind(_ kind: CommentKind, for id: UUID)
    public func editComment(_ id: UUID, kind: CommentKind, category: String, title: String, body: String, suggestion: String?)
    public func deleteComment(_ id: UUID)
    public func deletePendingAIComments()      // "Clear undecided AI comments" before running a review again
    public func beginComposingComment()        // captures the current selection; the sidebar shows the editor card
    public func cancelComposing()
    public func addUserComment(kind: CommentKind, category: String, title: String, body: String, anchoredTo selection: SelectionInfo?)   // also ends composing
    public func reanchorComment(_ id: UUID, to selection: SelectionInfo)
    public func setIncludeInReport(_ include: Bool, for id: UUID)

    // ---- discussion ----
    public func sendDiscussionMessage(_ text: String, commentID: UUID)
    public func acceptProposedRevision(commentID: UUID)
    public func discardProposedRevision(commentID: UUID)

    // ---- questions (selection Q&A and general chat) ----
    public func ask(_ question: String, about selection: SelectionInfo?, in conversationID: UUID?)
    public func convertReplyToComment(conversationID: UUID, messageID: UUID, kind: CommentKind)
    public func deleteConversation(_ id: UUID)

    // ---- report ----
    public func generateReport()
    public func updateReportMarkdown(_ markdown: String)     // user edits; re-lints (debounced)
    public func setRecommendation(_ recommendation: Recommendation?)
    public func reviseReportVoice()
    public func restoreReportVersion(at index: Int)
    public func exportReport(format: ExportFormat, to url: URL) throws
    public func reportText(format: ExportFormat) -> String   // for the pasteboard (.markdown / .plainText)

    // ---- citations ----
    public func lookUpCitation(mentionID: Int)
    public func lookUpEntry(entryID: Int)
    public func fetchReferencePDF(_ reference: ResolvedReference) async throws -> URL

    // ---- called by the PDF view ----
    public func readerSelectionChanged(_ selection: SelectionInfo?)   // normalises against paper.text, then refreshes rects
    public func readerClickedComment(_ id: UUID)
    public func readerClickedCitation(mentionID: Int)

    // ---- misc ----
    public func dismissBanner()
    public func dismissTransientUI()            // Esc: citation card, composing, editing, open thread, then the PDF selection
    public func updateMeta(_ meta: ManuscriptMeta)
    public func flushPendingSave() async
}


public extension Notification.Name {
    static let refereeSettingsDidChange = Notification.Name("local.referee.app.settingsDidChange")
}

@MainActor @Observable
public final class SettingsModel {
    public private(set) var settings: AppSettings
    public private(set) var availability: [ProviderID: ProviderAvailability] = [:]
    public private(set) var models: [ProviderID: [ModelInfo]] = [:]
    public private(set) var modelErrors: [ProviderID: String] = [:]
    public private(set) var storedSecrets: Set<String> = []       // keys that currently have a value in the Keychain
    public var providers: [ProviderDescriptor]

    public init(dependencies: AppDependencies, settings: AppSettings)

    public func update(_ mutate: (inout AppSettings) -> Void)     // saves (debounced 0.5 s) and posts .refereeSettingsDidChange
    public func setSecret(_ value: String?, for key: String)
    public func refreshAvailability(of id: ProviderID?) async    // nil = all
    public func refreshModels(of id: ProviderID) async
    /// Explicit button only; sends "Reply with exactly: OK" and spends a few tokens. Success stores ProviderSettings.verifiedAt.
    public func sendTestPrompt(to id: ProviderID) async -> Result<String, LLMError>
    public func resetPromptsToDefaults()
    /// Called once by AppDelegate at launch. Acts on first launch only (no review default yet): if Ollama is running
    /// and has a model, enable it and make it the default. Never enables a remote provider by itself.
    public func applyFirstRunDefaultsIfNeeded() async
}
```

---

## Appendix B. Default prompts, rubric, report template, lint rules

Derived from the user's own peer-review rubric (`~/.claude/skills/peer-review/SKILL.md`): its foundational principle, five questions, mathematics checks, writing checks, report format, "what not to do", and the rules for a review that reads as written by a person. Everything in B.1 and B.3–B.6 is the default value of an editable setting. B.2 is a constant in code. The reviewer ran B.1 and B.2 through two local models and found them faithful to the rubric; three changes below come from what those models did with them: the "authors" rule, the limit on `strength` comments, and the note about extraction artefacts.

### B.1 `reviewSystem`

```text
You are refereeing a manuscript for a serious academic journal. You are a knowledgeable, honest, constructive referee: not a summariser and not a cheerleader. Your job is to evaluate the paper, to help the editor decide and to help the authors improve it.

Do not summarise the paper back. Every comment must do one of three things: identify a problem, ask a question the paper fails to answer, or name a genuine strength specifically enough that the authors know exactly what you mean.

Read the whole manuscript before writing anything. Then work through these five questions, in order.

1. What can and cannot be legitimately concluded? Read the methods and results on their own terms, then compare them with the abstract, introduction and discussion. Look for causal claims from correlational designs, generalisation beyond the sample, results that are statistically significant but practically trivial (or the reverse), selective reporting, tables that do not match the text, and language stronger than the estimates support.

2. What was not measured, and what is quietly assumed? Omitted variables that could confound the main finding, instruments whose validity is assumed, sample selection the authors do not discuss, assumptions stated technically but never defended, robustness checks a referee in this field would expect and does not find.

3. How far do the conclusions travel? Narrow or convenience samples framed as universal, conditions specific to a time, policy regime or institution, heterogeneity the paper averages over, and whether an independent team could reproduce the study from the description given.

4. What debate is this paper entering? Whether the literature review represents the state of the debate or only the side that supports the authors, competing explanations left unaddressed, whether the cited authors would recognise how their work is described, and whether the paper advances the debate or repeats a known finding.

5. What important work is missing from the bibliography? Only work whose absence weakens the argument: foundational papers, recent work on the same question with other methods or data, null or contradictory findings, relevant work from adjacent fields. Never name a specific paper unless you are confident it exists; if you are not sure of the exact reference, describe the line of work instead.

For proofs, derivations and formal models: check every step you can. Do not accept "it follows that" or "it is easy to see" when the step is not obvious. Verify signs, the direction of inequalities (especially after multiplying by a quantity that could be negative or taking reciprocals), behaviour at the boundaries of the parameter space, and the base case of any induction. Flag jumps between equations, claims supported only by numerical examples, and lemmas invoked without proof or exact citation. If you explain why a property fails, check that your explanation matches the authors' own example. When you cite a number, name the table, the column and the row. Say plainly what you verified, what you found, and what you could not verify.

For the writing: flag sentences that need several readings, missing logical links, undefined terms, inconsistent notation, material in the wrong section, and overclaiming words that the evidence does not earn ("novel", "first", "clearly", "obviously", "robust", "demonstrates", "proves", and "significant" used ambiguously). If a passage reads as generated text, note the pattern and quote an example; do not accuse.

Rules.
- Be specific. "The abstract overstates the results" is useless. "The abstract says the intervention 'reduces mortality', but Table 2 reports a hazard ratio of 0.91 with a 95% confidence interval of [0.78, 1.06], which includes one" is useful.
- Do not ask the authors to do a different study. Evaluate the study they did.
- Do not confuse "I would have written this differently" with "this is wrong".
- Do not hedge. If a proof is wrong, say it is wrong and show where. If you cannot judge something, say so.
- Do not praise generically. If something is well done, say what and why.
- Direct is not dismissive. Never be cruel.
- Write in the first person, in plain words, as a person who read this paper. No filler.
- Refer to "the authors" in the third person. Never address them as "you".
- If part of the paper is outside your competence, say so in the relevant comment and concentrate on logic and method.
```

### B.2 Format and task constants (`RefereeCore/FormatSpec.swift`, not editable)

In code: `FormatSpec.review` (`FORMAT_REVIEW`), `.revision` (`FORMAT_REVISION`), `.taskReviewText`, `.taskReviewPDF`, `.taskPart`, `.taskWhole`, `.taskContinue`. Placeholders in braces are filled by `PromptBuilder`. The constants carry the texts below with three differences, and the doc comment of `FormatSpec` in `Sources/RefereeCore/FormatSpec.swift` is the binding rule for every placeholder: the "← only when …" notes are not prompt text and are left out; `{same optional lines}` is written out as the three optional lines; and `taskReviewText` is the two text-mode blocks in one string, split by `PromptBuilder` at the line `{paper text}` (what stands before it goes with the rendered paper before the cache boundary, the rest after it). An optional line whose condition does not hold is removed with its line break; `{if i > 1:}` is always removed, and for the first part the two lines after it and the following empty line go too.

`FORMAT_REVIEW` (appended to `reviewSystem` after the rubric block):

```text
OUTPUT FORMAT. Your output is read by a program, so follow this exactly.

Write each comment as a block:

@@COMMENT
kind: major | minor | question | strength
category: one of the category ids listed above
page: the PDF page number of the quoted passage
quote: a passage copied exactly from the manuscript, 6 to 40 words, on one line
title: at most 12 words
body:
The comment itself: what the problem is, why it matters for the paper's conclusions, and exactly where it is (section, equation, table, figure).
suggestion:
A concrete way to resolve it. Leave this field out if you have none; do not write "N/A" or "none".
@@END

Rules:
- Copy the quote character for character from the manuscript so that it can be found. Do not paraphrase it, do not shorten it with "...", do not put quotation marks around it. For a comment about an equation, table or figure, quote the sentence that introduces or refers to it. For a comment about something missing, quote the passage where it should have been addressed.
- One issue per comment. Do not number the comments.
- "major" threatens the paper's main conclusions. "minor" should be fixed but does not. "question" is something whose answer could change your assessment. "strength" is something done well: write at most two, and only if you can say what is unusual about it; a compliment that would fit any paper is not a comment.
- Write nothing outside the blocks: no introduction, no summary, no closing remarks.
- Most serious comments first. Do not pad: a clean paper gets few comments.
- After the last comment write a line containing only @@DONE
```

Rubric block (generated, inserted between `reviewSystem` and `FORMAT_REVIEW`):

```text
Categories (use the id in the "category" field):
- claims: Claims vs. evidence. <guidance>
- assumptions: …
```

`TASK_REVIEW`, text mode:

```text
The manuscript follows as text extracted from a PDF. Lines of the form [[page N]] mark where PDF page N begins; they are not part of the manuscript, and each is placed at the nearest sentence boundary.
Extraction leaves artefacts: words run together without spaces, odd hyphenation, and equations and tables broken into fragments. These are not errors in the manuscript; do not comment on them. If you cannot read a formula or a table well enough to check it, say that you could not check it.

{paper text}
```
followed (after the cache boundary) by
```text
Write your referee comments on this manuscript in the required format.
{Reviewer's notes: …}                      ← only when meta.reviewerNotes is not empty
{Target journal: …}                        ← only when meta.targetVenue is set
{Comments already made, do not repeat them: title; title; …}     ← only when there are existing comments
```

`TASK_REVIEW`, PDF mode: the `.pdf` part, the cache boundary, then

```text
The manuscript is the attached PDF. Use PDF page numbers: the first page of the file is page 1.
Write your referee comments on this manuscript in the required format.
{same optional lines}
```

`TASK_PART`:

```text
The manuscript is long, so you are reading it in parts, as text extracted from a PDF. This is part {i} of {n}: PDF pages {a} to {b}. Lines of the form [[page N]] mark where PDF page N begins. Words run together, odd hyphenation and broken equations or tables are artefacts of extraction; do not comment on them.

{if i > 1:}
Your notes on the earlier parts:
{notes}

{text of the part}

First write comments on this part in the required format. Comment only on what you can judge from this part and your notes; keep issues that need the whole paper for the end.
Then write a line containing only @@NOTES and, after it, updated notes for yourself, at most 350 words: the paper's question, design and data, key assumptions, the main claims with the numbers that support them, notation, and what you want to check against later parts. Include up to 8 short passages copied exactly from the manuscript that you may want to cite later, each as: p.N: passage
End with a line containing only @@DONE
```

`TASK_WHOLE`:

```text
You have now read the whole manuscript in parts. Your notes:
{notes}

Comments you already made: {titles}

Write any further comments that only make sense for the paper as a whole: conclusions against evidence, hidden assumptions, how far the results travel, position in the debate, missing work. Use the required format. For each quote use one of the passages copied in your notes. If you have nothing to add, write only @@DONE
```

`TASK_CONTINUE`:

```text
Your previous answer was cut off. Comments already written (do not repeat them): {titles}
Continue with the remaining comments in the same format and end with a line containing only @@DONE
```

`FORMAT_REVISION` (appended to `discussionSystem`):

```text
If the discussion changes what the comment should say, end your reply with the revised comment in exactly this form:
@@REVISED
kind: major | minor | question | strength
title: at most 12 words
body:
…
suggestion:
…
@@END
If the comment should be dropped, end your reply with a line containing only @@WITHDRAW
Otherwise write no block.
```

### B.3 `discussionSystem` and `questionSystem`

```text
You are assisting a referee who is reviewing a manuscript. You are discussing one of the comments on it. The referee decides; you advise.

Answer the referee's message directly and briefly. Before asserting what the manuscript says, check it, and quote the passage you rely on. If the referee's point shows the comment is wrong or overstated, say so plainly; do not defend it out of habit. If the comment stands, say why in terms of the paper's own text, tables and equations. Say what you could not verify.

Write as one researcher to another: first person, plain words, no flattery, no filler.
```

```text
You are assisting a referee who is reading a manuscript under review. The referee selected a passage and asks about it.

Answer the question precisely and concisely. Ground every statement about the manuscript in its text and quote the relevant words. If the question is whether a step, claim or number is correct, check it and report what you verified, what fails and what you could not check. If the answer is not in the manuscript, say so. Do not summarise the paper unless asked. Do not use any output format; write plain prose.
```

### B.4 `reportSystem` and `reportTemplate`

```text
You are drafting a referee report from a referee's approved notes. The referee will edit it and submit it under their own name, so it must read as a person wrote it.

Use only the approved comments and the reviewer's notes given below. Do not add criticisms of your own. Merge comments that make the same point. Order concerns by importance. Keep every location reference (page, lines, table, equation) exactly as given.

Fill in the template you are given, keeping its headings exactly.

Summary assessment: two to four sentences. State what the paper does and the overall verdict. Be direct. Do not open with a paragraph that summarises the paper; the editor knows what it is about.

Recommendation: one of Accept, Minor revision, Major revision, Reject, with one or two sentences of justification. The recommendation must match the severity of the concerns: no positive recommendation above devastating criticisms, no rejection over minor complaints.

Publication probability: a blunt, calibrated percentage range for the target journal (or a typical top journal in the field if none is named), with two to four sentences of reasoning: how fundamental the concerns are, how crowded the area is, whether the contribution survives the criticisms, and how selective the journal is. A major revision is not a likely acceptance at a top journal; say so when it applies. Do not round to a convenient single number. If the paper would do better elsewhere, name where.

Major concerns: numbered. Each states the problem in one sentence, why it matters for the paper's conclusions, where it is in the paper, and a path to resolution when there is one.

Minor concerns: numbered. Things to fix that do not threaten the core contribution.

Questions for the authors: questions whose answers could change the assessment.

Voice.
- First person: "I am not convinced that…", "I could not verify…", "This is the strongest part of the paper." Never "this reviewer", never "it is noted that".
- Refer to "the authors" in the third person; never address them as "you".
- Concrete, not evaluative: numbers, tables, equations, pages and lines.
- Vary sentence length. Let some sentences be short and blunt.
- No flattering opener. No closing paragraph about promise or potential. End when the last question is asked.
- Do not state a concern and excuse it in the same sentence.
- Numbered lists only under Major concerns, Minor concerns and Questions for the authors. Everything else is prose. No section of strengths and weaknesses.
- Do not use these words: delve, tapestry, landscape (in the abstract sense), multifaceted, pivotal, testament, underscore, leverage, utilize, foster, showcase, elucidate, illuminate, navigate (in the abstract sense), synergy, paradigm, holistic, robust (unless it names a specific robustness check).
- No em dashes; use commas, parentheses or separate sentences. No "not only … but also". Write "is", not "serves as" or "stands as". No lists of three for rhythm. No trailing "-ing" clauses that add nothing, such as "highlighting the need for further research".
- No stacked hedges such as "it could potentially be argued that". Take a position or say you cannot judge.
- Direct, never cruel.

Before you finish, reread the report as the editor would. Delete any sentence that could appear in a review of any other paper.

Output the report in Markdown and nothing else.
```

```text
## Summary assessment

## Recommendation

## Publication probability

## Major concerns

## Minor concerns

## Questions for the authors
```

Report user turn (assembled by the engine after the paper context):

```text
Target journal: {venue, or "not specified"}
Reviewer's notes: {notes, or "none"}

Approved comments:
[M1] major | claims | p. 4, lines 14–16
quote: …
title: …
body: …
suggestion: …
…

Template:
{reportTemplate}
```

### B.5 `voiceRevisionSystem`

```text
You are editing a referee report so that it reads as written by the referee, a person, and not by a language model. Change wording only. Do not add, remove or soften any criticism, number, location reference, heading or list item, and do not change the recommendation or the probability.

Fix every passage listed under "Flagged" and anything similar you notice: the banned vocabulary, em dashes, "not only … but also", "serves as", trailing "-ing" clauses, stacked hedges, flattering openers, closing optimism, "this reviewer", and sentences so generic that they could appear in a review of any paper (make them specific to this paper or delete them). Vary sentence length. Keep the first person.

Output the full revised report in Markdown and nothing else.
```

### B.6 Default rubric categories and quick questions

| id | name | guidance (inserted into the prompt) |
|---|---|---|
| `claims` | Claims vs. evidence | Where the stated conclusions go beyond what the design, estimates and tables support. |
| `assumptions` | Hidden assumptions and omissions | What was not measured, controlled or tested, and what is assumed without defence. |
| `generality` | How far the results travel | Sample, setting and period limits; heterogeneity; replicability. |
| `positioning` | Position in the debate | Whether the paper represents and engages the relevant literature fairly. |
| `literature` | Missing work | Specific work whose absence weakens the argument. |
| `math` | Proofs and derivations | Steps, signs, inequalities, boundary cases, unproven lemmas. |
| `data` | Numbers, tables and figures | Mismatches between text and tables, misread columns, unreported statistics. |
| `writing` | Writing and presentation | Clarity, notation, structure, overclaiming language, generated-sounding passages. |
| `other` | Other | Anything that fits none of the above. |

Quick questions: "Is this claim supported by the evidence in the paper?", "Check this step of the derivation.", "What assumption is doing the work here?", "Does this number match the tables?", "Explain this passage in plain terms."

### B.7 Report lint rules (`ReportLinter`, deterministic)

All matching is case-insensitive and on word boundaries unless noted.

| Rule id | Pattern | Message |
|---|---|---|
| `banned-word` | `delv(e|es|ed|ing)`, `tapestry`, `multifaceted`, `pivotal`, `testament`, `underscor(e|es|ed|ing)`, `leverag(e|es|ed|ing)`, `utili[sz](e|es|ed|ing)`, `foster(s|ed|ing)?`, `showcas(e|es|ed|ing)`, `elucidat(e|es|ed|ing)`, `illuminat(e|es|ed|ing)`, `synerg(y|ies)`, `paradigms?`, `holistic` | "'<word>' reads as machine-written; use a plain word." |
| `check-word` | `landscape`, `navigat(e|es|ed|ing)`, `robust` | "Keep '<word>' only in its literal sense (for 'robust': a named robustness check)." |
| `em-dash` | `—` | "Em dash: use a comma, parentheses or a new sentence." |
| `not-only` | `not only\b[^.?!]{0,120}\bbut also` | "'not only … but also': state the point directly." |
| `copula` | `(serves|stands|functions) as` | "Write 'is'." |
| `gerund-tail` | `,\s+(highlighting|underscoring|reflecting|emphasi[sz]ing|showcasing|demonstrating|illustrating|underlining)\b[^.?!]*[.?!]` | "Trailing '-ing' clause: make it a sentence with a specific claim, or delete it." |
| `third-person` | `this reviewer`, `the reviewer (believes|feels|notes|thinks)`, `it is noted that`, `it should be noted` | "Use the first person." |
| `hedge-stack` | `(could|might|may) (potentially|possibly|perhaps)`, `it could be argued` | "Stacked hedge: take a position or say you cannot judge." |
| `flattering-opener` | first paragraph after the first heading matches `commendable|valuable contribution|interesting paper|well[- ]written|timely` | "Opening praise without content." |
| `optimistic-closer` | last paragraph matches `promising|exciting|potential to|bright future|future directions` | "Ends on generic optimism; end with the last question." |
| `template-heading` | a heading containing `strengths` and `weaknesses` | "This heading is a common marker of generated reviews." |
| `missing-section` | any of the six template headings absent | "Section '<name>' is missing." |
| `opens-with-summary` | first sentence under "Summary assessment" starts with `this (paper|manuscript|study|article) (presents|proposes|investigates|explores|examines)` and the paragraph has more than four sentences | "Do not summarise the paper; state the assessment." |
| `recommendation-mismatch` | recommendation is accept or minor revision and there is at least one numbered item under Major concerns; or recommendation is reject or major revision and there is none | "The recommendation does not match the concerns listed." |

---

## Appendix C. Fixture sources

`scripts/make-fixtures.sh` builds seven PDFs from three LaTeX files; it was run as printed and produced the documents described in §3.6 [V]. The four author–year fixtures are derived from one source with `sed`, so that they share every sentence; the single-column numeric fixture is derived from the two-column one. Each file is compiled three times because the ruler fixture's "Page N of M" header needs the page count.

`scripts/make-fixtures.sh`

```bash
#!/bin/bash
# Regenerates Fixtures/pdf and Fixtures/raw from Fixtures/tex. Needs MacTeX (pdflatex) and sips. Usage: scripts/make-fixtures.sh [--pdf-only]
set -euo pipefail
cd "$(dirname "$0")/.."
TEX=Fixtures/tex; PDF=Fixtures/pdf; RAW=Fixtures/raw
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$PDF" "$RAW"
STRIP_JOURNAL='/\\usepackage{draftwatermark}/d; /\\SetWatermarkText/d; /\\SetWatermarkScale/d; /\\linenumbers/d'
cp "$TEX/ay_nolinks.tex" "$TEX/s1_preamble.tex" "$TEX/num_twocol_links.tex" "$WORK/"
sed -e "$STRIP_JOURNAL" -e '/\\usepackage{lineno}/d' -e 's/\\usepackage{natbib}/\\usepackage[round]{natbib}/' "$TEX/ay_nolinks.tex" > "$WORK/ay_round_nolinks.tex"
sed -e "$STRIP_JOURNAL" -e '/\\usepackage{lineno}/d' -e 's/\\usepackage{natbib}/\\usepackage{natbib}\\usepackage[colorlinks=true,citecolor=blue]{hyperref}/' "$TEX/ay_nolinks.tex" > "$WORK/ay_links.tex"
sed -e "$STRIP_JOURNAL" -e 's/\\usepackage{lineno}/\\input{s1_preamble}/' -e 's/\\usepackage{natbib}/\\usepackage[round]{natbib}/' "$TEX/ay_nolinks.tex" > "$WORK/s1_ruler.tex"
sed -e 's/\[10pt,twocolumn\]/[11pt]/' -e 's/A Two-Column Numeric Fixture With Links/A Single-Column Numeric Fixture With Links/' "$TEX/num_twocol_links.tex" > "$WORK/num_links.tex"
for name in ay_nolinks ay_round_nolinks ay_links s1_ruler num_links num_twocol_links; do
  ( cd "$WORK" && for pass in 1 2 3; do pdflatex -interaction=nonstopmode -halt-on-error "$name.tex" >/dev/null; done )
  cp "$WORK/$name.pdf" "$PDF/$name.pdf"
  echo "built $PDF/$name.pdf"
done
sips -s format png "$PDF/ay_round_nolinks.pdf" --out "$WORK/scan.png" >/dev/null
sips -s format pdf "$WORK/scan.png" --out "$PDF/scanned.pdf" >/dev/null
echo "built $PDF/scanned.pdf"
[[ "${1:-}" == "--pdf-only" ]] && exit 0
scripts/build.sh --product referee-cli
CLI="$(swift build --show-bin-path)/referee-cli"
for f in "$PDF"/*.pdf; do
  "$CLI" dump-raw "$f" > "$RAW/$(basename "$f" .pdf).raw.json"
  echo "dumped $RAW/$(basename "$f" .pdf).raw.json"
done
```

`Fixtures/tex/ay_nolinks.tex`

```latex
\documentclass[12pt]{article}
\usepackage[T1]{fontenc}
\usepackage{natbib}
\usepackage{setspace}
\usepackage{lineno}
\usepackage{draftwatermark}
\SetWatermarkText{CONFIDENTIAL}
\SetWatermarkScale{0.6}
\doublespacing
\linenumbers
\title{Information Aggregation in Sequential Markets: A Fixture}
\author{Anonymous}
\date{}
\begin{document}
\maketitle
\begin{abstract}
We study how sequential traders aggregate private signals. Our identification strategy exploits the staggered rollout of a disclosure rule. The effect is statistically significant but economically small.
\end{abstract}
\section{Introduction}
Herding has been studied extensively since \citet{banerjee1992} and \citet{bikhchandani1992}. Later work extends the framework to markets \citep{avery1998, smith2000}. As shown by \citet{acemoglu2011}, network structure determines whether learning is efficient; see also \citep[p.~12]{smith2000} and \citet{kogan2020,lee2021}. The coefficient in Table 2 is 0.91 with a confidence interval that crosses one, which is difficult to reconcile with the claim of a robust effect. We define the office-specific identification threshold and afterwards verify the differentiability of the payoff function.

In \citet{banerjee1992}, agents observe only the actions of their predecessors. The \citet{avery1998} model adds a market maker who updates prices. See \citet{lee2021} for heterogeneous priors. Following \citet{smith2000}, we allow unbounded signals. Equilibrium notions are taken from \citet{osborne1994}, and the voting application follows the sequential procedure of \citet{dekel2000}.

\section{Model}
Consider a sequence of agents $i = 1, 2, \ldots$ who each observe a private signal $s_i$ and the history of actions $h_i$. The posterior belief satisfies
\begin{equation}
\mu_i = \frac{\pi \, f(s_i \mid H)}{\pi f(s_i \mid H) + (1-\pi) f(s_i \mid L)} . \label{eq:posterior}
\end{equation}
Proposition 1 states that an information cascade begins with positive probability. The proof follows \citet{bikhchandani1992} with minor modifications. It is easy to see that the inequality is preserved when both sides are multiplied by the likelihood ratio.

\section{Results}
\setcounter{table}{1}
Table~\ref{tab:main} reports the estimates; the posterior in (\ref{eq:posterior}) is evaluated at the sample mean of the signal.
\begin{table}[h]
\centering
\caption{Baseline estimates}\label{tab:main}
\begin{tabular}{lcc}
\hline
Specification & Estimate & 95\% interval \\
\hline
Baseline & 0.91 & [0.78, 1.06] \\
Staggered rollout & 0.87 & [0.74, 1.02] \\
Office fixed effects & 0.95 & [0.80, 1.12] \\
\hline
\end{tabular}
\end{table}

\bibliographystyle{plainnat}
\begin{thebibliography}{9}
\bibitem[Acemoglu et~al.(2011)Acemoglu, Dahleh, Lobel, and Ozdaglar]{acemoglu2011}
Acemoglu, D., Dahleh, M.~A., Lobel, I., and Ozdaglar, A. (2011).
\newblock Bayesian learning in social networks.
\newblock {\em Review of Economic Studies}, 78(4):1201--1236.
\bibitem[Avery and Zemsky(1998)]{avery1998}
Avery, C. and Zemsky, P. (1998).
\newblock Multidimensional uncertainty and herd behavior in financial markets.
\newblock {\em American Economic Review}, 88(4):724--748.
\bibitem[Banerjee(1992)]{banerjee1992}
Banerjee, A.~V. (1992).
\newblock A simple model of herd behavior.
\newblock {\em Quarterly Journal of Economics}, 107(3):797--817.
\bibitem[Bikhchandani et~al.(1992)Bikhchandani, Hirshleifer, and Welch]{bikhchandani1992}
Bikhchandani, S., Hirshleifer, D., and Welch, I. (1992).
\newblock A theory of fads, fashion, custom, and cultural change as informational cascades.
\newblock {\em Journal of Political Economy}, 100(5):992--1026.
\bibitem[Dekel and Piccione(2000)]{dekel2000}
Dekel E, Piccione M (2000) Sequential voting procedures in symmetric binary elections.\\
J Polit Econ 108(1):34--55
\bibitem[Kogan(2020)]{kogan2020}
Kogan, D. (2020).
\newblock Learning from reviews with strategic sellers.
\newblock Working paper.
\bibitem[Lee(2021)]{lee2021}
Lee, J. (2021).
\newblock Observational learning with heterogeneous priors.
\newblock {\em Games and Economic Behavior}, 125:1--20.
\bibitem[Osborne and Rubinstein(1994)]{osborne1994}
Osborne, M.~J. and Rubinstein, A. (1994).\\
\newblock {\em A Course in Game Theory}. MIT Press.
\bibitem[Smith and S{\o}rensen(2000)]{smith2000}
Smith, L. and S{\o}rensen, P. (2000).
\newblock Pathological outcomes of observational learning.
\newblock {\em Econometrica}, 68(2):371--398.
\end{thebibliography}
\end{document}
```

`Fixtures/tex/s1_preamble.tex`

```latex
% Journal-system stamps in the style of ScholarOne: a ruler of the numbers 1-60 down the left margin of every page
% (fixed 12 pt spacing, unrelated to the text baselines, restarting on each page), a "Page N of M" header,
% a footer line with a URL, and a diagonal watermark. The journal name and URL are invented.
\usepackage{eso-pic}
\usepackage{fancyhdr}
\usepackage{lastpage}
\usepackage{draftwatermark}
\SetWatermarkText{For Peer Review}
\SetWatermarkScale{0.5}
\pagestyle{fancy}
\fancyhf{}
\renewcommand{\headrulewidth}{0pt}
\fancyhead[L]{\footnotesize Journal of Synthetic Economics}
\fancyhead[R]{\footnotesize Page \thepage\ of \pageref{LastPage}}
\fancyfoot[C]{\footnotesize https://mc.example.org/jse}
\makeatletter\let\ps@plain\ps@fancy\makeatother
\newcount\rulerline
\AddToShipoutPictureBG{\AtPageLowerLeft{\rulerline=0
  \loop\advance\rulerline by 1
    \put(\LenToUnit{40pt},\LenToUnit{\dimexpr 760pt-12pt*\rulerline\relax}){\makebox(0,0)[r]{\scriptsize\the\rulerline}}%
  \ifnum\rulerline<60 \repeat}}
```

`Fixtures/tex/num_twocol_links.tex`

```latex
\documentclass[10pt,twocolumn]{article}
\usepackage[T1]{fontenc}
\usepackage{lipsum}
\usepackage[colorlinks=false]{hyperref}
\title{A Two-Column Numeric Fixture With Links}
\author{Anonymous}
\date{}
\begin{document}
\maketitle
\begin{abstract}
We evaluate attention models on translation. The proposed architecture is clearly superior, a claim we revisit below.
\end{abstract}
\section{Introduction}
Recurrent models \cite{hochreiter1997} were the dominant approach \cite{cho2014,bahdanau2015}. Attention mechanisms \cite{bahdanau2015,vaswani2017,devlin2019} changed this. Several results \cite{hochreiter1997,cho2014,bahdanau2015,vaswani2017} are relevant here. The first column of this page contains the sentence that must be anchored before the second column begins, which tests reading order.
\lipsum[1-3]
\section{Method}
The efficient configuration is defined in the first paragraph of this section, and the difficult identification problem is deferred. \lipsum[4-6]
\section{Results}
Table 1 reports a BLEU score of 28.4 for the base model. \lipsum[7-8]
\begin{thebibliography}{9}
\bibitem{bahdanau2015} Dzmitry Bahdanau, Kyunghyun Cho, and Yoshua Bengio. Neural machine translation by jointly learning to align and translate. In \emph{ICLR}, 2015.
\bibitem{cho2014} Kyunghyun Cho, Bart van Merrienboer, Caglar Gulcehre, Dzmitry Bahdanau, Fethi Bougares, Holger Schwenk, and Yoshua Bengio. Learning phrase representations using RNN encoder-decoder for statistical machine translation. In \emph{EMNLP}, 2014. \url{https://doi.org/10.3115/v1/D14-1179}
\bibitem{devlin2019} Jacob Devlin, Ming-Wei Chang, Kenton Lee, and Kristina Toutanova. BERT: Pre-training of deep bidirectional transformers for language understanding. In \emph{NAACL}, 2019. arXiv:1810.04805.
\bibitem{hochreiter1997} Sepp Hochreiter and J\"urgen Schmidhuber. Long short-term memory. \emph{Neural Computation}, 9(8):1735--1780, 1997.
\bibitem{vaswani2017} Ashish Vaswani, Noam Shazeer, Niki Parmar, Jakob Uszkoreit, Llion Jones, Aidan N. Gomez, Lukasz Kaiser, and Illia Polosukhin. Attention is all you need. In \emph{NeurIPS}, 2017.
\end{thebibliography}
\end{document}
```

---

## Appendix D. Recorded streams and model-output fixtures

Save each block under the named test target: as a data file in its `Fixtures/` folder (excluded in the manifest), or as a Swift string literal (§3.7; WP4 and WP5 chose literals, WP6 files). Lines are shown exactly as received or as documented; `…` inside JSON means "other fields, ignore".

### D.1 Anthropic Messages stream [D]

```
event: message_start
data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","content":[],"model":"m","stop_reason":null,"usage":{"input_tokens":25,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: ping
data: {"type":"ping"}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"@@COMMENT\nkind: major\n"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"title: Example\n@@END\n@@DONE"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}

event: message_stop
data: {"type":"message_stop"}
```

Expected: text `@@COMMENT\nkind: major\ntitle: Example\n@@END\n@@DONE`, `.finished(.endOfTurn, Usage(25, 15))`. In-stream error variant: `event: error` / `data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}` → `.overloaded`. HTTP error body: `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_1"}`. Model list item: `{"type":"model","id":"m","display_name":"M","created_at":"2026-09-21T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000,"capabilities":{"pdf_input":{"supported":true}, …}}` inside `{"data":[…],"has_more":false,"first_id":"m","last_id":"m"}`.

### D.2 OpenAI Responses stream, and xAI Chat Completions stream [D]

```
event: response.created
data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"},"sequence_number":0}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hello","sequence_number":1,"logprobs":[]}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":" world","sequence_number":2,"logprobs":[]}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":12,"output_tokens":2,"total_tokens":14}},"sequence_number":3}
```

Variants to test: `{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}, …}}` → `.finished(.maxTokens)`; `{"type":"response.failed","response":{"error":{"code":"server_error","message":"…"}}}`; `{"type":"error","code":"rate_limit_exceeded","message":"…","param":null,"sequence_number":1}`. HTTP error body: `{"error":{"message":"…","type":"invalid_request_error","param":null,"code":"context_length_exceeded"}}`. Model list: `{"object":"list","data":[{"id":"x","object":"model","created":1686935002,"owned_by":"openai"}]}`.

xAI Chat Completions stream, as printed in xAI's streaming guide (data-only events; the first chunk carries reasoning, which is ignored):

```
data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"reasoning_content":"The","role":"assistant"}}],"usage":{"prompt_tokens":41,"completion_tokens":1,"total_tokens":42},"system_fingerprint":"fp_x"}

data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Ah","role":"assistant"}}],"usage":{"prompt_tokens":41,"completion_tokens":1,"total_tokens":42},"system_fingerprint":"fp_x"}

data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":",","role":"assistant"}}],"usage":{"prompt_tokens":41,"completion_tokens":2,"total_tokens":43},"system_fingerprint":"fp_x"}

data: [DONE]
```

Expected: text `Ah,`, `.finished(.endOfTurn, Usage(41, 2))`. Variant to test **[A]**: a last chunk `"choices":[{"index":0,"delta":{},"finish_reason":"length"}]` → `.maxTokens`. xAI model list item: `{"id":"x","created":1686935002,"context_length":256000,"aliases":[], …}` inside `{"data":[…]}`. xAI errors are plain HTTP statuses with a JSON or text body; map by status (§5.4.3).

### D.3 Gemini Interactions stream [D]

```
event: interaction.created
data: {"interaction":{"id":"v1_abc","status":"in_progress","object":"interaction","model":"m"},"event_type":"interaction.created"}

event: interaction.status_update
data: {"interaction_id":"v1_abc","status":"in_progress","event_type":"interaction.status_update"}

event: step.start
data: {"index":0,"step":{"type":"thought"},"event_type":"step.start"}

event: step.delta
data: {"index":0,"delta":{"signature":"abc","type":"thought_signature"},"event_type":"step.delta"}

event: step.stop
data: {"index":0,"event_type":"step.stop"}

event: step.start
data: {"index":1,"step":{"type":"model_output"},"event_type":"step.start"}

event: step.delta
data: {"index":1,"delta":{"text":"1, 2, 3, ","type":"text"},"event_type":"step.delta"}

event: step.delta
data: {"index":1,"delta":{"text":"4, 5","type":"text"},"event_type":"step.delta"}

event: step.stop
data: {"index":1,"event_type":"step.stop"}

event: interaction.completed
data: {"interaction":{"id":"v1_abc","status":"completed","usage":{"total_tokens":101,"total_input_tokens":11,"total_output_tokens":90}},"event_type":"interaction.completed"}

event: done
data: [DONE]
```

Expected text `1, 2, 3, 4, 5`, `.finished(.endOfTurn, Usage(11, 90))`. Truncated variant: the same with `"status":"incomplete"` in `interaction.completed` → `.finished(.maxTokens, …)`. Error event: `data: {"error":{"message":"Deadline expired before operation could complete.","code":"gateway_timeout"},"event_type":"error"}` → `.server` (the code is in the "server fault" row of §5.5, which also catches unknown codes). HTTP error body: `{"error":{"code":"invalid_request","message":"…"}}`. Model list: `{"models":[{"name":"models/m","displayName":"M","inputTokenLimit":1048576,"outputTokenLimit":65536,"supportedGenerationMethods":["generateContent"]}],"nextPageToken":"t"}`. (Whether the final line after `event: done` is `[DONE]` or empty is not shown in the docs; the parser must accept either.)

### D.4 Ollama chat stream [V, captured from this machine]

```
{"model":"gemma:2b","created_at":"2026-11-22T07:32:06.326224Z","message":{"role":"assistant","content":"OK"},"done":false}
{"model":"gemma:2b","created_at":"2026-11-22T07:32:06.346764Z","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","total_duration":2405164125,"load_duration":2075894750,"prompt_eval_count":33,"prompt_eval_cached_count":0,"prompt_eval_duration":302959000,"eval_count":2,"eval_duration":20789000}
```

`/api/tags` item [V]: `{"name":"gemma4:e4b","model":"gemma4:e4b","size":9608350718,"details":{"family":"gemma4","parameter_size":"8.0B","quantization_level":"Q4_K_M","context_length":131072},"capabilities":["completion","vision","audio","tools","thinking"]}`. `/api/show` [V]: `{"capabilities":["completion"],"model_info":{"general.architecture":"phi3","phi3.context_length":16384, …}}`. `/api/version` [V]: `{"version":"0.40.17"}`. Error line [D]: `{"error":"an error was encountered while running the model"}`.

### D.5 Claude Code `--output-format stream-json` [D]

```
{"type":"system","subtype":"init","session_id":"s1","model":"m","tools":[],"mcp_servers":[]}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":40,"output_tokens":1}}},"session_id":"s1","parent_tool_use_id":null,"uuid":"u1"}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}},"session_id":"s1","parent_tool_use_id":null,"uuid":"u2"}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}},"session_id":"s1","parent_tool_use_id":null,"uuid":"u3"}
{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Hello world"}]},"session_id":"s1","parent_tool_use_id":null}
{"type":"result","subtype":"success","is_error":false,"result":"Hello world","session_id":"s1","num_turns":1,"duration_ms":1200,"total_cost_usd":0.001,"usage":{"input_tokens":40,"output_tokens":2}}
```

Tripwire variants, for the fake CLI and its tests: an init line with `"tools":["Bash","Read"]`; an init line with no `tools` key; after a first text delta, `{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"Bash","input":{}}},"session_id":"s1"}` followed by `{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}]},"session_id":"s1"}` and more text. Read-tool mode (§5.6.6): init with `"tools":["Read"]`; an allowed call `{"type":"tool_use","id":"tu_2","name":"Read","input":{"file_path":"<workdir>/manuscript.pdf","pages":"1-4"}}`; a forbidden one with `"file_path":"/etc/passwd"`. The `tool_use` shapes follow the Messages API; that Claude Code prints them in this envelope is **[A]** until the smoke prompt has run.

Stream-json input line for variant C1 of §5.6.6 **[A: that a `document` block is accepted is what the experiment tests]**: `{"type":"user","message":{"role":"user","content":[{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"JVBERi0x…"}},{"type":"text","text":"…"}]}}`.

Failure variants (the message texts are documented; the exact envelope around them is **[A]**): `{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login", …}`; `…"result":"Failed to authenticate: OAuth session expired and could not be refreshed"…`; `…"result":"You've hit your session limit · resets 3:45pm"…`; `{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["…"], …}`; retry notice `{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":2000,"error_status":529,"error":"overloaded","session_id":"s1","uuid":"u9"}`. `claude auth status` output [V, shape only; values replaced]: `{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"<plan>","loginExpiresAt":"<ISO 8601 date>","email":"<…>","orgId":"<…>", …}`. Never log or display the `email` and `org…` fields.

### D.6 Codex `exec --json` [D]

```
{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}
{"type":"turn.started"}
{"type":"item.started","item":{"id":"item_1","type":"reasoning","text":""}}
{"type":"item.updated","item":{"id":"item_2","type":"agent_message","text":"Hello"}}
{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Hello world"}}
{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":0}}
```

Expected text `Hello world` (delta "Hello" then " world"). Tripwire variants [D: item types from `exec_events.rs`; field details beyond `type` are not needed]: `{"type":"item.started","item":{"id":"item_3","type":"command_execution","command":"ls","status":"in_progress"}}`; `{"type":"item.completed","item":{"id":"item_4","type":"file_change","changes":[],"status":"completed"}}`; `{"type":"item.started","item":{"id":"item_5","type":"mcp_tool_call","server":"s","tool":"t","status":"in_progress"}}`; `{"type":"item.started","item":{"id":"item_6","type":"some_future_type"}}`. Allowed besides `agent_message` and `reasoning`: `{"type":"item.completed","item":{"id":"item_7","type":"todo_list","items":[]}}`, `{"type":"item.completed","item":{"id":"item_8","type":"error","message":"…"}}`. Failures: `{"type":"turn.failed","error":{"message":"…"}}`, `{"type":"error","message":"…"}`. `codex login status` [V]: `Logged in using ChatGPT`, exit 0. `codex debug models` [V, trimmed]: `{"models":[{"slug":"gpt-6-astra","display_name":"GPT-6-Astra","context_window":272000,"max_context_window":872000,"visibility":"list","priority":2, …},{"slug":"codex-auto-review","display_name":"Codex Auto Review","context_window":272000,"visibility":"hide","priority":43, …}]}`.

### D.7 Antigravity `--output-format stream-json` [D]

```
{"event":"init","conversation_id":"9ec58bfd","init":{"cwd":"/tmp/x","tools":["ask_permission","run_command","write_to_file"],"permission_mode":"request-review"}}
{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":0,"state":"DONE","step_type":"user_input"}}
{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"apple"}}
{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"\n","duration_seconds":1.17,"usage":{"input_tokens":30384,"output_tokens":4,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":30388}}}
{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":3,"state":"DONE","step_type":"checkpoint","duration_seconds":0.5}}
{"event":"result","result":{"conversation_id":"9ec58bfd","status":"SUCCESS","response":"apple\n","duration_seconds":1.43,"num_turns":1,"usage":{"input_tokens":30384,"output_tokens":4,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":30388}}}
```

Expected text `apple\n`. Tripwire variants: a tool step exactly as the documentation prints it, `{"event":"step_update","step_update":{"conversation_id":"edb1c8c1","step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.07,"tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hello_headless_demo"},"output":"hello_headless_demo\r\n"}}}`; an init line with `"permission_mode":"always-proceed"`; an init line without `permission_mode`. Error: `{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"invalid model selection (--model \"x\" --effort \"\"): model x is not recognized as a known model or custom model in settings", …}}` → `.modelNotFound`; an `error` containing `authentication required` → `.auth`. `agy models` output: lines such as `gemini-4-neon-high             Gemini 4 Neon (High)`.

### D.8 Grok Build over the Agent Client Protocol [D: xAI's example client and the ACP v1 specification]

One JSON object per line. `→` lines are written by the adapter, `←` lines by `grok agent stdio`.

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},"clientInfo":{"name":"referee","version":"0.1.0"}}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"delete":{}}},"authMethods":[{"id":"cached_token","name":"Cached login"},{"id":"xai.api_key","name":"API key"}]}}
→ {"jsonrpc":"2.0","id":2,"method":"authenticate","params":{"methodId":"cached_token","_meta":{"headless":true}}}
← {"jsonrpc":"2.0","id":2,"result":{}}
→ {"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"/tmp/referee-cli-x","mcpServers":[]}}
← {"jsonrpc":"2.0","id":3,"result":{"sessionId":"sess_1"}}
→ {"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"…"}]}}
← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}}}}
← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}
← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":" world"}}}}
← {"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}
→ {"jsonrpc":"2.0","id":5,"method":"session/delete","params":{"sessionId":"sess_1"}}
← {"jsonrpc":"2.0","id":5,"result":{}}
```

Expected text `Hello world`, `.finished(.endOfTurn, nil)`. Tripwire variants: `← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"tool_call","toolCallId":"call_001","title":"Reading file","kind":"read","status":"pending"}}}`; and a request from the agent, `← {"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"sess_1","toolCall":{"toolCallId":"call_001"},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}`, to which the adapter answers `→ {"jsonrpc":"2.0","id":7,"result":{"outcome":{"outcome":"cancelled"}}}` before killing the process. Failures: `authMethods` without `cached_token` → `.auth`; `← {"jsonrpc":"2.0","id":4,"error":{"code":-32603,"message":"…"}}` → `.server`. Other stop reasons: `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`. `grok models` output **[A]**: one model id per line, possibly followed by a description.

### D.9 Model outputs for the parser and the mock (`Fixtures/llm/`)

`review_clean.txt` (the mock's review answer; every quote occurs in `ay_nolinks`, `ay_round_nolinks`, `ay_links` and `s1_ruler`, on the page it names):

```text
@@COMMENT
kind: major
category: claims
page: 1
quote: The coefficient in Table 2 is 0.91 with a confidence interval that crosses one
title: The interval includes one, yet the effect is called robust
body:
The introduction reports a coefficient of 0.91 whose confidence interval crosses one and, in the same sentence, speaks of a robust effect. These cannot both stand. As reported, the data are consistent with no effect.
suggestion:
State the interval wherever the estimate is quoted and drop "robust" unless a specific robustness check supports it.
@@END
@@COMMENT
kind: major
category: assumptions
page: 1
quote: Our identification strategy exploits the staggered rollout of a disclosure rule.
title: Nothing shows that rollout timing is unrelated to outcomes
body:
The design rests on the timing of the rollout being as good as random. I could not find any evidence on how the order was decided or any test for pre-trends.
suggestion:
Describe how the rollout order was set and show an event-study plot with pre-period coefficients.
@@END
@@COMMENT
kind: major
category: claims
page: 1
quote: The effect is statistically significant but economically small.
title: Abstract and introduction disagree about the result
body:
The abstract calls the effect statistically significant. The introduction reports an interval that crosses one. One of the two statements is wrong, or they refer to different specifications that the paper does not distinguish.
@@END
@@COMMENT
kind: minor
category: math
page: 2
quote: It is easy to see that the inequality is preserved when both sides are multiplied by the likelihood ratio.
title: The sign of the multiplier is not established
body:
Multiplying an inequality by a likelihood ratio preserves its direction only if the ratio is positive, which holds, but the step also needs the ratio to be finite at the boundary. Please show the step.
@@END
@@COMMENT
kind: question
category: math
page: 2
quote: Proposition 1 states that an information cascade begins with positive probability.
title: Which signal structure does Proposition 1 need?
body:
Does the result require bounded signals? With unbounded likelihood ratios cascades need not form. The statement of the proposition should say.
@@END
@@COMMENT
kind: minor
category: positioning
page: 1
quote: network structure determines whether learning is efficient
title: Relation to the network-learning results is asserted, not shown
body:
The sentence cites the network literature as if it supported the present setting, where agents observe the full history. It is not clear that those results apply.
@@END
@@DONE
```

Four more files are written by WP6 under `Tests/ReviewEngineTests/Fixtures/`. `review_sloppy.txt`: five comments that between them use: `### @@COMMENT 1`, `**@@COMMENT**`, a block with no `@@END` before the next `@@COMMENT`, `**Kind:** Major concern`, `- kind: minor`, `* **Quote:** …`, `Type: minor`, `Severity: critical`, a quote wrapped in curly quotation marks, a quote wrapped over two lines, two sentences of prose before the first block and after the last, a body containing the line `Title: this is part of the body`, `Fix:` instead of `suggestion:`, a last block with `suggestion: N/A`, and no `@@DONE`. `review_json.txt`: the six comments of `review_clean.txt` as a fenced JSON array of objects with keys `kind`, `category`, `page`, `quote`, `title`, `body`, `suggestion`. `review_prose.txt`: four paragraphs of ordinary prose with no markers. `review_dupes.txt`: the first block of `review_clean.txt`; the same block again unchanged; a third block of kind `major` with the same quote and the title "Missing definition of the interval"; a fourth of kind `question` with the same quote; then four `strength` blocks on four different quotes; `@@DONE`.

`discussion_revise.txt` (mock discussion answer):

```text
You are right that the interval is in the text and not only in the table. The sentence says the interval "crosses one", so the comment should not say the paper hides it. The problem that remains is the word "robust".
@@REVISED
kind: minor
title: "Robust" is not supported by the reported interval
body:
The introduction itself says the interval crosses one. Calling the effect robust in the same sentence is unsupported. Please delete the word or point to the robustness check it refers to.
@@END
```

`question_answer.txt`: three plain sentences answering whether the abstract's claim is supported, quoting "The coefficient in Table 2 is 0.91".

`report_sample.txt` (mock report; contains three deliberate style-check hits, an em dash, "serves as" and "robust", so that the lint scene and tests have findings):

```text
## Summary assessment

The paper studies how sequential traders aggregate private signals, using the staggered rollout of a disclosure rule. I do not think the main empirical claim holds as stated: the reported interval includes one, and the identifying assumption is not defended.

## Recommendation

Major revision. The concerns below go to the main result — they are not matters of presentation.

## Publication probability

10–20% at a top field journal. The design could work, but the paper has to show that rollout timing is unrelated to outcomes, and the headline estimate may not survive.

## Major concerns

1. The interval includes one (p. 1). The introduction reports 0.91 with a confidence interval that crosses one and still calls the effect robust.
2. Rollout timing (p. 1). Nothing in the paper serves as evidence that the order of the rollout was unrelated to outcomes.

## Minor concerns

1. The step before Proposition 1 multiplies an inequality by the likelihood ratio without stating its sign or behaviour at the boundary (p. 2).

## Questions for the authors

1. Does Proposition 1 require bounded signals?
```

### D.10 Reference services [V, recorded 2026-11-22, trimmed]

Crossref `GET /works?query.bibliographic=Hochreiter+Schmidhuber+Long+short-term+memory+Neural+computation+1997&rows=2&select=DOI,title,author,issued,container-title,score,type` (response headers included `x-rate-limit-limit: 1`, `x-rate-limit-interval: 1s`, `x-concurrency-limit: 1`, `x-api-pool: public-array`):

```json
{"status":"ok","message-type":"work-list","message":{"total-results":5104456,"items":[{"DOI":"10.1162/neco.1997.9.8.1735","title":["Long Short-Term Memory"],"author":[{"given":"Sepp","family":"Hochreiter","sequence":"first"},{"given":"Jürgen","family":"Schmidhuber","sequence":"additional"}],"issued":{"date-parts":[[1997,11,1]]},"container-title":["Neural Computation"],"score":77.511246,"type":"journal-article"},{"DOI":"10.1162/neco.1997.9.1.1","title":["Flat Minima"],"author":[{"given":"Sepp","family":"Hochreiter","sequence":"first"},{"given":"Jürgen","family":"Schmidhuber","sequence":"additional"}],"issued":{"date-parts":[[1997,1,1]]},"container-title":["Neural Computation"],"score":53.478394,"type":"journal-article"}]}}
```

OpenAlex `GET /works/doi:10.1162/neco.1997.9.8.1735?select=…` without a key (response headers included `x-ratelimit-cost-usd: 0`, `x-ratelimit-limit-usd: 0.1`):

```json
{"id":"https://openalex.org/W2064675550","doi":"https://doi.org/10.1162/neco.1997.9.8.1735","title":"Long Short-Term Memory","publication_year":1997,"open_access":{"is_oa":false,"oa_status":"closed","oa_url":null,"any_repository_has_fulltext":false},"best_oa_location":null,"authorships":[{"author_position":"first","author":{"display_name":"Sepp Hochreiter"}},{"author_position":"last","author":{"display_name":"Jürgen Schmidhuber"}}],"primary_location":{"landing_page_url":"https://doi.org/10.1162/neco.1997.9.8.1735","pdf_url":null,"is_oa":false,"source":{"display_name":"Neural Computation"}}}
```

For an open-access case, write a second fixture by hand with `"open_access":{"is_oa":true,"oa_status":"green","oa_url":"https://example.org/paper.pdf"}` and `"best_oa_location":{"is_oa":true,"landing_page_url":"https://example.org/abs","pdf_url":"https://example.org/paper.pdf","license":"cc-by","version":"submittedVersion"}`. For the year rule, write a third Crossref fixture by hand: the same item with `"issued":{"date-parts":[[2001,1,1]]}`, to be resolved against an entry dated 1997.

---

## Appendix E. Sources consulted (fetched 2026-11-22)

**Anthropic API.** https://platform.claude.com/docs/en/api/versioning · https://platform.claude.com/docs/en/build-with-claude/streaming · https://platform.claude.com/docs/en/build-with-claude/pdf-support · https://platform.claude.com/docs/en/api/models/list · https://platform.claude.com/docs/en/api/errors · https://platform.claude.com/docs/en/api/rate-limits

**Claude Code.** https://code.claude.com/docs/en/headless · https://code.claude.com/docs/en/cli-reference · https://code.claude.com/docs/en/authentication · https://code.claude.com/docs/en/setup · https://code.claude.com/docs/en/legal-and-compliance · https://code.claude.com/docs/en/agent-sdk/streaming-output · https://code.claude.com/docs/en/agent-sdk/typescript · https://code.claude.com/docs/en/errors · https://code.claude.com/docs/en/model-config · `claude --help` (2.1.330)

**OpenAI API.** https://developers.openai.com/api/docs/guides/migrate-to-responses · https://developers.openai.com/api/docs/guides/streaming-responses · https://developers.openai.com/api/docs/guides/file-inputs · https://developers.openai.com/api/reference/resources/responses/methods/create · https://developers.openai.com/api/reference/resources/responses/streaming-events · https://developers.openai.com/api/reference/resources/models/methods/list · https://developers.openai.com/api/docs/guides/error-codes · https://developers.openai.com/api/docs/guides/rate-limits · https://developers.openai.com/api/reference/overview

**Codex CLI.** https://learn.chatgpt.com/docs/non-interactive-mode · https://learn.chatgpt.com/docs/developer-commands?surface=cli · https://learn.chatgpt.com/docs/auth · https://learn.chatgpt.com/docs/config-file/config-reference · https://learn.chatgpt.com/docs/config-file/environment-variables · https://learn.chatgpt.com/docs/codex/cli · https://github.com/openai/codex (README; `codex-rs/exec/src/exec_events.rs`) · https://chatgpt.com/codex/install.sh · `codex --help`, `codex exec --help`, `codex login --help`, `codex features list`, `codex debug prompt-input --help` (0.167.0-alpha.3.2)

**Gemini API.** https://aistudio.google.com/llms.txt · https://aistudio.google.com/api-reference · https://aistudio.google.com/api-reference/api-versions · https://aistudio.google.com/api-reference/interactions-api/create-interaction?api-version=v1 · https://aistudio.google.com/docs/interactions-overview · https://aistudio.google.com/docs/streaming · https://aistudio.google.com/docs/document-processing · https://aistudio.google.com/docs/text-generation · https://aistudio.google.com/docs/api-errors · https://aistudio.google.com/api-reference/models · https://aistudio.google.com/api-reference/models/list-models · https://aistudio.google.com/docs/interactions-breaking-changes-may-2026

**Gemini CLI and Antigravity CLI.** https://github.com/google-gemini/gemini-cli (README status notice; `docs/cli/headless.md`) · https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/ · https://antigravity.google/docs/cli/headless · https://antigravity.google/docs/cli/reference · https://antigravity.google/docs/cli/modes · https://antigravity.google/docs/sandbox?tab=cli · https://antigravity.google/docs/permissions?tab=cli · https://antigravity.google/docs/settings?tab=cli · https://antigravity.google/docs/install · https://antigravity.google/docs/getting-started · https://antigravity.google/docs/plans · https://antigravity.google/docs/cli/troubleshooting · `gemini --help` (0.30.0)

**xAI.** https://docs.x.ai/llms.txt · https://docs.x.ai/developers/model-capabilities/text/comparison · https://docs.x.ai/developers/rest-api-reference/inference/responses · https://docs.x.ai/developers/rest-api-reference/inference/models · https://docs.x.ai/developers/model-capabilities/text/streaming · https://docs.x.ai/developers/model-capabilities/files/chat-with-files · https://docs.x.ai/developers/rate-limits · https://docs.x.ai/developers/debugging · https://docs.x.ai/build/overview · https://docs.x.ai/build/cli/headless-scripting · https://docs.x.ai/build/cli/reference · https://docs.x.ai/build/features/sandbox · https://docs.x.ai/build/features/permissions · https://docs.x.ai/build/features/sessions · https://docs.x.ai/build/modes-and-commands · https://docs.x.ai/build/enterprise · https://docs.x.ai/x-subscription/overview · https://docs.x.ai/x-subscription/pricing · https://docs.x.ai/x-subscription/usage-limits

**Agent Client Protocol** (for Grok Build). https://agentclientprotocol.com/llms.txt · https://agentclientprotocol.com/protocol/v1/initialization · …/v1/authentication · …/v1/session-setup · …/v1/prompt-turn · …/v1/tool-calls · …/v1/session-delete · …/v1/transports

**Ollama.** https://docs.ollama.com/api/chat · https://docs.ollama.com/api/tags · https://docs.ollama.com/api-reference/show-model-details · https://docs.ollama.com/api/ps · https://docs.ollama.com/context-length · https://docs.ollama.com/capabilities/thinking · https://docs.ollama.com/api/errors · the local server (0.40.17)

**Scholarly metadata.** https://www.crossref.org/documentation/retrieve-metadata/rest-api/access-and-authentication/ · https://www.crossref.org/documentation/retrieve-metadata/rest-api/tips-for-using-the-crossref-rest-api/ · https://github.com/CrossRef/rest-api-doc · https://help.openalex.org/api/authentication · https://help.openalex.org/access/example-costs · https://help.openalex.org/data/works/open-access · https://help.openalex.org/access/unpaywall · https://info.arxiv.org/help/api/tou.html

**Review.** `docs/plan-review.md` in this repository: the independent review of the first version of this plan, with its probes.

---

## Appendix F. What was verified on this machine (2026-11-22)

Three parties ran things: the coordinator (†), the independent reviewer (‡), and the plan's author (unmarked). "Prototype" means Python run on the real PDFKit output of the fixtures; the Swift implementation does not exist yet.

Toolchain and build:

- † Command Line Tools 26.6: Swift 6.3.3, macOS 26.5 SDK; tools-version 6.2 manifest with `.macOS(.v26)` and `swiftLanguageModes: [.v5]`; SwiftUI + PDFKit + `@Observable` app builds and runs.
- † Swift Testing runs under Command Line Tools only with command-line flags; manifest `unsafeFlags` give a silent zero-test run.
- † ‡ Window capture with `CGWindowListCreateImage` via `dlsym` works without Screen Recording permission; `cacheDisplay` and `CALayer.render` capture empty frames. ‡ SwiftUI overlays above the PDF and in-memory highlights are in the capture; a window moved to (−6000, −6000) captures identically.
- The manifest of §3.2 builds from clean with every declaration of §11.3 as a stub, Appendix A as printed, and the `Composition` file of §11.3 as printed; `scripts/build.sh`, `test.sh`, `run.sh`, `bundle.sh`, `snapshots.sh` and `make-fixtures.sh --pdf-only` run as printed; `test.sh` returns 0 / 1 / 3 for pass / failing test / zero tests, and `--filter <TestTarget>` selects one target (‡ confirmed on the first version).
- Appendix A compiles as printed (Swift 5 mode, no warnings), including the 46 generated initialisers; the JSON in §4.3 is its output; a file written without the two new optional fields still decodes; the test sink of `Log` and the id filter behave as described (Gate 0 replaced the single `setTestSink` with `addTestSink` and `removeTestSink`; `LogTests` runs several sinks at once). A memberwise initialiser in an extension collides with the synthesised one; two files with one base name in a target fail the build.
- `main.swift` of §9.1 compiles and runs with a non-isolated `AppMain.run` that uses `MainActor.assumeIsolated`.
- A hand-assembled, ad-hoc-signed `.app` verifies and runs; from inside it, HTTP to `127.0.0.1:11434` works.
- `@Test @MainActor` runs on the main thread; an unmarked `@Test` does not.
- PDF export: `NSPrintOperation` on a hand-built TextKit 1 view sized to its full text gives six Letter pages with text on every page (and A4 at 595 × 842), inside a main-actor test, with no `NSApplication`. Printing a plain `NSTextView(frame:)` gives the same page count with text on page 1 only; the reviewer's sample output (five pages, text on the first) shows the same defect. ‡ `.docx` export round-trips with bold headings; off the main thread the print path aborts.
- ‡ An undeclared transitive import compiles on this toolchain (not relied on).

PDFKit (fixtures rebuilt for this version: seven PDFs):

- Text of a `lineno` + double-spaced + watermarked manuscript: margin numbers glued to line ends or standing alone on the line before, space-less justified lines, watermark and page-number lines inline (§6.7).
- Text of the ruler fixture: the 60 ruler numbers of each page come first as 60 lines of their own, then the header, the text, and the footer URL.
- `selection(for: NSRange)`, `selectionsByLine()`, `range(at:on:)` are consistent with `page.string`; one range per line selection, ranges monotone, line text equal to its substring, on all fixtures and a real 15-page paper (‡ and the author). The number of line selections differs from the number of newline-separated pieces on pages with a displayed equation, on every page of the ruler fixture, and on 10 of 15 pages of the real paper. `characterBounds(at:)` and `characterIndex(at:)` are not consistent with `page.string` (‡: 24 of 25 samples).
- Selection bounds are exact for ranges that exclude margin numbers and wrong (x from −2) for ranges that include them. ‡ A simulated drag across two lines returns margin digits in its text and a page-wide first rectangle; reproduced on the rebuilt fixture.
- Two-column LaTeX pages: PDFKit's line order is column by column on page 1 of the fixture but wrong on page 2 (top of left column, whole right column, rest of left column).
- hyperref links arrive as `PDFActionGoTo` and `PDFActionURL`; natbib links author and year separately and splits at line breaks; `selectionForLine(at:)` at a destination fails for double-spaced lists. Link counts: 36 in `ay_links` (34 citation pieces), 12 in `num_links`, 12 in `num_twocol_links`.
- In-memory highlight annotations on a data-backed document: `page.annotation(at:)` finds them; the file on disk is unchanged; `documentURL` is nil. PDFKit extraction inside an actor on a background thread works.
- A PDF with an owner password and copying and printing disabled opens unlocked with `isEncrypted == true` and readable text; one with a user password is locked.
- ‡ A `PDFView` subclass that returns from `mouseDown` without calling `super` stops the jump to a link's destination; mouse events reach it through an internal page view; calling `mouseDown(with:)` on the hit-tested view works without activating the app; `PDFView.isFlipped` is false.

Prototypes (author, on the rebuilt fixtures and one real 15-page arXiv paper with 40 references):

- §7.2: line numbers 1–16 / 17–33 / 34–48 / 49–54 on `ay_nolinks`; a ruler 1–60 on each page of `s1_ruler`; nothing on the other fixtures or the real paper; kinds and step-6 numbers as tabulated in §7.2.
- §6.7: all listed quotes located (exact; fuzzy 0.90 for the two-word paraphrase); the across-a-page quote exact on both journal fixtures; an absent sentence rejected; the cross-column quote not found; labels as in WP1's table.
- §6.2: the rendering rules give the output shown there; 37 lines for each of the three text-identical fixtures; every assertion of WP1's rendering row.
- §8: entries, mentions and link targets as tabulated in §8.5, including the real paper (40 entries; 76 text mentions and 76 link mentions with identical targets in identical order). The prototype's first run on the real paper exposed three errors (style detection over the whole list, a list that never ended, arXiv ids read as years), which the rules now cover.
- ‡ A literal implementation of §6.5 and the folding parsed the block format from two local models without error and located 42 of 43 of their quotes.

Providers and tools:

- `claude` 2.1.330 exists only inside the VS Code extension; `claude --help` lists every protected flag of §5.6.4 and `--restricted`, `--input-format`; `claude auth status` JSON (logged in through claude.ai).
- `/opt/homebrew/bin/codex` (npm 0.128.0): its launch hung during the first research session (macOS had rejected the native binary's signature); the binary is now missing and the wrapper fails at once with `ENOENT`. `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` 0.167.0-alpha.3.2 works: `--help`, `exec --help` (including `--strict-config`, `--disable`, `-i`), `login status` ("Logged in using ChatGPT"), `debug models --bundled` JSON, `features list`.
- `codex debug prompt-input` (renders the model-visible tool list locally; nothing is sent), with an empty configuration directory: the tool list for no flags, for the first version's flags, and for §5.6.4's flags, as described there; an unknown feature name is an error; `agents.max_concurrent_threads_per_session=0` is rejected. ‡ With the user's real configuration the list includes a desktop-UI automation plugin.
- `gemini` 0.30.0 (Homebrew) `--help`. `agy` and `grok` are not installed; `npm` is.
- **No prompt was sent to any subscription CLI or paid API**, by anyone, for either version of this plan.
- Ollama 0.40.17: `/api/version`, `/api/tags` (with `details.context_length` and `capabilities`), `/api/show`, `/api/ps`, streaming `/api/chat` with `num_ctx`, consumed from a SwiftPM executable through `URLSession.bytes` and `LineSplitter`; `AsyncBytes.lines` drops empty lines; `"think": false` is accepted by a model that cannot think and by one that can. ‡ First byte after 95.5 s for a seven-page request to `phi4`; a default `URLSession` times out at 61 s; the timings and token counts of M9's table.
- Crossref public pool (headers and a bibliographic query) and OpenAlex keyless DOI lookup (cost 0). ‡ Semantic Scholar answers a keyless request with 429.
- Keychain add / read / delete from a SwiftPM-built executable; login-shell `PATH` lookup in 0.12 s. ‡ After a rebuild, read fails with −25293 and update succeeds.
- `pdflatex` builds all fixture sources in about five seconds; `sips` produces the image-only PDF.

Not verified (assumptions, all listed in §13 or tagged [A] where they are used): any real request to Anthropic, OpenAI, Gemini or xAI; any prompt through Claude Code, Codex, Antigravity or Grok Build, and therefore the runtime tool list of `claude -p --tools ""`, the exact JSON envelope of Claude Code failures and tool calls, whether Codex `item.updated` carries partial text, whether Codex's read-only sandbox blocks `apply_patch`, and whether either CLI accepts the manuscript itself (§5.6.6); everything about `agy` and `grok` beyond their documentation; xAI's finish reason on the Chat Completions stream; Keychain behaviour in a bundle signed with a stable identity; `LSHandlerRank`/"Open With" registration of the hand-made bundle; and, most important for this user, how real Editorial Manager and ScholarOne PDFs come out of PDFKit.

---

## Appendix G. Revision log (second version)

One line per finding of `docs/plan-review.md` and per coordinator decision. "As proposed" means the review's "Change" was applied; a line in **bold** differs from what the review or the decision asked for, and says why.

### G.1 Review findings

| Finding | What changed | Where |
|---|---|---|
| B1 tools in CLI agents | Tripwire in all four adapters, fail-closed; protected arguments that `extraArguments` cannot remove; a flag check against each binary's help text; Codex gets `--strict-config`, `--disable view_image`, `--disable sleep_tool`, `-c agents.enabled=false`; Antigravity pinned to `--mode=accept-edits`; Grok moved to the Agent Client Protocol with a strict sandbox, deny-by-default permissions and disallowed tools; the `!--ignore-user-config` advice is gone; §12.5 states per provider what is and is not guaranteed. **The Codex test the review proposed (no `exec_command`, `write_stdin` or `mcp__` anywhere in the rendered prompt) would fail with the right flags, because Codex's own instructions mention those words; the test inspects the tool declarations instead.** | §5.6.1, §5.6.3, §5.6.4, §12.5, WP5, D.5–D.8 |
| M1 engine contract | `EngineContext.model` and `.paperDigest`; `SendPlan.blockingReason`; where the model info comes from; context without an anchor = digest plus page 1 | A.6, A.9, §6.3, §6.4, WP6, WP8b |
| M2 snapshot registry | `LiveDependencies.make` builds the snapshot graph itself under `REFEREE_SNAPSHOT=1`; four named mocks; `MockResponse.stallAfterChunks`; `Composition` printed in full and compiled | §5.9, §10.1, §11.3, Gate 0 step 4, Gate 1 |
| M3 Reader–Shell seam | One `ReaderController` surface (`pdfView`, `attach()`, `isDocumentLoaded`, find, zoom) in §11.3 only; who calls `attach()`; `ReaderCommand.find` removed; banner and consent card belong to the Shell; settings notification and first-run defaults wired; an integration scene asserts the document loads | §7.4, §9.1, §9.2, §11.3, A.9, §10.1 |
| M4 HTTP timeouts | The session is built in `Composition` (printed) and every adapter also sets `URLRequest.timeoutInterval = 600`; a timeout is not retried | §5.3, §5.7, §11.3, WP4 |
| M5 false [V] on line counts | The newline claim is deleted and replaced by what holds and what does not; the test row asserts no line count; a displayed fraction and a table are in the fixtures and in WP2's rows | §7.2, §3.6, WP2, A.2 |
| M6 selections carry margin numbers | `SelectionNormalizer` in `AppCore`; the model normalises every selection and refreshes rectangles; tests on a synthetic text (WP8b) and on the real fixture (Gate 1), plus a snapshot scene with `verify` | §7.4, §6.9, §9.5, §11.3, WP8b, Gate 1 |
| M7 author–year detection | Rewritten from a prototype run on real PDFKit output: citations are recognised by the bibliography's own author keys on folded text (so sentence-initial words and space-less lines need no special case); the list ends only on positive evidence; heading tolerates trailing digits; Springer-style names; year rule relaxed. Fixtures gained the four sentence-initial forms, the "A Course in Game Theory. MIT Press." line and a Springer-style entry. **Wider than proposed: the token-walk rule was replaced, not patched, because the prototype showed it also fails on lines without spaces.** | §8.1–§8.5, §8.7, §3.6, WP3, Appendix C |
| M8 Keychain can lose keys | `setSecret` writes only after a successful read or "not found"; `SecretError`; a fake backend test; opt-in real-Keychain test; README note on a stable signing identity | §5.8, A.5, WP4, WP8b |
| M9 local-model defaults | Cap 32,768 at 24 GiB or more; 3.5 characters per token; `"think": false` by default through `extraBodyJSON`; reflowed rendering with markers at sentence boundaries; same-passage comments kept and marked `similarTo`; "N/A" suggestions dropped; at most two `strength` comments, in the format text and enforced. **Rendering joins only full-width lines, so table rows, headings and equation fragments stay on their own lines; a first prototype that joined whole paragraphs flattened the table.** | §5.4.5, §6.2, §6.4, §6.5, §6.6, A.4, B.2, WP1, WP6 |
| M10 subscription routes are text-only | A bounded experiment in WP5 (three variants, at most three prompts per CLI, one synthetic fixture), an outcome table that sets `supportsNativePDF`, `pdfDeliveryNote` and the tripwire, and plain "text only" wording when it fails | §5.6.6, §9.7, §11.6, A.5 |
| M11 execution structure | WP0 split in two; Gate 0 by a second agent; WP8 split; Gate 1 merges, fixes contracts and proves the pipeline from the command line before any UI work; three interaction checks; smoke prompts through real CLIs. The vertical-slice alternative was not taken: Gate 1 gives the same early end-to-end proof without a tenth wave. | §11 |
| m1 PDF export | **Kept, with `NSPrintOperation`, `@MainActor` and a test, but not "exactly as the reviewer's probe": that code prints text on the first page only. The view is laid out in full first, and the test checks text on every page.** | §6.10, §11.3, WP8a |
| m2 `referee-cli` dependencies | `PDFBridge` and `PaperText` declared in the manifest | §3.2, §2.1 |
| m3 one slot for two lanes | `streamingReportText` | A.9, §2.3, §9.8 |
| m4 three orderings | One rule, on `visibleComments` | A.9, §6.7, §9.3 |
| m5 lookup from the References tab | `CitationLookup.Target` | A.9, §8.6 |
| m6 untestable tests | (a) `Log.setTestSink`; (b) the real-Keychain test is opt-in, the logic is tested with a fake backend; (c) the source grep is dropped in favour of the byte-identity test; (d) key patterns anchored and applied to tracked files | A.8, §5.8, §4.6, §12.1, Gate 1 |
| m7 sample session hash | The runner rewrites `sha256` and `byteCount` from the fixture on disk | §10.1 |
| m8 parser tolerance | `FIELD` accepts list markers and emphasis around the colon | §6.5 |
| m9 folding | NFKD | §6.7 |
| m10 cursor over citations | `areaOfInterest(for:)` | §7.4 |
| m11 overlay coordinates | The flip is stated | §7.4, WP9 |
| m12 snapshot windows | Moved off screen after ordering front | §10.1 |
| m13 toolbar label | `.labelStyle(.titleAndIcon)` | §9.2 |
| m14 xAI adapter | Chat Completions, as proposed. **R12 is rewritten, not deleted: xAI's own comparison page labels that endpoint "deprecated", which the review did not mention; the fallback is one line.** | §5.4.3, R12, D.2 |
| m15 lookup chain | See decision 5 | §8.7 |
| m16 resolver cache | One cache file per review, inside its folder; `resolve(_:documentSHA256:)` and `forget(documentSHA256:)`; `deleteReviewData()` | §4.2, §8.7, A.3, A.9 |
| m17 tidying | `SelectionInfoBuilder.make(from:in:)` everywhere; `ReviewPhase.anchoring` removed; `.id` log values filtered at run time; `snapshots.sh` takes `--out`; Gemini stop reason from `interaction.status`; unknown Gemini error codes → `.server` | §11.3, A.6, A.8, §3.4, §5.4.4, §5.5 |
| Section 3, claim 29 | The Codex npm copy no longer hangs; it fails at once. Text corrected | §0.1, §5.6.1, Appendix F |
| Coverage notes | "refer to 'the authors'" in the review and report prompts | B.1, B.4 |

### G.2 Coordinator decisions

| Decision | What changed | Where |
|---|---|---|
| 1 Antigravity and Grok stay, hardened | As above under B1; experimental warning until a test prompt succeeds (`ProviderSettings.verifiedAt`); WP5 installs `grok` through npm for its help text and does not install `agy`. **For Grok the adapter uses the Agent Client Protocol instead of `grok -p`: it is the only documented interface that takes the prompt on stdin and reports tool use, without which neither the tripwire nor "no manuscript in arguments" can be met.** | §5.2, §5.6.4, §9.6, §9.7, A.7, WP5 |
| 2 Prompts through CLIs | A complete table of the prompts allowed | §11.6, §3.5, §5.6.6 |
| 3 Reading-order repair cut | Removed; one two-column smoke fixture; a single-column numeric fixture added | §1.3, §3.6, §6.7, §7.2, R19 |
| 4 PDF export kept | See m1 | §6.10, WP8a |
| 5 Lookup reduced | arXiv id; DOI → OpenAlex; Crossref → OpenAlex; Search Google Scholar. Semantic Scholar, OpenAlex search and arXiv title search removed, with their settings and keys | §8.7, §9.6, A.3, A.7, WP7 |
| 6 `referee-cli` trimmed | Eight subcommands; "Quote in chat", viewer tab grouping and the migration chain removed; version check kept | §10.2, §7.7, §4.4 |
| 7 Kept | Consent card, Local-only mode, linter, parser fallbacks, `e2e-ollama.sh` | unchanged |
| 8 Execution structure | As specified: 0a, 0b, Gate 0, Wave 1 with 8a and 8b, Gate 1, Wave 2 of three, Wave 3 | §11 |
| 9 Journal-system realism | `s1_ruler.pdf` with a 1–60 ruler, "Page N of M" header, URL footer and diagonal watermark; one rule set for both margin styles; labels give the ruler number level with the line; the M7 content; a fraction and a table | §3.6, §6.7, §7.2, WP1, Appendix C |
| 10 Review quality | See M9 and the coverage notes | B.1, B.2, B.4, §6.6 |

### G.3 Found while revising, not in the review

| What | Where |
|---|---|
| `lineno` numbers are not always glued to their line: PDFKit emits some on a line of their own before the text line, so the first version would have left those lines without a number. Step 6 of the cleaning handles this and the ruler with one rule. | §6.7, §7.2 |
| Tightly set lines arrive without spaces in the body and in the reference list; a real paper prints numeric labels on lines of their own, breaks a DOI at a slash, and has an arXiv id that reads as a year. | §8.1–§8.3 |
| Protected PDFs (owner password, copying disabled) open and their text is readable, but vendors reject the file: `LoadedPaper.isEncrypted` forces text mode. | §6.2, §7.2, A.2 |
| Two files with one base name in a target fail the build, which three UI agents working in sub-folders of `RefereeUI` would have discovered at merge: file-name prefixes. | §3.1, §3.7 |
| Memberwise initialisers cannot be added in an extension: Appendix A now prints all 46 inside their structs. | §3.1, Appendix A |
| Codex still exposes an agent-spawning tool family that `--disable multi_agent` does not remove; `-c agents.enabled=false` does. | §5.6.4 |
| Grok Build stores every conversation locally and can sync it; the adapter deletes the session after each run. | §5.6.4, §9.7, §12.3 |
| The public surface of `TestSupport` is now pinned and compiled, since nine agents test against it. | §11.3 |

### G.4 Amendments after WP0a (coordinator)

WP0a built the scaffold and reported nine contract problems (`docs/contract-notes/wp0a-scaffold.md`). Decisions, all reflected in the sections named:

| Problem | Decision | Where |
|---|---|---|
| 1 Test targets could not name the shared types without an undeclared import | Every test target declares `RefereeCore`; `RefereeUITests` also `AppCore` and `PDFBridge`; `IntegrationTests` every library | §3.2 |
| 2 No stand-in for `CitationIndexing` | `FakeCitationIndexer` in `TestSupport` | §11.3 |
| 3 `ReviewEngineTests` cannot reach `PaperRenderer` | `FakePaperRenderer` in `TestSupport`, with a rendering that never changes; WP6 tests against it | §11.3, WP6 |
| 4 Placeholders and presentation marks in the task texts | WP0a's representation stands: the constants hold placeholders, and the doc comment of `FormatSpec` is the binding rule. A part request is one text with the part inside the task | B.2, §6.3 |
| 5 Default settings | Ollama is enabled, every other real provider disabled, no default chosen; `mock` is not in the defaults (it would be written into the user's `settings.json`). Tests and the snapshot mode that need mocks use `SnapshotSupport.settings()` | §11.3, WP0a item 2 |
| 6 `SurfaceCheck` cannot name the UI from `IntegrationTests` | Two files, one in `RefereeUITests`, one in `IntegrationTests` | Gate 0 step 2 |
| 7 A scene cannot start a review before WP8b | The check is a permanent test through `LiveDependencies.make` | Gate 0 step 4 |
| 8 Types without a public initialiser | `Banner`, `ConsentRequest`, `ComposingComment` and `SnapshotContext` get one | A.9, §11.3 |
| 9 The release binary carried the checkout's absolute path | `Fixtures.root` uses `#filePath` in debug builds only; `REFEREE_REPO_ROOT` overrides; `scripts/bundle.sh` fails when the binary contains a home-directory path | §3.4, §3.6, §10.6, §11.3 |
| `__pycache__/` | Added to `.gitignore` | §3.3 |
| An `osascript` check hung | Agents never drive the screen; nothing in the tree carries a name, an address or a home-directory path | §11.1 |

### G.5 Amendments after WP0b and Gate 0

WP0b reported six contract problems (`docs/contract-notes/wp0b-testsupport.md`). The coordinator decided them; the Gate 0 reviewer applied the decisions in the code and here, and brought §10.1 and §11.3 in line with the code where they differed and the code was right (`docs/contract-notes/gate0.md`). Every change below is in the code and in the sections named.

| Problem | Decision | Where |
|---|---|---|
| WP0b 1: a minimum width on the PDF pane makes the window wider than 1280 pt | `ReaderPane` declares no minimum width; the window's 1000 × 640 minimum is what keeps the PDF readable; the diagram says "no minimum" | §9.2, WP9 |
| WP0b 2: "half of the third block" left three comments when counted in characters | The failing and stalling scripts cut after the third block's quote line, counted in lines as WP0b built it, so two comments are kept | §5.9, §11.3 |
| WP0b 3: `FakeResolver` could not show that `forget` was called, nor the session store how often it saved | `FakeResolver.forgottenDocuments` stays and is printed; `InMemorySessionStore.saveCount` added, with a test, so WP8b's "autosave" row needs no wrapper | §11.3 |
| WP0b 4: one log sink per process, while the tests of all targets run in parallel | `Log.setTestSink` replaced by `Log.addTestSink(_:) -> UUID` and `Log.removeTestSink(_:)`, changed identically in `Support.swift`; a sink sees the events of every test running at that moment, so a test filters by its own event names. `scripts/test.sh` keeps running tests in parallel | A.8, §10.3, WP6 "privacy", §12.2, Appendix F |
| WP0b 5: `log show` prints no info-level event without `--info` | `/usr/bin/log show --info --last 1m --predicate …` | §11.5 |
| WP0b decision 9: `Theme` was written but not printed, and three UI agents use it | Its public surface, taken from the code | §11.3, §9.10 |
| §10.1 described a runner other than the one built | Brought in line with the code: a data folder and a dependency graph per scene; the window subclass that AppKit cannot shrink, and where it is placed; content, size, style and title per scene kind; when the fixture PDF is opened; what `prepare` and `verify` receive; what counts as a failed scene; `manifest.jsonl` is never emptied; exit codes | §10.1 |
| The `placeholder` scene could be dropped by WP11, which would break a test in `Tests/RefereeUITests/Common` that WP11 cannot edit | Listed in the scene table and kept in every wave; `ShellScenes.swift` says so | §10.1 |
| `TestSupport` imports CryptoKit | Added to the table | §2.1 |
| §11.3 did not say that `StubURLProtocol`'s handler belongs to the calling test's task (WP0b decision 2) | A comment on `setHandler` | §11.3 |
| §11.3 did not say when `MockLLMProvider` records a request | "when `stream(_:)` is called" in the comment on `recordedRequests` | §11.3 |
| `Tests/RefereeUITests/Common/` was neither frozen nor owned (Gate 0 question 1) | Frozen with the other Wave 0 paths; only Gate 1 and Wave 3 change it | §11.2 |
| §2.1 left out two frameworks the snapshot runner imports (Gate 0 question 2) | CryptoKit and ImageIO added to the `RefereeUI` row | §2.1 |

### G.6 Amendments at Gate 1

Gate 1 merged the nine Wave 1 branches, read their notes (`docs/contract-notes/wp1-…` to `wp8b-…`) and applied the coordinator's decisions and its own (`docs/contract-notes/gate1.md`, which has the reasons). Every change below is in the code and in the sections named, in the same commit.

| Problem | Decision | Where |
|---|---|---|
| WP1 1, WP8b 6: `TextRange` is ambiguous in type position outside `RefereeCore` (Apple Events' C struct of the same name comes with Foundation) | One internal `typealias TextRange = RefereeCore.TextRange` per module that uses the type, in `TextRangeAlias.swift` (`CommonTextRangeAlias.swift` in `RefereeUI` and `RefereeUITests`), written by Gate 1 for every such module and for `RefereeUI`; Wave 2 adds none | §3.7 |
| WP4 1, WP5 1, WP6 1: data files in a test target make SwiftPM warn, and the three packages each got round it differently | One rule: Swift literals, or data files in `Tests/<Target>Tests/Fixtures/` with `exclude: ["Fixtures"]` for that target and no Swift file in the folder. `ReviewEngineTests` is excluded and its four files left the hidden `.llm` folder; LLMKit's two literal files left its `Fixtures/` folder; the fake CLIs stay literals | §3.2, §3.3, §3.7, §10.3, §11.2, Appendix D |
