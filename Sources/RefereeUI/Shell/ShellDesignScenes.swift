import SwiftUI
import AppKit
import RefereeCore
import AppCore
import TestSupport

// The Shell's scenes of the design review (docs/design-review.md, step 4): states of the welcome window, the review
// window and Settings that the scenes of plan.md section 10.1 do not show. They stay in the repository as the
// verification scenes of the changes the review proposes (step 5). Each checks in `verify` that the model or the view
// reached the state its picture is meant to show; what the picture must show after a change is in the review.
//
// - design-welcome-first-run: no recent reviews, no provider set up.
// - design-welcome-many: fourteen recent reviews with long titles and journal-system file names; Ollama found.
// - design-review-no-provider: a paper open with every provider switched off.
// - design-review-long-names: a long file name and the longest indicator text (experimental CLI, long model, text only).
// - design-review-parts: a review read in parts (a small context window), stalled in its first part.
// - design-consent-subscription-pdf: the consent card for a subscription CLI that receives the PDF itself.
// - design-banner-provider-down: a local provider that fails at once: the banner, with the indicator still green.
// - design-settings-first-run: Settings ▸ Providers with nothing switched on and no default provider.
//
// Added in step 5, as the review asks:
// - design-review-split-destinations (D4, step 5c): chat goes to Claude Code while the review stays on this Mac:
//   "Custom" over the three jobs.
// - design-review-provider-offline (D13): the chosen local provider reports that it is not running.
// And for the user's requests of step 5b (a model wherever a provider is chosen; "Custom" for a job-by-job choice):
// - design-review-choose-model: a provider and model chosen for the paper, in the title; its models listed, one checked.
// - design-review-custom-menu: the menu of a paper in Custom, the three jobs' destinations, a provider's models.
// And for a finding of the Reader agent at step 5b:
// - design-review-sidebar-returns: the sidebar hidden, then a comment begun from the selection bar's path: it shows again.
// And for venues (step 5, G.9):
// - design-venue-menu: the paper on EC, the toolbar's venue menu open: journals and conferences, EC checked.

@MainActor enum ShellDesignScenes {
    static var all: [SnapshotScene] {
        [welcomeFirstRun, welcomeMany, reviewNoProvider, reviewLongNames, reviewParts, consentSubscriptionPDF, bannerProviderDown,
         settingsFirstRun, reviewSplitDestinations, reviewProviderOffline, reviewChooseModel, reviewCustomMenu, reviewSidebarReturns,
         venueMenu]
    }

    /// An invented journal-system file name, longer than the toolbar can show.
    static let longFileName = "ECTA-D-26-00412R2_Ratings_Herding_and_Price_Discovery_on_a_Sequential_Platform.pdf"
    /// An invented model id, as long as real ones get.
    static let longModel = "example-extended-context-preview"

    // ---- welcome ----

    /// First launch without Ollama: no recent reviews, no provider set up: "Set Up AI Provider…" and its sentence under
    /// the drop hint, and no bottom line (D5); on the right "How it works" (step 5's brand).
    static var welcomeFirstRun: SnapshotScene {
        SnapshotScene(name: "design-welcome-first-run", kind: .welcome, prepare: { context in
            guard let hosting = context.window.contentViewController as? NSHostingController<WelcomeView> else { return }
            hosting.rootView = WelcomeView(recent: [], open: { _ in }, providerLine: { .notSetUp }, openSettings: {})
        }, verify: { context in
            guard let hosting = context.window.contentViewController as? NSHostingController<WelcomeView> else {
                return ["the window does not show a WelcomeView"]
            }
            var failures = ShellSceneSupport.welcomeWindowIsDressed(context)
            if !hosting.rootView.recent.isEmpty { failures.append("\(hosting.rootView.recent.count) recent reviews, expected none") }
            if hosting.rootView.providerLine() != .notSetUp { failures.append("the provider line is \(hosting.rootView.providerLine())") }
            return failures
        })
    }

