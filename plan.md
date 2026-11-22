# Referee — implementation plan

A macOS PDF reader for peer review: the manuscript on the left, AI-drafted referee comments in a sidebar to approve, reject, discuss or add to, questions about any highlighted passage, clickable citations that open the cited paper, and a generated referee report to edit and export. Works with Anthropic, OpenAI, Google, xAI and Ollama, by API key or through the vendor's own command-line tool for subscription plans.

Plan date: 2026-11-22. Target machine: macOS 26.6.1, Apple silicon, Command Line Tools only (no Xcode).

**Contents.** 0 How to read this plan · 1 Product definition · 2 Architecture · 3 Toolchain & build · 4 Data model & persistence · 5 LLM layer · 6 Review engine · 7 PDF layer · 8 Citations · 9 UI/UX · 10 Self-verification hooks · 11 Work breakdown · 12 Security & privacy · 13 Risks and open questions · Appendix A Contracts (Swift) · B Prompts, rubric, lint · C Fixture sources · D Recorded streams · E Sources · F Verification log

## 0. How to read this plan

**Audience.** Coding agents who see this file and a two-paragraph assignment, and cannot talk to each other. Everything two agents must agree on is written here as a concrete name, signature, format or command. If something you need is not specified, decide locally inside your own files and record the decision in `docs/contract-notes/<your work package>.md`; do not change a shared contract.

**Evidence tags.** Every external fact carries one of:

- **[V]** verified on this machine on 2026-11-22 by running it (probe list in Appendix F).
- **[D]** taken from the vendor's official documentation fetched on 2026-11-22 (URLs in Appendix E), not exercised here.
- **[A]** assumption. Each has a fallback, listed in §13.

**Reading order for a coder.** §2 (architecture), §3 (build rules), §11 (your work package), Appendix A (contracts), then the section for your area. §0.1 and §13 tell you what is known to be shaky.

### 0.1 Deviations from the brief (blocking flaws found during research)

1. **Google subscription route changed.** The brief says to drive `gemini -p` for Google-account plans. Since 2026-06-18 Gemini CLI no longer serves free or Google AI Pro/Ultra accounts; Google moved them to **Antigravity CLI (`agy`)** [D: gemini-cli README, Google Developers blog]. The Google subscription provider in this plan drives `agy`. Gemini CLI is not implemented. `agy` is not installed on this machine, so that adapter is built from documentation and fixture streams only.
2. **xAI has an official subscription route.** The brief says Grok is API-key only unless research finds one. xAI now ships **Grok Build (`grok`)**, a CLI with a documented headless mode and browser sign-in [D]. It is added as a fifth CLI provider, marked experimental: it is not installed here, its streaming JSON schema is undocumented (the adapter uses plain-text output), and the pages fetched do not say explicitly whether headless use draws on a subscription's included usage.
3. **Gemini API surface.** Google now labels `generateContent`/`streamGenerateContent` "legacy" and directs new projects to the **Interactions API**, generally available at `v1` [D]. The Gemini API-key provider uses `POST /v1/interactions`, not `streamGenerateContent`.
4. **Unpaywall dropped.** Unpaywall now runs on the OpenAlex database and returns the same open-access fields [D]. A DOI lookup on OpenAlex is free and needs neither key nor email [V]. The resolver uses OpenAlex and never needs an email; Crossref `mailto` stays an optional setting, empty by default.
5. **Test fallback dropped.** The coordinator verified Swift Testing under Command Line Tools 26.6 with extra command-line flags [V]. There is no custom test runner.
6. **Stale Codex binary.** During research, `/opt/homebrew/bin/codex --version` (npm install of 0.128.0, May 2026) hung; macOS logged an invalid code signature for the binary (`AppleMobileFileIntegrityError -420`) and the vendor binary file is now absent from the npm package directory [V]. The Codex CLI bundled inside `/Applications/ChatGPT.app` (0.167.0-alpha.3.2) works and is logged in [V]. Consequences: binary resolution must validate candidates and enforce a launch timeout (§5.6), and the user should reinstall Codex (`npm install -g @openai/codex@latest` or the standalone installer).

No other decision in the brief is reopened.

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
8. **Follow citations.** Click an in-text citation, numeric ("[12]", "[3–5]") or author–year ("Smith and Jones (2019)", "(Smith et al., 2020; Lee, 2021)"). A card shows the reference entry and resolved metadata; "Open PDF" opens an open-access copy in an in-app viewer window, otherwise "Open in Browser" goes to the DOI or publisher page.
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
| U12 | review PDFs from journal systems: no links, margin line numbers, watermarks, double spacing, two columns | §6.7, §7.2, §8 |

### 1.3 Non-goals for v1

- OCR. A scanned PDF with no text layer opens and can be sent natively to providers that accept PDFs, but comments anchor to pages only. The app says so.
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
| `TestSupport` | library | RefereeCore | `MockLLMProvider`, in-memory stores, `StubURLProtocol`, fixture locator, simple fakes of every protocol. Used by tests, the snapshot mode and `referee-cli --provider mock`. |
| `PaperText` | library | RefereeCore | Pure text algorithms: line classification, margin line-number removal, quote matching, LLM-facing rendering, chunking. No PDFKit. |
| `PDFBridge` | library | RefereeCore, PDFKit, CryptoKit | Everything that touches PDFKit outside the UI: loading, raw extraction, geometry for spans, link annotations, outline. |
| `CitationKit` | library | RefereeCore | Pure: reference-list segmentation and parsing, in-text citation detection, link-target matching. |
| `LLMKit` | library | RefereeCore, Security | HTTP providers (Anthropic, OpenAI, xAI, Gemini, Ollama), SSE/NDJSON parsing, retry, model listing, Keychain secret store. |
| `CLIProviders` | library | RefereeCore | Subscription providers that drive vendor CLIs (Claude Code, Codex, Antigravity, Grok Build): binary resolution, process runner, per-CLI adapters. |
| `ReviewEngine` | library | RefereeCore | Prompt assembly, streaming comment parser, chunk planning, review / discussion / question / report orchestration, report lint. |
| `ScholarKit` | library | RefereeCore | Reference resolution (Crossref, OpenAlex, Semantic Scholar, arXiv), rate limiting, caches, PDF download. |
| `Persistence` | library | RefereeCore | Session and settings files, paths, migration. |
| `Composition` | library | all libraries above | The one place that constructs real implementations: `LiveDependencies.make()`. |
| `AppCore` | library | RefereeCore, AppKit (for export only), Observation | `ReviewSessionModel`, `SettingsModel`, report export. Depends on protocols only. No SwiftUI, no PDFKit. |
| `RefereeUI` | library | AppCore, RefereeCore, PDFBridge, TestSupport (snapshot mode only), SwiftUI, AppKit, PDFKit | Views, window management, menus, snapshot mode. |
| `Referee` | executable | RefereeUI, Composition | `main.swift`: one call to `AppMain.run` (§9.1). |
| `referee-cli` | executable | Composition, RefereeCore | Command-line entry point to the same pipeline. |

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

- Implementation libraries (`PaperText` … `Persistence`) import **only** `RefereeCore`. They never import each other. They meet through protocols in `RefereeCore`, wired in `Composition`. This is what lets eight agents build them at once.
- `AppCore` never names a concrete implementation type.
- Only `PDFBridge` and `RefereeUI` import PDFKit. Only `LLMKit` imports Security. Only `RefereeUI` imports SwiftUI.

### 2.2 Data flow

```
PDF file ──read once──► Data ──► PDFBridge.PDFPaperService (actor, private PDFDocument)
                          │           │ raw pages, lines, links
                          │           ▼
                          │      PaperText.PaperTextBuilder ──► PaperText (clean lines, margin numbers stripped)
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
- `ReviewSessionModel` runs at most one job in each of two lanes: the **review lane** (review, report, voice revision) and the **reply lane** (discussion, question). A reviewer can discuss an early comment while the review is still streaming.
- No Combine, no `DispatchQueue` in new code except where an AppKit API requires it, no detached tasks that outlive their owner.

### 2.4 State management

One `ReviewSessionModel` per open manuscript window, `@Observable`. Views read its properties and call its methods; they hold no review state of their own beyond transient UI state (text being typed, hover). Engine events are applied on the main actor in arrival order. Every mutation of `session` schedules an autosave (1 s debounce) and bumps `updatedAt`. The PDF view is driven by a serial-numbered `readerCommand` property and reports back through `reader…` methods (Appendix A.9), so the model never references PDFKit.

### 2.5 Error handling

- Every thrown error is a type conforming to `RefereeError` (`userMessage`, `recoverySuggestion`, `isRetryable`). Providers throw only `LLMError`; the paper layer `PaperError`; stores `StoreError`; the resolver returns status values and throws `ResolverError` only from `fetchPDF`.
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
        .executableTarget(name: "referee-cli", dependencies: ["RefereeCore", "Composition"]),

        .testTarget(name: "RefereeCoreTests", dependencies: ["RefereeCore", "TestSupport"]),
        .testTarget(name: "PaperTextTests", dependencies: ["PaperText", "TestSupport"]),
        .testTarget(name: "PDFBridgeTests", dependencies: ["PDFBridge", "TestSupport"]),
        .testTarget(name: "CitationKitTests", dependencies: ["CitationKit", "TestSupport"]),
        .testTarget(name: "LLMKitTests", dependencies: ["LLMKit", "TestSupport"]),
        .testTarget(name: "CLIProvidersTests", dependencies: ["CLIProviders", "TestSupport"]),
        .testTarget(name: "ReviewEngineTests", dependencies: ["ReviewEngine", "TestSupport"]),
        .testTarget(name: "ScholarKitTests", dependencies: ["ScholarKit", "TestSupport"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "TestSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "TestSupport"]),
        .testTarget(name: "RefereeUITests", dependencies: ["RefereeUI", "TestSupport"]),
        .testTarget(name: "IntegrationTests", dependencies: ["Composition", "AppCore", "TestSupport"]),
    ],
    swiftLanguageModes: [.v5]
)
```

Manifest rules: no `resources:` anywhere (reason: `Bundle.module` does not resolve inside a hand-assembled `.app`; prompts and templates are Swift string literals, tests find fixtures by path, see §3.6); no `unsafeFlags`; no dependencies.

### 3.3 Repository layout

```
Referee/
  Package.swift   Makefile   README.md   plan.md   .gitignore
  scripts/        build.sh  test.sh  run.sh  bundle.sh  snapshots.sh  make-fixtures.sh  make-icon.sh  e2e-ollama.sh
  docs/           contract-notes/<WP>.md      (notes for the integrator)
  Fixtures/
    tex/          LaTeX sources of the synthetic manuscripts (Appendix C)
    pdf/          the generated PDFs, committed
    raw/          <name>.raw.json: RawDocument dumps of each PDF, committed (PDFKit-free tests read these)
    sessions/     sample ReviewSession JSON for snapshots
    llm/          model outputs for parser tests and the mock provider
    private/      git-ignored; optional real PDFs fetched by scripts/fetch-optional-fixtures.sh
  Sources/<Target>/…
  Tests/<Target>Tests/…          (a test target may keep its own data under Tests/<Target>Tests/Fixtures/)
  build/          git-ignored output: Referee.app, snapshots, icon
```

`.gitignore`: `.build/`, `build/`, `Fixtures/private/`, `*.local.json`, `.env`, `.DS_Store`, `*.xcuserstate`, `.swiftpm/`.

### 3.4 Commands (the only ones agents and the user run)

| Purpose | Command |
|---|---|
| Build everything (debug) | `scripts/build.sh` |
| Build one product | `scripts/build.sh --product referee-cli` |
| Run all tests | `scripts/test.sh` |
| Run one test target | `scripts/test.sh --filter PaperTextTests` |
| Run the app unbundled | `scripts/run.sh [app arguments]` |
| Assemble and sign the app | `scripts/bundle.sh` → `build/Referee.app`; then `open build/Referee.app` |
| Render UI snapshots | `scripts/snapshots.sh [outDir] [--scene name]` |
| Real local-LLM end-to-end | `scripts/e2e-ollama.sh [model]` |
| Regenerate fixture PDFs | `scripts/make-fixtures.sh` (needs MacTeX) |

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
codesign --force --sign "${REFEREE_SIGN_IDENTITY:--}" "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $APP"
```

`scripts/make-icon.sh` renders a 1024-pixel PNG with a small Swift script run through `swift -` (CoreGraphics: a rounded square and a serif "R"), resizes it with `sips` into `build/AppIcon.iconset/` at the ten standard sizes and runs `iconutil -c icns`. The bundle works without it.

`scripts/snapshots.sh`

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/snapshots}"; shift || true
scripts/build.sh --product Referee
mkdir -p "$OUT"
"$(swift build --show-bin-path)/Referee" --ui-snapshot "$OUT" "$@"
ls -1 "$OUT"/*.png
```

`Makefile`: phony targets `build`, `test`, `run`, `app`, `snapshots`, `e2e`, `fixtures` that call the scripts with no extra logic.

### 3.5 Test strategy

| Layer | What | How |
|---|---|---|
| Unit | pure algorithms, parsers, request builders, stores, view-model logic | Swift Testing in `Tests/<Target>Tests`, fakes from `TestSupport`, fixture files |
| Provider streams | every provider's stream format and error mapping | recorded bodies (Appendix D) served by `StubURLProtocol`; fake CLI shell scripts for the CLI providers |
| Integration | real PDF → extraction → clean text → anchoring → citations; review pipeline with the mock provider | `Tests/IntegrationTests`, real implementations from `Composition` |
| Live local | Ollama end to end | `scripts/e2e-ollama.sh`; tests tagged live are skipped unless `http://127.0.0.1:11434/api/version` answers |
| Live remote | real vendor APIs | never in the default run; enabled per provider by `REFEREE_KEY_<PROVIDER>` in the environment |
| UI | what the screen looks like | `--ui-snapshot` PNGs that the agent opens and inspects (§10.1); pure UI helpers unit-tested |

Rules: tests never read or write the user's Keychain item, `~/Library/Application Support/Referee`, or real CLIs' state; they set `REFEREE_HOME` to a temporary directory. Tests never send a prompt to a subscription CLI. A test that needs something absent (Ollama, a key, an optional fixture) must skip visibly (`try #require` on a condition with a clear comment, or `.enabled(if:)`), not pass silently.

### 3.6 Fixtures

- **Synthetic manuscripts** are written in LaTeX (`Fixtures/tex`, sources in Appendix C), compiled twice with `pdflatex`, and the PDFs are committed so tests never need TeX. `scripts/make-fixtures.sh` produces all six on this machine [V]. They contain invented text and invented or public references only; no real manuscript and no personal name of the user may ever be added to `Fixtures/` outside `private/`.

| File | What it exercises |
|---|---|
| `ay_nolinks.pdf` | author–year citations in square brackets (natbib default), **no link annotations**, `lineno` margin line numbers, double spacing, a "CONFIDENTIAL" watermark. The journal-system case. |
| `ay_round_nolinks.pdf` | author–year in round brackets with semicolons ("(Avery and Zemsky, 1998; Smith and Sørensen, 2000)"), no links, citations and surnames broken across lines. The economics working-paper case. |
| `ay_links.pdf` | author–year with hyperref: 21 internal link annotations, author and year linked separately, links split across line breaks [V]. |
| `num_twocol_links.pdf` | two columns, numeric citations with hyperref (10 internal links, 2 URL links to a DOI) [V]. |
| `num_twocol_nolinks.pdf` | the same without hyperref. |
| `scanned.pdf` | one page, image only, zero characters [V]. Built by `sips -s format png` then `sips -s format pdf`. |

