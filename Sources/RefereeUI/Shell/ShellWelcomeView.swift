import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RefereeCore
import AppCore

/// The welcome window (plan.md section 9.1): "Open PDF…", a drop target, the recent reviews and a line that says
/// which AI provider a review would use.
///
/// `WelcomeView(recent:open:)` knows nothing about providers, so it shows no provider line; the window manager uses
/// the internal initialiser, whose `providerLine` reads the app's settings (and so follows them).
///
/// Design review D5: with no provider set up, "Set Up AI Provider…" and a sentence under the drop hint take the place
/// of the bottom line; with one, the bottom line opens Settings ▸ Providers. D26: titles on two lines, only the
/// pending count in orange, and a context menu to open a review, show its file in Finder or delete its data; a review
/// whose file is gone says so, and a click on it asks for the file. Step 5's brand (docs/brand/brand.md 6.1): the
/// app's tile, wordmark and tagline at the top; on a first run, with no review yet, "How it works" on the right.
public struct WelcomeView: View {
    let recent: [SessionSummary]
    let open: (URL?) -> Void
    /// Read in `body`, so a line that reads the app's settings model follows its changes.
    let providerLine: @MainActor () -> ShellWelcomeProvider
    let openSettings: @MainActor () -> Void
    /// The recent reviews whose file is not where it was last seen (their ids), found off the main actor by the window
    /// manager: asking the file system from `body` could hang on a volume that is gone.
    let missing: Set<String>
    let showInFinder: @MainActor (URL) -> Void
    let deleteReviewData: @MainActor (SessionSummary) -> Void

    public init(recent: [SessionSummary], open: @escaping (URL?) -> Void) {   // nil = show the open panel
        self.init(recent: recent, open: open, providerLine: { .unknown }, openSettings: {})
    }

    init(recent: [SessionSummary], open: @escaping (URL?) -> Void, providerLine: @escaping @MainActor () -> ShellWelcomeProvider,
         openSettings: @escaping @MainActor () -> Void, missing: Set<String> = [], showInFinder: @escaping @MainActor (URL) -> Void = { _ in },
         deleteReviewData: @escaping @MainActor (SessionSummary) -> Void = { _ in }) {
        self.recent = recent
        self.open = open
        self.providerLine = providerLine
        self.openSettings = openSettings
        self.missing = missing
        self.showInFinder = showInFinder
        self.deleteReviewData = deleteReviewData
    }

    static let setUpProvider = "Set Up AI Provider…"
    static let setUpExplanation = "Reviews need an AI provider. A local model through Ollama keeps the manuscript on this Mac."

    /// The right column on a first run (no review yet): what the app does, and who decides.
    static let howItWorksTitle = "How it works"
    static let howItWorks: [(symbol: String, text: String)] = [
        ("doc.text.magnifyingglass", "The AI reads the paper and drafts comments in the sidebar."),
        ("person.crop.circle.badge.checkmark", "You approve, reject, discuss or edit each one, with single keys."),
        ("doc.richtext", "The report is drafted from the comments you approved, for you to edit."),
    ]
    static let howItWorksPromise = "Nothing reaches the report until you approve it."

    /// The welcome window's title, kept for the Window menu, Mission Control and VoiceOver but not shown: the wordmark
    /// is the one name on screen. The window manager and the snapshot mode both call this.
    static func dress(_ window: NSWindow) {
        window.title = CommonBrand.welcomeItemTitle
        window.titleVisibility = .hidden
    }

    @State private var dropTargeted = false

