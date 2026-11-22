import SwiftUI
import PDFKit
import RefereeCore
import AppCore
import TestSupport

// The Shell's scenes of the snapshot mode (plan.md section 10.1). "placeholder" is Wave 0's check of the runner and
// stays exactly as it is: it is in the scene table of section 10.1, and a test in Tests/RefereeUITests/Common, which
// WP11 does not own, checks it. The seven scenes of WP11 follow, then five more that show parts of the Shell the
// required ones do not (the other two settings tabs, a provider with a stored key, the destination menu, a running
// review). A scene that needs a tab or a menu reaches the window's own state through its hosting controller.

@MainActor public enum ShellScenes {
    public static var all: [SnapshotScene] {
        [
            SnapshotScene(name: "placeholder", kind: .review, fixturePDF: "ay_round_nolinks.pdf", verify: { context in
                guard let document = context.reader?.pdfView.document else { return ["the display document is not loaded"] }
                return document.pageCount == 4 ? [] : ["the display document has \(document.pageCount) pages, expected 4"]
            }),
            welcome,
            reviewEmpty,
            consent,
            bannerError,
            settings("settings-providers", tab: .providers, provider: "antigravity-cli"),
            settings("settings-prompts", tab: .prompts),
            settings("settings-privacy", tab: .privacy),
            settings("settings-references", tab: .references),
            settings("settings-advanced", tab: .advanced),
            settingsAPIKey,
            reviewDestinationMenu,
            reviewRunning,
        ]
    }

    // ---- welcome ----

    /// The welcome window with the runner's two recent reviews. The runner makes it with the public initialiser, which
    /// knows no provider; the scene gives it the line the snapshot settings would give ("AI: Local · mock").
    static var welcome: SnapshotScene {
        SnapshotScene(name: "welcome", kind: .welcome, prepare: { context in
            guard let hosting = context.window.contentViewController as? NSHostingController<WelcomeView> else { return }
            let shown = hosting.rootView
            let line = ShellDestination.welcomeLine(settings: SnapshotSupport.settings(), providers: SnapshotSupport.providers().map(\.descriptor))
            hosting.rootView = WelcomeView(recent: shown.recent, open: shown.open, providerLine: { line }, openSettings: {})
        }, verify: { context in
            guard let hosting = context.window.contentViewController as? NSHostingController<WelcomeView> else {
                return ["the window does not show a WelcomeView"]
            }
            var failures: [String] = []
            if hosting.rootView.recent.count != 2 { failures.append("\(hosting.rootView.recent.count) recent reviews, expected 2") }
            if hosting.rootView.providerLine() != .configured("AI: Local · mock", isLocal: true) {
                failures.append("the provider line is \(hosting.rootView.providerLine()), expected AI: Local · mock")
            }
            return failures
        })
    }

    // ---- review windows ----