- **Raw dumps.** `referee-cli dump-raw <pdf>` prints the `RawDocument` JSON; `scripts/make-fixtures.sh` writes one per PDF into `Fixtures/raw`. The pure libraries test against these.
- **Fixture access.** `TestSupport.Fixtures.url("pdf/ay_nolinks.pdf")` resolves the repository root from `#filePath` of its own source file (three directories up). No `Bundle.module`.
- **Optional real papers.** `scripts/fetch-optional-fixtures.sh` downloads a few arXiv PDFs into `Fixtures/private/` (git-ignored, one request every three seconds per arXiv's terms). Tests that use them skip when absent.
- **Model outputs and provider streams** are text files (Appendix D and `Fixtures/llm`).

### 3.7 Conventions for all code

- Four-space indentation, one type per file where practical, `public` only for what another target uses.
- Every public struct in `RefereeCore` has an explicit public memberwise initialiser, parameters in declaration order, defaulting optionals to `nil` and collections to empty.
- No `print` in libraries; use `Log.event`. `referee-cli` and tests may print.
- No file outside your owned paths may be edited (§11.2).
- Dates are encoded ISO 8601; JSON written to disk uses `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`.
- UTF-16 offsets into `PDFPage.string` are the only text coordinates (`TextRange`); never store `String.Index` or grapheme offsets.

---

## 4. Data model & persistence

### 4.1 Types

All types are in Appendix A (they compile as printed [V]). The ones that are persisted:

| Type | Meaning |
|---|---|
| `ReviewSession` | Everything about the review of one PDF: comments, question threads, report, audit trail of runs, consents. One per document. |
| `DocumentRef` | Identity of the PDF: SHA-256 of its bytes (the key), file name, last known path, size, page count. |
| `ReviewComment` | One referee comment: `origin` (AI run or user), `status` (pending / approved / rejected), `kind` (major / minor / question / strength), `category` (rubric slug), title, body, optional suggestion, `anchor`, discussion `thread`, optional `proposedRevision`, `previousVersions`, `includeInReport`. |
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
    resolver-cache.json                        reference lookups
~/Library/Caches/Referee/papers/<sha256(url)>.pdf     downloaded open-access PDFs (LRU, default cap 500 MB)
Keychain: one generic-password item, service "local.referee.app", account "secrets-v1"
```

- Keyed by content hash, in Application Support, not beside the PDF. Reasons: manuscripts arrive in Downloads and get moved or renamed; a sidecar file would be lost or left behind; and one private folder is easy to wipe when a review is finished ("Delete review data" in the File menu removes `sessions/<sha256>/`).
- The list of past reviews is built by scanning `sessions/*/session.json` (`SessionStoring.listSessions`); there is no separate index to go stale.
- The PDF is never copied into the store. If the file has moved, the app asks for it and verifies the hash.

### 4.3 `session.json`

Encoded with `JSONEncoder` (ISO-8601 dates; `prettyPrinted`, `sortedKeys`, `withoutEscapingSlashes`). Enums with associated values use Swift's synthesised encoding: `{"exact":{}}`, `{"fuzzy":{"score":0.82}}`, `{"ai":{"runID":"…"}}`, `{"failed":{"_0":"message"}}`. Optionals that are `nil` are omitted. Real output of the types in Appendix A [V]:

```json
{
  "comments" : [
    {
      "anchor" : {
        "confidence" : { "exact" : { } },
        "locationLabel" : "p. 1, lines 13-14",
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
  "document" : { "byteCount" : 176097, "fileName" : "manuscript.pdf", "lastKnownPath" : "/path/to/manuscript.pdf", "pageCount" : 3, "sha256" : "9f2c…" },
  "id" : "55555555-5555-4555-8555-555555555555",
  "meta" : { "reviewerNotes" : "", "title" : "Information Aggregation in Sequential Markets" },
  "runs" : [
    { "destination" : "127.0.0.1:11434", "finishedAt" : "2026-11-18T11:06:40Z", "id" : "11111111-1111-4111-8111-111111111111",
      "kind" : "review", "provider" : { "model" : "gemma4:e4b", "providerID" : "ollama" }, "requestCount" : 3, "sentPDF" : false,
      "startedAt" : "2026-11-18T11:06:40Z", "status" : { "completed" : { } }, "usage" : { "inputTokens" : 21000, "outputTokens" : 1800 } }
  ],
  "schemaVersion" : 1,
  "updatedAt" : "2026-11-18T11:06:40Z"
}
```

### 4.4 Versioning

- `schemaVersion` is 1. `FileSessionStore.currentSchemaVersion = 1`.
- Loading: read the file as `[String: Any]`, look at `schemaVersion`. Greater than supported → throw `StoreError.newerSchema` (the UI opens the PDF with an empty in-memory session and a banner; it does not overwrite the file). Lower → run the chain of JSON-level migrations `migrate_1_to_2(_ json: inout [String: Any])` … in order, then decode.
- After version 1 ships, a field may be added without a version bump only if it is `Optional` in the Swift type. Anything else needs a version bump and a migration function with a test that loads a frozen sample of the old version.
- `settings.json` follows the same rule. When a known provider id is missing from `providers`, the store fills in that provider's default settings on load.

### 4.5 Saving

- `ReviewSessionModel` schedules a save 1.0 s after the last mutation; it flushes immediately when the window closes, the app deactivates or terminates, and before any run starts.
- `FileSessionStore.save` writes to `session.json.tmp`, moves the current `session.json` to `session.json.bak`, then renames the temp file into place (`FileManager.replaceItemAt`), all inside the actor.
- A file that fails to decode is renamed to `session.corrupt-<timestamp>.json`; the `.bak` is tried next; a banner reports what happened.

### 4.6 The PDF is never modified

- The file is read once: `Data(contentsOf:options: .mappedIfSafe)`. Both `PDFDocument` instances (the display one and the extraction one) are created with `PDFDocument(data:)`, so they have no `documentURL` and nothing can save back to the path [V].
- No code calls `PDFDocument.write(to:)`, `write(toFile:)` or `dataRepresentation()`. A test in `IntegrationTests` greps `Sources/` for those three names.
- Highlights are `PDFAnnotation` objects added to the in-memory display document only (§7.3).
- When a provider gets the PDF natively, it gets the original `Data`, never a re-serialised document.

---

## 5. LLM layer

### 5.1 One contract for nine back ends

`LLMProvider` (Appendix A.5): `availability()`, `listModels()`, `stream(LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>`.

An `LLMRequest` is **one system prompt and one user turn**, made of parts (`.text`, `.pdf`, `.cacheBoundary`). There is no message-history API. Discussions and question threads are flattened by the review engine into that single user turn as a transcript. Reasons: four of the nine back ends are CLIs that take one prompt; and replaying assistant turns is where the HTTP APIs differ most and break most easily (Gemini requires resending signed "thought" steps unchanged [D]; Anthropic and OpenAI have their own rules for reasoning blocks). A flat transcript behaves identically everywhere, and the paper stays at the front of the prompt where provider-side prompt caching can reuse it.

The stream yields `.textDelta` any number of times, optional `.status`, then exactly one `.finished(StopReason, Usage?)`. Failures are thrown as `LLMError`, including after some deltas.

### 5.2 Provider roster

| id | Shown as | Auth | Transport | Native PDF | Stream granularity | Model list | Context window known from |
|---|---|---|---|---|---|---|---|
| `anthropic-api` | Anthropic API | API key | `POST https://api.anthropic.com/v1/messages` | yes | token | `GET /v1/models` | `max_input_tokens` in the model list [D] |
| `openai-api` | OpenAI API | API key | `POST https://api.openai.com/v1/responses` | yes | token | `GET /v1/models` | not exposed [D]; override or 128,000 assumed |
| `gemini-api` | Gemini API | API key | `POST https://generativelanguage.googleapis.com/v1/interactions` | yes | token | `GET /v1/models` | `inputTokenLimit` [D] |
| `xai-api` | xAI API | API key | `POST https://api.x.ai/v1/responses` | no (v1) | token | `GET /v1/models` | `context_length` [D] |
| `ollama` | Ollama (local) | none | `POST http://127.0.0.1:11434/api/chat` | no | token | `GET /api/tags` | `details.context_length` [V] |
| `claude-cli` | Claude Code (subscription) | CLI login | `claude -p` | no | token | fixed aliases + free text | 200,000 assumed, editable |
| `codex-cli` | Codex (ChatGPT plan) | CLI login | `codex exec` | no | message (see §5.6.4) | `codex debug models` [V] | `context_window` from that list [V] |
| `antigravity-cli` | Antigravity (Google AI plan) | CLI login | `agy` print mode | no | token | `agy models` [D] | 200,000 assumed, editable |
| `grok-cli` | Grok Build (experimental) | CLI login | `grok -p` | no | token (plain text) | `grok models` [D] | 128,000 assumed, editable |
| `mock` | Mock | none | in-process | accepts | token | fixed | 1,000,000 |

`isLocal` is true only for `ollama` when its base URL host is `127.0.0.1`, `localhost` or `::1`, and for `mock`. `isExperimental` is true for `antigravity-cli` and `grok-cli`: both adapters are built from documentation alone, because neither CLI is installed on this machine.

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
- Session configuration: `timeoutIntervalForRequest = 600` (the longest tolerated silence between bytes: reasoning models can think for minutes before the first token, and Ollama is silent while it loads a model), `timeoutIntervalForResource = 3600`, `waitsForConnectivity = false`, no cookies, no cache.
- `ProviderSettings.extraBodyJSON`, when it parses as a JSON object, is merged into the request body last (top-level keys overwrite). This is the escape hatch for vendor knobs the app does not model (reasoning effort, service tier), so API drift does not require a release.
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
- Limits used by the engine: request ≤ 128 MB; PDF ≤ 600 pages, or ≤ 100 pages when the model's context window is under 1,000,000 tokens [D]. App cap: 30 MB file.
- Models: `GET /v1/models?limit=1000` (follow `has_more` with `after_id`); per item `id`, `display_name`, `max_input_tokens`, `max_tokens`, `capabilities.pdf_input.supported` [D].
- Headers on 429: `retry-after` (seconds), not always present [D].

#### 5.4.2 OpenAI — Responses API [D]

"Responses is recommended for all new projects" [D]; Chat Completions is not used.

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

#### 5.4.3 xAI — Responses API [D]

Same adapter as OpenAI with base URL `https://api.x.ai/v1`, and these differences:

- Text only in v1. xAI accepts files only by public URL or by uploading to its Files API [D]; uploading a confidential manuscript to a file store is not worth it. `supportsNativePDF = false`.
- `store: false` always (default is true, stored 30 days [D]).
- Streaming is "data-only server-sent events … terminated by `data: [DONE]`" [D]. The event schema is not spelled out in the pages fetched. **[A]** it matches OpenAI's (`type: "response.output_text.delta"`). The shared parser therefore also accepts Chat-Completions-shaped chunks (`choices[0].delta.content`), and treats `[DONE]` as `.finished(.endOfTurn, nil)` if no completion event came first.
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
- Stream (JSON `event_type`): `step.delta` with `delta.type == "text"` → `.textDelta(delta.text)`; other delta types (`thought_signature`, `thought_summary`, …) ignored; `interaction.completed` → `.finished(.endOfTurn, usage)` from `interaction.usage.total_input_tokens/total_output_tokens`; `error` → throw from `error.code`; unknown events ignored [D: "handle unknown events"].
- Limits: 50 MB per file, 1,000 pages per PDF [D]. App cap: 30 MB.
- Models: `GET /v1/models?pageSize=1000` (follow `nextPageToken`); `name` minus the `models/` prefix, `displayName`, `inputTokenLimit`, `outputTokenLimit` [D]. Hide names containing `embedding`, `tts`, `image`, `live`, `transcribe`, `omni`, `banana`, `robotics`, `veo`, `lyria` (same "Show all" toggle).
- **[A]** If `POST /v1/interactions` answers 404 with code `not_found` (not `model_not_found`), retry once on `/v1beta/interactions` and remember that for the session.

#### 5.4.5 Ollama [V]

```
POST {base}/api/chat          base default http://127.0.0.1:11434
{ "model": "<name>", "stream": true, "keep_alive": "10m",
  "options": { "num_ctx": <contextWindow>, "num_predict": <maxOutputTokens>, "temperature": 0.2 },
  "messages": [ { "role": "system", "content": "<system>" }, { "role": "user", "content": "<all text parts joined by blank lines>" } ] }
```

- Body is NDJSON: each line `{"message":{"role":"assistant","content":"…"},"done":false}` → `.textDelta(content)` when non-empty (`message.thinking` is ignored); the last line has `"done":true`, `done_reason` (`stop` → `.endOfTurn`, `length` → `.maxTokens`), `prompt_eval_count`, `eval_count` → `.finished`. A line `{"error":"…"}` → throw `.server(status: 500, message:)` [V].
- **`num_ctx` must be set on every request.** Ollama otherwise allocates a default context by available memory (4k below 24 GiB VRAM, 32k up to 48 GiB [D]) and silently truncates longer prompts. The engine supplies `request.contextWindow` (§6.4).
- If `prompt_eval_count + eval_count >= num_ctx - 16` the adapter emits `.status("context window full; input may have been truncated")` before `.finished`.
- `availability()`: `GET /api/version` with a 2 s timeout → `.ready("Ollama <version>")`; connection refused → `.needsSetup("Ollama is not running", hint: "Start the Ollama app or run `ollama serve`.")`.
- Models: `GET /api/tags` → `models[].name`, `details.context_length`, `capabilities` [V on 0.40.17]. If `context_length` is absent, `POST /api/show {"model": name}` and read `model_info["<general.architecture>.context_length"]` [V]. Models whose `capabilities` lack `"completion"` are hidden.
- `.pdf` parts are a programming error for this provider: throw `.invalidRequest`.
- Installed here: `gemma4:e4b` (context 131,072), `gemma4:26b` (262,144), `phi4` (16,384), `gemma:2b` (8,192), `phi` (2,048); 24 GiB RAM [V].

### 5.5 Error mapping

| Condition | Anthropic | OpenAI / xAI | Gemini | Ollama | `LLMError` |
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
| server fault | 500, 504 | 500 | `api_error`, `deadline_exceeded`, `aborted` | 500, in-stream `error` | `.server` |
| transport | `URLError` except `.cancelled` | same | same | connection refused → `.notConfigured("Ollama is not running")` | `.network` |
| task cancelled | | | | | `.cancelled` |

### 5.6 CLI providers (`CLIProviders`)

Subscription access means running the vendor's own, unmodified CLI in its documented non-interactive mode, as the user who installed and signed in to it. The app never reads, copies or stores a vendor's OAuth token and never performs a login flow; when a CLI is not signed in, the settings pane shows the command to run in Terminal.

#### 5.6.1 Finding and validating the binary

```swift
struct CLISpec {                      // one constant per CLI
    let name: String                  // "claude"
    let candidates: [String]          // absolute paths or globs, ~ expanded, in priority order
    let versionArguments: [String]    // ["--version"]
    let environmentOverride: String   // "REFEREE_CLI_PATH_CLAUDE": tests and power users
}
actor BinaryResolver {
    func resolve(_ spec: CLISpec, explicitPath: String?) async -> Result<ResolvedBinary, LLMError>
}
struct ResolvedBinary { let path: String; let version: String }
```

Order: (1) `ProviderSettings.executablePath`; (2) the environment override; (3) `spec.candidates`; (4) `command -v <name>` run in a login shell. The first candidate that exists, is executable and **answers its version command within 20 s with exit code 0** wins; the result is cached with the file's modification date and revalidated when that changes.

| CLI | Candidates, in order | Recommended install [D] |
|---|---|---|
| `claude` | `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, newest of `~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude` (also `~/.vscode-insiders/…`, `~/.cursor/…`) | `curl -fsSL https://claude.ai/install.sh \| bash` → `~/.local/bin/claude` |
| `codex` | `~/.local/bin/codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` | `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` → `~/.local/bin/codex` |
| `agy` | `~/.local/bin/agy`, `/opt/homebrew/bin/agy`, `/usr/local/bin/agy` | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` → `~/.local/bin/agy` |
| `grok` | `~/.local/bin/grok`, `~/.grok/bin/grok`, `/opt/homebrew/bin/grok`, `/usr/local/bin/grok` | `curl -fsSL https://x.ai/cli/install.sh \| bash` |

Why validation with a timeout is mandatory: on this machine `/opt/homebrew/bin/codex` exists but its native binary fails code-signature validation and the launch hung indefinitely [V]. The VS Code extension's bundled `claude` (2.1.330) and the ChatGPT app's bundled `codex` (0.167.0-alpha.3.2) are the only working copies here [V], which is why those two locations are candidates.

#### 5.6.2 Environment and working directory

An app launched from Finder has a minimal `PATH`. The child environment is built from scratch:

- `PATH` = output of `/bin/zsh -l -c 'printf %s "$PATH"'` run once with a 5 s timeout (0.12 s here [V]; non-interactive, so `.zshrc` is not read and nothing can prompt), followed by `~/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` for anything missing. npm-installed CLIs are `#!/usr/bin/env node` scripts and need this.
- Copied from the app's environment when present: `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `TMPDIR`, `SHELL`, `SSH_AUTH_SOCK`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CONFIG_HOME`, `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`. Added: `TERM=dumb`, `NO_COLOR=1`.
- **Never copied**, so that the subscription login is what authenticates: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_PROFILE`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `GOOGLE_GEMINI_BASE_URL`, `XAI_API_KEY`. (Claude Code uses an `ANTHROPIC_API_KEY` in the environment ahead of the subscription login in `-p` mode [D].)
- Working directory: a new empty directory `<TMPDIR>/referee-cli-<uuid>` (mode 0700), deleted when the run ends. The agent inside the CLI has nothing to read or edit.
- stdin is always a pipe that the runner closes; stdout and stderr are pipes. Never a TTY, never inherited.

#### 5.6.3 Process runner

```swift
struct CLIInvocation {
    var executable: String
    var arguments: [String]
    var stdin: Data
    var workingDirectory: URL
    var environment: [String: String]
    var firstOutputTimeout: Duration = .seconds(300)   // spawn → first stdout byte
    var idleTimeout: Duration = .seconds(300)          // between stdout lines
    var totalTimeout: Duration = .seconds(3600)
}
enum CLIOutput { case line(String); case exit(code: Int32, stderrTail: String) }   // stderrTail: last 4 KB
struct CLIRunner { func run(_ invocation: CLIInvocation) -> AsyncThrowingStream<CLIOutput, Error> }
```

- `Foundation.Process`. stdin is written from a separate task and then closed (a 1 MB prompt must not deadlock against a full stdout pipe). stdout is read with `FileHandle.bytes` through `LineSplitter`. stderr is drained continuously into a 64 KB ring buffer.
- Timeouts throw `LLMError.cliTimeout(phase: "start" | "idle" | "total")`.
- Cancellation or timeout: `SIGINT`, wait 2 s, `SIGTERM`, wait 3 s, `SIGKILL`; then remove the working directory. (Claude Code ends the turn on SIGINT and exits 143 on SIGTERM [D].)
- Spawn failure → `.cliLaunchFailed`. Non-zero exit without a parsed result → `.cliExited(code, stderrTail)` after the adapter has had a chance to classify stderr (auth and quota patterns below).
- stderr text may contain fragments of the prompt; it is shown to the user in the error banner but never logged.
- `ProviderSettings.extraArguments` are appended to the default argument list of that CLI. An element that starts with `!` is not passed; instead it removes the default argument equal to the rest of the element (for example `!--sandbox`). This is the user's escape hatch when a CLI renames or drops a flag.

Prompt delivery: CLIs without a system-prompt option get `system` and the user parts joined as

```
<<SYSTEM INSTRUCTIONS>>
{system}
<<END SYSTEM INSTRUCTIONS>>

{user text}
```

#### 5.6.4 Per-CLI invocation and output

Timeouts (first output / idle, seconds): `claude-cli` 300 / 300; `codex-cli` 300 / 900 (its answer may arrive in one piece); `antigravity-cli` 300 / 600; `grok-cli` 900 / 900 (plain output: nothing is printed while the model thinks). Total 3,600 for all.

`ProviderDescriptor.maxPromptBytes`: `claude-cli` 9,000,000 (stdin is capped at 10 MB [D]); `codex-cli` and `antigravity-cli` 4,000,000 (our own cap); `grok-cli` 240,000 (argument); `nil` for HTTP providers.

**Claude Code** — flags verified against `claude --help` 2.1.330 and the CLI reference [V][D]; no prompt was sent.

```
claude -p "The complete task is in the piped input. Follow it exactly."
  --safe-mode --tools "" --disallowedTools "mcp__*" --strict-mcp-config --disable-slash-commands
  --no-session-persistence --permission-prompts none
  --system-prompt-file <workdir>/system.txt
  --output-format stream-json --verbose --include-partial-messages
  [--model <alias or id>]  [extraArguments…]
stdin: the user text (cap 10 MB [D])
```

- `--safe-mode` disables CLAUDE.md, skills, plugins, hooks, MCP servers and memory but keeps normal authentication. **Do not use `--bare`**: bare mode never reads the subscription login [D].
- `--tools ""` removes all built-in tools; `--no-session-persistence` keeps the manuscript out of `~/.claude` transcripts.
- stdout is JSON Lines. `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}}` → `.textDelta`. `{"type":"system","subtype":"api_retry",…}` → `.status("retrying (attempt n)")`. `{"type":"result","subtype":…,"is_error":bool,"result":"…","api_error_status":n?,"usage":{…}}` is the last line: `is_error == false` → `.finished(.endOfTurn, usage)`; otherwise classify `result` text and `api_error_status`: contains "Not logged in", "Failed to authenticate", "Login expired", "/login" → `.auth`; contains "hit your" and "limit" → `.quotaExhausted(result)`; 429 → `.rateLimited`; 529 → `.overloaded`; else `.server(status, result)`. If no text deltas were seen but `result` succeeded, emit `result` as one delta (older versions without partial messages).
- `availability()`: `claude auth status` prints JSON and exits 0 when logged in, 1 when not [D]; fields seen here: `loggedIn`, `authMethod` ("claude.ai" for a subscription), `subscriptionType`, `loginExpiresAt`, plus account identifiers that the app must ignore [V]. `authMethod` other than `claude.ai`/`oauth_token` → `.needsSetup("Claude Code is signed in with an API key, not a subscription", hint: "Run `claude` and use /login")`.
- Models: `[default, opus, sonnet, haiku, fable]` as `ModelInfo` with `contextWindow: nil`.

**Codex** — flags verified against `codex exec --help` 0.167.0-alpha.3.2 and the docs [V][D]; no prompt was sent.

```
codex exec - --json --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules
  --sandbox read-only -C <workdir>
  -c web_search="disabled" -c features.shell_tool=false -c history.persistence="none"
  [-m <model>]  [extraArguments…]
stdin: system and user text in the inline form above ("-" = read the whole prompt from stdin [V])
```

- `--ephemeral` and `history.persistence="none"` keep the manuscript out of `~/.codex` session files. `web_search` defaults to `"cached"`, so it is disabled explicitly [D]. No system-prompt flag is used: replacing Codex's built-in instructions has been rejected by the ChatGPT-plan back end in the past, so the instructions go in the prompt **[A]**.
- `--ignore-user-config` skips `~/.codex/config.toml` (and with it the user's MCP servers); "auth still uses `CODEX_HOME`" [V help text]. If a user keeps Codex credentials in the keyring through that config and login is not detected, they add `!--ignore-user-config` to this provider's extra arguments (see the removal rule in §5.6.3).
- stdout is JSON Lines: `thread.started`, `turn.started`, `item.started` / `item.updated` / `item.completed` with `item: {id, type, text?}`, `turn.completed {usage: {input_tokens, output_tokens}}`, `turn.failed {error: {message}}`, `error {message}` [D + source]. For items with `type == "agent_message"`, `text` is treated as cumulative per `item.id`: emit the suffix beyond what was already emitted for that id (if the new text does not extend the old, emit it whole on a new line). Other item types are ignored. `turn.completed` → `.finished(.endOfTurn, usage)`. `turn.failed` / `error` → classify `message`: "401", "Unauthorized", "login", "logged in" → `.auth`; "usage limit", "quota" → `.quotaExhausted`; "rate limit", "429" → `.rateLimited`; else `.server(500, message)`. Whether `item.updated` carries partial text is unverified, hence "message" granularity in the roster.
- `availability()`: `codex login status` exits 0 when credentials exist and prints "Logged in using ChatGPT" for a plan login [V]. Any other first line → `.needsSetup("Codex is not signed in with ChatGPT", hint: "Run `codex login`")`.
- Models: `codex debug models` prints `{"models":[{"slug","display_name","context_window","visibility","priority",…}]}` [V]; keep `visibility == "list"`, sort by `priority`. On failure fall back to `codex debug models --bundled`.

**Antigravity** — from documentation only [D]; `agy` is not installed here.

```
agy --input-format stream-json --output-format stream-json --disable-slash-commands --sandbox --print-timeout 60m
  [--model <slug>]  [extraArguments…]
stdin: one line  {"event":"user","message":{"content":"<system and user text, inline form>"}}  then EOF
```

- The process exits after stdin closes and the turn completes [D].
- stdout is NDJSON: `{"event":"init",…}`; `{"event":"step_update","step_update":{"step_type":"agent_response","state":"ACTIVE"|"DONE","text_delta":"…"}}` → `.textDelta(text_delta)` for `agent_response` steps only; `{"event":"result","result":{"status":"SUCCESS"|"ERROR"|…,"response":"…","error":"…","usage":{"input_tokens","output_tokens"}}}` → `SUCCESS` → `.finished(.endOfTurn, usage)`; otherwise classify `error`: contains "authentication required" → `.auth` [D wording]; "quota", "limit" → `.quotaExhausted`; "not recognized as a known model" → `.modelNotFound`; else `.server(500, error)`.
- Since v1.5.7 print mode runs in `auto` mode when the user has not chosen one, which auto-approves edits inside the workspace and sandboxed commands [D]. The workspace is our empty temporary directory and `--sandbox` is on; other tool requests are soft-denied in print mode [D].
- `availability()`: `agy --version` only; the docs give no auth-status command, so the result is `.ready("installed; sign-in is checked on first use")`.
- Models: `agy models` prints lines of `slug`, two or more spaces, display name [D].

**Grok Build** — from documentation only [D]; experimental.

```
grok --no-auto-update -p "<user text>" --system-prompt-override "<system>" --output-format plain
  --cwd <workdir> --max-turns 1 --disable-web-search --no-subagents --no-memory --no-plan
  [-m <model>]  [extraArguments…]
stdin: closed
```

- The prompt travels as an argument, so `maxPromptBytes = 240_000` (macOS allows about 1 MB for arguments plus environment); the engine reads longer papers in parts (§6.4).
- `plain` output: every stdout chunk is a `.textDelta` (decode incrementally as UTF-8; do not wait for newlines); exit code 0 → `.finished(.endOfTurn, nil)`; non-zero → classify stderr ("login", "auth" → `.auth`, hint "Run `grok login`") else `.cliExited`.
- Local session history may be written under `~/.grok/` [D]; this is stated in the provider's `retentionNote`.
- Models: `grok models`, first whitespace-delimited token of each non-empty line **[A]**.

#### 5.6.5 Policy note for the Claude subscription route

Anthropic's Claude Code terms say OAuth sign-in is for "ordinary use of Claude Code and other native Anthropic applications", that developers must not "offer Claude.ai login into their own applications, or … route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users", and that nothing prevents "an end user from signing in to the unmodified Claude Code binary with their own Claude subscription" [D: legal-and-compliance]. Referee launches the unmodified binary the user installed and signed in to, on the user's own machine, for the user's own work, and touches no credentials. That is within those terms for personal use. If the app is ever given to other people, this provider must be reviewed against those terms first; it is one file plus one registry line, so it can be removed cleanly. The settings pane labels these providers "Use my installed <CLI>" and never "Sign in".

### 5.7 Retry and rate limits

Implemented once, in `LLMKit`, as a wrapper every HTTP provider's `stream` goes through:

- Retry only if **no text delta has been yielded yet**. After the first delta a failure is thrown to the engine, which keeps the partial result (§6.6).
- `.rateLimited(retryAfter: t)`: wait `min(t, 60)` s plus 0–1 s jitter when `t` is given; otherwise use the backoff below. `.overloaded`, `.server`, `.network`: backoff 2 s, 6 s, 18 s (each ±25%).
- At most 3 attempts in total. Before each wait, yield `.status("Retrying in N s (reason)")`.
- Never retried: `.auth`, `.notConfigured`, `.quotaExhausted`, `.contextTooLong`, `.invalidRequest`, `.modelNotFound`, `.refused`, `.cancelled`, `.malformedResponse`, all CLI errors (Claude Code retries internally and reports `api_retry` events).
- The app sends at most one request at a time per provider from the review lane and one from the reply lane; there is no fan-out, so client-side rate limiting beyond this is unnecessary.

### 5.8 Secrets

- `KeychainSecretStore` (`LLMKit`): one generic-password item (`kSecClassGenericPassword`, service `local.referee.app`, account `secrets-v1`) whose value is a UTF-8 JSON object mapping key names to secrets. Keys: `anthropic-api`, `openai-api`, `gemini-api`, `xai-api`, `openalex`, `semanticscholar`. One item rather than six because an ad-hoc-signed app gets a new code identity on every rebuild and macOS then asks once per item before releasing it **[A]**; `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` from a SwiftPM-built binary work without prompts for the binary that created the item [V].
- `EnvironmentSecretStore` (`Composition`) wraps it: `REFEREE_KEY_<KEY in upper case, non-alphanumerics as _>` (for example `REFEREE_KEY_ANTHROPIC_API`) wins over the Keychain. With `REFEREE_NO_KEYCHAIN=1`, `LiveDependencies` leaves the Keychain out altogether (environment keys over an empty in-memory store). `referee-cli` sets that for itself unless `--use-keychain` is given, and the snapshot mode and all tests set it, so automated runs never touch the Keychain or trigger its prompt.
- Keys are sent only to their own vendor's host, only in the header that vendor documents, and appear in no log, file, error message or snapshot. Settings shows "•••• stored" and offers Replace and Remove; it cannot display a stored key.

### 5.9 Mock provider (`TestSupport`)

```swift
public struct MockResponse: Sendable {
    public var text: String
    public var chunkSize: Int                 // characters per delta; default 7
    public var delayPerChunk: Duration        // default .zero
    public var failAfterChunks: Int?          // then throw `failure`
    public var failure: LLMError?
    public var stop: StopReason               // default .endOfTurn
}
public struct MockScript: Sendable {
    public var responses: [RequestPurpose: [MockResponse]]    // consumed in order per purpose; the last one repeats
    public static let sample: MockScript                       // built from Fixtures/llm/*.txt (Appendix D)
}
public final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    public init(id: ProviderID = "mock", script: MockScript = .sample, isLocal: Bool = true, supportsNativePDF: Bool = false)
    public var recordedRequests: [LLMRequest] { get }          // lock-protected
}
```

Deterministic: same script, same deltas, in the same order. `Composition` registers it when `REFEREE_ENABLE_MOCK=1`, in snapshot mode, and for `referee-cli --provider mock`.

---

## 6. Review engine

### 6.1 Surface

```swift
public final class ReviewEngine: ReviewEngineProtocol {       // target ReviewEngine; protocol in Appendix A.6
    public init(providers: any ProviderResolving,
                paperService: any PaperService,
                matcherFactory: @escaping @Sendable (PaperText) -> any QuoteMatching,
                renderer: any PaperRendering)
}
```

Jobs: `plan`, `review`, `discuss`, `ask`, `generateReport`, `reviseVoice`, `lint`. Each LLM job returns a cold stream of events, records a `RunRecord`, and obeys cancellation.

### 6.2 How the paper reaches the model

Two modes. **PDF mode** sends the original file; the provider extracts text and renders page images itself, so the model sees equations, tables and figures. **Text mode** sends text extracted locally with page markers. PDF mode is preferred when available because referee work depends on tables and mathematics; text mode is the universal fallback and the only mode for local models and CLIs.

`sendsPDF` is true iff all hold: `providerSettings.inputMode != .text`; `descriptor.supportsNativePDF`; the chosen `ModelInfo.supportsPDFInput != false`; file ≤ 30 MB; page count within the provider limit (Anthropic 600, or 100 when the context window is under 1,000,000; Gemini 1,000; OpenAI no page limit) [D]; `pages × pdfTokensPerPage ≤ inputBudget` (below). If `inputMode == .pdf` but a condition fails, the engine uses text mode and emits a `.notice` saying why. If the paper has no text layer and PDF mode is unavailable, the review cannot run: `plan` returns the warning "This PDF has no text layer; choose a provider that accepts PDF files."

The PDF always travels inline (base64) in the request. No vendor's file-upload API is used (Anthropic Files, OpenAI `file_id`, Gemini Files, xAI Files): inline data covers the 30 MB cap, and an uploaded copy of a confidential manuscript would stay on the vendor's side until deleted.

Automatic fallback: in PDF mode, a `.contextTooLong`, or an `.invalidRequest` whose message mentions "pdf", "file", "document" or "image", restarts the job once in text mode with a `.notice`.

Text mode content is `PaperRendering.render` output:

```
[[page 1]]
Information Aggregation in Sequential
Markets: A Fixture
…
[[page 2]]
…
```

One marker line per PDF page (1-based index of the page in the file, not the printed page label), then that page's body lines, one PDF line per text line, with margin line numbers, running headers and footers, page numbers and watermarks removed (§7.2). No de-hyphenation and no paragraph reflow: the matcher ignores whitespace and hyphens, and untouched lines keep quotes verbatim.

### 6.3 Prompt assembly

Texts are in Appendix B. `PromptSet` fields are user-editable; the **format specification is a constant in code**, appended by the engine, so editing the rubric cannot break parsing.

| Job | `system` | User turn parts, in order |
|---|---|---|
| review, one pass | `reviewSystem` + rubric block + `FORMAT_REVIEW` | paper (`.pdf` or `.text`), `.cacheBoundary`, task text (`TASK_REVIEW` + reviewer notes + titles of existing comments) |
| review, part *i* of *n* | same | text of the part, task text (`TASK_PART` with notes so far) |
| review, whole-paper pass | same | task text (`TASK_WHOLE` with final notes and titles so far) |
| discuss | `discussionSystem` + `FORMAT_REVISION` | paper context, `.cacheBoundary`, the comment, the transcript, the new message |
| ask | `questionSystem` | paper context, `.cacheBoundary`, the selected passage with its location label, the transcript, the question |
| report | `reportSystem` | paper context, `.cacheBoundary`, venue and notes, approved comments, `reportTemplate` |
| voice revision | `voiceRevisionSystem` | the report Markdown, the lint findings |

The rubric block lists enabled `RubricCategory` entries as `- <id>: <name>. <guidance>` and tells the model to use exactly those ids in `category:`.

"Paper context" for discuss, ask and report: the same content as a one-pass review (PDF or full text) when that fits within 60% of the input budget; otherwise `session.paperDigest` (if a review in parts produced one) followed by the rendered text of the anchor's page and its two neighbours.

### 6.4 Planning: one pass or in parts

Constants (in `ReviewEngine/Planning.swift`):

```
charsPerToken            = 3.0      // deliberately low: over-estimates tokens for English prose with mathematics
promptOverheadTokens     = 3_000    // system prompt, rubric, format, task
cliOverheadTokens        = 30_000   // a coding CLI's own instructions (agy reports about 10k input tokens for a one-line prompt [D])
safetyTokens             = 1_024
unknownContextWindow     = 128_000
ollamaDefaultContextCap  = 16_384   // raise with ProviderSettings.contextWindowOverride
pdfTokensPerPage         = ["anthropic-api": 4_500, "openai-api": 3_500, "gemini-api": 1_500]
outputReserve            = review 16_000, reply 4_000, report 8_000
notesBudgetChars         = 2_400
```

```
context      = settings.contextWindowOverride ?? model.contextWindow ?? (CLI: 200_000, grok-cli: 128_000, else unknownContextWindow)
if provider is ollama:   context = min(context, settings.contextWindowOverride ?? ollamaDefaultContextCap)
                         reserve = min(4_096, context / 4)          // replaces outputReserve
inputBudget  = context − reserve − promptOverheadTokens − safetyTokens − (isCLI ? cliOverheadTokens : 0)
if inputBudget < 1_500 → the job fails before sending: "This model's context window is too small."
textFits     = paperChars / charsPerToken ≤ inputBudget  &&  paperUTF8Bytes + 20_000 ≤ (descriptor.maxPromptBytes ?? .max)
```

- `sendsPDF` or `textFits` → one request.
- Otherwise read in parts: `renderer.chunkPageRanges(paper, maxCharacters: min(inputBudget × charsPerToken, (maxPromptBytes ?? .max) − 20_000) − notesBudgetChars)`, pages never split; `requestCount = parts + 1` (the whole-paper pass).
- For Ollama every request sets `LLMRequest.contextWindow = context` and `maxOutputTokens = reserve`.
- `plan(paper:context:)` returns exactly this decision as a `SendPlan` (mode, request count, estimated input tokens, destination, warnings) with no network use; the consent prompt and the toolbar indicator show it.

Reading in parts is a sequential refine: each part's request carries the model's own running notes from the earlier parts and asks for (a) comments on this part in the normal format and (b) updated notes after a line `@@NOTES` (at most 350 words, including up to eight verbatim quotes with page numbers). The final whole-paper pass gets the notes and the titles so far and asks only for comments that need the whole paper; its quotes come from the notes. The final notes are emitted as `ReviewEvent.digest` and stored by the model as `session.paperDigest`.

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
FIELD    = ^\s*[*_`]{0,3}(kind|type|severity|category|page|pages|quote|title|body|comment|suggestion|fix|resolution)[*_`]{0,3}\s*[:：]\s*(.*)$
```

Rules:

1. `MARK(COMMENT)` closes any open block and opens a new draft. `MARK(END)` closes the open block. `MARK(DONE)` closes it and sets `sawDone`. `MARK(NOTES)` closes it; all following text up to `MARK(DONE)` or end of stream is the notes.
2. Inside a block, before `body` has started, a `FIELD` line sets that field (synonyms: `type`, `severity` → kind; `pages` → page; `comment` → body; `fix`, `resolution` → suggestion). Any other line continues the field that was set last (so a wrapped quote or title still works).
3. After `body` has started, only a `FIELD` line for suggestion (or its synonyms) or a `MARK` line ends it; every other line, including ones that look like fields, is body text. The same holds inside `suggestion`.
4. Outside a block, lines are ignored (but kept in `rawText`).
5. Value clean-up when the block closes: `kind` → first of `major`, `minor`, `question`, `strength` contained in the lower-cased value (`critical` → major, `query` → question, `praise`/`positive` → strength; none → minor); `page` → first integer in the value; `quote` → trimmed, surrounding straight or curly quotation marks and backticks removed; `category` → lower-cased slug, unknown → `other`; `title` → one line, Markdown emphasis stripped, at most 120 characters; empty title → first ten words of the body. A block with neither title nor body is dropped.
6. Nothing in the parser depends on chunk boundaries: feeding the same text one byte at a time or in one piece gives the same closed blocks (tested both ways).

Fallbacks when the stream ends and `sawAnyBlock` is false:

1. **JSON.** Strip code fences; find the first balanced `[`…`]` or `{`…`}`; if `JSONSerialization` parses it into an object, an array of objects, or an object with one array value, map each object's keys case-insensitively with the same synonyms.
2. **Unstructured.** One comment: kind minor, category `other`, title "Unstructured model output", body = the raw text (first 6,000 characters), no anchor; plus `.notice("The model ignored the output format; its answer is shown as a single comment.")`.

Continuation: if the stream ends with `StopReason.maxTokens`, or without `@@DONE` while the last block was left open, the engine sends a follow-up request with the same paper context and the task "Your previous answer was cut off. Comments already written (do not repeat them): <titles>. Continue with the remaining comments in the same format and end with @@DONE." At most two continuations per request. A stream that ends normally without `@@DONE` and with its last block closed is treated as complete.

### 6.6 Running a review

```
emit .started(run)                         (RunRecord with status .running)
emit .phase(.preparing)                    resolve provider and model, plan, build the matcher
for each request (one pass, or parts then the whole-paper pass):
    emit .phase(.reading(part:of:)) or .phase(.wholePaperPass)
    for each LLMEvent:
        .textDelta → parser.feed → .draft(DraftComment) for started/updated drafts
                     on blockClosed: validate, anchor (§6.7), fill rects, drop duplicates → .comment(c, replacesDraft:)
        .status    → .notice (deduplicated)
        .finished  → continuation check (§6.5)
emit .digest(notes)                        only after a review read in parts
emit .finished(run)                        status .completed, usage summed, requestCount set
```

- A new `ReviewComment` has `origin: .ai(runID:)`, `status: .pending`, `includeInReport: true`.
- Running a review again keeps every existing comment and adds only new ones: the titles of existing non-rejected comments go into the task text and the duplicate rule below applies. The Comments header's ⋯ menu offers "Clear undecided AI comments" (`deletePendingAIComments()`) for a clean second run.
- Duplicate rule: drop a comment if an existing non-rejected comment (from this run or passed in `existing`) has an anchor overlapping at least 60% of its span characters **and** at least 60% of its title words in common, or the same normalised quote and title.
- Any `LLMError`: close the parser (`finish()`), emit what it yields, then `.finished(run)` with `.failed(error.userMessage)`. The stream itself ends normally; the caller reads the failure from the run status. Comments already emitted stay.
- Cancellation: `.finished(run)` with `.cancelled`; open drafts are discarded.
- `StopReason.refusal`: `.notice("The model declined to continue.")`, run completes with what exists.

### 6.7 Anchoring a quote to the PDF

Implemented by `PaperText.QuoteMatcher` (pure; built once per paper) and `PDFBridge` (geometry). The clean text it works on comes from §7.2, where margin line numbers and boilerplate have already been removed.

**What PDFKit's text looks like** on a line-numbered, double-spaced, watermarked manuscript [V, fixture `ay_nolinks.pdf`]:

```
HerdinghasbeenstudiedextensivelysinceBanerjee[1992]andBikhchandani9
et al. [1992]. Later work extends the framework to markets [Avery and Zem-10
sky, 1998, Smith and Sørensen, 2000]. As shown by Acemoglu et al. [2011],11
…
Table 2 is 0.91 with a confidence interval that crosses one, which is difficult to14
reconcile with the claim of a robust effect. We define the office-specific iden-15
```

So: margin numbers are glued to the **end** of each line with no space; tightly justified lines lose all their spaces; words are hyphenated across lines with the line number in between; a watermark line appears mid-page. A matcher that only collapses whitespace finds none of the test quotes [V]. The design below finds all of them [V, prototype on the same data].

**Folding.** `fold(scalar)` maps one Unicode scalar to zero or more: expand ligatures (ﬀ ﬁ ﬂ ﬃ ﬄ ﬅ ﬆ → ff fi fl ffi ffl st st); map µ (U+00B5) to μ; canonically decompose and drop combining marks; keep the result only if it is a letter or a digit, lower-cased. Everything else (whitespace, hyphens and dashes of every kind, quotation marks, punctuation, symbols, soft hyphens, zero-width characters) maps to nothing. "office-specific", "office- specific" and "officespecific" fold to the same string; so do "identi-\nfication" and "identification".

**Index** (built in `QuoteMatcher.init(paper:)`):

- `stream`: the folded characters of every `.body` line's `contentRange` text, pages in order and lines in the reading order of `PageText.lines` (§7.2 step 2), with parallel arrays giving for each folded unit its `(pageIndex, utf16Offset)` in the page string and the index of its line. Line breaks contribute nothing.
- `tokens`: maximal runs of folded letters/digits with their `(pageIndex, range)`; a token that ends a line whose last non-space character is a hyphen is merged with the first token of the next line.

**`locate(quote:pageHint:)`**, first success wins:

1. If the quote contains `…`, `...` or `[...]`, split on it; treat the first and last pieces (each at least 12 folded units) as head and tail in step 3.
2. *Exact.* `q = fold(quote)`. If `q.count ≥ 12` (or `≥ 6` when a `pageHint` is given, searching only that page and its neighbours), find all occurrences of `q` in `stream`. One → match. Several → the one on the hinted page, else the one nearest to it, else the first. Confidence `.exact`.
3. *Head and tail.* If `q.count > 160` (or step 1 produced pieces): find the first 80 and last 80 units separately; choose the nearest pair with tail after head and distance at most `3 × q.count`; the match runs from head start to tail end. Confidence `.fuzzy(score: 0.9)`.
4. *Fuzzy on tokens.* Needs at least 6 quote tokens (shorter quotes are too easy to match by accident). Take the five quote tokens that are rarest in the document (length ≥ 4, not all digits, present in the document). For each occurrence of each (at most 200 candidates), form the window of document tokens that would contain the whole quote with a slack of 3 tokens before and `3 + n/4` after; score = LCS(quote tokens, window tokens) / n. Best score ≥ 0.75 with at least 5 matched tokens → match trimmed to the first and last matched tokens. Confidence `.fuzzy(score:)`. Prefer candidates on the hinted page when scores tie within 0.05.
5. Otherwise `nil`.

The match is an interval of `stream`; converting through the parallel arrays gives `spans`: **one per text line touched**, from the first to the last matched character on that line. (Per line, not per page: on a re-ordered multi-column page two consecutive lines of the text are not neighbours in the page string, and a span must never cover text between them.)

**From spans to highlight rectangles** — `PaperService.rects(for:in:)`: for each span, for each `TextLine` of that page whose `contentRange` intersects the span (normally exactly one; a span from a user selection may cover several), take the intersection and ask PDFKit for `page.selection(for: intersection)?.bounds(for: page)`. One rectangle per line. Never pass a range that includes margin-number characters: the bounds then stretch across the page (x from −2 to 495 in the fixture) [V]; sub-ranges that exclude them are exact (x = 110.9) [V].

**Label** — `locationLabel(for:)`: `p. N` with N = page index + 1; if the paper has margin line numbers, append `, line a` or `, lines a–b` from the `marginNumber` of the first and last lines touched.

**In the engine**: `matcher.locate(quote, pageHint: page − 1)` → `Anchor(confidence: .exact/.fuzzy)` with rects and label. No match but a valid page → `.pageOnly` (label "p. N", no highlight; the comment sorts at the top of that page). No match and no usable page → `.none` (the card shows "Passage not found" and a button "Attach to selection"; such comments sort last). The quote text is always kept and shown, so the reviewer can find the passage by eye or with ⌘F.

Two-column pages: PDFKit's own order is not reliable (§7.2 step 2), so the matcher and the renderer use the reading order established by `PaperTextBuilder`. Comments are displayed in that order too: by page, then by the position of the first span's line in `PageText.lines`.

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

`ask(paper:conversation:question:context:)`. A new conversation's `anchor` is built from the `SelectionInfo` (quote = selected text, spans and rects from the selection, confidence `.exact`). Request: paper context; "Selected passage (p. 4, lines 14–16): «…»"; transcript; the question. The reply is plain text. `ReviewSessionModel.convertReplyToComment` turns an answer into a pending user-origin comment anchored to the same selection. A question asked with no selection has `anchor == nil` and is about the whole paper.

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

**Export** (`AppCore.ReportExporter`):

| Format | How |
|---|---|
| Markdown `.md` | the text as is |
| Plain text `.txt` and "Copy as plain text" | headings become their text on a line of their own followed by a blank line; emphasis markers removed; numbered lists kept; for pasting into a journal's web form |
| Word `.docx` | `NSAttributedString` built from the Markdown (headings as bold larger runs, paragraphs, numbered items), written with `documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]` [V: produces a valid zip] |
| PDF `.pdf` | the same attributed string laid out in an off-screen `NSTextView` (US Letter or A4 by locale, 1-inch margins) and written with `dataWithPDF(inside:)`, paginated with `NSPrintOperation` to a file when longer than one page |

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

**Do not use** `page.characterBounds(at:)` or `page.characterIndex(at:)`: on this OS their indices do not correspond to `page.string` (bounds for index *i* belonged to a character about 50 positions away; `characterIndex` returned 304 for a character at 320) [V].

**Raw extraction** (`PDFBridge.RawExtractor`, per page): `string = page.string ?? ""`; `whole = page.selection(for: NSRange(0, utf16Length))`; `lines = whole.selectionsByLine()`; each line's range is `range(at: 0, on: page)` with trailing newline characters trimmed, its text the substring, its bounds `bounds(for: page)`. The line list matches the newline-separated lines of the string one to one [V]. Links: every annotation of type `Link` → `RawLink` with target from `action` (GoTo → page index and point; URL → string), falling back to `destination` / `url`; `text` = `page.selection(for: annotation.bounds)?.string ?? ""`. Outline: preorder walk of `document.outlineRoot`.

`load` fails with `PaperError.encrypted` when `isLocked` (no password UI in v1), `.empty` for zero pages, `.notAPDF` when the data does not start with `%PDF-` within the first 1,024 bytes.

**Cleaning** (`PaperText.PaperTextBuilder.build(from:)`, pure):

1. **Margin line numbers.** For each page and each of two modes, collect candidates per non-empty line. *Trailing* mode: the run of digits at the end of the line; every suffix of that run of length 1–4 not starting with 0 is a candidate (so "…199213" can yield 13). *Leading* mode: a run of 1–4 digits at the start of the line that is followed by whitespace, a letter or the end of the line (not by "." or ")", which would be a list or reference number). Walk the lines in order keeping, for each value v, the longest chain ending at v where each step goes from v−1 on an earlier line to v on a later line; a line contributes at most one value to a chain. A page *qualifies* in a mode if its best chain has at least max(5, 40% of its non-empty lines) members. The document has margin numbers in a mode if at least half of its pages with ten or more lines qualify; if both modes do, take the one with more chained lines. For every chained line: `marginNumber = v`, `contentRange` = the line range without those digits and adjacent whitespace; a line left empty becomes `.marginNumberOnly`. On the fixture this finds 1–16, 17–31 and 32–40 on the three pages, and finds nothing on the four fixtures without line numbers or on a real 15-page arXiv paper [V, prototype].
2. **Reading order on multi-column pages.** PDFKit emits text blocks in an order of its own. On page 2 of both two-column fixtures it gives the top of the left column, then the entire right column (including the reference list), then the rest of the left column [V]. So `PageText.lines` is put into reading order (each line keeps its range in the page string). Per page, skipped when the page has fewer than 20 non-empty lines or the document has margin line numbers (their line bounds are unreliable): try gutters `g` every 2 pt between 35% and 65% of the page width. For each, a line is *left* if it ends before `g + 6`, *right* if it starts after `g − 6`, *crossing* otherwise. A gutter is admissible if each side has at least 8 lines and at least 60% of each side's lines are wider than a quarter of the page (this rejects figure pages full of short labels). Take the admissible gutter with the fewest crossing lines (ties: nearest the centre); if none, or more than 25% of lines cross, the page is single-column and keeps PDFKit's order. Otherwise walk the lines from top to bottom (by top edge): a *spanning* line (crossing, or shorter than 40 pt and centred within 10 pt of the gutter, such as a page number) first flushes the pending left lines then the pending right lines, then is emitted itself; other lines are queued left or right; flush at the end. On the fixtures this fixes page 2, leaves page 1 and all single-column fixtures untouched, and changes nothing in a 15-page single-column arXiv paper with figure pages [V, prototype].
3. **Page numbers.** The first or last non-empty line of a page that, after step 1, is only a number (or "Page N", "N of M", "– N –") and whose number increases by one from the previous page → `.pageNumber`.
4. **Repeated lines.** Normalise each line (lower-case, digits → `#`, whitespace collapsed). In documents of three or more pages, a normalised line found on at least max(3, 60% of pages) is `.runningHeader` or `.runningFooter` when it is among the first two or last two lines of its page, otherwise `.watermark`.
5. **Journal-system boilerplate**, by pattern regardless of frequency → `.watermark`: lines matching `^(for peer review( only)?|confidential|manuscript (id|number)\b.*|click here to (download|view|access).*|powered by editorial manager.*|.*scholarone.*|electronic copy available at.*)$` (case-insensitive).
6. Whitespace-only lines → `.empty`; everything else `.body`.
7. `hasTextLayer` = at least 200 letters in the whole document. `titleGuess` = among the first 15 body lines of page 1, the consecutive lines with the tallest bounds (joined with a space); `nil` when bounds are missing.

`PDFPaperService` then replaces `bounds` for every line whose `contentRange` differs from `range` with `page.selection(for: contentRange)?.bounds(for: page)`.

The builder is a heuristic over real-world variety that the synthetic fixtures cannot cover (journal systems stamp numbers in other ways). Two safety nets exist: the fuzzy matcher (§6.7 step 4) tolerates leftover digits, and Settings ▸ Advanced has "Remove margin line numbers: Automatic / Never".

### 7.3 Highlights without touching the file

Highlights are `PDFAnnotation(bounds:forType: .highlight, withProperties: nil)` objects added to pages of the **display** document, one per `PageRect`, with `userName = "referee:" + commentID.uuidString` for hit-testing (`page.annotation(at:)` returns it [V]). They exist only in memory; the document has no URL and is never written (§4.6). PDFKit draws, scrolls and zooms them [V, snapshot]. Reason for annotations over a custom overlay: correct drawing and hit-testing for free, verified to work.

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

```swift
// RefereeUI/Reader — the only public surface other UI code uses
@MainActor public final class ReaderController {
    public init(model: ReviewSessionModel)
    public let pdfView: RefereePDFView                   // created once, lives as long as the window
    public func attach()                                 // loads the display document when model.paper appears; starts observing
}
public struct ReaderPane: View { public init(controller: ReaderController) }       // PDF + overlays + find bar
public struct NavigatorPane: View { public init(controller: ReaderController) }    // thumbnails / outline / references
public struct ReferenceViewerView: View { public init(fileURL: URL, title: String) }   // read-only viewer for cited papers
```

- `RefereePDFView: PDFView` overrides `mouseDown(with:)`: convert the point to page space (`page(for:nearest:)`, `convert(_:to:)`); if it hits one of our highlight annotations → `model.readerClickedComment(id)` and continue to `super` (so selection still works); else if it lies in a citation rectangle → `model.readerClickedCitation(mentionID:)` and **do not** call `super` (this also stops PDFKit from jumping to the bibliography for hyperref links); else `super.mouseDown`. `mouseMoved` sets the pointing-hand cursor over citation rectangles.
- Configuration: `autoScales = true`, `displayMode = .singlePageContinuous`, `displaysPageBreaks = true`, `backgroundColor` from `Theme`.
- Selection: observe `PDFViewSelectionChanged`; build `SelectionInfo` with `PDFBridge.SelectionInfoBuilder.make(from: PDFSelection, document:)` (per page: `selectionsByLine()`, union of `range(at:on:)`, bounds per line); debounce 150 ms; call `model.readerSelectionChanged`.
- Commands: observe `model.readerCommand` (serial number changes): `.reveal(rects, flash)` → `go(to: rect, on: page)` with the first rectangle about one third from the top, then if `flash` add a temporary underline annotation for 0.8 s; `.goToPage`; `.find(query)`; `.clearSelection`.
- Overlays are SwiftUI views layered over the PDF inside `ReaderPane`, positioned by converting page rectangles with `pdfView.convert(_:from:)`; they are dismissed on scroll, page change, Esc, or a click elsewhere. Overlays rather than `NSPopover` because a popover is a separate window and the snapshot mode captures only the main window (§10.1).

### 7.5 Navigation both ways

- Comment → passage: selecting a card (click, J/K, Return) calls `model.revealSelectedCommentInPDF()`, which issues `.reveal(rects: anchor.rects, flash: true)`; page-only anchors issue `.goToPage`.
- Passage → comment: clicking a highlight selects its card and scrolls the sidebar to it (`ScrollViewReader`), switching the sidebar to the Comments tab. Where highlights overlap, the smallest rectangle wins.
- Window title: set `window.title` and `window.representedURL` directly; `.navigationTitle` does not reach a window created around `NSHostingController` [V].

### 7.6 Search, thumbnails, outline, zoom

- Find (⌘F): a find bar over the top of `ReaderPane`. `PDFDocument.findString(_:withOptions: [.caseInsensitive])` on the display document for up to 5,000 results; `pdfView.highlightedSelections` shows all, `setCurrentSelection(_:animate:)` + `go(to:)` step through with ⌘G / ⇧⌘G; the bar shows "3 of 17".
- Navigator (left column), three tabs: **Pages** (`PDFThumbnailView` bound to `controller.pdfView`, wrapped in `NSViewRepresentable`), **Outline** (`model.paper.outline` as an indented list; hidden when empty), **References** (the parsed reference list with a status icon per entry; click → citation card for that entry).
- Zoom: ⌘+ / ⌘− / ⌘0 (`zoomIn`, `zoomOut`, `autoScales = true`); pinch works natively.

### 7.7 Several documents

- Each manuscript opens in its own window with its own `ReviewSessionModel`, `ReaderController` and display document. Opening a file whose hash is already open brings that window forward.
- A cited paper opens in a **reference viewer window**: `ReferenceViewerView` (PDF, thumbnails, find, zoom; no sidebar, no AI, no session). Its title is the reference's title. Viewer windows of one manuscript are grouped as tabs of one window (`tabbingIdentifier = "refs-" + sha256`), so cited papers do not scatter across the screen. v1 stretch goal, only if time allows: "Quote in chat" on a selection in the viewer, which pastes the selected text into the manuscript's chat input.

---

## 8. Citations

### 8.1 Model

`CitationIndex` (Appendix A.3): `style`, `entries: [BibEntry]` (the reference list, each with raw text, spans, first-line bounds and parsed surnames / year / title / DOI / arXiv id / URL), `mentions: [CitationMention]` (each in-text citation with its click rectangles and candidate entry ids). Built once per document by `CitationKit.CitationIndexer.buildIndex(paper:links:)`, pure, from the clean text and the raw link annotations. Both detection paths below produce the same types and are merged.

`CitationKit` works on a **flow text** it builds per page run: body lines joined by single spaces, except that a line ending in a hyphen followed by a line starting with a lower-case letter is joined without the hyphen ("Bikhchan-" + "dani" → "Bikhchandani", as in fixture `ay_round_nolinks` [V]); a parallel array maps every flow character back to `(pageIndex, utf16Offset)`.

### 8.2 Finding and splitting the reference list

1. **Heading.** The last body line in the document that matches `^\s*(\d+\.?\s+)?(references|bibliography|works cited|literature cited|reference list)\s*$` (case-insensitive) and is followed by at least three entry-like items. None → an empty index with `style = .unknown`; the app then intercepts no clicks, and PDFKit's own handling of link annotations still works.
2. **End.** The first of: (a) a body line that is short (at most 40 characters) and starts with `appendix`, `online appendix`, `supplementary`, `supplemental`, `tables`, `figures`, `footnotes` or a letter-numbered appendix heading (`^[A-Z](\.\d+)?\s+[A-Z]`); (b) on a page where the list is running, a line whose left edge is more than 40 pt to the left of the leftmost list line on that page, i.e. the text has jumped back to an earlier column (a guard for pages whose reading order was not repaired); (c) the end of the document.
3. **Style.** Numeric if at least 60% of candidate entry starts match `^\s*(\[\d{1,3}\]|\d{1,3}\.)\s`; otherwise author–year.
4. **Entries, numeric.** A new entry starts at each line matching that pattern with the next number in sequence; `label` is the number.
5. **Entries, author–year.** Hanging indent first: let x0 be the 10th percentile of `bounds.x` over the list's lines on a page; a line with `x ≤ x0 + 2` starts an entry, a line indented more continues it. If fewer than 20% of lines are indented (block style), fall back to text: a line starts an entry if the previous entry's text ends with `.` or `)` or a URL/DOI, and this line begins with an upper-case letter and contains a year `(1[89]|20)\d{2}[a-z]?` within its first 200 characters (looking ahead into the next two lines).
6. `rawText` = the entry's lines joined as flow text; `spans` per page; `firstLineBounds` from the first line.

### 8.3 Parsing an entry

Heuristic and deliberately modest; it only has to support matching and lookup.

- `doi`: `10\.\d{4,9}/[^\s"<>]+` with trailing `.,;)` removed, lower-cased; also from a URL link annotation inside the entry (`RawLink` whose rectangle lies inside one of the entry's line bounds and whose URL contains `doi.org/`).
- `arxivID`: `arXiv:\s*(\d{4}\.\d{4,5})(v\d+)?` or `arxiv\.org/abs/([\w.\-/]+)`.
- `url`: first `https?://\S+` (text or link annotation).
- `year`, `yearSuffix`: the first `(1[89]|20)\d{2}` (plus optional letter) in the entry; for numeric lists, the last one.
- `authorSurnames`: the text before the year (author–year) or before the title's opening (numeric: up to the first period that follows a lower-case word or closing quotation mark). Split on `,`, `;`, ` and `, ` & `. For each piece: "Surname, I." or "Surname, Given" → the part before the comma; "I. Surname" / "Given Surname" → the last word, joined with a preceding particle (`van`, `von`, `de`, `del`, `della`, `di`, `da`, `la`, `le`, `ten`, `ter`, `der`, `den`). "et al." ends the list.
- `title`: author–year → the sentence after the year; numeric → the sentence after the authors. Stripped of quotation marks.

### 8.4 In-text citations from text patterns

Runs over body flow text before the reference list (and after its end, for appendices).

**Numeric.** `\[(\d{1,3}(\s*[-–]\s*\d{1,3})?(\s*[,;]\s*\d{1,3}(\s*[-–]\s*\d{1,3})?)*)\]`. Accept only if the list is numeric and every number is at most the entry count. **One mention per number or range inside the brackets**, so that each number is its own click target, as it is in a hyperref PDF: "[1, 5, 3]" gives three mentions; a range gives one mention whose `entryIDs` are expanded ("[3–5]" → 3, 4, 5).

**Author–year, driven by the reference list.** Precision comes from only accepting names that are in the list:

1. Build a dictionary from each entry's folded first-author surname (case and diacritics folded; "Sørensen" also as "Sorensen") to its entries.
2. Find every year token `(1[89]|20)\d{2}[a-z]?` in the flow text.
3. For each year, look left up to 120 characters, not crossing a sentence end (`. ` followed by an upper-case letter, except after "al." or a single initial) or an opening bracket's matching boundary. Tokenise that window right to left and accept only: surname words (upper-case initial, may contain hyphens, apostrophes, particles), `and`, `&`, `et al.`, commas, an opening `(` or `[` directly before the year, possessive `'s`, and the lead-ins `see`, `e.g.,`, `cf.`, `also`. Stop at the first other token.
4. The left-most accepted surname must be in the dictionary. Candidates = entries with that first-author surname and that year (and suffix, if any). Disambiguate by the second surname if present in the mention, and by "et al." (three or more authors). Exactly one → `entryIDs = [id]`; several → all of them; none → skip (not a citation of this paper's list).
5. Several years after one author list ("Smith (2019, 2021)", "Smith et al. (2020a,b)") produce one mention per year sharing the author text.
6. Inside a parenthesis with several citations ("(Avery and Zemsky, 1998; Smith and Sørensen, 2000)") each item is its own mention; its span covers that item's authors and year only. For a narrative citation ("Acemoglu et al. (2011)") the span covers the authors through the closing bracket.

Both bracket styles and both separators must work: "(Smith et al., 2020; Lee, 2021)" and "[Avery and Zemsky, 1998, Smith and Sørensen, 2000]" (natbib's default) [V: both appear in fixtures].

Text-pattern mentions come back with `spans` and empty `rects`; `ReviewSessionModel` fills `rects` with `PaperService.rects(for:in:)` right after indexing.

### 8.5 In-text citations from link annotations

For every `RawLink` with `.internalDestination(pageIndex, x, y)` whose destination lies inside the reference list's page range:

- Target entry: among the entries whose first line is on the destination page, keep those whose `firstLineBounds.x` is within 60 pt of the destination `x` (this separates the columns of a two-column list; if none qualifies, keep all). Of those, choose the entry whose first-line top edge (`y + height`) is the highest one that is still at or below `y + 4`; if no top edge is below the destination, choose the nearest. Reason: a hyperref destination sits at, or a few points above, the first line of its entry. `selectionForLine(at:)` at the destination found the right line for a single-spaced numeric list but returned nothing for a double-spaced author–year list, so a point lookup is not enough [V].
- Mention rectangle = the annotation bounds; text = the link's text.
- Merge links with the same target entry that are adjacent on one line (gap under 12 pt) or on consecutive lines (natbib links author and year separately and splits links at line breaks: "Avery and Zem-" / "sky" / "1998" [V]) into one mention with several rectangles.
- Internal links whose destination is outside the reference list (equations, sections, footnotes) are ignored; PDFKit handles them as usual because they are not in our hit-test set.

**Merge of the two paths.** `buildIndex` has no geometry for text mentions, so it merges by text position: a link mention is matched to the text mention on the same page whose text contains the link's text (folded) and whose entry candidates include the link's target; the pair becomes one mention with the link's target and rectangles and the text mention's `text` and `spans`. Unmatched mentions of either kind are kept. Result sorted by page and position (text offset when known, else top-to-bottom, left-to-right of the first rectangle), ids reassigned 0…n−1.

### 8.6 Clicking a citation

`RefereePDFView.mouseDown` hit-tests the mention rectangles of the clicked page (expanded by 2 pt). A hit calls `model.readerClickedCitation(mentionID:)`, which sets `citationLookup = .resolving` and starts resolution of each candidate entry; the reader shows the **citation card** overlay next to the mention:

- header: the mention text; for each candidate entry: the raw reference text (up to four lines), then resolved title, authors, year, venue when available, and a badge "Open access" when a PDF URL was found;
- buttons: **Open PDF** (enabled when `openAccessPDFURL != nil`; downloads then opens the reference viewer), **Open in Browser** (`landingURL`, else the DOI URL, else the entry's URL), **Copy DOI**, **Search Scholar** (always available; `ReferenceResolving.searchURL(for:)`), **Show in References** (selects the entry in the navigator);
- states: resolving (spinner beside the raw text, which is shown immediately), resolved, not found ("No match found" with Search Scholar), failed ("Lookup failed: <reason>", Retry).

A mention with no candidate entries shows its text and Search Scholar only.

### 8.7 Resolving a reference (`ScholarKit.ReferenceResolver`)

Lookups happen **only when the user clicks** (default). Reason: each lookup discloses one reference string of a confidential manuscript to a third party; a click is a deliberate act. Settings ▸ References offers "Look up all references when a document opens" (off).

Order, stopping at the first step that yields a DOI, arXiv id or PDF URL and passes validation:

| Step | Condition | Request | Notes |
|---|---|---|---|
| 0 | cache hit | — | `resolver-cache.json`, key = SHA-256 of the folded `rawText`; resolved entries kept 180 days, `notFound` 30 days, `failed` not cached |
| 1 | entry has an arXiv id | none | `landingURL = https://arxiv.org/abs/<id>`, `openAccessPDFURL = https://arxiv.org/pdf/<id>`; confidence 1.0 |
| 2 | entry has a DOI | `GET https://api.openalex.org/works/doi:<doi>?select=id,doi,title,publication_year,authorships,primary_location,open_access,best_oa_location` | free, no key, no email [V: `x-ratelimit-cost-usd: 0`]; PDF from `best_oa_location.pdf_url`, else `open_access.oa_url` when it ends in `.pdf`; landing `https://doi.org/<doi>`; 404 → keep the DOI, no metadata |
| 3 | no identifier | `GET https://api.crossref.org/works?query.bibliographic=<rawText, first 300 chars>&rows=3&select=DOI,title,author,issued,container-title,score,type` (+ `&mailto=<address>` only if the user set one) | validate (below); on success continue with step 2 for open-access data [V: returns the right DOI for a test reference] |
| 4 | still nothing, Semantic Scholar enabled | `GET https://api.semanticscholar.org/graph/v1/paper/search/match?query=<title>&fields=title,year,authors,externalIds,openAccessPdf,url` (header `x-api-key` if the user stored one) | 404 "Title match not found" → next step [D]; gives DOI/arXiv id and sometimes a PDF URL; catches working papers and preprints Crossref lacks |
| 5 | still nothing, OpenAlex search enabled | `GET https://api.openalex.org/works?search=<title>&per_page=3&select=…` (+ `api_key=` if stored) | costs search credits: about 100 per day without a key, 1,000 with a free key [D] |
| 6 | still nothing and the entry mentions "arXiv" or "working paper" or "mimeo" | `GET https://export.arxiv.org/api/query?search_query=ti:"<title>"&max_results=3` | Atom XML (parse with `XMLParser`): entry `id` gives the arXiv id, `title`, `author/name`, `published` |

Where open-access PDF links come from: OpenAlex (`best_oa_location.pdf_url`, `open_access.oa_url`), Semantic Scholar (`openAccessPdf.url`) and arXiv (by construction from the id). Crossref is used for identification only. Unpaywall (`api.unpaywall.org/v2/{doi}?email=…`) is not called: it requires an email address and now serves the same open-access data as OpenAlex [D].

**Validation of a candidate** (steps 3–6): folded first-author surname equals the entry's; year within ±1 of the entry's (preprint versus publication); at least 60% of the candidate title's words (length ≥ 4) occur in the entry's `rawText`. Confidence = 0.5 + 0.5 × that title fraction. A candidate that fails is discarded; if all fail → `notFound`.

**Politeness and limits** (one token bucket per host inside the actor):

| Host | Limit used | Source |
|---|---|---|
| api.crossref.org | 1 request/s, 1 at a time; with `mailto` 3 requests/s, 3 at a time | public pool: `x-rate-limit-limit: 1`, `x-rate-limit-interval: 1s`, `x-concurrency-limit: 1` [V]; polite pool [D] |
| api.openalex.org | 5 requests/s; stop searching for the day on a 429 with reason `daily_budget` | 10/s without a key [D] |
| api.semanticscholar.org | 1 request/s | unauthenticated calls share one pool and are often throttled; a key gives 1 request/s [D] |
| export.arxiv.org | 1 request every 3 s, 1 at a time | arXiv API terms [D] |

A 429 or 5xx is retried once after `Retry-After` (or 2 s); a second failure makes the step return `failed`, and the pipeline continues with the next step. `User-Agent: Referee/<version>`; the address is appended as `(mailto:<address>)` only when the user set one. No request carries anything but the reference text or identifier.

**Fetching the PDF** (`fetchPDF`): `https` only (an `http` URL is offered as "Open in Browser" instead); follow redirects; stop at 100 MB; accept only if the body starts with `%PDF-`; store as `~/Library/Caches/Referee/papers/<sha256(url)>.pdf`; evict least-recently-used files beyond the cache limit. arXiv's terms allow retrieving e-prints for personal use and forbid re-serving them [D]; the cache is local and private.

**Manual fallback**: `searchURL(for:)` = `https://scholar.google.com/scholar?q=<percent-encoded title, or first 200 characters of rawText>`, opened in the default browser. No API involved.

---

## 9. UI/UX specification (first version; a designer will refine it)

### 9.1 App shell

AppKit owns the lifecycle and the windows; every window's content is SwiftUI in an `NSHostingController`. Reason: the snapshot mode that lets agents see the UI was verified with exactly this construction, including a three-column layout with a trailing inspector, toolbar items and PDF highlights [V]; and opening files from Finder, several document windows, viewer tabs and explicit window titles are direct in AppKit.

```swift
// RefereeUI/Shell
public enum AppMain {
    /// Parses arguments. `--ui-snapshot <dir> …` runs the snapshot mode (§10.1) and exits; otherwise starts the app.
    /// `environmentOverrides` are merged over the process environment (the snapshot mode sets REFEREE_HOME and REFEREE_ENABLE_MOCK).
    /// Not @MainActor: top-level code in main.swift is not main-actor-isolated in Swift 5 mode, so a @MainActor entry point
    /// does not compile there [V]. The body is `MainActor.assumeIsolated { start(makeDependencies) }`.
    public static func run(makeDependencies: @escaping @Sendable (_ environmentOverrides: [String: String]) async -> AppDependencies) -> Never
}
```

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
// RefereeUI/Common/UIActions.swift (Wave 0, frozen)
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

The shell sets real closures with `.environment(\.uiActions, …)` on every window's root view; the defaults do nothing, which is what the snapshot mode uses. Everything else flows through `ReviewSessionModel`.

- `AppDelegate`: builds the main menu; `application(_:open:)` forwards file URLs to `WindowManager.openReview(url:)`; `applicationShouldTerminateAfterLastWindowClosed` → false; on terminate, flushes every model's pending save.
- `WindowManager` (main actor): `openReview(url:)` (one window per document hash; brings an existing one forward), `openReferenceViewer(fileURL:title:groupID:)`, `showSettings()`, `showWelcome()`. Review windows: 1280 × 800 default, 1000 × 640 minimum, `styleMask` titled, closable, resizable, miniaturizable, `fullSizeContentView`; frame autosaved per document hash.
- **Main menu** (built in code with `NSMenu`; SwiftUI `.commands` is not used):

| Menu | Items (key) |
|---|---|
| Referee | About, Settings… (⌘,), Hide, Quit (⌘Q) |
| File | Open… (⌘O), Open Recent ▸, Close (⌘W), Export Report… (⇧⌘E), Delete Review Data… |
| Edit | Undo, Redo, Cut, Copy, Paste, Select All, Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G) — standard selectors so text fields work |
| Review | Run Review (⌘R), Cancel (⌘.), Generate Report (⇧⌘R), Approve, Reject, Discuss, Edit, Next Comment, Previous Comment, New Comment (the single-key shortcuts of §9.4 are shown as hints but handled by the key monitor) |
| View | Comments (⌘1), Chat (⌘2), Report (⌘3), Toggle Navigator (⌃⌘S), Toggle Sidebar (⌥⌘0), Zoom In (⌘+), Zoom Out (⌘−), Fit Width (⌘0) |
| Window | standard |
| Help | Referee Help (opens README) |

- **Welcome window** (shown at launch when no document is opened): "Open PDF…" button, drop target, list of recent reviews from `SessionStoring.listSessions()` (title, file name, date, "12 comments · 3 pending"), and a provider status line ("AI: Local · gemma4:e4b" or "No AI provider set up — Open Settings").

### 9.2 Review window

```
┌ toolbar ───────────────────────────────────────────────────────────────────────────────────────────────┐
│ [navigator]   <file name>      ( ⌂ Local · gemma4:e4b ▾ )                 [▶ Review] [Report] [sidebar] │
├──────────────┬───────────────────────────────────────────────┬─────────────────────────────────────────┤
│ Pages|Outline│                                               │  Comments | Chat | Report               │
│ |References  │   PDF  (highlights; overlays: find bar,       │  filter chips · "12 of 31 decided"      │
│              │   selection bar, citation card, banner,       │  comment cards …                        │
│ thumbnails   │   consent card)                               │                                         │
│ 160–240 pt   │   flexible, min 480 pt                        │  320–520 pt, ideal 380                  │
└──────────────┴───────────────────────────────────────────────┴─────────────────────────────────────────┘
```

Structure (verified to render in a hosted window [V]):

```swift
public struct ReviewWindowView: View {          // RefereeUI/Shell
    public init(model: ReviewSessionModel, reader: ReaderController)
    // NavigationSplitView { NavigatorPane(controller: reader) } detail: { ReaderPane(controller: reader) }
    //   .inspector(isPresented: $showSidebar) { ReviewSidebar(model: model).inspectorColumnWidth(min: 320, ideal: 380, max: 520) }
    //   .toolbar { … }      .overlay { ConsentCard / Banner }
}
public struct ReviewSidebar: View { public init(model: ReviewSessionModel) }     // RefereeUI/Sidebar
```

Toolbar, left to right: navigator toggle; the **destination indicator** (principal position, §9.7); Review button (label "Review", becomes "Cancel" with a spinner and the phase text "Reading part 2 of 5…" while running; disabled with a tooltip when no provider is ready); Report button (switches the sidebar to Report); sidebar toggle.

### 9.3 Sidebar: Comments tab

Header: filter chips `All · Pending · Approved · Rejected · Major · Minor · Questions`; a thin progress bar with "12 of 31 decided"; a "+" button (new own comment). List: `ScrollView` + `LazyVStack` of cards in document order (page, then text offset; page-only anchors first on their page; unanchored last). While a review streams, drafts appear at the end under "Writing…" and move into place when finished.

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

A local `NSEvent` key-down monitor installed by the review window controller handles these keys **only when** the window is key and the first responder is not a text-editing view (`NSTextView`, field editor). The mapping is a pure function, unit-tested:

```swift
enum TriageIntent: Equatable { case next, previous, approve, reject, resetStatus, discuss, edit, reveal, newComment, setKind(CommentKind), dismiss }
enum TriageKeymap { static func intent(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> TriageIntent? }
```

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

Intent → model call: `next` → `selectNextComment(pendingOnly: false)`; `previous` → `selectPreviousComment()`; `approve` / `reject` / `resetStatus` → `setStatus(_:for: selectedCommentID)`; `discuss` → `openThreadCommentID = selectedCommentID`; `edit` → `editingCommentID = selectedCommentID`; `reveal` → `revealSelectedCommentInPDF()`; `newComment` → `beginComposingComment()`; `setKind(k)` → `setKind(k, for:)`; `dismiss` → `dismissTransientUI()`. The sidebar reacts to those properties (expands the thread and focuses its input, shows the editor, shows the composing card).

Modified keys go through the menu: ⌘R, ⌘., ⇧⌘R, ⌘F, ⌘G, ⌘1–3, ⌘+, ⌘−, ⌘0. In any text input ⌘↩ sends or saves.

### 9.5 Selection bar, Chat tab, citation card

- **Selection bar**: appears 6 pt above the first line of a selection of at least three characters, 200 ms after it settles: `[Ask AI] [Comment] [Copy]  [▾ quick questions]`. Ask AI expands the bar into a text field (placeholder "Ask about this passage…", Return sends); the question and its streaming answer then live in the Chat tab, which opens. Quick questions come from `PromptSet.quickQuestions` and send immediately. Comment calls `model.beginComposingComment()` and switches the sidebar to Comments.
- **Chat tab**: conversations newest first. Each: the quoted passage (click → reveal), location label, messages, streaming answer, a follow-up field, and per answer "Make comment ▾" (kind) and Copy. At the bottom of the tab a field "Ask about the paper…" starts a conversation with no selection. Empty state: "Select text in the PDF and choose Ask AI."
- **Citation card**: §8.6. Anchored below the mention; 360 pt wide.

### 9.6 Settings window (780 × 560, tabs)

- **Providers.** Three groups: *API key* (Anthropic, OpenAI, Gemini, xAI), *Subscription through an installed CLI* (Claude Code, Codex, Antigravity, Grok Build [experimental]), *Local* (Ollama). Each row: enable switch; status from `availability()` with a coloured dot (green ready, yellow needs setup with the hint, red unavailable); for API providers a secure key field that only accepts input ("•••• stored" when set, Replace, Remove); model picker filled from `listModels()` with a refresh button, "Show all" where a filter applies, and "Custom…" for a typed id; for CLIs the detected path and version, a path override field, the install command with a Copy button and the sign-in command to run in Terminal. Advanced disclosure per provider: base URL, context window override, max output tokens, input mode (Automatic / Text / PDF), extra arguments (CLI) or extra body JSON (API). "Send test prompt" button with the note "uses a few tokens". Below the list: default provider pickers for Review, Chat and Report (Chat and Report default to "Same as Review").
- **Prompts.** Editors for `reviewSystem`, `discussionSystem`, `questionSystem`, `reportSystem`, `reportTemplate`, `voiceRevisionSystem`; the rubric table (enabled, id, name, guidance; add, remove); the quick questions list; the fixed output-format text shown read-only with the note "The app parses this format; it cannot be edited"; "Restore defaults".
- **Privacy.** "Local only" switch; "Ask before the first send of each document" (on); the data folder path with Reveal in Finder; "Delete all review data…"; a plain-language summary of §12.3.
- **References.** "Look up references only when I click them" (on); Crossref contact email (empty; note: "optional; gives faster lookups"); OpenAlex key and Semantic Scholar key (secure fields, optional); switches for Semantic Scholar and OpenAlex search; PDF cache size and Clear.
- **Advanced.** "Remove margin line numbers from extracted text: Automatic / Never" (applies to documents opened afterwards); "Advance to the next comment after a decision"; "Show highlights of rejected comments".

### 9.7 The destination indicator and consent

The indicator is always visible in the toolbar and is the only place the destination is chosen per document.

| Situation | Icon and text | Tint |
|---|---|---|
| local provider | laptop, "Local · gemma4:e4b" | green |
| API provider | cloud, "Anthropic API · <model>" | orange |
| CLI provider | terminal, "Claude Code · default" | orange |
| nothing ready | slashed circle, "No AI provider" (click opens Settings) | grey |
| Local-only is on and a remote provider is selected | lock, "Remote blocked (Local only)" | red |

Clicking it opens a menu-style overlay: the enabled providers (choose one; stored as `session.preferredProvider`); the current `SendPlan` in words ("A review will send the PDF file in 1 request, about 135,000 tokens, to api.anthropic.com"); the provider's `retentionNote`; the "Local only" switch; "Privacy settings…".

**Consent card** (in-window overlay that blocks the window until answered), shown before the first request of any kind that would send this document to a non-local provider not yet in `session.consents`, when "Ask before the first send" is on:

```
Send this manuscript to Anthropic?
The PDF file (2.1 MB, 34 pages) will be sent to api.anthropic.com in 1 request (about 135,000 tokens).
Later questions, discussions and the report will send it again to the same provider.
Check the journal's policy on AI tools before sending a manuscript under review.
[ ] Ask again next time                                   [Cancel]  [Send]
```

Send records a `ConsentRecord` (unless "Ask again" is ticked) and starts the job; Cancel leaves everything untouched. With "Local only" on, non-local providers cannot be selected and any job addressed to one fails immediately with a banner.

`retentionNote` texts: Anthropic API "Sent to Anthropic under your API account's data terms."; OpenAI "Sent with store=false; not kept for retrieval by the API."; Gemini "Sent with store=false."; xAI "Sent with store=false."; Ollama "Processed on this Mac; nothing is sent." (or "Sent to <host> on your network." for a non-loopback base URL); Claude Code "Runs through your Claude Code login; no session transcript is saved."; Codex "Runs through your ChatGPT plan; session files are not kept."; Antigravity "Runs through your Google account; the CLI may keep a local conversation record."; Grok Build "Runs through your xAI account; the CLI may keep local session history in ~/.grok."

### 9.8 Report tab

Top: Target venue field (`meta.targetVenue`), "Notes for the report" field (`meta.reviewerNotes`), the count "8 approved comments (3 major, 4 minor, 1 question)". Buttons: Generate (or Regenerate), Revise voice, Versions ▾, Export ▾ (Copy as plain text, Copy Markdown, Markdown file…, Text file…, Word document…, PDF…). Body: a plain-text Markdown editor (13-pt system font, comfortable line spacing) with a Preview toggle (rendered with `AttributedString(markdown:)`). Under it a collapsible "Style check" list of lint findings (rule, message; clicking selects the range) and the recommendation picker (Accept / Minor revision / Major revision / Reject) prefilled from the text, with the consistency warning when it disagrees with the concerns.

### 9.9 States

| Area | Empty | Loading / streaming | Error |
|---|---|---|---|
| Window, no document | welcome content inside the window | "Opening <file>…" with a progress indicator | "This file could not be opened: <reason>" and "Open another…" |
| PDF with no text layer | — | — | yellow banner: "This PDF has no text layer. Comments can be tied to pages only, and only providers that accept PDF files can review it." |
| Comments tab | "No comments yet. Run a review (⌘R) or add your own (N)." | drafts under "Writing…"; phase text in the toolbar | banner "Review stopped: <message>" with Retry; comments received so far stay |
| Comment thread | — | streaming reply bubble | inline error with Retry |
| Chat tab | hint text (§9.5) | streaming answer | inline error with Retry |
| Report tab | "Approve at least one comment, then generate the report." | text streams into the editor (read-only until finished) | banner with Retry; previous draft kept |
| Citation card | — | raw reference text + spinner | "No match found" / "Lookup failed" with Search Scholar and Retry |
| Provider row | "Not set up" + hint | "Checking…" | red dot + reason |
| Any job, provider missing or blocked | — | — | banner "Set up an AI provider" (Open Settings) or "Remote providers are blocked by Local only" |

Banners sit at the top of the PDF column, one at a time, dismissible; errors stay until dismissed, notices fade after 6 s.

### 9.10 Shared theme (`RefereeUI/Common/Theme.swift`, written in Wave 0, frozen)

Kind colours: major red, minor grey, question purple, strength teal. Status colours: pending yellow, approved green, rejected grey, own blue. Highlight colours and alphas as in §7.3. Card corner radius 8, card padding 10, list spacing 10, sidebar padding 10. Fonts: system; card title `.headline`, body `.callout`, quote `.callout.italic()`, metadata `.caption`. Light and dark appearance both supported through semantic colours.

---

## 10. Self-verification hooks

The building agents cannot see the screen and may lack screen-recording permission. These hooks are how they check their own work.

### 10.1 UI snapshot mode

```
Referee --ui-snapshot <outDir> [--scene <name>]… [--dark] [--size 1280x800]
```

Mechanism, verified end to end on this machine without any Screen Recording permission [V]:

1. `NSApplication.shared.setActivationPolicy(.accessory)`; create a fresh temporary directory, write a `settings.json` there whose review default is the `mock` provider, and build dependencies with the overrides `REFEREE_HOME=<that directory>`, `REFEREE_ENABLE_MOCK=1` and `REFEREE_NO_KEYCHAIN=1`. Then replace two members of the returned `AppDependencies` so that a snapshot run starts no process and makes no network request: `resolver = TestSupport.FakeResolver()` and `providers = ProviderRegistry(TestSupport.snapshotProviders)` (a local mock, a non-local mock for the consent scene, and one `StaticProvider` per real provider id with a scripted status and model list for the settings scenes). Nothing of the user's is read or written.
2. For each scene: create the window exactly as the app does (`NSWindow(contentViewController: NSHostingController(rootView: …))`), fixed content size, `window.appearance` forced to aqua (or dark aqua), `window.center()`, `orderFrontRegardless()`.
3. Run the scene's `prepare` closure (it drives the model through its public methods), then keep the main run loop turning for the scene's settle time (default 2.0 s; PDF pages render asynchronously).
4. Capture the app's own window: resolve `CGWindowListCreateImage` with `dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")` (the symbol is marked unavailable in the macOS 15+ Swift SDK), cast to `@convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?`, call with `(.null, 8 /* including window */, UInt32(window.windowNumber), 1 | 8 /* ignore framing, best resolution */)`.
5. Write `<outDir>/<scene>.png`; append one JSON line to stdout and to `<outDir>/manifest.jsonl`: `{"scene":"review-pending","file":"…","width":2560,"height":1600,"nonBlank":true}`. `nonBlank` is true when at least 2% of pixels differ from the top-left pixel by more than 8/255 in any channel.
6. Close the window; after the last scene exit 0 if every scene was captured and non-blank, else 1.

Things that do **not** work and must not be tried again: `NSView.cacheDisplay(in:to:)` and `CALayer.render(in:)` capture empty frames for SwiftUI and PDF content [V]. Known cosmetics: the window is drawn in its inactive look, and it is briefly visible on screen. Child windows (popovers, sheets) are not captured, which is why transient UI is built as in-window overlays (§7.4, §9.7).

```swift
// RefereeUI/Common/SnapshotScene.swift (Wave 0, frozen)
@MainActor public struct SnapshotContext {
    public let window: NSWindow
    public let model: ReviewSessionModel?         // review scenes
    public let reader: ReaderController?          // review scenes
    public let settings: SettingsModel?           // settings scenes
}
@MainActor public struct SnapshotScene {
    public enum Kind { case review, settings, welcome, referenceViewer }
    public var name: String
    public var kind: Kind
    public var fixturePDF: String?                // under Fixtures/pdf (review and referenceViewer scenes)
    public var fixtureSession: String?            // under Fixtures/sessions; copied into the temporary REFEREE_HOME before the PDF is opened
    public var settleSeconds: Double              // default 2.0
    public var prepare: @MainActor (SnapshotContext) async -> Void   // drive the models through their public API
}
// SnapshotRunner runs  ShellScenes.all + ReaderScenes.all + SidebarScenes.all ; each UI work package fills its own list
```

Required scenes:

| Scene | Owner | Shows |
|---|---|---|
| `welcome` | Shell | welcome window with two recent reviews |
| `review-empty` | Shell | `ay_round_nolinks.pdf` open, no comments, destination indicator "Local · mock" |
| `consent` | Shell | consent card for a non-local mock provider |
| `banner-error` | Shell | review failed mid-stream (mock failure), banner with Retry, two comments kept |
| `settings-providers`, `settings-prompts`, `settings-privacy` | Shell | settings panes; provider rows in each status |
| `reader-highlights` | Reader | `ay_nolinks.pdf` with the sample session: yellow, green and blue highlights on page 1, navigator on Pages |
| `reader-selection` | Reader | a programmatic selection with the selection bar |
| `reader-citation` | Reader | citation card open on "Acemoglu et al." with a resolved reference (fake resolver) |
| `reader-find` | Reader | find bar with "3 of 7" and highlighted matches |
| `reader-references` | Reader | navigator on References |
| `reference-viewer` | Reader | viewer window showing `num_twocol_links.pdf` |
| `sidebar-pending` | Sidebar | six comments, one selected, mixed kinds |
| `sidebar-streaming` | Sidebar | review paused mid-stream (mock with a long delay after N chunks): two finished cards, one draft |
| `sidebar-states` | Sidebar | approved, rejected, fuzzy, page-only and unanchored cards |
| `sidebar-discussion` | Sidebar | open thread with two messages and a proposed revision |
| `sidebar-editing` | Sidebar | a card in edit mode |
| `sidebar-chat` | Sidebar | Chat tab with one conversation |
| `sidebar-report` | Sidebar | Report tab with generated text and three lint findings |

How an agent uses it: run `scripts/snapshots.sh build/snapshots --scene <name>`, open the PNG with its file-reading tool, and compare against this section. An agent must look at every scene it owns before declaring its work package done, and list in `docs/contract-notes/<WP>.md` anything that looks wrong but is outside its files.

### 10.2 `referee-cli`

Same pipeline as the app, no UI. Hand-written argument parsing.

```
referee-cli providers [--json]                                   availability of every provider (no tokens spent)
referee-cli models --provider <id> [--json]
referee-cli dump-raw <pdf>                                       RawDocument JSON
referee-cli extract <pdf> [--pages A-B] [--stats]                the text a model would receive; --stats prints line-kind counts and margin-number ranges
referee-cli anchor <pdf> --quote <text> [--page N] [--json]      exit 0 found, 1 not found
referee-cli citations <pdf> [--json]                             style, entries, mentions
referee-cli resolve <pdf> --entry <n> [--json]                   network lookup of one reference
referee-cli plan <pdf> --provider <id> [--model <m>]             the SendPlan
referee-cli review <pdf> --provider <id> [--model <m>] [--mode auto|text|pdf] [--context <tokens>] [--json] [--save]
referee-cli ask <pdf> --provider <id> [--model <m>] --question <text> [--quote <text>]
referee-cli report <pdf> --provider <id> [--model <m>] [--approve-all]     uses the saved session (after `review --save`)
referee-cli lint <report.md>
global:  --home <dir>   (sets REFEREE_HOME; default: a temporary directory, so the CLI never touches the user's data unless asked)
         --use-keychain (read API keys from the Keychain as the app does; default: environment variables only)
```

- `review` prints each comment as it completes (`[major] p. 1, lines 13–14 (exact)  Title` then the body) and ends with one machine-readable line: `SUMMARY comments=7 anchored=6 pageOnly=1 unanchored=0 requests=1 status=completed seconds=41.2`. `--json` prints one JSON object per event instead.
- Keys come only from `REFEREE_KEY_*` environment variables (§5.8) unless `--use-keychain` is given. `--provider mock` works with no setup.
- Exit codes: 0 success; 1 job failed; 2 usage error; 3 provider not configured or not available.
- Consent prompts do not apply to the CLI; choosing a remote provider on the command line is the consent. It prints one line to stderr: `sending <text|PDF> to <destination>`.

### 10.3 Deterministic stand-ins

- `MockLLMProvider` (§5.9) for engines, the model, snapshots and the CLI; `StaticProvider` (descriptor, scripted `availability()` and `listModels()`, `stream` throws `.notConfigured`) and `snapshotProviders` for the snapshot mode.
- `StubURLProtocol` (`TestSupport`): register `(URLRequest) -> StubResponse?` handlers; a response has status, headers and a body delivered in chunks with optional delays, so stream parsers see realistic chunk boundaries; `StubURLProtocol.session()` returns a `URLSession` wired to it.
- Fake CLIs (`Tests/CLIProvidersTests/FakeCLI/claude`, `codex`, `agy`, `grok`): executable shell scripts selected through `REFEREE_CLI_PATH_<NAME>`. They answer `--version`, read stdin to the end, and print canned stream lines (Appendix D). `FAKE_MODE` selects `ok`, `auth`, `quota`, `garbage`, `hang` (sleep 600), `slow` (one line per second), `echo-bytes` (print the stdin byte count) and `print-env` (print the environment, for the scrubbing test).
- In-memory `SessionStoring`, `SettingsStoring`, `SecretStoring`; `FakePaperService`, `FakeQuoteMatcher` (exact substring on `PaperText`), `FakeResolver`, `ScriptedReviewEngine` (plays a list of events) for `AppCore` and UI tests.

### 10.4 End-to-end with a real local model

`scripts/e2e-ollama.sh [model]` (default `gemma4:e4b`): exits 3 if `http://127.0.0.1:11434/api/version` does not answer; builds `referee-cli`; runs `review Fixtures/pdf/ay_round_nolinks.pdf --provider ollama --model <model> --home <tmp> --save`; requires exit 0, `status=completed` and `comments>=1` in the SUMMARY line; prints `anchored=`. Then runs `ask … --question "Is the claim in the abstract supported?" --quote "The effect is statistically significant but economically small."` and requires non-empty output. A local model's content is not asserted, only that the pipeline completes. Zero cost; this is the one live test every integrator must run.

### 10.5 Debug transcript (off by default)

`REFEREE_DEBUG_DUMP=<dir>` makes `ReviewEngine` write each request's prompt and the raw model output to `<dir>/<timestamp>-<purpose>.txt`. This is the only way manuscript text can reach a file other than the session, it is never enabled by the app's UI, and the destination indicator shows a red "debug dump on" tag while it is set.

### 10.6 Environment variables

| Variable | Read by | Effect |
|---|---|---|
| `REFEREE_HOME` | `AppPaths` | data directory (settings, sessions, resolver cache; caches under `Caches/`) instead of the user's Library; tests, CLI and snapshots always set it |
| `REFEREE_KEY_<NAME>` | `EnvironmentSecretStore` | a secret that takes precedence over the Keychain, e.g. `REFEREE_KEY_ANTHROPIC_API`, `REFEREE_KEY_OPENAI_API`, `REFEREE_KEY_GEMINI_API`, `REFEREE_KEY_XAI_API` |
| `REFEREE_ENABLE_MOCK=1` | `LiveDependencies` | registers the mock provider |
| `REFEREE_CLI_PATH_CLAUDE`, `_CODEX`, `_AGY`, `_GROK` | `BinaryResolver` | explicit CLI binary (fake CLIs in tests) |
| `REFEREE_DEBUG_DUMP=<dir>` | `ReviewEngine` | writes prompts and raw model output there (§10.5) |
| `REFEREE_NO_KEYCHAIN=1` | `LiveDependencies`, tests | the Keychain is never read or written (secrets come from `REFEREE_KEY_*` only); the Keychain unit test is skipped |
| `REFEREE_LIVE_NET=1` | tests | enables tests that call the public reference services |
| `REFEREE_SIGN_IDENTITY`, `REFEREE_VERSION` | `scripts/bundle.sh` | signing identity (default ad hoc) and version string |

---

## 11. Work breakdown for parallel coding agents

### 11.1 Isolation: one git worktree per agent, in waves

**The hazard.** Agents building at once in one checkout fight over the `.build` lock, and one agent's half-written target breaks `swift build` and `swift test` for everyone.

**The procedure.**

1. **Wave 0** is one agent working alone in the repository root on `main`. It commits a package in which every target exists, compiles and passes smoke tests (real contracts, stub implementations).
2. For every later work package the coordinator creates a worktree on its own branch from the tip of `main`, for example `git worktree add ../Referee-worktrees/wp1-papertext -b wp/1-papertext main` (the Agent tool's worktree isolation does the same). The agent works only inside that directory, builds into that directory's own `.build`, and commits on its branch. It never pushes, never touches `main`, another worktree, or `git stash`.
3. At the end of a wave the integrator merges the branches into `main` (`git merge --no-ff wp/…`), runs the full test suite, and only then are the next wave's worktrees created from the new tip.

**Why this and not separate local packages per module.** A local path dependency is compiled from source by every package that uses it, so a half-written module still breaks its dependants, and each package would need its own manifest and test set-up. A worktree gives each agent a private copy of the sources *and* a private build directory: nothing an agent does can be seen by another until merge. One manifest stays the single description of the build.

**Why merges do not conflict.** Ownership of paths is disjoint (§11.2), shared code is frozen after Wave 0, and implementation targets do not import each other (§2.1).

**Consequences every agent must respect.**

- Your branch must build and pass `scripts/test.sh` on its own: other packages are still stubs in your worktree, and that is expected.
- Do not pass `--scratch-path` or `--build-path`; do not run `swift package clean`, `reset` or `update`.
- Frozen paths (below) are read-only. If a contract is wrong or missing something: implement what you need inside your own target (an extension, an internal helper), keep the public shape, and write the problem and your workaround in `docs/contract-notes/<WP>.md`. The integrator resolves these.
- Commit early and often on your branch; the last commit must have the acceptance commands passing. Put the commands you ran and their final lines in `docs/contract-notes/<WP>.md`.

### 11.2 Waves and ownership

| WP | Wave | Name | Owns (may create and edit) |
|---|---|---|---|
| 0 | 0 | Scaffold and contracts | everything at first; afterwards **frozen**: `Package.swift`, `Makefile`, `scripts/`, `.gitignore`, `Sources/RefereeCore/`, `Sources/TestSupport/`, `Sources/Composition/`, `Sources/Referee/`, `Sources/RefereeUI/Common/`, `Tests/RefereeCoreTests/`, `Fixtures/` |
| 1 | 1 | PaperText | `Sources/PaperText/`, `Tests/PaperTextTests/` |
| 2 | 1 | PDFBridge | `Sources/PDFBridge/`, `Tests/PDFBridgeTests/` |
| 3 | 1 | CitationKit | `Sources/CitationKit/`, `Tests/CitationKitTests/` |
| 4 | 1 | LLMKit (HTTP providers) | `Sources/LLMKit/`, `Tests/LLMKitTests/` |
| 5 | 1 | CLIProviders | `Sources/CLIProviders/`, `Tests/CLIProvidersTests/` |
| 6 | 1 | ReviewEngine | `Sources/ReviewEngine/`, `Tests/ReviewEngineTests/` |
| 7 | 1 | ScholarKit | `Sources/ScholarKit/`, `Tests/ScholarKitTests/` |
| 8 | 1 | AppCore and Persistence | `Sources/AppCore/`, `Sources/Persistence/`, `Tests/AppCoreTests/`, `Tests/PersistenceTests/` |
| 9 | 2 | Reader UI | `Sources/RefereeUI/Reader/`, `Tests/RefereeUITests/Reader/` |
| 10 | 2 | Sidebar UI | `Sources/RefereeUI/Sidebar/`, `Tests/RefereeUITests/Sidebar/` |
| 11 | 2 | Shell, settings, snapshots | `Sources/RefereeUI/Shell/`, `Tests/RefereeUITests/Shell/`, `Fixtures/sessions/` (additions only) |
| 12 | 2 | Command line and end-to-end | `Sources/referee-cli/`, `Tests/IntegrationTests/`, `scripts/e2e-ollama.sh`, `scripts/fetch-optional-fixtures.sh` |
| 13 | 3 | Integration | everything |

Every work package also owns `docs/contract-notes/<its number>-<name>.md`. Test data private to a target goes in `Tests/<Target>Tests/Fixtures/`.

Wave 1 has eight agents, Wave 2 four. Wave 2 starts only after Wave 1 is merged and green, because the UI is built against the real `ReviewSessionModel` and real engines.

### 11.3 Fixed public surface of each target

Wave 0 creates these exact declarations with stub bodies; owners fill them in and may add anything `internal`. `Composition` and other work packages rely on these names and signatures.

```swift
// PaperText
public struct PaperTextBuilder: PaperTextBuilding { public init(stripMarginLineNumbers: @escaping @Sendable () -> Bool = { true }) }
public struct QuoteMatcher: QuoteMatching { public init(paper: PaperText) }
public struct PaperRenderer: PaperRendering { public init() }

// PDFBridge
public actor PDFPaperService: PaperService { public init(builder: any PaperTextBuilding) }
public enum RawExtractor { public static func extract(from document: PDFDocument) -> RawDocument }
@MainActor public enum SelectionInfoBuilder { public static func make(from selection: PDFSelection, in document: PDFDocument) -> SelectionInfo? }

// CitationKit
public struct CitationIndexer: CitationIndexing { public init() }

// LLMKit
public enum LLMKitFactory { public static func makeProviders(environment: ProviderEnvironment) -> [any LLMProvider] }
        // ids, in order: anthropic-api, openai-api, gemini-api, xai-api, ollama
public final class KeychainSecretStore: SecretStoring { public init(service: String = "local.referee.app", account: String = "secrets-v1") }

// CLIProviders
public enum CLIProviderFactory { public static func makeProviders(environment: ProviderEnvironment) -> [any LLMProvider] }
        // ids, in order: claude-cli, codex-cli, antigravity-cli, grok-cli

// ReviewEngine
public final class ReviewEngine: ReviewEngineProtocol {
    public init(providers: any ProviderResolving, paperService: any PaperService,
                matcherFactory: @escaping @Sendable (PaperText) -> any QuoteMatching, renderer: any PaperRendering)
}

// ScholarKit
public actor ReferenceResolver: ReferenceResolving {
    public init(settings: @escaping @Sendable () -> ReferenceSettings, secrets: any SecretStoring,
                urlSession: URLSession, dataDirectory: URL, cacheDirectory: URL)
}

// Persistence
public enum AppPaths {                                   // honours REFEREE_HOME: data = $REFEREE_HOME, caches = $REFEREE_HOME/Caches
    public static func dataDirectory(environment: [String: String]) -> URL
    public static func cacheDirectory(environment: [String: String]) -> URL
}
public actor FileSessionStore: SessionStoring { public init(directory: URL) }
public actor FileSettingsStore: SettingsStoring { public init(fileURL: URL) }

// Composition (Wave 0, frozen)
public enum LiveDependencies {
    /// Loads settings, builds every real implementation, registers providers
    /// (LLMKit + CLIProviders, plus MockLLMProvider when environment["REFEREE_ENABLE_MOCK"] == "1").
    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment) async -> AppDependencies
}

// AppCore: ReviewSessionModel, SettingsModel (Appendix A.9), and
public enum ReportExporter {
    public static func plainText(fromMarkdown markdown: String) -> String
    public static func data(markdown: String, format: ExportFormat) throws -> Data      // .markdown/.plainText → UTF-8; .docx; .pdf
}

// RefereeUI
public enum AppMain { public static func run(makeDependencies: @escaping @Sendable ([String: String]) async -> AppDependencies) -> Never }   // Shell
public struct ReviewWindowView: View { public init(model: ReviewSessionModel, reader: ReaderController) }     // Shell
public struct SettingsRootView: View { public init(model: SettingsModel) }                                    // Shell
public struct WelcomeView: View { public init(recent: [SessionSummary], open: @escaping (URL?) -> Void) }     // Shell
@MainActor public final class ReaderController { public init(model: ReviewSessionModel) }                    // Reader
public struct ReaderPane: View { public init(controller: ReaderController) }                                  // Reader
public struct NavigatorPane: View { public init(controller: ReaderController) }                               // Reader
public struct ReferenceViewerView: View { public init(fileURL: URL, title: String) }                          // Reader
public struct ReviewSidebar: View { public init(model: ReviewSessionModel) }                                  // Sidebar
public struct UIActions { … }   and   EnvironmentValues.uiActions                                              // Common (§9.1)
@MainActor public enum ShellScenes { public static var all: [SnapshotScene] }                                // Shell
@MainActor public enum ReaderScenes { public static var all: [SnapshotScene] }                               // Reader
@MainActor public enum SidebarScenes { public static var all: [SnapshotScene] }                              // Sidebar
```

`Composition` wiring (Wave 0 writes it against the stubs; it never changes): `AppPaths` → `FileSettingsStore` wrapped in a decorator that keeps a lock-protected current `AppSettings` (the source for `ProviderEnvironment.settings` and for `ReferenceResolver`'s settings closure) → `EnvironmentSecretStore(KeychainSecretStore())` (or over an empty in-memory store when `REFEREE_NO_KEYCHAIN=1`) → `ProviderRegistry(LLMKitFactory… + CLIProviderFactory… [+ mock])` → `PDFPaperService(builder: PaperTextBuilder(stripMarginLineNumbers: { current.ui.stripMarginLineNumbers }))` → `ReviewEngine(providers:paperService:matcherFactory: { QuoteMatcher(paper: $0) }, renderer: PaperRenderer())` → `ReferenceResolver` → `FileSessionStore` → `AppDependencies`.

### 11.4 Work packages

Each lists what to read, what to build, and the commands that must pass. "Tests" are the minimum; add more. Test names are suggestions; behaviours are required.

#### WP0 — Scaffold and contracts (Wave 0, alone, on `main`)

Read: all of §2, §3, §5.9, §10.1, §11, Appendices A–D.

Build:

1. Repository files of §3.3; scripts of §3.4 exactly as printed; `Package.swift` of §3.2 exactly as printed.
2. `RefereeCore`: Appendix A verbatim, plus public memberwise initialisers, `DefaultSettings.make() -> AppSettings` (prompts, rubric, quick questions from Appendix B; every provider id of §5.2 present and disabled except `ollama`; privacy defaults: `localOnly` false, confirm on, background lookups off), and `FormatSpec` constants (Appendix B.2).
3. `TestSupport`: `Fixtures` locator; `MockLLMProvider` and `MockScript.sample`; `StaticProvider` and `snapshotProviders`; `StubURLProtocol`; in-memory stores; `FakePaperService`, `FakeQuoteMatcher`, `FakeResolver`, `ScriptedReviewEngine`; `identityPaperText(from:)` (§10.3).
4. Stubs with the surface of §11.3 in every other target. Stub behaviour: `PaperTextBuilder.build` copies raw lines to `.body` lines with `contentRange == range`; `PaperRenderer` is implemented for real (it is ten lines; WP1 owns it afterwards); `QuoteMatcher.locate` returns `nil`; `CitationIndexer` returns an empty index; providers report `.needsSetup("not implemented", …)` and throw `.notConfigured` from `stream`; `ReviewEngine` streams finish with a failed run; `ReferenceResolver.resolve` returns `notFound`; stores work in memory; `ReviewSessionModel` and `SettingsModel` have every member of Appendix A.9 with harmless bodies (no `fatalError`).
5. `PDFBridge.RawExtractor.extract` and `PDFPaperService.load` implemented for real in their simplest form (§7.2 raw extraction; WP2 owns and completes them), because fixtures need them.
6. A seed `referee-cli` with only `dump-raw <pdf>` (WP12 owns it afterwards).
7. Fixtures: LaTeX sources from Appendix C; `scripts/make-fixtures.sh` (pdflatex twice per file, `sips` for `scanned.pdf`, then `referee-cli dump-raw` into `Fixtures/raw`); run it and commit the PDFs and dumps; `Fixtures/llm/*` from Appendix D; `Fixtures/sessions/sample.json` (six comments quoting sentences of the fixtures, in the states needed by §10.1; anchors may be empty, the snapshot runner re-anchors on load).
8. `RefereeUI`: `Common/Theme.swift`, `Common/UIActions.swift`, `Common/SnapshotScene.swift`, `Common/SnapshotRunner.swift` (the full mechanism of §10.1), placeholder views with the signatures of §11.3 composed as in §9.2 (`ReviewWindowView` really uses `NavigationSplitView` + `.inspector`), a minimal `AppMain` that opens a review window for a PDF path argument and dispatches `--ui-snapshot`, and one scene `placeholder` in `ShellScenes`.
9. `README.md` (commands of §3.4), `docs/contract-notes/README.md`, initial commit.

If this is too much for one session, split it into two consecutive sessions on `main`, never parallel: first items 1, 2, 4, 9 (everything builds), then items 3, 5, 6, 7, 8.

Acceptance:

```
scripts/build.sh                                         # no errors
scripts/test.sh                                          # OK, at least 20 tests
scripts/test.sh --filter RefereeCoreTests                # codable round-trip of the §4.3 sample; DefaultSettings sanity; LineSplitter; MockLLMProvider determinism; every fixture PDF and raw dump present and decodable
"$(swift build --show-bin-path)"/referee-cli dump-raw Fixtures/pdf/ay_nolinks.pdf | head -c 200
scripts/snapshots.sh build/snapshots --scene placeholder # exit 0, PNG is non-blank; open it and check three columns are visible
scripts/bundle.sh && codesign --verify build/Referee.app
git status --porcelain | wc -l                           # 0
```

#### WP1 — PaperText (Wave 1)

Read: §6.2 (rendering), §6.7, §7.2 (cleaning), Appendix A.2.

Build: `PaperTextBuilder` (§7.2 steps 1–7), `QuoteMatcher` (§6.7), `PaperRenderer` (`render`, `chunkPageRanges`). Pure Foundation; inputs for tests are `Fixtures/raw/*.raw.json` decoded as `RawDocument`.

Acceptance: `scripts/build.sh` and `scripts/test.sh --filter PaperTextTests` with at least these behaviours:

| Test | Requirement |
|---|---|
| margin numbers found | `ay_nolinks`: `hasMarginLineNumbers`; margin numbers 1…16 on page 1, 17…31 on page 2, 32…40 on page 3; the line that starts "Table 2 is 0.91" has `marginNumber == 14` and `text` ending "difficult to" |
| no false positives | `hasMarginLineNumbers == false` for `ay_links`, `ay_round_nolinks`, `num_twocol_links`, `num_twocol_nolinks`; and for any PDF in `Fixtures/private` (skipped when absent) |
| setting respected | `PaperTextBuilder(stripMarginLineNumbers: { false })` leaves every `contentRange == range` |
| boilerplate | `ay_nolinks`: the three "CONFIDENTIAL" lines are `.watermark`; the last line of each page is `.pageNumber` |
| numbered lists are not line numbers | a synthetic page of 30 reference lines "1. …", "2. …" is not treated as leading margin numbers |
| exact anchors | on `ay_nolinks`, each of these is found with `.exact` on the stated page, with one span per text line touched: "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one" (p. 1), "Herding has been studied extensively since Banerjee" (p. 1), "office-specific identification threshold" (p. 1), "an information cascade begins with positive probability" (p. 2), "It is easy to see that the inequality is preserved when both sides are multiplied by the likelihood ratio." (p. 2) |
| reading order | `num_twocol_nolinks` and `num_twocol_links`, page 2: in `PageText.lines` the line starting "3 Results" and the last left-column line ("tae justo. Aliquam vestibulum fringilla lorem. Sed") come before the first right-column line ("neque lectus, consectetuer at, …") and before "References"; the page number is last; page 1 and every single-column fixture keep PDFKit's order |
| two columns | on `num_twocol_links`: "column of this page contains the sentence that must be anchored before the second column begins" (p. 1) and "Table 1 reports a BLEU score of 28.4 for the base model" (p. 2); a quote that runs from the bottom of the left column of page 2 into the top of the right column ("Aliquam vestibulum fringilla lorem. Sed neque lectus, consectetuer at") is found `.exact` with one span per line |
| fuzzy | "The coefficient in Table 2 equals 0.91 with a confidence interval which crosses one, which is difficult to reconcile" (two words changed) → `.fuzzy` with score ≥ 0.85 on p. 1; a five-token quote with one word changed is not matched by the fuzzy stage |
| ellipsis | "The coefficient in Table 2 is 0.91 … reconcile with the claim of a robust effect" → found on p. 1 |
| absent | "this sentence is not in the paper at all whatsoever" → `nil` |
| short quotes | "Table 2" → `nil` without a hint; found with `pageHint: 0` |
| repeated text | a quote occurring on two pages returns the hinted page |
| label | the Table 2 quote → "p. 1, lines 13–14"; on `ay_links` → "p. 1" |
| rendering | starts with "[[page 1]]\n"; contains "difficult to\n" and not "to14"; contains no "CONFIDENTIAL"; page count of markers equals page count |
| chunking | ranges are contiguous, cover all pages, and each rendered chunk is within the limit unless it is a single page |
| robustness | builder and matcher terminate on empty documents, one-character pages, and 200 KB of random Unicode |
| speed | building the matcher for a 60-page synthetic document and 50 `locate` calls take under 1 s in a debug build |

#### WP2 — PDFBridge (Wave 1)

Read: §4.6, §6.7 ("From spans to highlight rectangles"), §7.1, §7.2, Appendix A.2.

Build: complete `RawExtractor` (pages, lines, links, outline), `PDFPaperService` (`load(url:)`, `load(data:fileName:)`, SHA-256 with CryptoKit, `PaperError` cases, bounds recomputation for stripped lines, `rects(for:in:)`, `unload`), `SelectionInfoBuilder`. Follow the allowed and forbidden PDFKit calls of §7.2 exactly.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter PDFBridgeTests`:

| Test | Requirement |
|---|---|
| raw consistency | for every fixture and page: each `RawLine.text` equals the substring of `string` at `range`; ranges are increasing and non-overlapping; line count equals the number of newline-separated lines |
| links | `num_twocol_links`: 12 links, 10 with `.internalDestination` into page 2 and 2 with `.url` containing `doi.org/10.3115/v1/D14-1179`; `ay_links`: 21 internal links; `ay_nolinks`: none |
| load | page counts 3, 3, 3, 2, 2, 1; `DocumentRef.sha256` equals `shasum -a 256` of the file; two loads give equal `PaperText` |
| failures | data not starting with `%PDF-` → `.notAPDF`; an encrypted PDF made in the test with `PDFDocument.write(to:withOptions:)` to a temporary file → `.encrypted`; `scanned.pdf` loads with `hasTextLayer == false` |
| rects exclude margin numbers | with a test builder that marks the trailing digits of `ay_nolinks` lines as margin numbers, `rects` for the "Table 2 … crosses one" span returns two rectangles, each with `x` within 1 pt of the text block's left edge or to its right, and `width < 400`; none starts at `x < 100` |
| rects in two columns | a span in column 1 of `num_twocol_links` yields rectangles with `x + width < 310` |
| selection info | a `PDFSelection` made from a known range round-trips to the same `TextSpan` and non-empty rects |
| file untouched | bytes of the fixture file are identical before and after `load` + `rects` |
| off-main | `load` and `rects` called from a detached task complete (they run inside the actor) |

#### WP3 — CitationKit (Wave 1)

Read: §8.1–§8.5, Appendix A.3. Input in tests: `PaperTextBuilder().build(from:)` is still a stub in your worktree, so build `PaperText` for tests with the helper `TestSupport.identityPaperText(from: RawDocument)` (all lines `.body`); that is clean for every fixture except `ay_nolinks`, which is covered at integration.

Build: `CitationIndexer` with internal pieces `FlowText`, `BibliographyLocator`, `EntrySplitter`, `ReferenceParser`, `TextMentionFinder`, `LinkMentionFinder`, `MentionMerger`.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter CitationKitTests`:

| Test | Requirement |
|---|---|
| reference list, author–year | `ay_round_nolinks`: style `.authorYear`; 7 entries; first surnames in order Acemoglu, Avery, Banerjee, Bikhchandani, Kogan, Lee, Smith; years 2011, 1998, 1992, 1992, 2020, 2021, 2000; Acemoglu has 4 surnames |
| mentions, round brackets | `ay_round_nolinks` (links: []): exactly 9 mentions; "Banerjee (1992)" → Banerjee; the hyphen-broken "Bikhchan-dani et al. (1992)" → Bikhchandani; "(Avery and Zemsky, 1998; Smith and Sørensen, 2000)" → two mentions with the right entries; "Acemoglu et al. (2011)" split across a line break; "(Smith and Sørensen, 2000, p. 12)"; "Kogan (2020); Lee (2021)" → two mentions; the one in the Model section; no mention inside the reference list; none for "Table 2" or "Proposition 1" |
| mentions, square brackets | `ay_links` with `links: []`: the same 9 targets from "Banerjee [1992]", "[Avery and Zemsky, 1998, Smith and Sørensen, 2000]", … |
| link path | `ay_links` with its links: every internal link maps to the correct entry; pieces "Avery and Zem-", "sky", "1998" merge into one mention with three rectangles; text and link mentions for the same citation merge into one |
| numeric | `num_twocol_nolinks`: style `.numeric`; 5 entries labelled 1–5; "[4]", "[2, 1]", "[1, 5, 3]", "[4, 2, 1, 5]" → ten mentions whose entry labels are 4, 2, 1, 1, 5, 3, 4, 2, 1, 5 in reading order; the entry labelled 2 has `doi == "10.3115/v1/d14-1179"`; the entry labelled 3 has `arxivID == "1810.04805"`; a synthetic "[3–5]" is one mention with three entries; "[99]" is ignored |
| numeric links | `num_twocol_links`: the 10 internal links resolve to entry labels 4, 2, 1, 1, 5, 3, 4, 2, 1, 5 in reading order, merged one-to-one with the ten text mentions; the URL link annotation gives the entry labelled 2 its DOI |
| parser table | at least 15 reference strings in economics, APA, numeric and "et al." styles, with particles ("van der Berg"), initials before and after surnames, and a DOI at the end → expected first surname, year, DOI |
| no list | a document without a reference heading → empty entries, `.unknown`, no crash |
| robustness | random text and a 5,000-line document complete in under 2 s |

#### WP4 — LLMKit (Wave 1)

Read: §5.1–§5.5, §5.7, §5.8, Appendix A.5, Appendix D.

Build: `HTTPStreamClient`, the retry wrapper, the five adapters and providers, model listing with the filters of §5.4, `KeychainSecretStore`. Tests use `StubURLProtocol.session()` passed through `ProviderEnvironment.urlSession`; stream bodies come from Appendix D, saved under `Tests/LLMKitTests/Fixtures/`.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter LLMKitTests`:

| Test | Requirement |
|---|---|
| request shape, per provider | URL, method, headers and JSON body exactly as in §5.4 for (text only) and (PDF + text + cache boundary); Anthropic body has no `temperature`, `top_p`, `top_k`, `thinking`; OpenAI, xAI and Gemini bodies have `"store": false`; the OpenAI file part's `filename` is `manuscript.pdf`; `extraBodyJSON` keys are merged; `baseURL` override is honoured; no key → `.notConfigured` without a request |
| stream parsing, per provider | the Appendix D body, delivered in 1-byte chunks and again in one chunk, yields the same deltas whose concatenation equals the expected text, then exactly one `.finished` with the expected stop reason and usage |
| unknown events | bodies with extra unknown event types and extra JSON fields parse identically |
| in-stream errors | Anthropic `error` event → `.overloaded`; OpenAI `response.failed` → mapped error; Gemini `error` event → mapped by code; Ollama `{"error":…}` line → `.server` |
| early end | a body cut before the terminal event → the deltas so far, then `.malformedResponse` |
| HTTP errors | one case per cell of the §5.5 table, including `Retry-After` parsing |
| retry | two 529/503 responses then a good stream → one successful stream and two `.status` events (use an injected sleep function so the test is instant); failure after the first delta is not retried; `.auth` is not retried |
| cancellation | cancelling the consuming task stops the stub (its `stopLoading` is called) and the stream ends with `.cancelled` or silently, never hangs |
| xAI tolerance | a Chat-Completions-shaped chunk stream ending in `[DONE]` is parsed |
| models | each vendor's list JSON → expected `ModelInfo` (context window, PDF support, filters, pagination across two pages) |
| Ollama context | `num_ctx` equals `LLMRequest.contextWindow`; the "context full" status is emitted when the counts say so |
| Keychain | set, get, replace and delete under a unique test service name, cleaned up afterwards; skipped when `REFEREE_NO_KEYCHAIN=1` |
| live Ollama | enabled only if `/api/version` answers: a 16-token chat with the smallest installed model streams at least one delta |

#### WP5 — CLIProviders (Wave 1)

Read: §5.6 entirely, §5.5, Appendix A.5, Appendix D. **Never send a prompt to a real vendor CLI.** `--version`, `--help`, `auth status`, `login status`, `debug models`, `models` are allowed.

Build: `BinaryResolver`, login-shell `PATH` lookup, environment builder, `CLIRunner`, the four adapters and providers, the fake CLIs of §10.3.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter CLIProvidersTests`:

| Test | Requirement |
|---|---|
| argument lists | for each CLI, the exact argument array of §5.6.4 for (default model) and (explicit model), with `extraArguments` appended and `!flag` removal applied |
| resolver order | explicit path beats environment override beats candidates beats `PATH`; a candidate whose `--version` hangs (fake `hang`) is skipped after the timeout (use a 1 s timeout in the test) and the next one is chosen; nothing found → `.needsSetup` carrying the install command |
| environment | with `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CODEX_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY` set in the injected process environment, the fake `print-env` shows none of them and shows `HOME`, a `PATH` containing `/opt/homebrew/bin`, `TERM=dumb`, `NO_COLOR=1` |
| working directory | the fake reports an empty current directory that no longer exists after the run |
| stdin | a 2 MB prompt reaches the fake intact (`echo-bytes`) without deadlock |
| stream parsing | for each CLI the Appendix D lines → expected deltas and `.finished`; Codex cumulative `item.updated` text produces only the new suffix |
| failures | fake `auth` → `.auth`; `quota` → `.quotaExhausted`; `garbage` (non-JSON lines) is ignored and the run still ends with `.cliExited` or `.malformedResponse`, never a crash; non-zero exit → `.cliExited` with the stderr tail |
| timeouts and cancel | fake `hang` → `.cliTimeout(phase: "start")` with a 1 s test timeout; cancelling the consumer kills the fake within 6 s (verify the PID is gone) |
| model lists | recorded `codex debug models` JSON → models with `visibility == "list"` ordered by priority with context windows; recorded `agy models` text → slugs and names |
| availability | fake `claude auth status` JSON for logged-in subscription, logged-in API key, logged out → `.ready`, `.needsSetup`, `.needsSetup` |
| real binaries (skipped when absent) | `claude --version` through the resolver; `claude auth status` parses; `codex login status` parses; the resolver does not pick a `codex` whose `--version` fails |

#### WP6 — ReviewEngine (Wave 1)

Read: §6 entirely, §5.1, Appendices A.4–A.6, B, D. Dependencies in tests: `MockLLMProvider`, `FakePaperService`, `FakeQuoteMatcher`, the real `PaperRenderer` (already implemented in Wave 0).

Build: `Planning`, `PromptBuilder`, `CommentStreamParser`, `ReplyParser` (revision / withdraw), `ReviewEngine` jobs, `ReportLinter`, the debug dump (§10.5).

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter ReviewEngineTests`:

| Test | Requirement |
|---|---|
| parser, clean | `Fixtures/llm/review_clean.txt` → 6 comments with the expected kinds, categories, pages, quotes, titles; `sawDone` |
| parser, chunking | the same text fed in chunks of 1, 7 and 4,096 characters gives identical closed blocks; drafts only grow |
| parser, sloppy | `review_sloppy.txt` (decorated markers, bold field names, missing `@@END`, quoted quotes, prose between blocks, numbered comments, "Type:" and "Severity:" synonyms, a body containing a line that starts "Title:") → the expected 5 comments |
| parser, fallbacks | `review_json.txt` → comments via the JSON path; `review_prose.txt` → one "Unstructured model output" comment and a notice |
| parser, garbage | random bytes and a 5 MB line do not crash or hang |
| planning | table-driven: (provider, context window, pages, characters, file size, input mode) → expected `SendPlan` (PDF or text, request count, warnings), including: Anthropic with a 34-page PDF → PDF, 1 request; the same with `inputMode == .text` → text; Ollama at 16,384 with 120,000 characters → several parts + 1; `grok-cli` with a 400 KB paper → parts because of `maxPromptBytes`; context 2,048 → failure before sending; scanned PDF with a text-only provider → warning and failure |
| prompts | review system prompt contains the rubric ids and the format constant; PDF mode puts the `.pdf` part first and a `.cacheBoundary` after it; reviewer notes and existing titles appear in the task; no prompt contains the document's file name |
| review, one pass | mock script → events in the order of §6.6; comments carry anchors from the fake matcher, labels, `.pending`; `RunRecord` has `requestCount == 1`, usage, `.completed` |
| review, in parts | 3 parts → 4 requests; request 2 contains the notes returned by request 1; the final notes are emitted once as `.digest` before `.finished` |
| continuation | first response ends with `.maxTokens` mid-block → a second request listing the titles so far; at most two continuations |
| duplicates | a repeated comment (same quote and title) is dropped; an overlapping anchor with a different title is kept |
| failure mid-stream | mock fails after 3 chunks → comments so far, then `.finished` with `.failed`; the stream does not throw |
| PDF fallback | mock throws `.contextTooLong` on a PDF request → one retry in text mode and a notice |
| cancellation | cancelling during streaming ends with `.finished` `.cancelled` promptly |
| discussion | reply text before `@@REVISED` is the visible reply; the block becomes a `CommentRevision`; `@@WITHDRAW` → `withdraw == true`; no block → `nil` |
| ask | the selected passage and its label appear in the request; a general question has no passage section |
| report | the request lists only approved, included comments in the order major, minor, question, strength with prefixes and labels; zero approved → the job fails without a request; the recommendation is parsed from four sample reports |
| lint | a table of sentences → expected rule ids (Appendix B.7), including a clean report with no findings and the recommendation/severity mismatch |
| privacy | with a spy on `Log`, no logged value contains any substring of the paper text or the prompts |

#### WP7 — ScholarKit (Wave 1)

Read: §8.7, Appendix A.3.

Build: `ReferenceResolver` with clients for OpenAlex, Crossref, Semantic Scholar, arXiv (Atom parsing with `XMLParser`), host token buckets with an injectable clock, the JSON cache, the PDF cache with LRU eviction, `searchURL`.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter ScholarKitTests` (HTTP stubbed; JSON bodies recorded from the real services are in Appendix D):

| Test | Requirement |
|---|---|
| identifier short-circuits | an entry with an arXiv id makes no request and returns the abs and pdf URLs; an entry with a DOI makes exactly one request, to `api.openalex.org/works/doi:…` |
| Crossref path | an entry without identifiers → Crossref request with `query.bibliographic`, `rows=3`, the `select` list, and **no** `mailto` and no email in `User-Agent` by default; with a configured address both appear; the Hochreiter fixture resolves to DOI `10.1162/neco.1997.9.8.1735` and then calls OpenAlex |
| validation | a top hit with a different first author, or a year off by 3, or a title sharing under 60% of words, is rejected; all rejected → `.notFound` |
| fallbacks | Crossref empty → Semantic Scholar match (404 handled) → OpenAlex search → arXiv (only for entries mentioning arXiv or working paper); disabled services are skipped |
| rate limits | with the test clock, two Crossref calls are at least 1 s apart and never concurrent; arXiv calls are 3 s apart |
| transient failures | 429 with `Retry-After: 1` is retried once; a second 429 makes that step fail and the pipeline continue; if nothing resolves and some step failed → `.failed`, which is not cached |
| cache | a second `resolve` of the same entry makes no request; expiry rules of §8.7 |
| open access | `best_oa_location.pdf_url` is preferred; `oa_url` is used only if it ends in `.pdf`; none → `openAccessPDFURL == nil` |
| PDF fetch | stubbed PDF body → file in the cache directory whose bytes start with `%PDF-`; HTML body → `.notAPDF`; `http` URL → `.noOpenAccessPDF`; eviction keeps the directory under the limit |
| search URL | percent-encoding of a title with quotes, ampersands and non-ASCII letters |
| live (only with `REFEREE_LIVE_NET=1`) | the Hochreiter entry resolves against the real services |

#### WP8 — AppCore and Persistence (Wave 1)

Read: §2.3–§2.5, §4, §6.6–§6.10 (behaviour seen from the model), §9.3–§9.8 (what the views will ask of the model), Appendix A.9.

Build: `AppPaths`, `FileSessionStore` (atomic save, backup, corrupt-file handling, version check and migration hook, listing), `FileSettingsStore` (defaults, filling in missing providers), `ReviewSessionModel`, `SettingsModel`, `ReportExporter`. All dependencies in tests are fakes from `TestSupport`; use an injected clock for debounces.

Behaviour to implement in `ReviewSessionModel` beyond what the member names say:

- `open(url:)`: `.loading` → `paperService.load` → load or create the session by hash (update `lastKnownPath`, `fileName`) → for every comment and conversation whose anchor has a non-empty quote but no spans, re-anchor with the matcher (this is how sample sessions and older sessions heal) → build the citation index off the main actor and fill text-mention rects → `.ready`. Errors → `.failed(message:)`.
- Provider for a job: `session.preferredProvider ?? settings.defaults.<job> ?? settings.defaults.review`; none or not enabled → banner "Set up an AI provider" with the action "Open Settings".
- Consent and Local-only as in §9.7; every job goes through one private gate `authorize(job:) async -> Bool`.
- Lanes as in §2.3; starting a job in a busy lane is ignored (the UI disables the buttons).
- Review events: `.draft` → upsert in `drafts`; `.comment` → remove the draft, append to `session.comments`; `.notice` → info banner; `.digest` → `session.paperDigest`; `.finished` → append the `RunRecord`, `runState = .idle`, failed → error banner with Retry.
- `setStatus`: updates the comment; approving sets `includeInReport = true`; then, when `settings.ui.autoAdvanceAfterTriage`, selects the next pending comment in visible order.
- `editComment`, `acceptProposedRevision`: push the old version to `previousVersions` (cap 20).
- `visibleComments` ordering as in §9.3; `triage` counts decided (approved or rejected) over all.
- Report: `generateReport` streams into `streamingReplyText` and replaces `session.report` at the end (old draft → `versions`, cap 10); `updateReportMarkdown` sets `userEdited` and re-lints after 0.5 s.
- Citations: `lookUpCitation` → `.resolving` → resolve each candidate entry concurrently → `.resolved`.
- Autosave as in §4.5.

Acceptance: `scripts/build.sh`, `scripts/test.sh --filter PersistenceTests`, `scripts/test.sh --filter AppCoreTests`:

| Test | Requirement |
|---|---|
| store round trip | save then load equals; the file is pretty-printed with sorted keys; a second save leaves a `.bak` with the first content |
| atomicity | a simulated failure between temp write and rename leaves the old file readable |
| corrupt file | garbage in `session.json` → the `.bak` is loaded, the bad file is renamed `session.corrupt-*.json`; both bad → `StoreError.corrupt` |
| versions | `schemaVersion: 2` → `StoreError.newerSchema(found: 2, supported: 1)` and the file is untouched; the §4.3 sample decodes |
| listing | three sessions → three summaries with correct counts, newest first |
| settings | missing file → `DefaultSettings.make()`; a file lacking a provider id gains it on load; unknown keys are ignored |
| paths | `REFEREE_HOME=/x` → data `/x`, caches `/x/Caches`; unset → the Application Support and Caches paths |
| open | fake paper → `.ready`, session created, comments with quotes get anchors, citations present |
| consent | non-local provider: `startReview` sets `consentRequest` and sends nothing; `answerConsent(granted: true)` records consent and starts; a second job does not ask; `granted: false` leaves state unchanged; local provider never asks; `localOnly` blocks with a banner |
| review flow | scripted events → drafts appear and are replaced; comments appended in order; run recorded; failure → banner and comments kept |
| triage | approve/reject/reset transitions; auto-advance picks the next pending in visible order; counts |
| editing and revisions | edit pushes history; accept revision applies fields and clears the proposal; accept withdrawal rejects; discard clears |
| own comments | with and without a selection; `reanchorComment` |
| lanes | a discussion can start while a review runs; a second review cannot |
| report | generate → draft, recommendation, lint findings; edit → `userEdited`, re-lint; regenerate pushes a version; restore version |
| export | Markdown → the text; plain text conversion of a sample report (headings, numbered lists, emphasis); `.docx` data starts with `PK`; `.pdf` data starts with `%PDF` |
| autosave | several mutations within the debounce → one save; `flushPendingSave` saves at once |
| settings model | `update` saves and posts the notification; `setSecret` updates `storedSecrets` and never exposes values; `refreshModels` fills `models` or `modelErrors`; `applyFirstRunDefaultsIfNeeded` selects Ollama only when its fake reports ready with a model, and never a remote provider |

#### WP9 — Reader UI (Wave 2)

Read: §7, §8.6, §9.2, §9.5, §9.9, §9.10, §10.1.

Build: `ReaderController`, `RefereePDFView`, `PDFViewRepresentable`, `HighlightController`, `ReaderPane` (PDF, find bar, selection bar, citation card, banner slot), `NavigatorPane` (Pages / Outline / References), `ReferenceViewerView`, `ReaderScenes` (six scenes of §10.1). Pure helpers with unit tests: desired-highlight computation (comments + filter + selection → list of `(rect, colour, alpha, id)`), hit-testing (point + rect lists → comment id or mention id; smallest rectangle wins), overlay placement (page rect + view bounds → overlay origin that stays inside the view).

Acceptance:

```
scripts/build.sh
scripts/test.sh --filter RefereeUITests
scripts/snapshots.sh build/snapshots --scene reader-highlights --scene reader-selection --scene reader-citation --scene reader-find --scene reader-references --scene reference-viewer     # exit 0
```

and, by looking at each PNG: highlights lie exactly on the quoted lines in the right colours; the selected comment's highlight is stronger; the selection bar sits just above the selection; the citation card shows the reference text and its buttons and does not leave the window; the find bar shows a count and matches are marked; thumbnails show pages; the reference viewer shows the two-column paper. Describe what you saw for each scene in your notes file.

#### WP10 — Sidebar UI (Wave 2)

Read: §9.3–§9.5, §9.8–§9.10, §6.8–§6.10, §10.1.

Build: `ReviewSidebar` (tab switch bound to `model.sidebarTab`), `CommentsTab`, `CommentCard` and its states, `CommentEditor`, `ThreadView`, `ChatTab`, `ReportTab` (editor, preview, lint list, recommendation, versions, export menu using `NSSavePanel` and `ReportExporter`), `SidebarScenes` (seven scenes). Pure helpers with unit tests: card view-state derivation (comment + model state → what the card shows), filter chips counts, Markdown preview conversion.

Acceptance:

```
scripts/build.sh
scripts/test.sh --filter RefereeUITests
scripts/snapshots.sh build/snapshots --scene sidebar-pending --scene sidebar-streaming --scene sidebar-states --scene sidebar-discussion --scene sidebar-editing --scene sidebar-chat --scene sidebar-report     # exit 0
```

and, by looking at each PNG: every state of §9.3 is distinguishable; no text is clipped at 380 pt width; buttons match the state; the streaming scene shows a growing draft; the report scene shows headings, lint findings and the export menu button. Describe each scene in your notes file.

#### WP11 — Shell, settings, snapshots (Wave 2)

Read: §9.1, §9.2, §9.6, §9.7, §9.9, §10.1, §3.4 (bundle).

Build: `AppMain`, `AppDelegate`, `WindowManager`, `MainMenu`, `ReviewWindowController` (window, key monitor with `TriageKeymap`, title, close → flush), `ReviewWindowView` (composition, toolbar, destination indicator and its overlay, consent card, banner), `WelcomeView`, the settings window and panes on `SettingsModel`, drag-and-drop of PDFs onto windows, Open Recent, `ShellScenes` (seven scenes), `Fixtures/sessions/*` needed by scenes. Unit tests: `TriageKeymap` table; destination indicator state derivation; consent text from a `SendPlan`.

Acceptance:

```
scripts/build.sh
scripts/test.sh --filter RefereeUITests
scripts/snapshots.sh build/snapshots        # all scenes that exist in this worktree; exit 0
scripts/bundle.sh && codesign --verify build/Referee.app
build/Referee.app/Contents/MacOS/Referee --ui-snapshot build/snapshots-bundle --scene review-empty     # the bundled binary also works
```

and, by looking at the PNGs: three columns with toolbar; the indicator text and colour for local and remote mock providers; the consent card wording of §9.7; the error banner with Retry; each settings pane complete and unclipped. Describe each scene in your notes file.

#### WP12 — Command line and end-to-end (Wave 2)

Read: §10.2, §10.4, §3.5, §3.6.

Build: the full `referee-cli` (§10.2), `scripts/e2e-ollama.sh`, `scripts/fetch-optional-fixtures.sh`, and `Tests/IntegrationTests` on the real implementations:

| Test | Requirement |
|---|---|
| pipeline on every fixture | load → `PaperText` → matcher → citations completes; `ay_nolinks` has margin numbers and all WP1 quotes anchor through the real `PDFPaperService` with rectangles starting right of x = 100 |
| citations with line numbers | `ay_nolinks` (real builder): 7 entries and the same 9 mention targets as the square-bracket test of WP3 |
| mock review end to end | `LiveDependencies.make` with `REFEREE_ENABLE_MOCK=1` and a temporary `REFEREE_HOME`: review of `ay_round_nolinks` yields 6 comments, at least 5 anchored `.exact`, session saved and reloadable |
| model end to end | `ReviewSessionModel` with live dependencies and the mock provider: open, review, approve all, generate report → a report with the six headings |
| file safety | no source file under `Sources/` contains `write(to:`, `write(toFile:` or `dataRepresentation(` applied to a PDF document (grep test); fixture bytes unchanged after a full review |
| CLI | run the built binary `<repository root>/.build/debug/referee-cli` as a subprocess (root found from `#filePath`; the test requires the file to exist, which `scripts/build.sh` guarantees, and fails with a clear message otherwise): `providers --json` parses; `review … --provider mock` prints `SUMMARY … status=completed`; `anchor` exit codes; `extract --stats` reports margin numbers 1–40 for `ay_nolinks` |

Acceptance:

```
scripts/build.sh
scripts/test.sh --filter IntegrationTests
"$(swift build --show-bin-path)"/referee-cli review Fixtures/pdf/ay_round_nolinks.pdf --provider mock      # ends with SUMMARY … status=completed
scripts/e2e-ollama.sh                                                                                       # exit 0 (needs Ollama running)
```

### 11.5 Integration (Wave 3, one agent)

1. Merge order within a wave does not matter. After each merge run `scripts/build.sh`; after the last, `scripts/test.sh`.
2. Read every `docs/contract-notes/*.md`. Apply agreed contract changes in `RefereeCore`, fix call sites, re-run tests.
3. Cross-package checks that single packages could not make: the whole `IntegrationTests` target; every snapshot scene with all real panes (`scripts/snapshots.sh`), each PNG looked at; `scripts/e2e-ollama.sh` with `gemma4:e4b`, and once with `phi4` to exercise reading in parts.
4. `scripts/bundle.sh`; launch `build/Referee.app` once with `open -n build/Referee.app --args <fixture pdf>` and confirm from `log show --last 1m --predicate 'subsystem == "local.referee.app"'` that the document reached `.ready`; run the bundled binary's snapshot mode.
5. Manual provider checks that need the user's accounts (list them in the README as a checklist, do not run them unasked): one real review per configured API provider and per installed CLI on a non-confidential PDF.
6. Final `README.md`: install, first run, provider set-up, privacy summary, troubleshooting (Codex reinstall, Keychain prompt after rebuild, Ollama not running).

---

## 12. Security & privacy

### 12.1 Secrets

- API keys live only in the Keychain item of §5.8, or in `REFEREE_KEY_*` environment variables for the CLI and tests. They are never written to `settings.json`, session files, logs, snapshots, crash output or the repository.
- The app never reads or stores subscription credentials. CLI providers run the vendor's binary, which reads its own credential store.
- `.gitignore` (§3.3) covers build output, `Fixtures/private/`, `.env` and `*.local.json`. The repository contains only synthetic manuscripts. WP12's grep test also fails the build if any file under the repository contains a string matching `sk-[A-Za-z0-9_-]{20,}`, `xai-[A-Za-z0-9]{20,}` or `AIza[0-9A-Za-z_-]{30,}`.
- Nothing personal (name, email, institution) is in source, defaults or requests. The Crossref contact email is a user setting, empty by default.

### 12.2 No manuscript text in logs

- `Log.event(name, [String: LogValue])` is the only logging call in libraries, and `LogValue` cannot carry free text: only integers, doubles, booleans and `.id` for identifiers the code itself defines (provider ids, model ids, error codes, scene names).
- File names are treated as manuscript content (they often contain manuscript numbers or author names): never logged, never sent to a provider (`manuscript.pdf` is sent instead).
- Error messages shown to the user may quote a provider's message; they are not logged. CLI stderr is shown, not logged.
- The only switch that writes prompts or model output outside the session file is `REFEREE_DEBUG_DUMP` (§10.5).

### 12.3 What leaves the machine, and when

| Data | Goes to | When |
|---|---|---|
| The PDF file, or its extracted text | the selected AI provider (shown in the toolbar) | only when the user starts a review, sends a discussion message, asks a question, or generates or revises a report; first time per document and provider needs explicit consent |
| Approved comments, discussion text, reviewer notes | the same provider | with those same actions |
| One reference's text or identifier | Crossref, OpenAlex, Semantic Scholar, arXiv | when the user clicks that citation (or for all references if the user turned on background lookups) |
| A request for an open-access PDF | the host of that PDF | when the user clicks Open PDF |
| An API key | its own vendor's API host | with each request to that vendor, including listing models |
| Nothing else | | no telemetry, no update checks, no crash reporting |

With an Ollama provider on loopback and no citation clicked, the app makes no network connection other than to `127.0.0.1`. "Local only" enforces that for AI providers; reference lookups are a separate, visible choice.

Provider-side retention is reduced where the API offers a switch: `store: false` for OpenAI, xAI and Gemini; no session persistence for Claude Code; ephemeral session and no history for Codex. Antigravity and Grok Build may keep local conversation records; their rows say so.

### 12.4 Local data

- Review data: `~/Library/Application Support/Referee/sessions/<hash>/`. It contains quotes from the manuscript and the reviewer's comments. "Delete Review Data…" removes one review; Settings ▸ Privacy removes all.
- Downloaded papers: `~/Library/Caches/Referee/papers/`, clearable in Settings.
- Temporary files: the per-run CLI working directory (holds the system prompt file for Claude Code), mode 0700, removed after each run and on next launch if a crash left one.
- The app is not sandboxed (it must launch CLIs and read PDFs anywhere). It requests no entitlements, no Accessibility, no Screen Recording, no Full Disk Access.

### 12.5 Untrusted input

- PDFs and model output are untrusted. Parsers are total and bounded (WP1, WP3, WP6 robustness tests). Model output is rendered as plain text or through `AttributedString(markdown:)` with links disabled in comment cards; nothing from a model is executed, fetched or opened automatically.
- A prompt-injection attempt inside a manuscript ("ignore your instructions…") can at worst distort the model's comments, which the reviewer reads and triages; the model has no tools in any provider configuration (API calls declare none; CLIs run with tools removed or in an empty sandboxed directory).
- Downloaded PDFs are `https` only, size-limited, and checked for the PDF signature before PDFKit opens them.

---

## 13. Risks and open questions

Each item has a default so that nothing waits for the user.

### 13.1 Risks

| # | Risk | Mitigation | Default if unresolved |
|---|---|---|---|
| R1 | **Antigravity and Grok Build adapters are untested**: neither CLI is installed here; Grok's JSON stream is undocumented; plan coverage of headless Grok use is not stated. | Adapters are thin and table-driven; streams tested against documented samples and fake CLIs; `extraArguments` with `!flag` removal lets the user fix a renamed flag without a rebuild; Grok uses plain-text output. | Ship both with `isExperimental = true` (an "experimental" badge in Settings and in the destination indicator) until the user has completed one real run with each. |
| R2 | **Claude Code may change headless defaults.** The docs say `--bare` "will become the default for `-p`", and bare mode ignores the subscription login. | `availability()` plus clear `.auth` mapping make the failure obvious; the fix would be one flag in one argument table; the API-key provider is the fallback. | Keep the invocation of §5.6.4; revisit when a Claude Code release note announces the change. |
| R3 | **Subscription use from a third-party app** is governed by Anthropic's terms (§5.6.5) and by the other vendors' plans. | The app only launches the user's own installed binary for the user's own work; no credentials are touched; wording in the UI avoids "sign in". | Personal use only. Before giving the app to anyone else, re-read the terms and consider disabling the CLI providers. |
| R4 | **Journal-system PDFs differ from the fixtures** (line numbers stamped on a grid, in other positions, mixed with headers). | Leading and trailing detection, fuzzy anchoring, page-only fallback, an off switch, `extract --stats` to diagnose; optional private fixtures. | Ship with synthetic fixtures; tune when the user supplies real samples (Q7). |
| R5 | **PDFKit text quirks**: missing spaces in tight lines, garbled mathematics, unusable per-character geometry. | Matching ignores whitespace and punctuation; geometry only through selections; PDF mode sends the real file to capable providers. | As designed. |
| R6 | **Anchoring in PDF mode**: the provider's own text extraction may differ from PDFKit's, lowering exact matches. | Folded matching and the fuzzy stage; page hint from the model; page-only fallback; the SUMMARY line and run records expose the anchoring rate. | Accept; if under 80% of comments anchor on real papers, add the extracted text of the quoted page to a follow-up "locate" request. |
| R7 | **Small local models ignore the format or write poor comments.** | Tolerant parser, JSON and prose fallbacks, continuation; reading in parts with notes. Quality itself is the model's limit. | Recommend `gemma4:e4b` or larger in the README; keep `phi4` working through parts. |
| R8 | **Context estimates are rough** (3 characters per token; assumed windows for OpenAI and CLIs). | Conservative constants; per-provider override; automatic text-mode fallback on "too long"; Ollama full-context warning. | As designed. |
| R9 | **Keychain prompt after each rebuild** of an ad-hoc-signed app (new code identity). | One Keychain item, so one prompt; optional `REFEREE_SIGN_IDENTITY` for a stable self-signed identity; CLI and tests use environment keys. | Ad-hoc signing; document the prompt. |
| R10 | **Stale or blocked CLI binaries** (seen with Codex here). | Validation with timeout, several candidate locations, clear install hints. | As designed; the user reinstalls Codex. |
| R11 | **Snapshot capture depends on a private-by-availability symbol** (`CGWindowListCreateImage` via `dlsym`) and a logged-in GUI session. | Verified today; used only in a developer mode, never in normal operation. | If a future OS removes it, switch the snapshot mode to ScreenCaptureKit (needs Screen Recording permission). |
| R12 | **xAI stream shape** assumed OpenAI-compatible. | Parser accepts both Responses and Chat-Completions chunk shapes and `[DONE]`. | As designed; verify with a real key at integration checklist time. |
| R13 | **Gemini `v1` Interactions path** may not be enabled for every key or region. | One automatic retry on `v1beta` after a path-level 404. | As designed. |
| R14 | **Public reference services throttle or change** (OpenAlex budgets, Semantic Scholar shared pool). | Free DOI lookups first; every step optional; Search Scholar always works; optional keys. | As designed. |
| R15 | **Journals may forbid AI tools for manuscripts under review.** | Local-only mode; per-document consent with a reminder; the audit trail of runs in the session. | The reviewer decides per manuscript. |
| R16 | **Cost surprises** with large PDFs on premium models. | The consent card and indicator show request count and token estimate; text mode is one click away. | No price table (prices change); tokens only. |
| R17 | **A model invents references** in "missing literature" comments. | Prompt forbids citing unless sure; such comments carry a "verify" tag in the card when category is `literature`; Search Scholar on any selected text in a comment is a later addition. | Tag only. |
| R18 | **Agents diverge from the contracts.** | Contracts compile as printed; stubs on `main` before parallel work; frozen paths; notes files; an integration wave with cross-package tests. | As designed. |

### 13.2 Open questions for the user (defaults in force until answered)

| # | Question | Default |
|---|---|---|
| Q1 | Name and identifier: "Referee", `local.referee.app`? | Yes. |
| Q2 | Which provider should be preselected on first run? | Ollama, if it is running and has a model (`SettingsModel.applyFirstRunDefaultsIfNeeded`). Otherwise none: the Welcome window points to Settings. The app never enables a remote provider by itself. |
| Q3 | May the README tell you to install Antigravity CLI and reinstall Codex CLI? The app itself installs nothing. | Yes; hints only. |
| Q4 | Reference lookups only on click, or all at open? | Only on click. |
| Q5 | Review data in Application Support (keyed by file hash) rather than next to the PDF? | Yes. |
| Q6 | Export formats: Markdown, plain text, Word, PDF. Any journal need another? | Those four. |
| Q7 | Can you provide a few real journal-system PDFs (non-confidential, e.g. your own past submissions as built by Editorial Manager or ScholarOne) for `Fixtures/private`? | Proceed without; R4 applies. |
| Q8 | Will anyone else use the app? | No (see R3). |
| Q9 | Should approving a comment include it in the report automatically, and should "strength" comments exist? | Yes and yes; strengths feed only the summary assessment. |
| Q10 | Do you want an optional "Confidential comments to the editor" section in the report template? | Not in the default template; add it by editing the template. |
| Q11 | Should the model be allowed web search for the "missing literature" question in a later version? | Not in v1. |

---

## Appendix A. Contracts (Swift)

These files are the shared language of the project. A.1–A.8 are the complete contents of `Sources/RefereeCore/` apart from default settings and prompt constants; they compile exactly as printed (Swift 5 language mode, no warnings) [V]. Wave 0 copies them verbatim and adds, for every public struct that lacks one, a public memberwise initialiser with parameters in declaration order, defaulting optionals to `nil` and collections to empty. A.9 lists the public members of the two application models in `AppCore` (declarations only).

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
}

// ---- Raw extraction (produced by PDFBridge straight from PDFKit) ----

public struct RawLine: Codable, Sendable, Equatable {
    public var range: TextRange          // range in page string, excluding the trailing newline
    public var text: String              // == page string substring(range)
    public var bounds: PageRect?         // PDFSelection bounds of the whole line (unreliable if margin numbers are present)
}

public struct RawPage: Codable, Sendable, Equatable {
    public var index: Int
    public var label: String?
    public var size: PageSize            // mediaBox size
    public var string: String            // PDFPage.string ?? ""
    public var lines: [RawLine]          // from page.selection(for: whole).selectionsByLine(), in string order
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
}

public struct OutlineItem: Codable, Sendable, Equatable, Identifiable {
    public var id: Int                   // preorder index
    public var title: String
    public var pageIndex: Int?
    public var depth: Int
}

public struct RawDocument: Codable, Sendable, Equatable {
    public var pages: [RawPage]
    public var links: [RawLink]
    public var outline: [OutlineItem]
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
    public var marginNumber: Int?        // the manuscript's printed line number, when detected
    public var bounds: PageRect?         // bounds of contentRange (clean geometry)
}

public struct PageText: Codable, Sendable, Equatable {
    public var index: Int
    public var label: String?
    public var size: PageSize
    public var string: String            // raw PDFPage.string: the coordinate system for every TextRange on this page
    public var lines: [TextLine]         // in READING order, which can differ from string order on multi-column pages
}

public struct PaperText: Codable, Sendable, Equatable {
    public var pages: [PageText]
    public var hasTextLayer: Bool            // false => scanned PDF (fewer than 200 letters in total)
    public var hasMarginLineNumbers: Bool
    public var titleGuess: String?
}

public struct LoadedPaper: Sendable, Equatable {
    public var ref: DocumentRef
    public var data: Data                    // the original, unmodified file bytes
    public var text: PaperText
    public var links: [RawLink]
    public var outline: [OutlineItem]
}

/// What the user has selected in the PDF view (computed on the main actor from PDFSelection).
public struct SelectionInfo: Sendable, Equatable {
    public var text: String
    public var spans: [TextSpan]
    public var rects: [PageRect]
}

// ---- Anchoring ----

public enum AnchorConfidence: Codable, Sendable, Equatable {
    case exact
    case fuzzy(score: Double)   // 0.75 ... 1.0
    case pageOnly
    case none
}

public struct AnchorMatch: Sendable, Equatable {
    public var spans: [TextSpan]            // one per text line touched, in reading order; never empty
    public var confidence: AnchorConfidence // .exact or .fuzzy
}

public protocol PaperTextBuilding: Sendable {
    /// Pure function of its input. Classifies lines, detects and strips margin line numbers, detects boilerplate.
    /// Leaves `TextLine.bounds` equal to the raw line bounds; PDFBridge recomputes bounds where contentRange != range.
    func build(from raw: RawDocument) -> PaperText
}

public protocol QuoteMatching: Sendable {
    /// `pageHint` is a 0-based page index. Returns nil when the quote cannot be located anywhere.
    func locate(quote: String, pageHint: Int?) -> AnchorMatch?
    /// "p. 4, lines 14-16" / "p. 4"; uses margin line numbers when the manuscript has them.
    func locationLabel(for spans: [TextSpan]) -> String
}

public protocol PaperRendering: Sendable {
    /// LLM-facing text: "[[page N]]" marker lines (1-based) followed by that page's body lines.
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
}

public struct BibEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int                       // 0-based position in the reference list
    public var label: String?                // "13" for numeric lists
    public var rawText: String               // entry lines joined by a space, margin numbers removed
    public var spans: [TextSpan]
    public var firstLineBounds: PageRect?
    public var parsed: ParsedReference
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
}

public struct CitationIndex: Codable, Sendable, Equatable {
    public var style: CitationStyle
    public var entries: [BibEntry]
    public var mentions: [CitationMention]
    public var bibliographyHeading: TextSpan?
}

public protocol CitationIndexing: Sendable {
    /// Pure. Text-pattern mentions come back with `rects == []`; the caller fills them with PaperService.rects(for:in:).
    func buildIndex(paper: PaperText, links: [RawLink]) -> CitationIndex
}

// ---- Resolution ----

public enum ResolutionSource: String, Codable, Sendable { case entryText, linkAnnotation, crossref, openAlex, semanticScholar, arxiv }
public enum ResolutionStatus: String, Codable, Sendable { case resolved, notFound, failed }

public struct ResolvedReference: Codable, Sendable, Equatable {
    public var entryID: Int
    public var status: ResolutionStatus      // .failed = transient (network, rate limit); not cached for long
    public var title: String?
    public var authors: [String]
    public var year: Int?
    public var venue: String?
    public var doi: String?
    public var arxivID: String?
    public var landingURL: String?
    public var openAccessPDFURL: String?
    public var source: ResolutionSource?
    public var confidence: Double            // 1.0 when the identifier was printed in the entry itself
    public var resolvedAt: Date
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
    /// Never throws; inspect `status`. Reads and writes the on-disk resolver cache.
    func resolve(_ entry: BibEntry) async -> ResolvedReference
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
    public var locationLabel: String         // "p. 4, lines 14-16"; "" when unanchored
}

public enum MessageRole: String, Codable, Sendable { case user, assistant }

public struct ThreadMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    public var provider: ProviderRef?        // set on assistant messages
}

