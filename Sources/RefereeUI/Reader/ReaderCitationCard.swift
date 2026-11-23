import SwiftUI
import AppKit
import RefereeCore
import AppCore

// The citation card (plan.md sections 8.6, 9.5 and 9.9, refined by design review D15), 360 points wide: the mention's
// text as its header, then per candidate entry what the lookup found, the reference as printed, and the buttons.
//
// - Before the lookup returns: the reference as printed (up to four lines) with a spinner.
// - Resolved: the record first, as the referee wants it: the title (3 lines), one line "authors · year · venue"
//   (2 lines), the tags "Open access" (`CommonTag`) and "year differs: …"; then the reference as printed (2 lines, the
//   whole of it in the tooltip).
// - Not found: "No match in Crossref or OpenAlex." with "Common for working papers and books." under it. Failed:
//   "Lookup failed: <reason>" with Retry. Each followed by the reference as printed.
// - Buttons (`ReaderCardActions`): Open PDF, Open in Browser and Copy DOI only when they can act; Search Google Scholar
//   always; Show in References last. The first of Open PDF, Open in Browser and Search Google Scholar is prominent.
//
// Opening goes through the shell's closures (`uiActions.openReferenceViewer`, `uiActions.openInBrowser`), which do
// nothing in the snapshot mode. Open PDF downloads first (`model.fetchReferencePDF`). For VoiceOver the card is one
// element, "Citation <heading>", that contains its parts (D22).

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
                .accessibilityLabel("Close")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Citation \(content.heading)")
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

    /// A mention that matches no entry of the reference list: its text, and a search (prominent: the only way on).
    private var noEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No entry of the reference list matches this citation.")
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ReaderScholarButton(controller: controller, entry: ReaderCitationText.searchEntry(forMention: content.mentionText ?? content.heading),
                                isProminent: ReaderCardActions.noEntry.prominent == .searchScholar)
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
    @State private var copiedDOI = 0                  // bumped by Copy DOI: "Copied" for Theme.feedbackDuration
    @State private var showsCopiedDOI = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reference {
                record(reference)
                printed
                    .lineLimit(2)
                    .help(entry.rawText)
            } else {
                // Before the lookup returns, the reference as printed comes first, with a spinner while it is looked up.
                HStack(alignment: .top, spacing: 6) {
                    printed
                        .lineLimit(4)
                    if isResolving {
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                            .help("Looking the reference up…")
                    }
                }
            }
            if let downloadProblem {
                Text(downloadProblem)
                    .font(Theme.metadataFont)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
                .padding(.top, 2)
        }
        .task(id: copiedDOI) {
            guard copiedDOI > 0 else { return }
            showsCopiedDOI = true
            try? await Task.sleep(for: Theme.feedbackDuration)
            guard !Task.isCancelled else { return }
            showsCopiedDOI = false
        }
    }

    /// The reference as printed in the paper.
    private var printed: some View {
        Text(entry.rawText)
            .font(Theme.metadataFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    @ViewBuilder private func record(_ reference: ResolvedReference) -> some View {
        switch reference.status {
        case .resolved:
            VStack(alignment: .leading, spacing: 3) {
                if let title = reference.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = ReaderCitationText.recordLine(reference) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let yearNote = ReaderCitationText.yearNote(listYear: entry.parsed.year, recordYear: reference.year)
                if reference.openAccessPDFURL != nil || yearNote != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if reference.openAccessPDFURL != nil {
                            CommonTag("Open access", color: .green)
                        }
                        if let yearNote {
                            Text(yearNote)
                                .font(Theme.metadataFont)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        case .notFound:
            VStack(alignment: .leading, spacing: 2) {
                Text(ReaderCitationText.notFoundLine)
                    .font(Theme.bodyFont)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ReaderCitationText.notFoundNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        let actions = ReaderCardActions.make(reference: reference, entry: entry)
        return VStack(alignment: .leading, spacing: 6) {
            if !actions.linkActions.isEmpty {
                HStack(spacing: 6) {
                    if actions.shows(.openPDF) {
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
                        .readerCardButtonStyle(prominent: actions.prominent == .openPDF)
                        .disabled(isDownloading)
                        .help("Download the PDF and open it")
                    }
                    if actions.shows(.openInBrowser) {
                        Button {
                            if let url = browserURL { uiActions.openInBrowser(url) }
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                        .readerCardButtonStyle(prominent: actions.prominent == .openInBrowser)
                    }
                    if actions.shows(.copyDOI) {
                        Button {
                            guard let doi else { return }
                            ReaderPasteboard.copy(doi)
                            copiedDOI &+= 1
                        } label: {
                            if showsCopiedDOI {
                                Label("Copied", systemImage: "checkmark")
                            } else {
                                Label("Copy DOI", systemImage: "doc.on.doc")
                            }
                        }
                        .readerCardButtonStyle(prominent: false)
                    }
                }
            }
            HStack(spacing: 6) {
                ReaderScholarButton(controller: controller, entry: entry, isProminent: actions.prominent == .searchScholar)
                Button {
                    controller.showInReferences(entryID: entry.id)
                } label: {
                    Label("Show in References", systemImage: "list.bullet")
                }
                .readerCardButtonStyle(prominent: false)
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
/// nothing is requested until the browser opens it. Prominent when nothing better can be offered (D15).
private struct ReaderScholarButton: View {
    let controller: ReaderController
    let entry: BibEntry
    let isProminent: Bool
    @Environment(\.uiActions) private var uiActions

    var body: some View {
        Button {
            uiActions.openInBrowser(controller.model.searchURL(for: entry))
        } label: {
            Label("Search Google Scholar", systemImage: "magnifyingglass")
        }
        .labelStyle(.titleAndIcon)
        .readerCardButtonStyle(prominent: isProminent)
    }
}

private extension View {
    /// The card's one next step is filled in the accent colour; the other buttons are bordered (D15).
    @ViewBuilder func readerCardButtonStyle(prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
