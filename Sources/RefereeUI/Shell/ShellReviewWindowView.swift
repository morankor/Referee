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
    }

    /// A file URL of a PDF: by its type when the file says, else by its extension.
    static func isPDF(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type.conforms(to: .pdf) }
        return url.pathExtension.lowercased() == "pdf"
    }
}

/// The toolbar of section 9.2, left to right: navigator toggle; the destination indicator (principal); Review (or
/// Cancel with a spinner and the phase while the review lane runs); Report; sidebar toggle. Buttons that must show
/// their word use `.titleAndIcon`: on macOS 26 a toolbar button otherwise shows its icon alone.
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
            ShellReviewButton(model: model)
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

/// "Review", or "Cancel" with a spinner and the phase text while a job of the review lane runs.
struct ShellReviewButton: View {
    let model: ReviewSessionModel

    var body: some View {
        if case .running(let kind, let phase, _) = model.runState {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(ShellReviewButton.phaseText(kind: kind, phase: phase))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    model.cancelRun()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                }
                .help("Stop the running job (⌘.)")
            }
        } else {
            Button {
                model.startReview()
            } label: {
                Label("Review", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canStartReview)
            .help(model.canStartReview ? "Run the review (⌘R)" : ShellReviewButton.disabledReason(model))
        }
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