public struct CommentRevision: Codable, Sendable, Equatable {
    public var kind: CommentKind
    public var title: String
    public var body: String
    public var suggestion: String?
    public var withdraw: Bool                // true = the assistant proposes dropping the comment
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
    public var createdAt: Date
    public var updatedAt: Date
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
}

public struct Conversation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var anchor: Anchor?               // the selection it started from; nil = question about the whole paper
    public var messages: [ThreadMessage]
    public var createdAt: Date
}

public enum Recommendation: String, Codable, Sendable, CaseIterable { case accept, minorRevision, majorRevision, reject }

public struct ReportVersion: Codable, Sendable, Equatable {
    public var markdown: String
    public var savedAt: Date
    public var note: String                  // "generated", "before regenerate", "before voice revision"
}

public struct ReportDraft: Codable, Sendable, Equatable {
    public var markdown: String
    public var recommendation: Recommendation?
    public var generatedAt: Date?
    public var provider: ProviderRef?
    public var basedOnCommentIDs: [UUID]
    public var userEdited: Bool
    public var versions: [ReportVersion]     // newest last, max 10
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
}

public struct ConsentRecord: Codable, Sendable, Equatable {
    public var providerID: ProviderID
    public var grantedAt: Date
}

public struct ManuscriptMeta: Codable, Sendable, Equatable {
    public var title: String?
    public var targetVenue: String?
    public var manuscriptID: String?
    public var reviewerNotes: String         // free text passed to review and report prompts
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
    public var streaming: StreamingGranularity
    public var maxPromptBytes: Int?          // transport limit (stdin/argv); nil = none
    public var retentionNote: String         // one line for the privacy popover
    public var isExperimental: Bool
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
}