    /// Fourteen recent reviews with long titles and journal-system file names, and the line "AI: Local · gemma4:e4b"
    /// that a first launch with Ollama running gives. D26: titles on two lines, only "12 pending" in orange; the blinded
    /// submission's file is gone ("File not found").
    static var welcomeMany: SnapshotScene {
        SnapshotScene(name: "design-welcome-many", kind: .welcome, prepare: { context in
            guard let hosting = context.window.contentViewController as? NSHostingController<WelcomeView> else { return }
            let line = ShellDestination.welcomeLine(settings: ollamaSettings(), providers: SnapshotSupport.providers().map(\.descriptor))
            hosting.rootView = WelcomeView(recent: manyRecentReviews(), open: { _ in }, providerLine: { line }, openSettings: {},
                                           missing: [missingReviewID])
        }, verify: { context in
            guard let hosting = context.window.contentViewController as? NSHostingController<WelcomeView> else {
                return ["the window does not show a WelcomeView"]
            }
            var failures = ShellSceneSupport.welcomeWindowIsDressed(context)
            let recent = hosting.rootView.recent
            if recent.count != 14 { failures.append("\(recent.count) recent reviews, expected 14") }
            if hosting.rootView.providerLine() != .configured("AI: Local · gemma4:e4b", isLocal: true) {
                failures.append("the provider line is \(hosting.rootView.providerLine()), expected AI: Local · gemma4:e4b")
            }
            if let first = recent.first {
                let parts = ShellRecentReviewRow.progressParts(first)
                if parts.map(\.text) != ["25 comments", "12 pending"] || parts.map(\.standsOut) != [false, true] {
                    failures.append("the first progress line is \(parts), expected only \"12 pending\" to stand out")
                }
            }
            if hosting.rootView.missing != [missingReviewID] || !recent.contains(where: { $0.id == missingReviewID }) {
                failures.append("the review whose file is gone is not the blinded submission")
            }
            return failures
        })
    }

    /// The blinded submission of `manyRecentReviews`, whose file is gone (D26).
    static let missingReviewID = String(format: "%064x", 12)

    /// The snapshot settings with Ollama switched on, gemma4:e4b chosen and made the review default, as
    /// `applyFirstRunDefaultsIfNeeded` leaves them when Ollama is running.
    static func ollamaSettings() -> AppSettings {
        var settings = SnapshotSupport.settings()
        settings.providers["ollama"] = ProviderSettings(enabled: true, model: "gemma4:e4b", inputMode: .auto)
        settings.defaults = TaskDefaults(review: ProviderRef(providerID: "ollama", model: "gemma4:e4b"))
        return settings
    }

    /// Invented titles and file names; dates and counts that never change. Paths are relative, as in the runner's own two.
    static func manyRecentReviews() -> [SessionSummary] {
        let rows: [(String?, String, Int, Int, Bool)] = [
            ("Ratings, Herding and Price Discovery on a Sequential Platform: Evidence from a Staggered Change in How Ratings Are Displayed",
             "JEEA-D-26-00412_R1.pdf", 25, 12, false),
            ("Information Aggregation in Sequential Markets", "ECTA-2026-0731.pdf", 18, 0, true),
            ("Learning from Reviews When Sellers Choose What to Show", "AER-2026-1188_manuscript.pdf", 0, 0, false),
            ("Disclosure Rules and the Speed of Social Learning", "RESTUD-MS-26-117.pdf", 9, 9, false),
            ("Platform Design, Search Frictions and Price Dispersion in Used-Equipment Markets", "QJE-26-0219.pdf", 31, 4, true),
            ("Cascades with Costly Information Acquisition", "TE-2026-0098.pdf", 14, 0, true),
            ("A Note on Bounded Signals", "JET-D-26-00051.pdf", 6, 2, false),
            ("Who Reads the Histogram? Attention and Rating Displays", "MS-2026-4410.R2.pdf", 22, 0, true),
            ("Sequential Auctions with Observable Bids: An Experiment", "GEB-D-26-00213.pdf", 11, 11, false),
            ("Reputation, Entry and the Value of a Clean Record", "RAND-26-071.pdf", 17, 1, true),
            ("Persuasion by Summary Statistics", "AEJMicro-2026-0302.pdf", 5, 0, false),
            (nil, "submission_8812_blinded.pdf", 3, 3, false),
            ("The Informational Content of Star Ratings: Theory and Evidence from Twenty-Four Product Categories",
             "JPE-26-1044_R3.pdf", 28, 0, true),
            ("Herding in Thin Markets", "IER-26-0187.pdf", 8, 0, true),
        ]
        return rows.enumerated().map { index, row in
            SessionSummary(id: String(format: "%064x", index + 1), fileName: row.1, title: row.0, lastKnownPath: "Manuscripts/" + row.1,
                           updatedAt: Date(timeIntervalSince1970: 1_795_000_000 - Double(index) * 190_000),
                           commentCount: row.2, pendingCount: row.3, hasReport: row.4)
        }
    }

