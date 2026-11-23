import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RefereeCore
import AppCore

/// The review window (plan.md section 9.2): navigator, PDF and sidebar in three columns, the toolbar, the banner above
/// the PDF, and the two overlays over the whole window, the destination menu and the consent card.
///
/// Who draws what: the Reader draws the PDF and the overlays tied to positions in it; the Sidebar the inspector's
/// content; the Shell everything tied to the window. No column declares a minimum width (section 9.2): the window's
/// 1000 × 640 minimum keeps the PDF readable, and a declared minimum would be added to the window's smallest width.
public struct ReviewWindowView: View {
    let model: ReviewSessionModel
    let reader: ReaderController
    let windowState: ShellReviewWindowState
    let services: ShellWindowServices

    public init(model: ReviewSessionModel, reader: ReaderController) {
        self.init(model: model, reader: reader, windowState: ShellReviewWindowState(), services: ShellWindowServices())
    }

    /// The app's window: state the menu can reach, and the services of the window manager.
    init(model: ReviewSessionModel, reader: ReaderController, windowState: ShellReviewWindowState, services: ShellWindowServices) {
        self.model = model
        self.reader = reader
        self.windowState = windowState
        self.services = services
    }

    public var body: some View {
        @Bindable var state = windowState
        NavigationSplitView(columnVisibility: $state.navigatorVisibility) {
            NavigatorPane(controller: reader)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                BannerView(model: model, windowState: windowState, services: services)
                ReaderPane(controller: reader)
                    .overlay { ShellDocumentStateView(model: model, services: services) }
            }
            .overlay(alignment: .top) {
                if windowState.destinationMenuOpen {
                    ShellDestinationMenu(model: model, windowState: windowState, services: services)
                        .padding(.top, 6)
                        .transition(.opacity)
                }
            }
        }
        .inspector(isPresented: $state.showSidebar) {
            ReviewSidebar(model: model)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
        .toolbar { ShellReviewToolbar(model: model, windowState: windowState, services: services) }
        .overlay {
            if windowState.destinationMenuOpen {
                // A click anywhere outside the menu closes it; the menu itself is drawn above, in the detail column.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { windowState.destinationMenuOpen = false }
                    .accessibilityHidden(true)
            }
        }
        .overlay { ConsentCard(model: model) }
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter(ReviewWindowView.isPDF)
            guard !pdfs.isEmpty else { return false }
            services.openFiles(pdfs)
            return true
        }
        .environment(\.uiActions, services.uiActions)
        .onChange(of: model.consentRequest != nil) { _, asking in
            if asking { windowState.destinationMenuOpen = false }
        }
        // D19: a narrow window gives the PDF the navigator's room, and a wide one gives it back.
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
            windowState.adaptNavigator(toWidth: width)
        }
    }

    /// A file URL of a PDF: by its type when the file says, else by its extension.
    static func isPDF(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type.conforms(to: .pdf) }
        return url.pathExtension.lowercased() == "pdf"
    }
}

/// The toolbar of section 9.2, left to right: navigator toggle; the destination indicator (principal); Review (or the
/// progress and Stop while the review lane runs); Report; sidebar toggle. Buttons that must show their word use
/// `.titleAndIcon`: on macOS 26 a toolbar button otherwise shows its icon alone.
struct ShellReviewToolbar: ToolbarContent {
    let model: ReviewSessionModel
    let windowState: ShellReviewWindowState
    let services: ShellWindowServices

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation { windowState.toggleNavigator() }
            } label: {
                Label("Navigator", systemImage: "sidebar.left")
            }
            .help(windowState.showsNavigator ? "Hide the navigator" : "Show the navigator")
        }
        ToolbarItem(placement: .principal) {
            ShellDestinationIndicator(model: model, windowState: windowState, services: services)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ShellReviewButton(model: model, windowState: windowState)
            Button {
                model.sidebarTab = .report
                windowState.showSidebar = true
            } label: {
                Label("Report", systemImage: "doc.text")
                    .labelStyle(.titleAndIcon)
            }
            .help("Show the report")
            Button {
                withAnimation { windowState.showSidebar.toggle() }
            } label: {
                Label("Sidebar", systemImage: "sidebar.right")
            }
            .help(windowState.showSidebar ? "Hide the sidebar" : "Show the sidebar")
        }
    }
}

/// "Review" ("Review Again" once the session holds AI comments, D20), or, while a job of the review lane runs, a gauge
/// or a spinner, the phase with the time since the job started, and "Stop" (D9).
struct ShellReviewButton: View {
    let model: ReviewSessionModel
    let windowState: ShellReviewWindowState