public struct Usage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
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
    func setSecret(_ value: String?, for key: String) throws   // nil deletes
}
```

### A.6 `Engine.swift`

```swift
import Foundation

/// Everything an engine call needs besides the paper. Built by AppCore from AppSettings at call time.
public struct EngineContext: Sendable, Equatable {
    public var provider: ProviderRef
    public var providerSettings: ProviderSettings
    public var prompts: PromptSet
    public var rubric: [RubricCategory]
    public var meta: ManuscriptMeta
}

public enum ReviewPhase: Sendable, Equatable {
    case preparing
    case reading(part: Int, of: Int)         // 1-based
    case wholePaperPass
    case anchoring
}

public struct SendPlan: Sendable, Equatable {
    public var sendsPDF: Bool
    public var requestCount: Int             // 1 = single pass
    public var estimatedInputTokens: Int
    public var destination: String
    public var isLocal: Bool
    public var warnings: [String]            // "No text layer", "Paper will be read in 6 parts", ...
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
}

public protocol ReviewEngineProtocol: Sendable {
    /// No network. Used by the consent sheet and the toolbar indicator.
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
}

public struct PromptSet: Codable, Sendable, Equatable {
    public var reviewSystem: String          // rubric and referee stance (editable)
    public var discussionSystem: String
    public var questionSystem: String
    public var reportSystem: String          // voice and rules for the final report
    public var reportTemplate: String        // Markdown skeleton with the section headings
    public var voiceRevisionSystem: String
    public var quickQuestions: [String]      // presets in the selection popover
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
    public var cachedModels: [ModelInfo]
    public var cachedModelsAt: Date?
}