    /// `ay_round_nolinks.pdf` open, no comments, the indicator "Local · mock" in green, Review enabled.
    static var reviewEmpty: SnapshotScene {
        SnapshotScene(name: "review-empty", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            await ShellSceneSupport.wait { model.sendPlan != nil }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures = ShellSceneSupport.indicator(of: model, text: "Local · mock", tint: .green)
            if model.session?.comments.isEmpty != true { failures.append("the session has comments") }
            if !model.canStartReview { failures.append("Review is disabled: \(ShellReviewButton.disabledReason(model))") }
            if let banner = model.banner { failures.append("a banner is shown: \(banner.message)") }
            return failures
        })
    }

    /// `setActiveProvider("mock-remote")`, `startReview()`: the consent card, with the text-only sentence. Nothing is sent.
    static var consent: SnapshotScene {
        SnapshotScene(name: "consent", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            await ShellSceneSupport.choose("mock-remote", in: model)
            model.startReview()
            await ShellSceneSupport.wait { model.consentRequest != nil }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures = ShellSceneSupport.indicator(of: model, text: "Mock (remote) · mock · text only", tint: .orange)
            guard let request = model.consentRequest else { return failures + ["no consent card"] }
            let text = ShellPlanText.consent(request: request, pageCount: model.paper?.ref.pageCount ?? 0, byteCount: model.paper?.ref.byteCount ?? 0)
            if request.provider.id != "mock-remote" { failures.append("the card asks about \(request.provider.id)") }
            if request.plan.sendsPDF { failures.append("the plan sends the PDF; the text-only case was expected") }
            if !text.what.hasSuffix(ShellPlanText.textOnlyWarning) { failures.append("the card lacks the text-only sentence: \(text.what)") }
            if text.title != "Send this manuscript to Mock?" { failures.append("the title is \(text.title)") }
            if model.session?.runs.isEmpty != true { failures.append("a run was recorded before consent") }
            model.answerConsent(granted: false)
            return failures
        })
    }

    /// `setActiveProvider("mock-fail")`, review: the banner "Review stopped: …" with Retry above the PDF; the two
    /// comments received before the failure are kept (the sidebar of Wave 2 is a placeholder here, so the count is
    /// checked against the model).
    static var bannerError: SnapshotScene {
        SnapshotScene(name: "banner-error", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            await ShellSceneSupport.choose("mock-fail", in: model)
            model.startReview()
            await ShellSceneSupport.wait(seconds: 10) { model.runState == .idle && model.banner != nil }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures: [String] = []
            guard let banner = model.banner else { return ["no banner"] }
            if banner.style != .error { failures.append("the banner is not an error") }
            if !banner.message.hasPrefix("Review stopped: ") { failures.append("the banner says \(banner.message)") }
            if banner.action != .retry { failures.append("the banner has no Retry") }
            let comments = model.session?.comments.count ?? 0
            if comments != 2 { failures.append("\(comments) comments kept, expected 2") }
            if case .failed? = model.session?.runs.last?.status {} else { failures.append("the run is not recorded as failed") }
            return failures
        })
    }

    /// The destination menu open, with a remote provider chosen: the providers, the plan sentence with the text-only
    /// sentence, the retention note, Local only and "Privacy Settings…".
    static var reviewDestinationMenu: SnapshotScene {
        SnapshotScene(name: "review-destination-menu", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            await ShellSceneSupport.choose("mock-remote", in: model)
            ShellSceneSupport.windowState(context)?.destinationMenuOpen = true
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures: [String] = []
            if ShellSceneSupport.windowState(context)?.destinationMenuOpen != true { failures.append("the destination menu is not open") }
            let choices = Set(model.selectableProviders.map(\.id))
            if choices != ["mock", "mock-remote", "mock-fail", "mock-stall", "ollama"] {
                failures.append("the providers to choose are \(choices.sorted()), expected the four mocks and Ollama")
            }
            guard let provider = model.activeProvider, let plan = model.sendPlan else { return failures + ["no plan for the menu"] }
            let lines = ShellPlanText.menuLines(plan: plan, descriptor: provider)
            if lines.first?.text.hasSuffix(ShellPlanText.textOnlyWarning) != true { failures.append("the plan sentence lacks the text-only sentence") }
            return failures
        })
    }

    /// `mock-stall`: the review lane runs; the toolbar shows the phase, a spinner and Cancel.
    static var reviewRunning: SnapshotScene {
        SnapshotScene(name: "review-running", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            await ShellSceneSupport.choose("mock-stall", in: model)
            model.startReview()
            await ShellSceneSupport.wait { !model.drafts.isEmpty }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures: [String] = []
            if case .running(.review, _, _) = model.runState {} else { failures.append("no review is running") }
            model.cancelRun()
            return failures
        })
    }

    // ---- settings ----

    /// A settings tab, with every provider's status checked first.
    static func settings(_ name: String, tab: ShellSettingsTab, provider: ProviderID? = nil) -> SnapshotScene {
        SnapshotScene(name: name, kind: .settings, prepare: { context in
            guard let model = context.settings else { return }
            ShellSceneSupport.navigation(context)?.tab = tab
            ShellSceneSupport.navigation(context)?.provider = provider
            await model.refreshAvailability(of: nil)
            if tab == .references { await model.refreshPDFCacheSize() }
        }, verify: { context in
            guard let model = context.settings else { return ["a settings scene without a settings model"] }
            var failures: [String] = []
            if ShellSceneSupport.navigation(context)?.tab != tab { failures.append("the window does not show \(tab.title)") }
            switch tab {
            case .providers:
                let lights = Set(model.providers.map { ShellProviderRows.status(model.availability[$0.id]).light })
                for light in [ShellProviderStatus.Light.green, .yellow, .red] where !lights.contains(light) {
                    failures.append("no provider row is \(light)")
                }
                let experimental = model.providers.filter { ShellProviderRows.showsExperimentalWarning($0, settings: model.settings.providers[$0.id]) }
                if experimental.isEmpty { failures.append("no provider shows the experimental warning") }
                if let provider, !experimental.contains(where: { $0.id == provider }) {
                    failures.append("the provider shown, \(provider), has no experimental warning")
                }
            case .privacy:
                if model.dataDirectory == nil { failures.append("the data folder is not known") }
            case .references:
                if model.pdfCacheBytes == nil { failures.append("the size of the downloaded papers is not known") }
            case .prompts, .advanced:
                break
            }
            return failures
        })
    }

    /// An API provider with a stored key and its model list: "•••• stored", Replace, Remove, the model picker. The key is
    /// written to the snapshot graph's in-memory store (the snapshot mode never reaches the Keychain).
    static var settingsAPIKey: SnapshotScene {
        SnapshotScene(name: "settings-api-key", kind: .settings, prepare: { context in
            guard let model = context.settings else { return }
            ShellSceneSupport.navigation(context)?.tab = .providers
            ShellSceneSupport.navigation(context)?.provider = "anthropic-api"
            await model.setSecret("snapshot-placeholder", for: "anthropic-api")
            await model.refreshAvailability(of: nil)
            await model.refreshModels(of: "anthropic-api")
        }, verify: { context in
            guard let model = context.settings else { return ["a settings scene without a settings model"] }
            var failures: [String] = []
            if !model.storedSecrets.contains("anthropic-api") { failures.append("no key is stored") }
            if (model.models["anthropic-api"] ?? []).isEmpty { failures.append("no model list") }
            if model.settings.providers["anthropic-api"]?.model == nil { failures.append("no model chosen") }
            return failures
        })
    }
}

