# Step 5a — Foundation of the design pass

Notes of step 5a, alone on `main`: the part of `docs/design-review.md` that the Reader, Sidebar and Shell agents of step 5 build on, namely D16 (shared tokens and `CommonTag`) and the three additions outside the UI, O1–O3. Read by the coordinator and by the three area agents, who start from this step's last commit. The plan's record is Appendix G.8.

## What was added

Everything is additive, with defaults; nothing existing changed meaning except the one colour D16 changes on purpose.

### D16: shared tokens and `CommonTag` (`Sources/RefereeUI/Common/`)

In `CommonTheme.swift`, on `public enum Theme`:

```swift
public static func kindColor(_ kind: CommentKind) -> Color        // .minor now returns .brown (it was .gray); major .red, question .purple, strength .teal as before
public static let tagFont: Font = .caption2.weight(.semibold)
public static let feedbackDuration: Duration = .milliseconds(1_500)
```

A new file, `CommonTag.swift`:

```swift
public struct CommonTag: View {
    public init(_ text: String, color: Color)
    public var body: some View   // Text(text).font(Theme.tagFont).foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 1)
                                 //     .background(color.opacity(0.15), in: Capsule()).fixedSize()
}
```

### O1: where chat and report go (`Sources/AppCore/ReviewSessionModel.swift`)

```swift
public var chatProvider: ProviderDescriptor? { resolveTarget(for: .chat)?.descriptor }
public var reportProvider: ProviderDescriptor? { resolveTarget(for: .report)?.descriptor }
```

### O2: the status of a local active provider (`Sources/AppCore/ReviewSessionModel.swift`)

```swift
public private(set) var activeAvailability: ProviderAvailability?
public func refreshActiveAvailability()
```

### O3: two stand-ins in the snapshot registry (`Sources/TestSupport/SnapshotSupport.swift`)

No public signature changed. `SnapshotSupport.providers()` returns 15 providers instead of 13: the four mocks, the nine static rows, then these two. `SnapshotSupport.settings()` is unchanged and has no entry for either, so both are off.