public struct TaskDefaults: Codable, Sendable, Equatable {
    public var review: ProviderRef?
    public var chat: ProviderRef?            // nil = same as review
    public var report: ProviderRef?          // nil = same as review
}

public struct PrivacySettings: Codable, Sendable, Equatable {
    public var localOnly: Bool               // true = every non-local provider is disabled
    public var confirmFirstSendPerDocument: Bool
    public var resolveReferencesInBackground: Bool   // false = look references up only when clicked
}

public struct ReferenceSettings: Codable, Sendable, Equatable {
    public var crossrefMailto: String        // "" = public pool; never pre-filled
    public var useSemanticScholar: Bool
    public var useOpenAlexSearch: Bool
    public var pdfCacheLimitMB: Int
}

public struct UISettings: Codable, Sendable, Equatable {
    public var autoAdvanceAfterTriage: Bool
    public var showRejectedHighlights: Bool
    public var sidebarWidth: Double
    public var stripMarginLineNumbers: Bool  // false = never remove margin line numbers from the text
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
}

public final class ProviderRegistry: ProviderResolving {
    public let all: [any LLMProvider]
    public init(_ providers: [any LLMProvider]) { self.all = providers }
    public func provider(id: ProviderID) -> (any LLMProvider)? { all.first { $0.descriptor.id == id } }
}

