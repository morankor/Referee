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
public struct WelcomeView: View {
    let recent: [SessionSummary]
    let open: (URL?) -> Void
    /// Read in `body`, so a line that reads the app's settings model follows its changes.
    let providerLine: @MainActor () -> ShellWelcomeProvider
    let openSettings: @MainActor () -> Void

    public init(recent: [SessionSummary], open: @escaping (URL?) -> Void) {   // nil = show the open panel
        self.init(recent: recent, open: open, providerLine: { .unknown }, openSettings: {})
    }

    init(recent: [SessionSummary], open: @escaping (URL?) -> Void, providerLine: @escaping @MainActor () -> ShellWelcomeProvider,
         openSettings: @escaping @MainActor () -> Void) {
        self.recent = recent
        self.open = open
        self.providerLine = providerLine
        self.openSettings = openSettings
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
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ShellAppGlyph()
                .frame(width: 84, height: 84)
            VStack(spacing: 4) {
                Text("Referee")
                    .font(.largeTitle.weight(.semibold))
                Text("Read a manuscript, triage AI comments, write the report.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            Spacer(minLength: 0)
            providerStatus
        }
        .padding(20)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var providerStatus: some View {
        switch providerLine() {
        case .unknown:
            EmptyView()
        case .configured(let line, let isLocal):
            Label {
                Text(line).lineLimit(2)
            } icon: {
                Circle().fill(isLocal ? Color.green : Color.orange).frame(width: 8, height: 8)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .notSetUp:
            HStack(spacing: 4) {
                Text("No AI provider set up —")
                    .foregroundStyle(.secondary)
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
    }

    // ---- right: recent reviews ----

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent reviews")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            if recent.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No reviews yet. Open a PDF to start one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(recent) { summary in
                            ShellRecentReviewRow(summary: summary) {
                                open(summary.lastKnownPath.map { URL(fileURLWithPath: $0) })
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// The welcome window's provider line (section 9.1).
enum ShellWelcomeProvider: Equatable {
    case unknown                                  // nothing known (the public initialiser): no line
    case notSetUp                                 // "No AI provider set up — Open Settings"
    case configured(String, isLocal: Bool)        // "AI: Local · gemma4:e4b"
}

/// One recent review: title, file name and date, and how far the triage is ("12 comments · 3 pending").
struct ShellRecentReviewRow: View {
    let summary: SessionSummary
    let open: () -> Void
    @State private var hovering = false

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
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(summary.fileName) · \(summary.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ShellRecentReviewRow.progress(summary))
                        .font(.caption)
                        .foregroundStyle(summary.pendingCount > 0 ? Color.orange : Color.secondary)
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
        .help(summary.lastKnownPath.map { "Open \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "Choose the PDF")
    }

    /// The manuscript's title when the review has one, else the file name.
    static func title(_ summary: SessionSummary) -> String {
        if let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return summary.fileName
    }

    /// "12 comments · 3 pending", "7 comments · report drafted", "No comments yet".
    static func progress(_ summary: SessionSummary) -> String {
        var parts: [String] = []
        parts.append(summary.commentCount == 0 ? "No comments yet" : ShellFormat.count(summary.commentCount, "comment", "comments"))
        if summary.pendingCount > 0 { parts.append("\(ShellFormat.grouped(summary.pendingCount)) pending") }
        if summary.hasReport { parts.append("report drafted") }
        return parts.joined(separator: " · ")
    }
}

/// The app's mark, drawn: a page with a pen stroke, as the icon of scripts/make-icon.sh is a page-like square with an "R".
struct ShellAppGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.33, blue: 0.62), Color(red: 0.09, green: 0.2, blue: 0.42)],
                                     startPoint: .top, endPoint: .bottom))
            Text("R")
                .font(.system(size: 52, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .accessibilityHidden(true)
    }
}
