import SwiftUI
import AppKit
import RefereeCore
import AppCore

// The citation card (plan.md sections 8.6, 9.5 and 9.9), 360 points wide: the mention's text, then per candidate entry
// the reference as printed (up to four lines) with a spinner while it is looked up, the resolved record (title,
// authors, year, venue, "Open access", "year differs: …"), or "No match found", or "Lookup failed: <reason>" with Retry;
// and the buttons Open PDF, Open in Browser, Copy DOI, Search Google Scholar and Show in References.
//
// Opening goes through the shell's closures (`uiActions.openReferenceViewer`, `uiActions.openInBrowser`), which do
// nothing in the snapshot mode. Open PDF downloads first (`model.fetchReferencePDF`).

struct ReaderCitationCard: View {
    let controller: ReaderController
    let content: ReaderCardContent

    static let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(content.heading)
                    .font(Theme.cardTitleFont)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    controller.dismissCitationCard()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
            }
            if content.entries.isEmpty {
                noEntry
            } else {
                ViewThatFits(in: .vertical) {
                    entryList
                    ScrollView { entryList }
                }
            }
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius + 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCornerRadius + 2).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
    }

    private var entryList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(content.entries) { entry in
                if entry.id != content.entries.first?.id { Divider() }
                ReaderCitationEntry(controller: controller, entry: entry, reference: content.references[entry.id],
                                    isResolving: content.isResolving, target: content.target)
            }
        }
    }

    /// A mention that matches no entry of the reference list: its text, and a search.
    private var noEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No entry of the reference list matches this citation.")
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ReaderScholarButton(controller: controller, entry: ReaderCitationText.searchEntry(forMention: content.mentionText ?? content.heading))
        }
        .controlSize(.small)
    }
}

/// One candidate entry of the card.
private struct ReaderCitationEntry: View {
    let controller: ReaderController
    let entry: BibEntry
    let reference: ResolvedReference?
    let isResolving: Bool
    let target: CitationLookup.Target
    @Environment(\.uiActions) private var uiActions
    @State private var isDownloading = false
    @State private var downloadProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(entry.rawText)
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if isResolving && reference == nil {
                    Spacer(minLength: 0)
                    ProgressView()
                        .controlSize(.small)
                        .help("Looking the reference up…")
                }
            }
            if let reference { record(reference) }
            if let downloadProblem {
                Text(downloadProblem)
                    .font(Theme.metadataFont)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
    }

    @ViewBuilder private func record(_ reference: ResolvedReference) -> some View {
        switch reference.status {
        case .resolved:
            VStack(alignment: .leading, spacing: 3) {
                if let title = reference.title, !title.isEmpty {
                    Text(title)
                        .font(Theme.bodyFont.weight(.semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let authors = ReaderCitationText.authorsLine(reference.authors) {
                    Text(authors)
                        .font(Theme.metadataFont)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let details = ReaderCitationText.recordDetails(reference) {
                    Text(details)
                        .font(Theme.metadataFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if reference.openAccessPDFURL != nil {
                        Text("Open access")
                            .font(Theme.metadataFont.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .foregroundStyle(.white)
                            .background(Color.green, in: Capsule())
                    }
                    if let note = ReaderCitationText.yearNote(listYear: entry.parsed.year, recordYear: reference.year) {
                        Text(note)
                            .font(Theme.metadataFont)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .notFound:
            Text("No match found")
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ReaderCitationText.failureLine(reference))
                    .font(Theme.bodyFont)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: openPDF) {
                    if isDownloading {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Open PDF")
                        }
                    } else {
                        Label("Open PDF", systemImage: "doc.richtext")
                    }
                }
                .disabled(reference?.openAccessPDFURL == nil || isDownloading)
                .help(reference?.openAccessPDFURL == nil ? "No open-access PDF is known for this reference" : "Download the PDF and open it")
                Button {
                    if let url = browserURL { uiActions.openInBrowser(url) }
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .disabled(browserURL == nil)
                Button {
                    if let doi { ReaderPasteboard.copy(doi) }
                } label: {
                    Label("Copy DOI", systemImage: "doc.on.doc")
                }
                .disabled(doi == nil)
            }
            HStack(spacing: 6) {
                ReaderScholarButton(controller: controller, entry: entry)
                Button {
                    controller.showInReferences(entryID: entry.id)
                } label: {
                    Label("Show in References", systemImage: "list.bullet")
                }
            }
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    private var browserURL: URL? { ReaderCitationText.browserURL(reference: reference, entry: entry) }
    private var doi: String? { ReaderCitationText.doi(reference: reference, entry: entry) }

    private func retry() {
        switch target {
        case .mention(let id): controller.model.lookUpCitation(mentionID: id)
        case .entry(let id): controller.model.lookUpEntry(entryID: id)
        }
    }

    private func openPDF() {
        guard let reference, !isDownloading else { return }
        let title = ReaderCitationText.viewerTitle(reference: reference, entry: entry)
        let open = uiActions.openReferenceViewer
        let model = controller.model
        isDownloading = true
        downloadProblem = nil
        Task { @MainActor in
            do {
                let file = try await model.fetchReferencePDF(reference)
                isDownloading = false
                open(file, title)
            } catch {
                isDownloading = false
                downloadProblem = (error as? any RefereeError)?.userMessage ?? "The PDF could not be downloaded."
            }
        }
    }
}

/// "Search Google Scholar": always available; the address comes from the resolver (`model.searchURL(for:)`), and
/// nothing is requested until the browser opens it.
private struct ReaderScholarButton: View {
    let controller: ReaderController
    let entry: BibEntry
    @Environment(\.uiActions) private var uiActions

    var body: some View {
        Button {
            uiActions.openInBrowser(controller.model.searchURL(for: entry))
        } label: {
            Label("Search Google Scholar", systemImage: "magnifyingglass")
        }
        .labelStyle(.titleAndIcon)
    }
}