/// The only logging API. Values are restricted by type so manuscript text, prompts, model output,
/// quotes and file names cannot be logged by accident.
public enum LogValue: Sendable {
    case int(Int), double(Double), bool(Bool)
    case id(String)        // provider ids, model ids, error codes, scene names. Never user content.
}
public enum Log {
    private static let logger = Logger(subsystem: "local.referee.app", category: "app")
    public static func event(_ name: StaticString, _ fields: [String: LogValue] = [:]) {
        let rendered = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.info("\(name.description, privacy: .public) \(rendered, privacy: .public)")
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
}

public struct ConsentRequest: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var provider: ProviderDescriptor
    public var model: String?
    public var plan: SendPlan
}

/// An own comment being written (N key, "+" button, or "Comment" in the selection bar).
public struct ComposingComment: Sendable, Equatable {
    public var selection: SelectionInfo?     // the passage it will be anchored to, captured when composing began
}

public enum CommentFilter: Sendable, Equatable { case all, pending, approved, rejected, kind(CommentKind) }
public enum SidebarTab: String, Sendable, CaseIterable { case comments, chat, report }
public enum ExportFormat: String, Sendable, CaseIterable { case markdown, plainText, docx, pdf }

public enum ReaderCommand: Sendable, Equatable {
    case reveal(rects: [PageRect], flash: Bool)
    case goToPage(Int)
    case find(String)
    case clearSelection
}

