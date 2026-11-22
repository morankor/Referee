import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// Settings ▸ Privacy (plan.md section 9.6): Local only, the consent question, where the review data is and how to
/// delete it, and a plain-language summary of sections 12.3 and 12.5.
struct ShellPrivacyPane: View {
    let model: SettingsModel
    let services: ShellSettingsServices
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteResult: String?

    /// Section 12.3 in plain words.
    static let leavesTheMac = "A manuscript, as a PDF or as extracted text, goes only to the provider shown in its window's toolbar, "
        + "and only when you start a review, send a message, ask a question or write the report. A reference goes to Crossref "
        + "or OpenAlex when you click it; API keys go only to their own vendor. Nothing else leaves this Mac: no telemetry, "
        + "update checks or crash reports."
    /// Section 12.5 in plain words.
    static let whatProvidersCanDo = "API-key and local providers cannot act on your Mac. Command-line tools are agents: Referee "
        + "switches their tools off where it can, runs them in an empty folder and stops them if they use a tool. For Antigravity "
        + "and Grok Build this is untested on this Mac until a test prompt succeeds."

    var body: some View {
        Form {
            Section("Sending manuscripts") {
                Toggle(isOn: Binding(get: { model.settings.privacy.localOnly }, set: { value in model.update { $0.privacy.localOnly = value } })) {
                    Text("Local only")
                    Text("Only providers that run on this Mac can be used; every remote provider is blocked.")
                }
                Toggle(isOn: Binding(get: { model.settings.privacy.confirmFirstSendPerDocument },
                                     set: { value in model.update { $0.privacy.confirmFirstSendPerDocument = value } })) {
                    Text("Ask before the first send of each document")
                    Text("Before a remote provider first receives a manuscript, Referee says what will be sent and asks.")
                }
            }
            Section("Review data") {
                LabeledContent("Data folder") {
                    HStack(spacing: 8) {
                        Text(ShellPrivacyPane.displayPath(model.dataDirectory))
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: 380, alignment: .trailing)
                            .help(ShellPrivacyPane.displayPath(model.dataDirectory))
                        if let folder = model.dataDirectory {
                            Button("Reveal in Finder") { services.revealInFinder(folder) }
                        }
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete all review data")
                        Text(deleteResult ?? "Every review's comments, discussions, questions, report and reference lookups. Your PDFs are not touched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                        .disabled(deleting)
                }
            }
            Section("What leaves this Mac") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ShellPrivacyPane.leavesTheMac)
                    Text(ShellPrivacyPane.whatProvidersCanDo)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all review data?", isPresented: $confirmingDelete) {
            Button("Delete All Review Data", role: .destructive) { deleteAll() }
        } message: {
            Text("Every open review window is closed, and the comments, discussions, questions, reports and reference lookups of every "
                 + "document are deleted from this Mac. This cannot be undone. Your PDFs are not touched.")
        }
    }

    private func deleteAll() {
        deleting = true
        Task {
            do {
                try await services.deleteAllReviewData(model)
                deleteResult = "All review data was deleted."
            } catch {
                deleteResult = (error as? any RefereeError)?.userMessage ?? "The review data could not be deleted."
            }
            deleting = false
        }
    }

    /// The folder with the home directory written as "~", so that a picture of this pane shows no account name.
    static func displayPath(_ url: URL?) -> String {
        guard let url else { return "Not known" }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Settings ▸ References (section 9.6): when lookups happen, the optional Crossref contact, and the downloaded papers.
struct ShellReferencesPane: View {
    let model: SettingsModel
    @State private var clearing = false

    static let cacheLimits = [100, 250, 500, 1_000, 2_000]

    var body: some View {
        Form {
            Section("Lookups") {
                Toggle(isOn: Binding(get: { !model.settings.privacy.resolveReferencesInBackground },
                                     set: { value in model.update { $0.privacy.resolveReferencesInBackground = !value } })) {
                    Text("Look up references only when I click them")
                    Text("When off, every reference of a document is looked up as soon as it opens.")
                }
                LabeledContent {
                    ShellCommitField("Your email address", value: model.settings.references.crossrefMailto) { text in
                        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.update { $0.references.crossrefMailto = address }
                    }
                    .frame(maxWidth: 260)
                } label: {
                    Text("Crossref contact email")
                    Text("Optional; gives faster lookups.")
                }
            }
            Section("Downloaded papers") {
                LabeledContent("Space used") {
                    HStack(spacing: 8) {
                        Text(model.pdfCacheBytes.map(ShellFormat.bytes) ?? "Measuring…")
                            .monospacedDigit()
                        Button("Clear") {
                            clearing = true
                            Task {
                                await model.clearPDFCache()
                                clearing = false
                            }
                        }
                        .disabled(clearing || model.pdfCacheBytes == 0)
                    }
                }
                Picker("Keep at most", selection: Binding(get: { model.settings.references.pdfCacheLimitMB },
                                                          set: { value in model.update { $0.references.pdfCacheLimitMB = value } })) {
                    ForEach(ShellReferencesPane.limits(including: model.settings.references.pdfCacheLimitMB), id: \.self) { megabytes in
                        Text("\(ShellFormat.grouped(megabytes)) MB").tag(megabytes)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshPDFCacheSize() }
    }

    static func limits(including current: Int) -> [Int] {
        cacheLimits.contains(current) ? cacheLimits : (cacheLimits + [current]).sorted()
    }
}

/// Settings ▸ Advanced (section 9.6).
struct ShellAdvancedPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Text extraction") {
                Picker(selection: Binding(get: { model.settings.ui.stripMarginLineNumbers },
                                          set: { value in model.update { $0.ui.stripMarginLineNumbers = value } })) {
                    Text("Automatic").tag(true)
                    Text("Never").tag(false)
                } label: {
                    Text("Remove margin line numbers from extracted text")
                    Text("Applies to documents opened afterwards.")
                }
            }
            Section("Comments") {
                Toggle(isOn: Binding(get: { model.settings.ui.autoAdvanceAfterTriage },
                                     set: { value in model.update { $0.ui.autoAdvanceAfterTriage = value } })) {
                    Text("Advance to the next comment after a decision")
                    Text("After A or R, the next pending comment is selected.")
                }
                Toggle(isOn: Binding(get: { model.settings.ui.showRejectedHighlights },
                                     set: { value in model.update { $0.ui.showRejectedHighlights = value } })) {
                    Text("Show highlights of rejected comments")
                }
            }
        }
        .formStyle(.grouped)
    }
}