    public var body: some View {
        HStack(spacing: 0) {
            start
                .frame(width: 250)
            Divider()
            recentList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 420)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter(ReviewWindowView.isPDF)
            guard let first = pdfs.first else { return false }
            for url in [first] + pdfs.dropFirst() { open(url) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // ---- left: the app, the open button, the provider line ----

    private var start: some View {
        let line = providerLine()
        return VStack(spacing: 14) {
            Spacer(minLength: 0)
            CommonBrandMark(size: 72, style: .tile)
            VStack(spacing: 6) {
                Text(CommonBrand.wordmark(size: 24))
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                Text(CommonBrand.tagline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                Button {
                    open(nil)
                } label: {
                    Label("Open PDF…", systemImage: "doc.badge.plus")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("or drop a PDF on this window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if line == .notSetUp {
                VStack(spacing: 6) {
                    Button {
                        openSettings()
                    } label: {
                        Label(WelcomeView.setUpProvider, systemImage: "cpu")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Text(WelcomeView.setUpExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            providerStatus(line)
        }
        .padding(20)
        .frame(maxHeight: .infinity)
    }

    /// The bottom line (section 9.1): with a provider, a button that opens Settings ▸ Providers (D5); without one,
    /// nothing, since "Set Up AI Provider…" is above.
    @ViewBuilder private func providerStatus(_ line: ShellWelcomeProvider) -> some View {
        switch line {
        case .unknown, .notSetUp:
            EmptyView()
        case .configured(let text, let isLocal):
            Button {
                openSettings()
            } label: {
                Label {
                    Text(text).lineLimit(2)
                } icon: {
                    Circle().fill(isLocal ? Color.green : Color.orange).frame(width: 8, height: 8)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Change the provider in Settings ▸ Providers")
        }
    }

    // ---- right: recent reviews, or on a first run how it works ----

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(recent.isEmpty ? WelcomeView.howItWorksTitle : "Recent reviews")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            if recent.isEmpty {
                howItWorks
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(recent) { summary in
                            let gone = missing.contains(summary.id)
                            let file = gone ? nil : summary.lastKnownPath.map { URL(fileURLWithPath: $0) }
                            ShellRecentReviewRow(summary: summary, missing: gone, open: { open(file) },
                                                 showInFinder: file.map { url in { showInFinder(url) } },
                                                 deleteReviewData: { deleteReviewData(summary) })
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Three steps, 14 points apart, each a symbol and a sentence; the promise 8 points under them, aligned with the
    /// sentences.
    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(WelcomeView.howItWorks.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: step.symbol)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Text(step.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(WelcomeView.howItWorksPromise)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The welcome window's provider line (section 9.1).
enum ShellWelcomeProvider: Equatable {
    case unknown                                  // nothing known (the public initialiser): no line
    case notSetUp                                 // "Set Up AI Provider…" (D5)
    case configured(String, isLocal: Bool)        // "AI: Local · gemma4:e4b"
}

/// One recent review: title, file name and date, and how far the triage is ("12 comments · 3 pending", only the
/// pending count in orange). A review whose file is gone shows "File not found"; a click then asks for the file (D26).
struct ShellRecentReviewRow: View {
    let summary: SessionSummary
    let missing: Bool
    let open: () -> Void
    let showInFinder: (() -> Void)?              // nil: the file is gone, or its place is not known
    let deleteReviewData: () -> Void
    @State private var hovering = false

    static let fileNotFound = "File not found"

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: summary.hasReport ? "doc.text.fill" : "doc.text")
                    .font(.title3)
                    .foregroundStyle(summary.hasReport ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ShellRecentReviewRow.title(summary))
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(summary.fileName) · \(summary.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if missing {
                        Text(ShellRecentReviewRow.fileNotFound)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(ShellRecentReviewRow.progressText(summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(hovering ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(missing ? "Choose the PDF: it is no longer where it was"
                      : summary.lastKnownPath.map { "Open \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "Choose the PDF")
        .contextMenu {
            Button("Open", action: open)
            Button("Show in Finder") { showInFinder?() }
                .disabled(showInFinder == nil)
            Divider()
            Button("Delete Review Data…", action: deleteReviewData)
        }
    }

    /// The manuscript's title when the review has one, else the file name.
    static func title(_ summary: SessionSummary) -> String {
        if let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return summary.fileName
    }

    /// "12 comments · 3 pending", "7 comments · report drafted", "No comments yet".
    static func progress(_ summary: SessionSummary) -> String {
        progressParts(summary).map(\.text).joined(separator: " · ")
    }

    /// The parts of the progress line; the pending count is the one to stand out (D26).
    static func progressParts(_ summary: SessionSummary) -> [(text: String, standsOut: Bool)] {
        var parts: [(text: String, standsOut: Bool)] = []
        parts.append((summary.commentCount == 0 ? "No comments yet" : ShellFormat.count(summary.commentCount, "comment", "comments"), false))
        if summary.pendingCount > 0 { parts.append(("\(ShellFormat.grouped(summary.pendingCount)) pending", true)) }
        if summary.hasReport { parts.append(("report drafted", false)) }
        return parts
    }

    /// The progress line with only the pending count in orange.
    static func progressText(_ summary: SessionSummary) -> AttributedString {
        var line = AttributedString()
        for (index, part) in progressParts(summary).enumerated() {
            if index > 0 { line.append(AttributedString(" · ")) }
            var piece = AttributedString(part.text)
            if part.standsOut { piece.foregroundColor = .orange }
            line.append(piece)
        }
        return line
    }
}