public enum CitationLookup: Sendable, Equatable {
    case idle
    case resolving(mentionID: Int)
    case resolved(mentionID: Int, entries: [BibEntry], references: [ResolvedReference])
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
    public private(set) var streamingReplyText: String = ""       // discussion / chat / report text in flight
    public private(set) var streamingTargetID: UUID?              // comment or conversation receiving the reply
    public private(set) var banner: Banner?
    public private(set) var consentRequest: ConsentRequest?
    public private(set) var activeProvider: ProviderDescriptor?   // nil = nothing usable is configured
    public private(set) var activeModel: String?                  // nil = the provider's own default
    public private(set) var sendPlan: SendPlan?                   // what a review would send now; refreshed when paper, provider or settings change
    public private(set) var lintFindings: [LintFinding] = []
    public private(set) var citationLookup: CitationLookup = .idle
    public private(set) var readerCommand: (serial: Int, command: ReaderCommand)?
    public private(set) var selection: SelectionInfo?
    public private(set) var composing: ComposingComment?
    public var selectedCommentID: UUID?
    public var openThreadCommentID: UUID?        // the comment whose discussion thread is expanded
    public var editingCommentID: UUID?           // the comment being edited in place
    public var filter: CommentFilter = .all
    public var sidebarTab: SidebarTab = .comments