| id | Type | `displayName` | `authMode`, `isLocal`, `destination` | Behaviour |
| --- | --- | --- | --- | --- |
| `mock-slow` | `MockLLMProvider` | "Mock (slow)" | `.none`, true, "this Mac" | `MockScript.sample` with `delayPerChunk` 40 ms for every purpose, 7 characters a delta: the report (`report_sample.txt`, 162 deltas) takes about 6.5 s, the review (`review_clean.txt`, 372 deltas) about 15 s, a test prompt 40 ms. Status `.ready(detail: "Built in")`, one model "mock" |
| `mock-offline` | `StaticProvider` | "Mock (offline)" | `.none`, true, "this Mac" | Status ``.needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`.")``, one model "mock" (context 1,000,000); `stream` throws `.notConfigured` |

**The snapshot mode still starts no process and makes no request.** `LiveDependencies.make` under `REFEREE_SNAPSHOT=1` uses `SnapshotSupport.providers()` as the whole registry, and the two stand-ins are of the two kinds it had already: a mock that plays its script in-process and a static row that only reports a status. Checked by tests that pass with them: `IntegrationReviewTests.theSnapshotGraphReviewsOnMocksOnly` requires every provider of the snapshot graph to be a `MockLLMProvider` or a `StaticProvider` and the resolver to be `FakeResolver`; `IntegrationSmokeTests.theSnapshotGraphHasTheFourMocksAndNoRealProvider` now also requires `mock-offline`, like the nine rows, to refuse to stream. O2 adds no reach either: in the snapshot graph every local provider whose status the model asks for is a mock or a static row.

## Decisions

Where the review left a choice.

1. **`CommonTag` is public**, as `Theme` is, so §11.3 prints it and the Common tests reach it. It has one initialiser, the review's. Its text is shown as given (`Text(String)`), not looked up as a localisation key.
2. **O2 asks on `isLocal`**, the test that makes the indicator green. Ollama with a base URL that is not on this Mac is not local, so it is not asked either. Its check reads no key: the Ollama adapter never calls the secret closure.
3. **O2's timing.** The model calls `refreshActiveAvailability()` inside `refreshPlan()` at the moment `activeProvider` changes, so also when the model is made: the window's first indicator can show the status. Opening a document with the same provider does not ask again. A remote provider, or none, gives nil at once, before anything else runs.
4. **O2 keeps the last answer of the same provider** while a new check is on its way ("Check Again", the app becoming active), so the indicator does not flicker between green and orange. A provider not asked before starts at nil. An answer that comes after the active provider changed is dropped (a generation counter, as `refreshPlan` has for the plan).
5. **O2 asks off the main actor** (`@concurrent`, as `SettingsModel.refreshAvailability` does) and as a tracked task, so `waitForBackgroundWork()` in the AppCore tests waits for it.
6. **O1 returns nil when the job's provider is not registered or not enabled.** That is `resolveTarget`'s rule, and the job itself would then fail with "Set up an AI provider": a `defaults.chat` naming a provider that is off does not fall back to the review's.
7. **O3's stand-ins are built in (`.none`) and named like the mocks.** `mock-offline` does not carry Ollama's descriptor: two "Ollama (local)" rows could not be told apart in a menu, `SnapshotSupportTests` requires unique names, and with `.local` it would sit in Settings' "Local" group beside the real Ollama row. Both appear in Settings ▸ Providers under "Built in", after the four mocks (snapshot mode only).
8. **O3's `mock-offline` has one model, "mock"**, as the mocks do, so a scene can choose `ProviderRef(providerID: "mock-offline", model: "mock")` and its plan has a context window.

## Changes outside the paths named, and why

- **Tests that pinned the snapshot registry.** The review names three updates; six lines in four files needed one:
  - `Tests/RefereeCoreTests/SnapshotSupportTests.swift`: line 14, the two ids appended, and line 72, `.dropFirst(4).prefix(9)`, as the review says. Also line 16, `providers.dropFirst(4).prefix(9).allSatisfy { $0 is StaticProvider }`, which `mock-slow` (a mock, not a static row) would fail. One new test checks the two stand-ins.
  - `Tests/IntegrationTests/SnapshotRowsTests.swift` line 17, `.dropFirst(4).prefix(9)`, as the review says.
  - `Tests/IntegrationTests/IntegrationSmokeTests.swift` line 38, the snapshot graph's ids, which the review does not name. The loop after it, which checks that no static row can send anything, now covers `mock-offline` too.
  - `Tests/RefereeUITests/Shell/ShellProviderRowsTests.swift` line 53 (`theSnapshotRegistryHasEveryStatusAndTheBuiltInsLast`): the "Built in" group now ends with "mock-slow", "mock-offline", and the doc comment says so. **This is the one change step 5a made in an area's files.** It is not a compile fix, but the test fails without it whatever auth mode `mock-offline` is given: `mock-slow` is a `MockLLMProvider`, always `.none`, so it joins the "Built in" group that the test pins. Nothing else under `Shell/`, `Sidebar/` or `Reader/` changed, and no compile fix was needed.
- `Tests/RefereeUITests/Common/CommonSurfaceCheck.swift` names the new public members (`Theme.tagFont`, `Theme.feedbackDuration`, `CommonTag`, `chatProvider`, `reportProvider`, `activeAvailability`, `refreshActiveAvailability()`), as Gate 1 and Wave 3 did for theirs.
- `plan.md`: §5.9 (the two stand-ins), §9.10 (the tokens and the tag), §11.3 (`SnapshotSupport`, `Theme`, `CommonTag`), Appendix A.9 (O1, O2), Appendix G.8 (new: one row each for D16, O1, O2, O3, pointing to the review). §11.3, Appendix A and the code agree: the surface check compiles against them.

## Contract problems

None.

## For the area agents

### All three

- **Tokens.** `Theme.tagFont` (`.caption2.weight(.semibold)`) and `Theme.feedbackDuration` (1.5 s). `Theme.kindColor(.minor)` is brown: every MINOR badge (`SidebarKindBadge`, the only user of `kindColor`) is brown in the pictures from this commit on, while the rejected line's badge stays grey, since `SidebarKindBadge(muted: true)` uses `.secondary`.
- **`CommonTag(_ text: String, color: Color)`**, one initialiser: `CommonTag("Open access", color: .green)`. Put it in a row as it is; it sizes itself and never wraps or truncates, so give it no padding, background or frame of its own. Its colour fills the capsule at 15% and colours the text.
- **Feedback.** "Copied" and the like: show it, wait `Theme.feedbackDuration`, then return, for example in a `.task(id:)` with `try? await Task.sleep(for: Theme.feedbackDuration)`, so that it is cancelled when the view goes.
- **The snapshot registry has two more providers, both off.** They are never in the destination menu or `selectableProviders` unless a scene enables them; they are listed in Settings ▸ Providers under "Built in". To use one in a scene: enable it through `model.reloadSettings` with `settings.providers["mock-slow"] = ProviderSettings(enabled: true, model: "mock", inputMode: .auto)`, then `model.setActiveProvider(ProviderRef(providerID: "mock-slow", model: "mock"))`, which needs an open session and an enabled provider. The Shell's `ShellSceneSupport.choose(_:in:)` does this second step, with `model: nil` (the entry's model), and waits for the plan.

### Sidebar

- D16: `SidebarTag(text: "You", color: Theme.ownColor)` and `SidebarTag(text: "verify", color: .orange)` in `SidebarCommentCard.swift` become `CommonTag("You", color: Theme.ownColor)` and `CommonTag("verify", color: .orange)`: filled instead of outlined, and 6 points of padding instead of 5, as D16 asks.
- D1: `CommonTag("Revision proposed", color: .accentColor)`.
- D8 and D33: the Copied label for `Theme.feedbackDuration`.
- `design-report-streaming` (O3): `mock-slow` as above, then approve a comment and `generateReport()`. The report job goes to `session.preferredProvider ?? defaults.report ?? defaults.review`, so choosing `mock-slow` with `setActiveProvider` makes it the report's provider too (`model.reportProvider` says so). With the default settle time of 2 s the capture comes about 2 s into a stream of about 6.5 s; `model.streamingReportText` holds what has arrived.

### Shell

- D4 (O1): `model.chatProvider` and `model.reportProvider`, compared by `id` with `model.activeProvider`. Either is nil when that job's provider is not registered or not enabled; the review's `{name}` needs one, so decide what nil shows (the job would fail with "Set up an AI provider"). For `design-review-split-destinations`, `claude-cli` as `defaults.chat` gives `chatProvider?.id == "claude-cli"` while `activeProvider` stays `mock`; a remote provider is never asked for its status.
- D13 (O2): `model.activeAvailability` is nil for a remote provider or none, and for a local one until its first answer; then `.ready`, `.needsSetup(reason:hint:)` or `.unavailable(reason:)`. The model already asks whenever the active provider changes; the window adds `model.refreshActiveAvailability()` on `NSApplication.didBecomeActiveNotification`, and the destination menu when it opens and in "Check Again". In the snapshot graph every local provider answers at once: the mocks and `mock-slow` `.ready(detail: "Built in")`, the static `ollama` row `.ready(detail: "Ollama 0.40.17")`, `mock-offline` `.needsSetup`.
- `design-review-provider-offline` (O3): enable and choose `mock-offline` as above. Its status arrives a moment after the choice, well within the settle time; a `verify` can read ``model.activeAvailability == .needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`.")``.
- D21: "Experimental" becomes `CommonTag("Experimental", color: .orange)`. Today's tag has 5 points of horizontal padding and CommonTag 6, so it grows by a point on each side; otherwise its look is the same (the review's "unchanged in look").
- D21's test-prompt note "by kind": `mock-slow` and `mock-offline` are built in (`.none`), as the mocks are.
- **D25 will stop the build in a frozen file.** `CommonSurfaceCheck.swift` (in `Tests/RefereeUITests/Common/`, line 380) switches exhaustively over `TriageIntent?`, on purpose, so `TriageIntent.nextPending` makes it fail to compile until `.nextPending?` is added to that one `case` line. The Shell agent needs the coordinator's leave to add it, or records it as a contract problem for the merge. §11.3 prints `TriageIntent` too: the docs pass adds the case there.
- `ShellProviderRowsTests.swift` line 53 was changed by step 5a (above); its expectation now names the six built-in providers.

