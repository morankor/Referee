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

@MainActor enum ShellDesignScenes {
    static var all: [SnapshotScene] {
        [welcomeFirstRun, welcomeMany, reviewNoProvider, reviewLongNames, reviewParts, consentSubscriptionPDF, bannerProviderDown,
         settingsFirstRun]
    }

    /// An invented journal-system file name, longer than the toolbar can show.
    static let longFileName = "ECTA-D-26-00412R2_Ratings_Herding_and_Price_Discovery_on_a_Sequential_Platform.pdf"
    /// An invented model id, as long as real ones get.
    static let longModel = "example-extended-context-preview"

    // ---- welcome ----

    /// First launch without Ollama: no recent reviews, "No AI provider set up".
    static var welcomeFirstRun: SnapshotScene {
        SnapshotScene(name: "design-welcome-first-run", kind: .welcome, prepare: { context in
            guard let hosting = context.window.contentViewController as? NSHostingController<WelcomeView> else { return }
            hosting.rootView = WelcomeView(recent: [], open: { _ in }, providerLine: { .notSetUp }, openSettings: {})
        }, verify: { context in
            guard let hosting = context.window.contentViewController as? NSHostingController<WelcomeView> else {
                return ["the window does not show a WelcomeView"]
            }
            var failures: [String] = []
            if !hosting.rootView.recent.isEmpty { failures.append("\(hosting.rootView.recent.count) recent reviews, expected none") }
            if hosting.rootView.providerLine() != .notSetUp { failures.append("the provider line is \(hosting.rootView.providerLine())") }
            return failures
        })
    }

    /// Fourteen recent reviews with long titles and journal-system file names, and the line "AI: Local · gemma4:e4b"
    /// that a first launch with Ollama running gives.
    static var welcomeMany: SnapshotScene {
        SnapshotScene(name: "design-welcome-many", kind: .welcome, prepare: { context in
            guard let hosting = context.window.contentViewController as? NSHostingController<WelcomeView> else { return }
            let line = ShellDestination.welcomeLine(settings: ollamaSettings(), providers: SnapshotSupport.providers().map(\.descriptor))
            hosting.rootView = WelcomeView(recent: manyRecentReviews(), open: { _ in }, providerLine: { line }, openSettings: {})
        }, verify: { context in
            guard let hosting = context.window.contentViewController as? NSHostingController<WelcomeView> else {
                return ["the window does not show a WelcomeView"]
            }
            var failures: [String] = []
            if hosting.rootView.recent.count != 14 { failures.append("\(hosting.rootView.recent.count) recent reviews, expected 14") }
            if hosting.rootView.providerLine() != .configured("AI: Local · gemma4:e4b", isLocal: true) {
                failures.append("the provider line is \(hosting.rootView.providerLine()), expected AI: Local · gemma4:e4b")
            }
            return failures
        })
    }

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
            return failures
        })
    }

    /// The longest texts the toolbar meets: a journal-system file name as the title, and an experimental subscription CLI
    /// with a long model id that receives extracted text.
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
            if context.window.title != longFileName { failures.append("the window's title is \(context.window.title)") }
            return failures
        })
    }

    /// A review read in parts, as phi4's 16,384 tokens read a 16-page paper (README): `mock-stall` with a context
    /// window small enough for three parts of `ay_long.pdf`, stalled in the first. The toolbar shows the phase.
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
            if case .running(.review, .reading(_, let total)?, _) = model.runState, total > 1 {} else {
                failures.append("the review is not reading the paper in parts: \(model.runState)")
            }
            model.cancelRun()
            return failures
        })
    }

    /// The consent card for a subscription CLI that receives the PDF file itself (Claude Code): the file's size and
    /// pages, the request count, the retention line of a CLI. Answered "no" in `verify`; nothing is sent.
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
            return failures
        })
    }

    // ---- settings ----

    /// Settings ▸ Providers on a first launch without Ollama: nothing switched on, no default provider, Ollama shown.
    static var settingsFirstRun: SnapshotScene {
        SnapshotScene(name: "design-settings-first-run", kind: .settings, prepare: { context in
            guard let model = context.settings else { return }
            model.update { settings in
                for id in Array(settings.providers.keys) { settings.providers[id]?.enabled = false }
                settings.defaults = TaskDefaults()
            }
            ShellSceneSupport.navigation(context)?.tab = .providers
            ShellSceneSupport.navigation(context)?.provider = "ollama"
            await model.refreshAvailability(of: nil)
        }, verify: { context in
            guard let model = context.settings else { return ["a settings scene without a settings model"] }
            var failures: [String] = []
            let enabled = model.settings.providers.filter { $0.value.enabled }.map(\.key).sorted()
            if !enabled.isEmpty { failures.append("providers switched on: \(enabled.joined(separator: ", "))") }
            if model.settings.defaults.review != nil { failures.append("a review default is set") }
            if ShellSceneSupport.navigation(context)?.provider != "ollama" { failures.append("the pane does not show Ollama") }
            return failures
        })
    }
}