/// Helpers of the scenes.
@MainActor enum ShellSceneSupport {
    /// Lets the main actor run until the condition holds, or until `seconds` have passed.
    static func wait(seconds: Double = 3, until condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int(seconds * 1_000))
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The document's provider, and its plan, before the scene goes on.
    static func choose(_ id: ProviderID, in model: ReviewSessionModel) async {
        model.setActiveProvider(ProviderRef(providerID: id, model: nil))
        await wait { model.activeProvider?.id == id && model.sendPlan != nil }
    }

    /// The review window's own state, through the hosting controller the runner made.
    static func windowState(_ context: SnapshotContext) -> ShellReviewWindowState? {
        (context.window.contentViewController as? NSHostingController<ReviewWindowView>)?.rootView.windowState
    }

    /// The settings window's navigation, through the hosting controller the runner made.
    static func navigation(_ context: SnapshotContext) -> ShellSettingsNavigation? {
        (context.window.contentViewController as? NSHostingController<SettingsRootView>)?.rootView.navigation
    }

    /// The indicator's text and tint, as expectations.
    static func indicator(of model: ReviewSessionModel, text: String, tint: ShellDestinationState.Tint) -> [String] {
        let state = ShellDestination.state(of: model)
        var failures: [String] = []
        if state.text != text { failures.append("the indicator reads \"\(state.text)\", expected \"\(text)\"") }
        if state.tint != tint { failures.append("the indicator is \(state.tint), expected \(tint)") }
        return failures
    }
}