### Reader

- D15: "Open access" becomes `CommonTag("Open access", color: .green)`, green text on a green tint instead of white on green.
- D14: Copy's "Copied" for `Theme.feedbackDuration`.

## Scenes, as seen

`scripts/snapshots.sh`: 46 scenes, the 16 `design-` scenes included, exit 0, each `"nonBlank":true,"failures":[]`. What the pictures show of this step:

- **The minor badge is brown**, on a brown tint, wherever a minor comment is shown: in `sidebar-pending` (the third card, "Position in the debate") and in `sidebar-states` (the unanchored card, beside its "verify" tag). With `--dark`, `sidebar-states` shows a lighter brown, legible on the dark card. The rejected line's badge (STRENGTH in `sidebar-states`) stays grey, so the two no longer look alike; major red, question purple and strength teal are as before. `design-triage-25` has no minor badge in view: around the selected MAJOR are a pending card scrolled to its title and a QUESTION.
- **The two stand-ins in Settings.** The settings scenes list them at the end of "Built in": in `settings-providers` "Mock (slow)" is the last row, cut by the list's bottom edge, and "Mock (offline)" lies below it in the part that scrolls. The rest of the pane is as Wave 3 described it.
- No pane uses `CommonTag`, the two tokens, O1 or O2 yet, so "You", "verify", "Open access" and "Experimental" look as they did, and the indicator is unchanged.