    // ---- derived ----
    public var visibleComments: [ReviewComment]  // filtered; sorted by (pageIndex, first span location); unanchored first
    public var triage: (decided: Int, total: Int)
    public var canStartReview: Bool
    public var selectableProviders: [ProviderDescriptor]   // enabled providers; non-local ones are left out when Local only is on

    public init(dependencies: AppDependencies, settings: AppSettings)

    // ---- document ----
    public func open(url: URL) async
    public func close() async

    // ---- provider & consent ----
    public func setActiveProvider(_ ref: ProviderRef)
    public func answerConsent(granted: Bool)
    public func reloadSettings(_ settings: AppSettings)

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
    public func readerSelectionChanged(_ selection: SelectionInfo?)
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
    public func sendTestPrompt(to id: ProviderID) async -> Result<String, LLMError>  // explicit button only; spends a few tokens
    public func resetPromptsToDefaults()
    /// First launch only (no review default yet): if Ollama is running and has a model, enable it and make it the default.
    /// Never enables a remote provider by itself.
    public func applyFirstRunDefaultsIfNeeded() async
}
```

---

## Appendix B. Default prompts, rubric, report template, lint rules

Derived from the user's own peer-review rubric (`~/.claude/skills/peer-review/SKILL.md`): its foundational principle, five questions, mathematics checks, writing checks, report format, "what not to do", and the rules for a review that reads as written by a person. Everything in B.1 and B.3–B.6 is the default value of an editable setting. B.2 is a constant in code.

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
- If part of the paper is outside your competence, say so in the relevant comment and concentrate on logic and method.
```

### B.2 Format and task constants (`RefereeCore/FormatSpec.swift`, not editable)

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
A concrete way to resolve it. Leave this field out if you have none.
@@END

Rules:
- Copy the quote character for character from the manuscript so that it can be found. Do not paraphrase it, do not shorten it with "...", do not put quotation marks around it. For a comment about an equation, table or figure, quote the sentence that introduces or refers to it. For a comment about something missing, quote the passage where it should have been addressed.
- One issue per comment. Do not number the comments.
- "major" threatens the paper's main conclusions. "minor" should be fixed but does not. "question" is something whose answer could change your assessment. "strength" is something done well, stated specifically; use it sparingly.
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
The manuscript follows. Lines of the form [[page N]] mark where PDF page N begins; they are not part of the manuscript.

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
The manuscript is long, so you are reading it in parts. This is part {i} of {n}: PDF pages {a} to {b}. Lines of the form [[page N]] mark where PDF page N begins.

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

`scripts/make-fixtures.sh` builds six PDFs from two LaTeX files; it was run as printed and produced the documents described in §3.6 [V]. The three variants are derived with `sed` so that all author–year fixtures share the same sentences.

`scripts/make-fixtures.sh`

```bash
#!/bin/bash
# Regenerates Fixtures/pdf and Fixtures/raw from Fixtures/tex. Needs MacTeX (pdflatex) and sips. Usage: scripts/make-fixtures.sh [--pdf-only]
set -euo pipefail
cd "$(dirname "$0")/.."
TEX=Fixtures/tex; PDF=Fixtures/pdf; RAW=Fixtures/raw
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$PDF" "$RAW"
STRIP_JOURNAL='/\\usepackage{lineno}/d; /\\usepackage{draftwatermark}/d; /\\SetWatermarkText/d; /\\SetWatermarkScale/d; /\\linenumbers/d'
cp "$TEX/ay_nolinks.tex" "$TEX/num_twocol_links.tex" "$WORK/"
sed -e "$STRIP_JOURNAL" -e 's/\\usepackage{natbib}/\\usepackage[round]{natbib}/' "$TEX/ay_nolinks.tex" > "$WORK/ay_round_nolinks.tex"
sed -e "$STRIP_JOURNAL" -e 's/\\usepackage{natbib}/\\usepackage{natbib}\\usepackage[colorlinks=true,citecolor=blue]{hyperref}/' "$TEX/ay_nolinks.tex" > "$WORK/ay_links.tex"
sed -e 's/\\usepackage\[colorlinks=false\]{hyperref}/\\newcommand{\\url}[1]{\\texttt{#1}}/' -e 's/With Links/Without Links/' "$TEX/num_twocol_links.tex" > "$WORK/num_twocol_nolinks.tex"
for name in ay_nolinks ay_round_nolinks ay_links num_twocol_links num_twocol_nolinks; do
  ( cd "$WORK" && pdflatex -interaction=nonstopmode -halt-on-error "$name.tex" >/dev/null && pdflatex -interaction=nonstopmode -halt-on-error "$name.tex" >/dev/null )
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

\section{Model}
Consider a sequence of agents $i = 1, 2, \ldots$ who each observe a private signal $s_i$ and the history of actions $h_i$. The posterior belief satisfies
\begin{equation}
\mu_i = \frac{\pi \, f(s_i \mid H)}{\pi f(s_i \mid H) + (1-\pi) f(s_i \mid L)} .
\end{equation}
Proposition 1 states that an information cascade begins with positive probability. The proof follows \citet{bikhchandani1992} with minor modifications. It is easy to see that the inequality is preserved when both sides are multiplied by the likelihood ratio.

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
\bibitem[Kogan(2020)]{kogan2020}
Kogan, D. (2020).
\newblock Learning from reviews with strategic sellers.
\newblock Working paper.
\bibitem[Lee(2021)]{lee2021}
Lee, J. (2021).
\newblock Observational learning with heterogeneous priors.
\newblock {\em Games and Economic Behavior}, 125:1--20.
\bibitem[Smith and S{\o}rensen(2000)]{smith2000}
Smith, L. and S{\o}rensen, P. (2000).
\newblock Pathological outcomes of observational learning.
\newblock {\em Econometrica}, 68(2):371--398.
\end{thebibliography}
\end{document}
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

Save each block as a file under the named test target's `Fixtures/` directory. Lines are shown exactly as received or as documented; `…` inside JSON means "other fields, ignore".

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

### D.2 OpenAI Responses stream [D]

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

Variants to test: `{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}, …}}` → `.finished(.maxTokens)`; `{"type":"response.failed","response":{"error":{"code":"server_error","message":"…"}}}`; `{"type":"error","code":"rate_limit_exceeded","message":"…","param":null,"sequence_number":1}`. HTTP error body: `{"error":{"message":"…","type":"invalid_request_error","param":null,"code":"context_length_exceeded"}}`. xAI data-only variant: the same `data:` lines without `event:` lines, ending with `data: [DONE]`; and the Chat-Completions shape `data: {"choices":[{"index":0,"delta":{"content":"Hello"}}]}`. Model list: `{"object":"list","data":[{"id":"x","object":"model","created":1686935002,"owned_by":"openai"}]}`; xAI adds `"context_length":256000` per item.

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

Expected text `1, 2, 3, 4, 5`. Error event: `data: {"error":{"message":"Deadline expired before operation could complete.","code":"gateway_timeout"},"event_type":"error"}`. HTTP error body: `{"error":{"code":"invalid_request","message":"…"}}`. Model list: `{"models":[{"name":"models/m","displayName":"M","inputTokenLimit":1048576,"outputTokenLimit":65536,"supportedGenerationMethods":["generateContent"]}],"nextPageToken":"t"}`. (Whether the final line after `event: done` is `[DONE]` or empty is not shown in the docs; the parser must accept either.)

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

Expected text `Hello world` (delta "Hello" then " world"). Failures: `{"type":"turn.failed","error":{"message":"…"}}`, `{"type":"error","message":"…"}`. `codex login status` [V]: `Logged in using ChatGPT`, exit 0. `codex debug models` [V, trimmed]: `{"models":[{"slug":"gpt-6-astra","display_name":"GPT-6-Astra","context_window":272000,"max_context_window":872000,"visibility":"list","priority":2, …},{"slug":"codex-auto-review","display_name":"Codex Auto Review","context_window":272000,"visibility":"hide","priority":43, …}]}`.

### D.7 Antigravity `--output-format stream-json` [D]

```
{"event":"init","conversation_id":"9ec58bfd","init":{"cwd":"/tmp/x","tools":["ask_permission","run_command","write_to_file"],"permission_mode":"request-review"}}
{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":0,"state":"DONE","step_type":"user_input"}}
{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"apple"}}
{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"\n","duration_seconds":1.17,"usage":{"input_tokens":30384,"output_tokens":4,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":30388}}}
{"event":"step_update","step_update":{"conversation_id":"9ec58bfd","step_index":3,"state":"DONE","step_type":"checkpoint","duration_seconds":0.5}}
{"event":"result","result":{"conversation_id":"9ec58bfd","status":"SUCCESS","response":"apple\n","duration_seconds":1.43,"num_turns":1,"usage":{"input_tokens":30384,"output_tokens":4,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":30388}}}
```

Expected text `apple\n`. Error: `{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"invalid model selection (--model \"x\" --effort \"\"): model x is not recognized as a known model or custom model in settings", …}}` → `.modelNotFound`; an `error` containing `authentication required` → `.auth`. `agy models` output: lines such as `gemini-4-neon-high             Gemini 4 Neon (High)`.

### D.8 Reference services [V, recorded 2026-11-22, trimmed]

Crossref `GET /works?query.bibliographic=Hochreiter+Schmidhuber+Long+short-term+memory+Neural+computation+1997&rows=2&select=DOI,title,author,issued,container-title,score,type` (response headers included `x-rate-limit-limit: 1`, `x-rate-limit-interval: 1s`, `x-concurrency-limit: 1`, `x-api-pool: public-array`):

```json
{"status":"ok","message-type":"work-list","message":{"total-results":5104456,"items":[{"DOI":"10.1162/neco.1997.9.8.1735","title":["Long Short-Term Memory"],"author":[{"given":"Sepp","family":"Hochreiter","sequence":"first"},{"given":"Jürgen","family":"Schmidhuber","sequence":"additional"}],"issued":{"date-parts":[[1997,11,1]]},"container-title":["Neural Computation"],"score":77.511246,"type":"journal-article"},{"DOI":"10.1162/neco.1997.9.1.1","title":["Flat Minima"],"author":[{"given":"Sepp","family":"Hochreiter","sequence":"first"},{"given":"Jürgen","family":"Schmidhuber","sequence":"additional"}],"issued":{"date-parts":[[1997,1,1]]},"container-title":["Neural Computation"],"score":53.478394,"type":"journal-article"}]}}
```

OpenAlex `GET /works/doi:10.1162/neco.1997.9.8.1735?select=…` without a key (response headers included `x-ratelimit-cost-usd: 0`, `x-ratelimit-limit-usd: 0.1`):

```json
{"id":"https://openalex.org/W2064675550","doi":"https://doi.org/10.1162/neco.1997.9.8.1735","title":"Long Short-Term Memory","publication_year":1997,"open_access":{"is_oa":false,"oa_status":"closed","oa_url":null,"any_repository_has_fulltext":false},"best_oa_location":null,"authorships":[{"author_position":"first","author":{"display_name":"Sepp Hochreiter"}},{"author_position":"last","author":{"display_name":"Jürgen Schmidhuber"}}],"primary_location":{"landing_page_url":"https://doi.org/10.1162/neco.1997.9.8.1735","pdf_url":null,"is_oa":false,"source":{"display_name":"Neural Computation"}}}
```

For an open-access case, write a second fixture by hand with `"open_access":{"is_oa":true,"oa_status":"green","oa_url":"https://example.org/paper.pdf"}` and `"best_oa_location":{"is_oa":true,"landing_page_url":"https://example.org/abs","pdf_url":"https://example.org/paper.pdf","license":"cc-by","version":"submittedVersion"}`. Semantic Scholar match [D]: `{"data":[{"paperId":"abc","title":"…","matchScore":174.2,"year":1997,"authors":[{"name":"Sepp Hochreiter"}],"externalIds":{"DOI":"10.1162/neco.1997.9.8.1735","ArXiv":null},"openAccessPdf":null,"url":"https://www.semanticscholar.org/paper/abc"}]}`; no match is HTTP 404 with a "Title match not found" message.

### D.9 Model outputs for the parser and the mock (`Fixtures/llm/`)

`review_clean.txt` (the mock's review answer; every quote occurs in all three `ay_*` fixtures):

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

`review_sloppy.txt`: write five comments that between them use: `### @@COMMENT 1`, `**@@COMMENT**`, a block with no `@@END` before the next `@@COMMENT`, `**Kind:** Major concern`, `Type: minor`, `Severity: critical`, a quote wrapped in curly quotation marks, a quote wrapped over two lines, two sentences of prose before the first block and after the last, a body containing the line `Title: this is part of the body`, `Fix:` instead of `suggestion:`, and no `@@DONE`. `review_json.txt`: the same six comments as a fenced JSON array of objects with keys `kind`, `category`, `page`, `quote`, `title`, `body`, `suggestion`. `review_prose.txt`: four paragraphs of ordinary prose with no markers.

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

---

## Appendix E. Sources consulted (fetched 2026-11-22)

**Anthropic API.** https://platform.claude.com/docs/en/api/versioning · https://platform.claude.com/docs/en/build-with-claude/streaming · https://platform.claude.com/docs/en/build-with-claude/pdf-support · https://platform.claude.com/docs/en/api/models/list · https://platform.claude.com/docs/en/api/errors · https://platform.claude.com/docs/en/api/rate-limits

**Claude Code.** https://code.claude.com/docs/en/headless · https://code.claude.com/docs/en/cli-reference · https://code.claude.com/docs/en/authentication · https://code.claude.com/docs/en/setup · https://code.claude.com/docs/en/legal-and-compliance · https://code.claude.com/docs/en/agent-sdk/streaming-output · https://code.claude.com/docs/en/agent-sdk/typescript · https://code.claude.com/docs/en/errors · https://code.claude.com/docs/en/model-config · `claude --help` (2.1.330)

**OpenAI API.** https://developers.openai.com/api/docs/guides/migrate-to-responses · https://developers.openai.com/api/docs/guides/streaming-responses · https://developers.openai.com/api/docs/guides/file-inputs · https://developers.openai.com/api/reference/resources/responses/methods/create · https://developers.openai.com/api/reference/resources/responses/streaming-events · https://developers.openai.com/api/reference/resources/models/methods/list · https://developers.openai.com/api/docs/guides/error-codes · https://developers.openai.com/api/docs/guides/rate-limits · https://developers.openai.com/api/reference/overview

**Codex CLI.** https://learn.chatgpt.com/docs/non-interactive-mode · https://learn.chatgpt.com/docs/developer-commands?surface=cli · https://learn.chatgpt.com/docs/auth · https://learn.chatgpt.com/docs/config-file/config-reference · https://learn.chatgpt.com/docs/config-file/environment-variables · https://learn.chatgpt.com/docs/codex/cli · https://github.com/openai/codex (README; `codex-rs/exec/src/exec_events.rs`) · https://chatgpt.com/codex/install.sh · `codex --help`, `codex exec --help`, `codex login --help` (0.167.0-alpha.3.2)

**Gemini API.** https://aistudio.google.com/llms.txt · https://aistudio.google.com/api-reference · https://aistudio.google.com/api-reference/api-versions · https://aistudio.google.com/api-reference/interactions-api/create-interaction?api-version=v1 · https://aistudio.google.com/docs/interactions-overview · https://aistudio.google.com/docs/streaming · https://aistudio.google.com/docs/document-processing · https://aistudio.google.com/docs/text-generation · https://aistudio.google.com/docs/api-errors · https://aistudio.google.com/api-reference/models · https://aistudio.google.com/api-reference/models/list-models · https://aistudio.google.com/docs/interactions-breaking-changes-may-2026

**Gemini CLI and Antigravity CLI.** https://github.com/google-gemini/gemini-cli (README status notice; `docs/cli/headless.md`) · https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/ · https://antigravity.google/docs/cli/headless · https://antigravity.google/docs/cli/reference · https://antigravity.google/docs/install · https://antigravity.google/docs/getting-started · https://antigravity.google/docs/plans · https://antigravity.google/docs/cli/troubleshooting · `gemini --help` (0.30.0)

**xAI.** https://docs.x.ai/llms.txt · https://docs.x.ai/developers/model-capabilities/text/comparison · https://docs.x.ai/developers/rest-api-reference/inference/responses · https://docs.x.ai/developers/rest-api-reference/inference/models · https://docs.x.ai/developers/model-capabilities/text/streaming · https://docs.x.ai/developers/model-capabilities/files/chat-with-files · https://docs.x.ai/developers/rate-limits · https://docs.x.ai/developers/debugging · https://docs.x.ai/build/overview · https://docs.x.ai/build/cli/headless-scripting · https://docs.x.ai/build/cli/reference · https://docs.x.ai/build/enterprise · https://docs.x.ai/x-subscription/overview · https://docs.x.ai/x-subscription/pricing · https://docs.x.ai/x-subscription/usage-limits

**Ollama.** https://docs.ollama.com/api/chat · https://docs.ollama.com/api/tags · https://docs.ollama.com/api-reference/show-model-details · https://docs.ollama.com/api/ps · https://docs.ollama.com/context-length · https://docs.ollama.com/api/errors · the local server (0.40.17)

**Scholarly metadata.** https://www.crossref.org/documentation/retrieve-metadata/rest-api/access-and-authentication/ · https://www.crossref.org/documentation/retrieve-metadata/rest-api/tips-for-using-the-crossref-rest-api/ · https://github.com/CrossRef/rest-api-doc · https://help.openalex.org/api/authentication · https://help.openalex.org/access/example-costs · https://help.openalex.org/data/works/open-access · https://help.openalex.org/access/unpaywall · https://www.semanticscholar.org/product/api · https://www.semanticscholar.org/product/api/tutorial · https://api.semanticscholar.org/graph/v1/swagger.json · https://info.arxiv.org/help/api/tou.html · https://info.arxiv.org/help/api/user-manual.html

---

## Appendix F. What was verified on this machine (2026-11-22)

Toolchain and build (items marked † were verified by the coordinator, the rest by the plan's author):

- † Command Line Tools 26.6: Swift 6.3.3, macOS 26.5 SDK; tools-version 6.2 manifest with `.macOS(.v26)` and `swiftLanguageModes: [.v5]`; SwiftUI + PDFKit + `@Observable` app builds and runs.
- † Swift Testing runs under Command Line Tools only with command-line flags; manifest `unsafeFlags` give a silent zero-test run.
- † Window capture with `CGWindowListCreateImage` via `dlsym` works without Screen Recording permission; `cacheDisplay` and `CALayer.render` capture empty frames.
- The manifest of §3.2 with stub sources builds; `scripts/build.sh`, `test.sh`, `run.sh`, `bundle.sh`, `make-fixtures.sh` run as printed; `test.sh` returns 0 / 1 / 3 for pass / failing test / zero tests, and `--filter <TestTarget>` selects one target.
- Appendix A compiles as printed (Swift 5 mode, no warnings); the JSON in §4.3 is its real output; `main.swift` of §9.1 compiles and runs with a non-isolated `AppMain.run` that uses `MainActor.assumeIsolated` (a `@MainActor` entry point does not compile from `main.swift`).
- A hand-assembled, ad-hoc-signed `.app` verifies and runs; from inside it, HTTP to `127.0.0.1:11434` works with and without `NSAllowsLocalNetworking`.
- A three-column SwiftUI layout (`NavigationSplitView` + `.inspector`) with toolbar items, a PDF view and in-memory highlight annotations renders correctly in an `NSHostingController` window and is captured by the snapshot method; `.navigationTitle` does not set that window's title.

PDFKit:

- Text of a `lineno` + double-spaced + watermarked manuscript: margin numbers glued to line ends, space-less justified lines, watermark lines inline (§6.7).
- `selection(for: NSRange)`, `selectionsByLine()`, `range(at:on:)` are consistent with `page.string`; `characterBounds(at:)` and `characterIndex(at:)` are not.
- Selection bounds are exact for ranges that exclude margin numbers and wrong (x from −2) for ranges that include them.
- Two-column LaTeX pages: PDFKit's line order is column by column on page 1 of the fixtures but wrong on page 2 (top of left column, whole right column, rest of left column). A Python prototype of the reading-order repair of §7.2 step 2 fixes it and leaves single-column documents untouched.
- hyperref links arrive as `PDFActionGoTo` (numeric and natbib author–year) and `PDFActionURL`; natbib links author and year separately and splits at line breaks; `selectionForLine(at:)` at a destination fails for double-spaced lists.
- In-memory highlight annotations on a data-backed document: `page.annotation(at:)` finds them; the file on disk is unchanged; `documentURL` is nil.
- PDFKit extraction inside an actor on a background thread works.
- `NSAttributedString` → `.officeOpenXML` produces a valid `.docx` container.
- A Python prototype of §7.2 step 1 and §6.7 on the raw dumps: margin numbers 1–16 / 17–31 / 32–40 found on `ay_nolinks`, none on four other fixtures and a 15-page arXiv paper; all listed quotes located (exact, or fuzzy 0.75 for the paraphrase); an absent sentence rejected.

Providers and tools:

- `claude` 2.1.330 exists only inside the VS Code extension; `claude --help` flags; `claude auth status` JSON (logged in through claude.ai).
- `/opt/homebrew/bin/codex` (npm 0.128.0) hung on `--version`; the system log shows an invalid code signature for its native binary, and that binary is now missing from the npm package directory. `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` 0.167.0-alpha.3.2 works: `--help`, `exec --help`, `login status` ("Logged in using ChatGPT"), `debug models --bundled` JSON.
- `gemini` 0.30.0 (Homebrew) `--help`. `agy` and `grok` are not installed.
- No prompt was sent to any subscription CLI.
- Ollama 0.40.17: `/api/version`, `/api/tags` (with `details.context_length` and `capabilities`), `/api/show`, `/api/ps`, streaming `/api/chat` with `num_ctx`, consumed from a SwiftPM executable through `URLSession.bytes` and `LineSplitter`; `AsyncBytes.lines` drops empty lines.
- Crossref public pool (headers and a bibliographic query) and OpenAlex keyless DOI lookup (cost 0).
- Keychain add / read / delete from a SwiftPM-built executable; login-shell `PATH` lookup in 0.12 s.
- `pdflatex` builds all fixture sources; `sips` produces the image-only PDF.

Not verified (assumptions, all listed in §13): any real request to Anthropic, OpenAI, Gemini or xAI; any prompt through Claude Code, Codex, Antigravity or Grok Build; the exact JSON envelope of Claude Code failures; whether Codex `item.updated` carries partial text; xAI's stream event names; Keychain prompting after a rebuild; `NSAllowsLocalNetworking` for non-loopback hosts; `LSHandlerRank`/"Open With" registration of the hand-made bundle; line-number layouts of real Editorial Manager and ScholarOne PDFs.