    // ---- review windows ----

    /// Every provider switched off and no default: the indicator says "No AI provider", Review is disabled, and the
    /// Comments tab has nothing to offer but its empty line.
    static var reviewNoProvider: SnapshotScene {
        SnapshotScene(name: "design-review-no-provider", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            var settings = model.settings
            for id in Array(settings.providers.keys) { settings.providers[id]?.enabled = false }
            settings.defaults = TaskDefaults()
            model.reloadSettings(settings)
            await ShellSceneSupport.wait { model.activeProvider == nil }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures = ShellSceneSupport.indicator(of: model, text: ShellDestination.noProvider, tint: .grey)
            if model.canStartReview { failures.append("Review is enabled without a provider") }
            if !model.selectableProviders.isEmpty { failures.append("\(model.selectableProviders.count) providers can be chosen, expected none") }
            // D5: with nothing switched on, the indicator still opens Settings (not "Choose AI provider").
            let state = ShellDestination.state(of: model)
            if !state.opensSettings || state.symbol != "nosign" { failures.append("the indicator does not lead to Settings: \(state)") }
            return failures
        })
    }

    /// The longest texts the toolbar meets: a journal-system file name as the title, and an experimental subscription CLI
    /// with a long model id that receives extracted text. D3: "Antigravity" over the detail, cut in the middle, at most
    /// 260 points wide, so that Review, Report and the sidebar button stay in the toolbar at 1,000 points.
    static var reviewLongNames: SnapshotScene {
        SnapshotScene(name: "design-review-long-names", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            context.window.title = longFileName
            var settings = model.settings
            settings.providers["antigravity-cli"] = ProviderSettings(enabled: true, model: longModel, inputMode: .auto)
            model.reloadSettings(settings)
            await ShellSceneSupport.choose("antigravity-cli", in: model)
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures = ShellSceneSupport.indicator(of: model, text: "Antigravity · \(longModel) · text only · experimental", tint: .orange)
            failures += ShellSceneSupport.indicatorLines(of: model, title: "Antigravity", detail: "\(longModel) · text only · experimental")
            if context.window.title != longFileName { failures.append("the window's title is \(context.window.title)") }
            // Step 5, G.9: the venue control beside the indicator, and still nothing in the toolbar's overflow.
            let venue = ShellVenueState(venue: model.currentVenue, hasPaper: model.session != nil)
            if venue.title != "Journal" || !venue.isEnabled { failures.append("the venue control reads \(venue.title)") }
            failures += ShellSceneSupport.toolbarFits(context)
            return failures
        })
    }

    /// A review read in parts, as phi4's 16,384 tokens read a 16-page paper (README): `mock-stall` with a context
    /// window small enough for three parts of `ay_long.pdf`, stalled in the first. The toolbar shows a gauge,
    /// "Reading part 1 of 3 · 0:0x" and Stop (D9).
    static var reviewParts: SnapshotScene {
        SnapshotScene(name: "design-review-parts", kind: .review, fixturePDF: "ay_long.pdf", prepare: { context in
            guard let model = context.model else { return }
            var settings = model.settings
            settings.providers["mock-stall"]?.contextWindowOverride = 24_000
            model.reloadSettings(settings)
            await ShellSceneSupport.choose("mock-stall", in: model)
            await ShellSceneSupport.wait { (model.sendPlan?.requestCount ?? 0) > 1 }
            model.startReview()
            await ShellSceneSupport.wait(seconds: 10) { !model.drafts.isEmpty }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures: [String] = []
            if case .running(.review, .reading(let part, let total)?, let startedAt) = model.runState, total > 1 {
                let text = ShellReviewButton.progressText(kind: .review, phase: .reading(part: part, of: total),
                                                          elapsed: Date().timeIntervalSince(startedAt))
                if !text.hasPrefix("Reading part \(part) of \(total) · 0:0") { failures.append("the progress reads \(text)") }
                if ShellReviewButton.gauge(kind: .review, phase: .reading(part: part, of: total)) == nil { failures.append("no gauge") }
            } else {
                failures.append("the review is not reading the paper in parts: \(model.runState)")
            }
            model.cancelRun()
            return failures
        })
    }

    /// The consent card for a subscription CLI that receives the PDF file itself (Claude Code): what (the file, its size
    /// and pages), to whom ("Anthropic, through Claude Code"), the requests, what is kept, and "Send to Anthropic" (D12).
    /// Answered "no" in `verify`; nothing is sent.
    static var consentSubscriptionPDF: SnapshotScene {
        SnapshotScene(name: "design-consent-subscription-pdf", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            var settings = model.settings
            settings.providers["claude-cli"] = ProviderSettings(enabled: true, inputMode: .auto)
            model.reloadSettings(settings)
            await ShellSceneSupport.choose("claude-cli", in: model)
            model.startReview()
            await ShellSceneSupport.wait { model.consentRequest != nil }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            guard let request = model.consentRequest else { return ["no consent card"] }
            var failures: [String] = []
            if request.provider.id != "claude-cli" { failures.append("the card asks about \(request.provider.id)") }
            if !request.plan.sendsPDF { failures.append("the plan sends extracted text; the PDF case was expected") }
            let text = ShellPlanText.consent(request: request, pageCount: model.paper?.ref.pageCount ?? 0, byteCount: model.paper?.ref.byteCount ?? 0)
            failures += ShellSceneSupport.facts(text.facts, labels: ["What", "To", "Requests", "Kept"])
            if text.facts.first?.value.hasPrefix("The PDF file · ") != true { failures.append("What reads \(text.facts.first?.value ?? "nothing")") }
            if text.facts.dropFirst().first?.value != "Anthropic, through Claude Code" { failures.append("To reads \(text.facts.dropFirst().first?.value ?? "nothing")") }
            if text.facts.last?.value != request.provider.retentionNote { failures.append("Kept is not Claude Code's retention note") }
            if text.sendButton != "Send to Anthropic" { failures.append("the send button reads \(text.sendButton)") }
            if model.session?.runs.isEmpty != true { failures.append("a run was recorded before consent") }
            model.answerConsent(granted: false)
            return failures
        })
    }

    /// A local provider that fails at once (the snapshot graph's Ollama stand-in can only report a status): the error
    /// banner with Retry, while the indicator went on saying "Local · gemma4:e4b" in green (decision e of Wave 3).
    static var bannerProviderDown: SnapshotScene {
        SnapshotScene(name: "design-banner-provider-down", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            var settings = model.settings
            settings.providers["ollama"] = ProviderSettings(enabled: true, model: "gemma4:e4b", inputMode: .auto)
            model.reloadSettings(settings)
            await ShellSceneSupport.choose("ollama", in: model)
            model.startReview()
            await ShellSceneSupport.wait(seconds: 10) { model.runState == .idle && model.banner != nil }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            guard let banner = model.banner else { return ["no banner"] }
            var failures: [String] = []
            if banner.style != .error { failures.append("the banner is not an error") }
            if banner.action != .retry { failures.append("the banner has no Retry") }
            if !banner.message.hasPrefix("Review stopped: ") { failures.append("the banner says \(banner.message)") }
            // The snapshot graph's Ollama row answers "ready" to the status check of D13: the indicator stays green.
            failures += ShellSceneSupport.indicator(of: model, text: "Local · gemma4:e4b", tint: .green)
            return failures
        })
    }

    /// D4, in Custom (the paper has no provider of its own, as every new paper): the review stays with "mock" on this
    /// Mac while chat goes to Claude Code (`defaults.chat`). The indicator, menu closed (step 5c): "Custom" over
    /// "Review: this Mac · Chat: Claude Code · Report: this Mac", orange. Claude Code is never asked for its status.
    static var reviewSplitDestinations: SnapshotScene {
        SnapshotScene(name: "design-review-split-destinations", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            var settings = model.settings
            settings.providers["claude-cli"] = ProviderSettings(enabled: true, inputMode: .auto)
            settings.defaults.chat = ProviderRef(providerID: "claude-cli", model: nil)
            model.reloadSettings(settings)
            await ShellSceneSupport.wait { model.chatProvider?.id == "claude-cli" && model.sendPlan != nil }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            let line = "Review: this Mac · Chat: Claude Code · Report: this Mac"
            var failures = ShellSceneSupport.indicator(of: model, text: "Custom · " + line, tint: .orange)
            failures += ShellSceneSupport.indicatorLines(of: model, title: "Custom", detail: line)
            if !model.usesCustomProviders { failures.append("the paper has a provider of its own") }
            if model.activeProvider?.id != "mock" { failures.append("the review goes to \(model.activeProvider?.id ?? "nothing")") }
            if model.reportProvider?.id != "mock" { failures.append("the report goes to \(model.reportProvider?.id ?? "nothing")") }
            if ShellDestinationMenu.otherJobLines(model) != ["Chat questions go to Claude Code (subscription)."] {
                failures.append("the menu says \(ShellDestinationMenu.otherJobLines(model))")
            }
            return failures
        })
    }

    /// Step 5b, the user's request: the destination menu of a paper in Custom whose three jobs go to three places (the
    /// review to "mock" on this Mac, chat to Claude Code with sonnet, the report to Anthropic API with Example Large).
    /// Custom checked, the three listed under it, "Edit in Settings…"; Anthropic API's models listed (Example Large,
    /// Example Small), none checked, since the paper has chosen no provider. Nothing is asked of the remote providers.
    static var reviewCustomMenu: SnapshotScene {
        SnapshotScene(name: "design-review-custom-menu", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            var settings = model.settings
            settings.providers["claude-cli"] = ProviderSettings(enabled: true, inputMode: .auto)
            settings.providers["anthropic-api"] = ProviderSettings(enabled: true, model: "example-large", inputMode: .auto,
                                                                   cachedModels: anthropicModels, cachedModelsAt: Date())
            settings.defaults.chat = ProviderRef(providerID: "claude-cli", model: "sonnet")
            settings.defaults.report = ProviderRef(providerID: "anthropic-api", model: "example-large")
            model.reloadSettings(settings)
            await ShellSceneSupport.wait { model.reportProvider?.id == "anthropic-api" && model.sendPlan != nil }
            ShellSceneSupport.openDestinationMenu(context, expanding: "anthropic-api")
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures = ShellSceneSupport.indicatorLines(of: model, title: "Custom",
                                                            detail: "Review: this Mac · Chat: Claude Code · Report: Anthropic")
            if !model.usesCustomProviders || ShellDestinationMenu.chosenRef(model) != nil { failures.append("the paper is not in Custom") }
            let custom = ShellCustomDestinations.lines(settings: model.settings,
                                                       providers: ShellDestinationMenu.knownProviders(model, services: ShellWindowServices()))
            if custom != ["Review: Mock · mock", "Chat: Claude Code · sonnet", "Report: Anthropic API · Example Large"] {
                failures.append("Custom says \(custom)")
            }
            let models = ShellModelChoices.menu(for: "anthropic-api", settings: model.settings, current: ShellDestinationMenu.chosenRef(model))
            if models.choices.map(\.title) != ["Default model (Example Large)", "Example Large", "Example Small"] {
                failures.append("Anthropic API offers \(models.choices.map(\.title))")
            }
            let state = ShellSceneSupport.windowState(context)
            if state?.destinationMenuOpen != true || state?.expandedProvider != "anthropic-api" { failures.append("the menu does not list Anthropic API's models") }
            return failures
        })
    }

    /// Anthropic API's list in `design-review-custom-menu`, as the snapshot graph's static row gives it.
    static let anthropicModels = [ModelInfo(id: "example-large", displayName: "Example Large", contextWindow: 1_000_000, supportsPDFInput: true),
                                  ModelInfo(id: "example-small", displayName: "Example Small", contextWindow: 200_000, supportsPDFInput: true)]

    /// D13 (with O3's stand-in): `mock-offline`, a local provider whose status is "Ollama is not running", switched on and
    /// chosen. The indicator: an orange triangle, "Local" over "Ollama is not running"; the destination menu open, its
    /// row with the reason in orange and Check Again.
    static var reviewProviderOffline: SnapshotScene {
        SnapshotScene(name: "design-review-provider-offline", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            var settings = model.settings
            settings.providers["mock-offline"] = ProviderSettings(enabled: true, model: "mock", inputMode: .auto)
            model.reloadSettings(settings)
            await ShellSceneSupport.choose("mock-offline", in: model)
            await ShellSceneSupport.wait { model.activeAvailability == offlineStatus }
            ShellSceneSupport.openDestinationMenu(context)
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures = ShellSceneSupport.indicator(of: model, text: "Local · Ollama is not running", tint: .orange)
            failures += ShellSceneSupport.indicatorLines(of: model, title: "Local", detail: "Ollama is not running")
            let state = ShellDestination.state(of: model)
            if state.symbol != "exclamationmark.triangle.fill" { failures.append("the indicator's symbol is \(state.symbol)") }
            if state.help != "Ollama is not running. Start the Ollama app or run ollama serve." { failures.append("the tooltip reads \(state.help)") }
            if model.activeAvailability != offlineStatus { failures.append("the provider's status is \(String(describing: model.activeAvailability))") }
            if ShellSceneSupport.windowState(context)?.destinationMenuOpen != true { failures.append("the destination menu is not open") }
            return failures
        })
    }

    /// The status of O3's `mock-offline`.
    static let offlineStatus = ProviderAvailability.needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`.")

    /// Step 5b: Ollama's list as Settings keeps it, ten models (the snapshot graph's two and eight invented ones), and
    /// the paper reviewed with phi4. The destination menu open: under Ollama's row "Default model (gemma4:e4b)", the
    /// first eight models with phi4 checked, and "More in Settings…"; the indicator "Local" over "phi4". The menu reads
    /// the list Settings keeps; nothing is asked of the provider.
    static var reviewChooseModel: SnapshotScene {
        SnapshotScene(name: "design-review-choose-model", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            var settings = model.settings
            settings.providers["ollama"] = ProviderSettings(enabled: true, model: "gemma4:e4b", inputMode: .auto, cachedModels: ollamaModels,
                                                            cachedModelsAt: Date())
            model.reloadSettings(settings)
            model.setActiveProvider(ProviderRef(providerID: "ollama", model: "phi4"))
            await ShellSceneSupport.wait { model.activeProvider?.id == "ollama" && model.activeModel == "phi4" && model.sendPlan != nil }
            ShellSceneSupport.openDestinationMenu(context)
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures = ShellSceneSupport.indicator(of: model, text: "Local · phi4", tint: .green)
            if model.session?.preferredProvider != ProviderRef(providerID: "ollama", model: "phi4") || model.usesCustomProviders {
                failures.append("the paper's choice is \(String(describing: model.session?.preferredProvider))")
            }
            if model.chatProvider?.id != "ollama" || model.reportProvider?.id != "ollama" { failures.append("chat or the report goes elsewhere") }
            let menu = ShellModelChoices.menu(for: "ollama", settings: model.settings, current: ShellDestinationMenu.chosenRef(model))
            let titles = menu.choices.map(\.title)
            if titles.first != "Default model (gemma4:e4b)" || titles.count != 9 { failures.append("the models offered are \(titles)") }
            if menu.settingsRow != ShellModelChoices.moreInSettings { failures.append("the last row is \(menu.settingsRow ?? "missing")") }
            let checked = menu.choices.filter { $0.ref == ShellDestinationMenu.chosenRef(model) }.map(\.title)
            if checked != ["phi4"] { failures.append("checked: \(checked), expected phi4") }
            let state = ShellSceneSupport.windowState(context)
            if state?.destinationMenuOpen != true || state?.expandedProvider != "ollama" { failures.append("the menu does not list Ollama's models") }
            return failures
        })
    }

    /// The sidebar hidden by hand, then a comment of one's own begun (`beginComposingComment()`, what the selection bar's
    /// Comment and N call): the sidebar shows again, with the new comment's card, rather than taking it out of sight.
    static var reviewSidebarReturns: SnapshotScene {
        SnapshotScene(name: "design-review-sidebar-returns", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model, let state = ShellSceneSupport.windowState(context) else { return }
            state.showSidebar = false
            await ShellSceneSupport.wait(seconds: 0.5) { false }          // the window lays itself out without the sidebar
            model.beginComposingComment()
            await ShellSceneSupport.wait { state.showSidebar }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures: [String] = []
            if ShellSceneSupport.windowState(context)?.showSidebar != true { failures.append("the sidebar stayed hidden") }
            if model.composing == nil { failures.append("no comment is being written") }
            if model.sidebarTab != .comments { failures.append("the sidebar shows \(model.sidebarTab)") }
            return failures
        })
    }

    /// Ollama's list in `design-review-choose-model`: the snapshot graph's two models, then eight invented ones.
    static let ollamaModels: [ModelInfo] = [
        ModelInfo(id: "gemma4:e4b", displayName: "gemma4:e4b", contextWindow: 131_072, supportsPDFInput: false),
        ModelInfo(id: "phi4", displayName: "phi4", contextWindow: 16_384, supportsPDFInput: false),
    ] + (1...8).map { ModelInfo(id: "example-local-\($0)", displayName: "example-local-\($0)", contextWindow: 32_768, supportsPDFInput: false) }

    // ---- venues (step 5, G.9) ----

    /// The paper on EC, the venue menu open under the toolbar's control: "Review this paper for", the journals (Journal
    /// (unspecified), Journal of Economic Theory · JET), the conferences (Conference (unspecified), ACM Conference on
    /// Economics and Computation · EC, checked), "Edit Venues…". The control reads "EC"; nothing is in the overflow.
    static var venueMenu: SnapshotScene {
        SnapshotScene(name: "design-venue-menu", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            await ShellSceneSupport.wait { model.session != nil && model.sendPlan != nil }
            model.setVenue(id: "ec")
            if let state = ShellSceneSupport.windowState(context), !state.venueMenuOpen { state.toggleVenueMenu() }
        }, verify: { context in
            guard let model = context.model, let state = ShellSceneSupport.windowState(context) else { return ["a review scene without a model"] }
            var failures: [String] = []
            if !state.venueMenuOpen || state.destinationMenuOpen { failures.append("the venue menu is not the menu open") }
            if model.currentVenue.id != "ec" { failures.append("the paper's venue is \(model.currentVenue.id)") }
            if model.session?.meta.venueID != "ec" || model.session?.meta.targetVenue != "ACM Conference on Economics and Computation (EC)" {
                failures.append("the paper's metadata names \(model.session?.meta.venueID ?? "no venue")")
            }
            let control = ShellVenueState(venue: model.currentVenue, hasPaper: true)
            if control.title != "EC" || control.symbol != "person.3" { failures.append("the control reads \(control.title) with \(control.symbol)") }
            if !control.help.contains("ACM Conference on Economics and Computation (EC)") { failures.append("the tooltip reads \(control.help)") }
            let groups = ShellVenueMenu.groups(model.venues).map { ($0.title, $0.venues.map(\.id)) }
            if groups.map(\.0) != ["Journals", "Conferences"] || groups.map(\.1) != [["journal", "jet"], ["conference", "ec"]] {
                failures.append("the menu's groups are \(groups)")
            }
            failures += ShellSceneSupport.toolbarFits(context)
            return failures
        })
    }

    // ---- settings ----

    /// Settings ▸ Providers on a first launch without Ollama: nothing switched on, no default provider. D21: the box
    /// "Start with a local model…" above the list, and the pane opens on Ollama by itself.
    static var settingsFirstRun: SnapshotScene {
        SnapshotScene(name: "design-settings-first-run", kind: .settings, prepare: { context in
            guard let model = context.settings else { return }
            model.update { settings in
                for id in Array(settings.providers.keys) { settings.providers[id]?.enabled = false }
                settings.defaults = TaskDefaults()
            }
            ShellSceneSupport.navigation(context)?.tab = .providers
            await model.refreshAvailability(of: nil)
        }, verify: { context in
            guard let model = context.settings else { return ["a settings scene without a settings model"] }
            var failures: [String] = []
            let enabled = model.settings.providers.filter { $0.value.enabled }.map(\.key).sorted()
            if !enabled.isEmpty { failures.append("providers switched on: \(enabled.joined(separator: ", "))") }
            if model.settings.defaults.review != nil { failures.append("a review default is set") }
            if !ShellProviderRows.noneSwitchedOn(model.providers, settings: model.settings) { failures.append("the start box is not shown") }
            if ShellSceneSupport.navigation(context)?.provider != ShellProviderRows.localStart { failures.append("the pane does not show Ollama") }
            return failures
        })
    }
}