    var body: some View {
        if case .running(let kind, let phase, let startedAt) = model.runState {
            HStack(spacing: 8) {
                if let gauge = ShellReviewButton.gauge(kind: kind, phase: phase) {
                    ProgressView(value: gauge.value, total: gauge.total)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(ShellReviewButton.progressText(kind: kind, phase: phase, elapsed: context.date.timeIntervalSince(startedAt)))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button {
                    model.cancelRun()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                }
                .help("Stop the running job (⌘.)")
            }
        } else if ShellReviewButton.isProminent(model) {
            reviewButton
                .buttonStyle(.borderedProminent)              // D30: the first thing to do with a new paper
        } else {
            reviewButton
        }
    }

    private var reviewButton: some View {
        Button {
            if let request = windowState.requestReview { request() } else { model.startReview() }
        } label: {
            Label(ShellReviewButton.title(model), systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
        }
        .disabled(!model.canStartReview)
        .help(model.canStartReview ? "Run the review (⌘R)" : ShellReviewButton.disabledReason(model))
    }

    /// "Review", or "Review Again" when the session holds comments of an earlier review (D20).
    @MainActor static func title(_ model: ReviewSessionModel) -> String {
        hasAIComments(model) ? "Review Again" : "Review"
    }

    @MainActor static func hasAIComments(_ model: ReviewSessionModel) -> Bool {
        model.session?.comments.contains { if case .ai = $0.origin { return true } else { return false } } ?? false
    }

    /// D30: idle, with a session that has no comment yet.
    @MainActor static func isProminent(_ model: ReviewSessionModel) -> Bool {
        model.runState == .idle && model.session?.comments.isEmpty == true
    }

    /// D20: what the question before a second review says, or nil when none is asked: the session holds no AI comment,
    /// the provider is on this Mac (a local review costs nothing), or there is no plan to give the figures.
    @MainActor static func reviewAgainQuestion(_ model: ReviewSessionModel) -> String? {
        guard hasAIComments(model), let provider = model.activeProvider, !provider.isLocal, let plan = model.sendPlan else { return nil }
        return ShellPlanText.reviewAgain(plan: plan, descriptor: provider)
    }

    /// The gauge of a review read in parts (D9): the parts done of the parts and the whole-paper pass that follows
    /// them. nil (a spinner) for any other phase, and for the report and its voice revision.
    static func gauge(kind: RunKind, phase: ReviewPhase?) -> (value: Double, total: Double)? {
        guard kind == .review, case .reading(let part, let total)? = phase, total > 1 else { return nil }
        return (Double(max(0, part - 1)), Double(total + 1))
    }

    /// "Reading part 2 of 5 · 3:12": the phase without its "…", and the time since the job started (D9).
    static func progressText(kind: RunKind, phase: ReviewPhase?, elapsed: TimeInterval) -> String {
        var phrase = phaseText(kind: kind, phase: phase)
        if phrase.hasSuffix("…") { phrase.removeLast() }
        return "\(phrase) · \(elapsedText(elapsed))"
    }

    /// "0:07", "3:12", "59:59" under an hour; "1:00:00" from an hour on.
    static func elapsedText(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let rest = seconds % 60
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(rest))" : "\(minutes):\(two(rest))"
    }

    /// "Reading part 2 of 5…" and the like.
    static func phaseText(kind: RunKind, phase: ReviewPhase?) -> String {
        switch kind {
        case .review:
            switch phase {
            case .reading(let part, let total)?: return total > 1 ? "Reading part \(part) of \(total)…" : "Reading the paper…"
            case .wholePaperPass?: return "Reading the whole paper…"
            case .preparing?, nil: return "Preparing the review…"
            }
        case .report: return "Writing the report…"
        case .revise: return "Revising the report…"
        case .discussion, .question: return "Answering…"
        }
    }

    /// The tooltip of a disabled Review button: the plan's blocking reason when there is one (section 9.2).
    @MainActor static func disabledReason(_ model: ReviewSessionModel) -> String {
        if let blocking = model.sendPlan?.blockingReason, !blocking.isEmpty { return blocking }
        if model.paper == nil || model.phase != .ready { return "Open a PDF to review it." }
        if model.activeProvider == nil { return "Set up an AI provider in Settings." }
        if model.consentRequest != nil { return "Waiting for your answer about sending the manuscript." }
        if model.sendPlan == nil { return "Working out what a review would send…" }
        return "A job is running."
    }
}

/// The document states of section 9.9 over the PDF: opening, could not be opened, nothing open.
struct ShellDocumentStateView: View {
    let model: ReviewSessionModel
    let services: ShellWindowServices

    var body: some View {
        switch model.phase {
        case .ready:
            EmptyView()
        case .loading(let fileName):
            panel {
                ProgressView()
                    .controlSize(.regular)
                Text("Opening \(fileName)…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            panel {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("This file could not be opened: \(message)")
                    .multilineTextAlignment(.center)
                Button("Open Another…") { services.showOpenPanel() }
            }
        case .empty:
            panel {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No document is open.")
                    .foregroundStyle(.secondary)
                Button("Open PDF…") { services.showOpenPanel() }
            }
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(24)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
    }
}
