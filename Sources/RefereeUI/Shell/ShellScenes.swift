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
            help,
            reviewEmpty,
            consent,
            bannerError,
            settings("settings-providers", tab: .providers, provider: "antigravity-cli"),
            settings("settings-prompts", tab: .prompts),
            settings("settings-privacy", tab: .privacy),
            settings("settings-references", tab: .references),
            settings("settings-advanced", tab: .advanced),
            settingsVenues,
            settingsAPIKey,
            reviewDestinationMenu,
            reviewRunning,
        ] + ShellDesignScenes.all
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
            var failures = ShellSceneSupport.welcomeWindowIsDressed(context)
            if hosting.rootView.recent.count != 2 { failures.append("\(hosting.rootView.recent.count) recent reviews, expected 2") }
            if hosting.rootView.providerLine() != .configured("AI: Local · mock", isLocal: true) {
                failures.append("the provider line is \(hosting.rootView.providerLine()), expected AI: Local · mock")
            }
            return failures
        })
    }

    /// Help ▸ Human in the Loop Help (step 5's brand, docs/brand/brand.md 6.3): the mark, the wordmark and the
    /// tagline over the keys and commands. The runner has no kind of scene for the Help window, so this one puts the
    /// Help view into the welcome scene's window, with the Help window's title, at the size the view asks for.
    static var help: SnapshotScene {
        SnapshotScene(name: "help", kind: .welcome, prepare: { context in
            let hosting = NSHostingController(rootView: ShellHelpView(readme: ShellHelpView.findReadme()))
            context.window.contentViewController = hosting
            context.window.title = CommonBrand.helpItemTitle
            context.window.titleVisibility = .visible
            context.window.setContentSize(hosting.view.fittingSize)
        }, verify: { context in
            var failures: [String] = []
            if !(context.window.contentViewController is NSHostingController<ShellHelpView>) {
                failures.append("the window does not show the Help view")
            }
            if context.window.title != CommonBrand.helpItemTitle { failures.append("the window's title is \(context.window.title)") }
            return failures
        })
    }

    // ---- review windows ----

    /// `ay_round_nolinks.pdf` open, no comments, the indicator "Local" over "mock" in green, Review enabled and prominent
    /// (design review D3, D30). Below 1,100 points wide the navigator has stepped aside (D19).
    static var reviewEmpty: SnapshotScene {
        SnapshotScene(name: "review-empty", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            await ShellSceneSupport.wait { model.sendPlan != nil }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures = ShellSceneSupport.indicator(of: model, text: "Local · mock", tint: .green)
            failures += ShellSceneSupport.indicatorLines(of: model, title: "Local", detail: "mock")
            if model.session?.comments.isEmpty != true { failures.append("the session has comments") }
            if !model.canStartReview { failures.append("Review is disabled: \(ShellReviewButton.disabledReason(model))") }
            if !ShellReviewButton.isProminent(model) { failures.append("Review is not the prominent button of a paper without comments") }
            if ShellReviewButton.title(model) != "Review" { failures.append("the button reads \(ShellReviewButton.title(model))") }
            if let banner = model.banner { failures.append("a banner is shown: \(banner.message)") }
            failures += ShellSceneSupport.navigatorFollowsWidth(context)
            return failures
        })
    }

    /// `setActiveProvider("mock-remote")`, `startReview()`: the consent card, its facts with the text-only warning and
    /// "Kept", "Don't Send" and "Send to Mock" (D12). Nothing is sent.
    static var consent: SnapshotScene {
        SnapshotScene(name: "consent", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            await ShellSceneSupport.choose("mock-remote", in: model)
            model.startReview()
            await ShellSceneSupport.wait { model.consentRequest != nil }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures = ShellSceneSupport.indicator(of: model, text: "Mock (remote) · mock · text only", tint: .orange)
            failures += ShellSceneSupport.indicatorLines(of: model, title: "Mock (remote)", detail: "mock · text only")
            guard let request = model.consentRequest else { return failures + ["no consent card"] }
            let text = ShellPlanText.consent(request: request, pageCount: model.paper?.ref.pageCount ?? 0, byteCount: model.paper?.ref.byteCount ?? 0)
            if request.provider.id != "mock-remote" { failures.append("the card asks about \(request.provider.id)") }
            if request.plan.sendsPDF { failures.append("the plan sends the PDF; the text-only case was expected") }
            if !text.what.hasSuffix(ShellPlanText.textOnlyWarning) { failures.append("the card lacks the text-only sentence: \(text.what)") }
            if text.title != "Send this manuscript to Mock?" { failures.append("the title is \(text.title)") }
            failures += ShellSceneSupport.facts(text.facts, labels: ["What", "To", "Requests", "Kept", ""])
            if text.facts.first?.value != "Extracted text of 4 pages" { failures.append("What reads \(text.facts.first?.value ?? "nothing")") }
            if text.facts.last?.isWarning != true { failures.append("the text-only warning row is missing") }
            if text.sendButton != "Send to Mock" { failures.append("the send button reads \(text.sendButton)") }
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

    /// The destination menu open, with a remote provider chosen, on the sample session (whose two runs went to "mock"):
    /// "For the review, chat and report of this paper.", Custom with where each job would go, the providers with the
    /// chosen one's models (none listed yet: "Choose in Settings…"), what a review sends as a grid with the text-only
    /// warning, the retention note, "Sent so far" with one line, Local only, "Provider Settings…" and "Privacy
    /// Settings…" (design review D4, D24, D34; step 5b).
    static var reviewDestinationMenu: SnapshotScene {
        SnapshotScene(name: "review-destination-menu", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sample.json",
                      prepare: { context in
            guard let model = context.model else { return }
            await ShellSceneSupport.choose("mock-remote", in: model)
            ShellSceneSupport.openDestinationMenu(context)
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures: [String] = []
            if ShellSceneSupport.windowState(context)?.destinationMenuOpen != true { failures.append("the destination menu is not open") }
            let choices = Set(model.selectableProviders.map(\.id))
            if choices != ["mock", "mock-remote", "mock-fail", "mock-stall", "ollama"] {
                failures.append("the providers to choose are \(choices.sorted()), expected the four mocks and Ollama")
            }
            guard let provider = model.activeProvider, let plan = model.sendPlan else { return failures + ["no plan for the menu"] }
            let summary = ShellPlanText.menuSummary(plan: plan, descriptor: provider, pageCount: model.paper?.ref.pageCount ?? 0,
                                                    byteCount: model.paper?.ref.byteCount ?? 0)
            failures += ShellSceneSupport.facts(summary.facts, labels: ["Sends", "To", "Requests", ""])
            if summary.facts.last?.value != ShellPlanText.textOnlyWarning { failures.append("the grid lacks the text-only warning") }
            if !ShellDestinationMenu.otherJobLines(model).isEmpty { failures.append("the menu names another job's provider") }
            // Step 5b: the chosen provider's models, from the list Settings keeps; it has none yet, so "Choose in Settings…".
            let models = ShellModelChoices.menu(for: provider.id, settings: model.settings, current: ShellDestinationMenu.chosenRef(model))
            if models.choices.map(\.title) != ["Default model (mock)"] || models.settingsRow != ShellModelChoices.chooseInSettings {
                failures.append("the models offered are \(models.choices.map(\.title)), then \(models.settingsRow ?? "nothing")")
            }
            if ShellDestinationMenu.chosenRef(model) != ProviderRef(providerID: "mock-remote", model: nil) || model.usesCustomProviders {
                failures.append("the paper's choice is \(String(describing: ShellDestinationMenu.chosenRef(model)))")
            }
            if ShellSceneSupport.windowState(context)?.expandedProvider != "mock-remote" { failures.append("the chosen provider's models are not listed") }
            // Custom, not chosen here, says where each job would go: the snapshot defaults send all three to "mock".
            let custom = ShellCustomDestinations.lines(settings: model.settings,
                                                       providers: ShellDestinationMenu.knownProviders(model, services: ShellWindowServices()))
            if custom != ["Review: Mock · mock", "Chat: Mock · mock", "Report: Mock · mock"] { failures.append("Custom says \(custom)") }
            let sent = ShellDestinationMenu.sentSoFar(model, services: ShellWindowServices())
            if sent.count != 1 || sent.first?.hasPrefix("Mock: 2 times, last ") != true || sent.first?.hasSuffix("(extracted text)") != true {
                failures.append("\"Sent so far\" reads \(sent), expected one line for Mock's two runs")
            }
            return failures
        })
    }

    /// `mock-stall`: the review lane runs; the toolbar shows a spinner, "Reading the paper · 0:0x" and Stop (D9).
    static var reviewRunning: SnapshotScene {
        SnapshotScene(name: "review-running", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            guard let model = context.model else { return }
            await ShellSceneSupport.choose("mock-stall", in: model)
            model.startReview()
            await ShellSceneSupport.wait { !model.drafts.isEmpty }
        }, verify: { context in
            guard let model = context.model else { return ["a review scene without a model"] }
            var failures: [String] = []
            if case .running(.review, let phase, let startedAt) = model.runState {
                let text = ShellReviewButton.progressText(kind: .review, phase: phase, elapsed: Date().timeIntervalSince(startedAt))
                if !text.hasPrefix("Reading the paper · 0:0") { failures.append("the progress reads \(text)") }
                if ShellReviewButton.gauge(kind: .review, phase: phase) != nil { failures.append("a one-part review shows a gauge") }
            } else {
                failures.append("no review is running")
            }
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
                // D21: Send Test Prompt cannot be pressed for a provider that is not ready (Antigravity is not installed).
                if let provider, ShellProviderRows.canSendTestPrompt(model.availability[provider]) {
                    failures.append("Send Test Prompt is enabled for \(provider), which is not ready")
                }
            case .privacy:
                if model.dataDirectory == nil { failures.append("the data folder is not known") }
            case .references:
                if model.pdfCacheBytes == nil { failures.append("the size of the downloaded papers is not known") }
            case .prompts, .venues, .advanced:
                break
            }
            return failures
        })
    }

    /// Settings ▸ Venues (step 5, G.9) on EC, a conference: the list with the four built-ins marked and Journal
    /// (unspecified) the default; EC's names, kind, guidance and its recommendation scale, with the caption that the
    /// default scale is a stand-in for the venue's real review form.
    static var settingsVenues: SnapshotScene {
        SnapshotScene(name: "settings-venues", kind: .settings, prepare: { context in
            ShellSceneSupport.navigation(context)?.tab = .venues
            ShellSceneSupport.navigation(context)?.venue = "ec"
        }, verify: { context in
            guard let model = context.settings, let navigation = ShellSceneSupport.navigation(context) else {
                return ["a settings scene without a settings model"]
            }
            var failures: [String] = []
            if navigation.tab != .venues { failures.append("the window does not show Venues") }
            guard let venue = ShellVenueEditing.selected(navigation.venue, in: model.venues) else { return failures + ["no venue is shown"] }
            if venue.id != "ec" || venue.kind != .conference { failures.append("the venue shown is \(venue.id), a \(venue.kind)") }
            if venue.scale != DefaultSettings.conferenceScale { failures.append("its scale is \(venue.scale)") }
            if !ShellVenueEditing.problems(of: venue).isEmpty { failures.append("the editor warns: \(ShellVenueEditing.problems(of: venue))") }
            if model.venues.map(\.id) != ["journal", "conference", "jet", "ec"] || !model.venues.allSatisfy({ $0.isBuiltIn }) {
                failures.append("the list is \(model.venues.map(\.id)), expected the four built-ins")
            }
            if model.defaultVenue.id != VenueProfile.journalID { failures.append("the default venue is \(model.defaultVenue.id)") }
            if ShellVenueState.shortTitle(venue) != "EC" || ShellVenueEditing.listDetail(venue) != "ACM Conference on Economics and Computation" {
                failures.append("its row reads \(ShellVenueState.shortTitle(venue)) over \(ShellVenueEditing.listDetail(venue))")
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
            // D21: a ready provider's Send Test Prompt can be pressed, with the note of an API key.
            if !ShellProviderRows.canSendTestPrompt(model.availability["anthropic-api"]) { failures.append("Send Test Prompt is disabled") }
            if let anthropic = model.providers.first(where: { $0.id == "anthropic-api" }),
               ShellProviderRows.testPromptNote(for: anthropic) != "Sends “Reply with exactly: OK” to api.anthropic.com; costs a few tokens." {
                failures.append("the test prompt's note reads \(ShellProviderRows.testPromptNote(for: anthropic))")
            }
            return failures
        })
    }
}