## Acceptance

Final run at commit `83bab0b`, after every Swift file under `Sources/` and `Tests/` had been touched, so that the whole package compiled again and "no warning" covers every file, not only the changed ones. This file's acceptance lines and its paragraph on the snapshot mode were committed after that run; no code changed.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh` | exit 0; every module compiled; no line with "warning:" or "error:" | `Build complete! (7.60s)` |
| `scripts/test.sh` | exit 0; no warning; 991 tests in 137 suites (984 before this step, 7 new); four skipped visibly, as at Wave 3 (real Keychain, live reference services, the delivery experiment, the CLI smoke prompt); `LLMKitLiveOllamaTests` ran, with its one 16-token prompt to the local Ollama server, and passed | `test.sh: OK (991 tests)` |
| `scripts/snapshots.sh` | exit 0; 46 scenes, each `"nonBlank":true,"failures":[]` | `build/snapshots/welcome.png` (the script lists the PNGs) |
| `git status --porcelain \| wc -l` | after the last commit | `0` |

Before that commit, on the same code: `scripts/build.sh` (`Build complete! (4.30s)`); `scripts/test.sh --filter "ReviewSessionModelProviderTests|SnapshotSupportTests|SnapshotRowsTests|IntegrationSmokeTests|CommonThemeTests|ShellProviderRowsTests|SnapshotGraphTests|ShellDestinationTests"`, the suites this step touched (`test.sh: OK (40 tests)`); the full `scripts/test.sh` (`test.sh: OK (991 tests)`); `scripts/snapshots.sh` (46 scenes, exit 0); and `scripts/snapshots.sh --out build/snapshots-dark --scene sidebar-states --scene sidebar-pending --dark` (exit 0, both `"failures":[]`, last line `build/snapshots-dark/sidebar-states.png`).

No network request went anywhere but the local Ollama server, and only from `LLMKitLiveOllamaTests` through `scripts/test.sh`. No AI command-line tool was run and nothing was installed.