/// Helpers of the scenes.
@MainActor enum ShellSceneSupport {
    /// Step 5's brand: the welcome window's title is "Welcome to Human in the Loop", kept for the Window menu and
    /// VoiceOver but not shown (`WelcomeView.dress`).
    static func welcomeWindowIsDressed(_ context: SnapshotContext) -> [String] {
        var failures: [String] = []
        if context.window.title != CommonBrand.welcomeItemTitle { failures.append("the window's title is \(context.window.title)") }
        if context.window.titleVisibility != .hidden { failures.append("the welcome window shows its title") }
        return failures
    }

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

    /// Opens the destination menu as a click on the indicator does (the models of the paper's own provider listed),
    /// or with the models of `expanding` listed instead.
    static func openDestinationMenu(_ context: SnapshotContext, expanding: ProviderID? = nil) {
        guard let state = windowState(context), let model = context.model, !state.destinationMenuOpen else { return }
        state.toggleDestinationMenu(chosen: model.session?.preferredProvider)
        if let expanding { state.expandedProvider = expanding }
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

    /// The indicator's two lines (design review D3), as expectations.
    static func indicatorLines(of model: ReviewSessionModel, title: String, detail: String?) -> [String] {
        let state = ShellDestination.state(of: model)
        var failures: [String] = []
        if state.title != title { failures.append("the indicator's title is \"\(state.title)\", expected \"\(title)\"") }
        if state.detail != detail { failures.append("the indicator's detail is \"\(state.detail ?? "none")\", expected \"\(detail ?? "none")\"") }
        return failures
    }

    /// The labels of a facts grid (D12, D24), in order; "" is the warning row.
    static func facts(_ facts: [ShellConsentFact], labels: [String]) -> [String] {
        let shown = facts.map(\.label)
        return shown == labels ? [] : ["the facts are \(shown), expected \(labels)"]
    }

    /// D3's rule (and the venue control's, step 5): no item of the window's toolbar is in its overflow menu. AppKit keeps
    /// an item that does not fit out of `visibleItems`.
    static func toolbarFits(_ context: SnapshotContext) -> [String] {
        guard let toolbar = context.window.toolbar else { return ["the window has no toolbar"] }
        let visible = Set((toolbar.visibleItems ?? []).map { ObjectIdentifier($0) })
        let hidden = toolbar.items.filter { !visible.contains(ObjectIdentifier($0)) }
        guard !hidden.isEmpty else { return [] }
        let width = Int(context.window.contentRect(forFrameRect: context.window.frame).width)
        return ["at \(width) points the toolbar's overflow holds \(hidden.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label })"]
    }

    /// D19: below 1,100 points wide the navigator has stepped aside; wider, it shows, as it does when a window opens.
    static func navigatorFollowsWidth(_ context: SnapshotContext) -> [String] {
        guard let state = windowState(context) else { return ["the window's state cannot be reached"] }
        let width = context.window.contentRect(forFrameRect: context.window.frame).width
        let expected = width >= ShellReviewWindowState.narrowWidth
        return state.showsNavigator == expected ? [] : ["at \(Int(width)) points the navigator is \(state.showsNavigator ? "shown" : "hidden")"]
    }
}
