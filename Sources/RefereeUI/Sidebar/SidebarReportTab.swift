import SwiftUI
import RefereeCore
import AppCore

/// The Report tab (plan.md sections 6.10 and 9.8). Top: "Venue and notes" (the paper's venue with "Change…", and notes
/// for the report; folded once a report exists), the count of approved comments with the recommendation picker beside it
/// (on the venue's scale: a journal's four recommendations, a conference's labels; step 5, G.9), and the buttons:
/// Generate before there is a report; then Copy Text, Export ▾, Revise Voice, Regenerate and Versions ▾. Body: the
/// Markdown editor with a Preview toggle; while a report or a voice revision streams it shows
/// `model.streamingReportText`, read-only. Under it the folded "Style check" list of lint findings (clicking one selects
/// its range in the editor).
///
/// Step 5 (D8): the editor is what the referee came to write, so it gets the room; checks and copies say what they are
/// and that they acted ("Copied"). D33: the Export menu copies the two boxes of a journal system, the comments to the
/// authors and the confidential comments to the editor.
///
/// Errors of the review lane are the Shell's banner; an export that fails is said here, in red, since the sidebar
/// shows no banner of its own.
struct SidebarReportTab: View {
    let model: ReviewSessionModel
    @Environment(\.uiActions) private var uiActions

    /// Which control shows "Copied" for a moment after a copy.
    enum CopyFeedback: Equatable { case copyText, exportMenu }

    @State private var showsPreview = false
    @State private var confirmsRegenerate = false
    @State private var exportProblem: String?
    @State private var reveal: SidebarEditorReveal?
    @State private var showsStyleCheck = false
    @State private var venueChoice: Bool?           // the referee opened or closed "Venue and notes"; nil: by the rule
    @State private var copied: CopyFeedback?
    @State private var copySerial = 0

    var body: some View {
        let comments = model.session?.comments ?? []
        let report = model.session?.report
        let streaming = streamingKind
        VStack(alignment: .leading, spacing: 0) {
            controls(comments: comments, report: report, streaming: streaming)
            Divider()
            editorArea(report: report, streaming: streaming, hasApprovedComments: !SidebarReportFacts.reportComments(comments).isEmpty)
                .frame(maxHeight: .infinity)
            if let report, streaming == nil {
                Divider()
                styleCheck(report)
            }
        }
        .onChange(of: report != nil) { _, _ in venueChoice = nil }
        .task(id: copySerial) {
            guard copySerial > 0 else { return }
            do {
                try await Task.sleep(for: Theme.feedbackDuration)
                copied = nil
            } catch {
                // A newer copy or the tab going away: its own feedback, or none.
            }
        }
    }

    /// The review lane is writing a report (`.report`) or revising its wording (`.revise`).
    private var streamingKind: RunKind? {
        if case .running(let kind, _, _) = model.runState, kind == .report || kind == .revise { return kind }
        return nil
    }

    private var isLaneBusy: Bool { model.runState != .idle }

    // ---- top ----

    private func controls(comments: [ReviewComment], report: ReportDraft?, streaming: RunKind?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            venueAndNotes(hasReport: report != nil)
            summaryRow(comments: comments, report: report, streaming: streaming)
            if let report, streaming == nil, recommendationDisagrees(report) {
                Label(SidebarReportFacts.mismatchMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.metadataFont)
                    .foregroundStyle(.orange)
            }
            buttons(comments: comments, report: report)
            if confirmsRegenerate {
                regenerateConfirmation
            }
            if let streaming {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(streaming == .revise ? "Revising the wording…" : "Writing the report…")
                        .font(Theme.metadataFont)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Stop") { model.cancelRun() }
                        .controlSize(.small)
                }
            }
            if let exportProblem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(exportProblem)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { self.exportProblem = nil }
                        .controlSize(.small)
                }
                .font(Theme.metadataFont)
                .foregroundStyle(.red)
            }
        }
        .padding(Theme.sidebarPadding)
    }

    /// Venue and notes, open while there is no report (they go into it) and folded once one exists. The venue is the
    /// paper's (step 5, G.9): its name and kind, and "Change…", which opens the toolbar's venue menu.
    private func venueAndNotes(hasReport: Bool) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { venueChoice ?? !hasReport }, set: { venueChoice = $0 })) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    fieldLabel("Venue")
                    venueRow
                }
                GridRow {
                    fieldLabel("Notes")
                    TextField("Notes for the report", text: notes, prompt: Text("Notes for the report"), axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }
            .controlSize(.small)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Venue and notes")
                    .font(Theme.metadataFont.weight(.semibold))
                // The venue stays in sight when the group is folded (step 5, G.9).
                Text(SidebarReportFacts.venueShortName(model.currentVenue))
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The paper's venue: the kind's symbol, the name over the kind, and "Change…".
    private var venueRow: some View {
        let venue = model.currentVenue
        let lines = SidebarReportFacts.venueLines(venue, typedName: model.session?.meta.targetVenue)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Theme.venueSymbol(venue.kind))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(lines.name)
                    .font(Theme.bodyFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(lines.kind)
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)                               // one line at any width: the tab asks for no height of its own (§9.2)
            }
            Spacer(minLength: 4)
            Button("Change…") { uiActions.chooseVenue() }
                .disabled(model.session == nil)
                .help("Choose the venue in the toolbar's venue menu; Settings ▸ Venues edits the venues")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Venue: \(lines.name), \(lines.kind)"))
    }

    /// "2 approved comments (1 major, 1 minor)" and, once there is a report, its recommendation (D8).
    private func summaryRow(comments: [ReviewComment], report: ReportDraft?, streaming: RunKind?) -> some View {
        let summary = SidebarReportFacts.approvedSummaryParts(of: comments)
        return HStack(alignment: .center, spacing: 8) {
            // On one line when it fits, else broken between the count and the kinds.
            ViewThatFits(in: .horizontal) {
                Text(SidebarReportFacts.approvedSummary(of: comments))
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.count)
                        .lineLimit(2)
                    if let kinds = summary.kinds {
                        Text(kinds)
                            .lineLimit(2)
                    }
                }
            }
            .font(Theme.metadataFont)
            .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if report != nil {
                Text("Recommendation")
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                recommendationPicker
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .disabled(streaming != nil)
                    .help(model.currentVenue.kind == .conference ? "The recommendation in the report, on the venue's scale"
                                                                 : "The recommendation in the report")
            }
        }
    }

    /// A journal's four recommendations; a conference's scale (step 5, G.9), its labels most favourable first.
    @ViewBuilder private var recommendationPicker: some View {
        if model.currentVenue.kind == .conference {
            Picker("Recommendation", selection: recommendationLabelChoice) {
                Text("Not set").tag(String?.none)
                ForEach(model.recommendationScale, id: \.self) { label in
                    Text(label).tag(String?.some(label))
                }
            }
        } else {
            Picker("Recommendation", selection: recommendationChoice) {
                Text("Not set").tag(Recommendation?.none)
                ForEach(Recommendation.allCases, id: \.self) { value in
                    Text(SidebarReportFacts.title(of: value)).tag(Recommendation?.some(value))
                }
            }
        }
    }

    /// The recommendation the picker shows disagrees with the concerns the report lists, on the venue's scale.
    private func recommendationDisagrees(_ report: ReportDraft) -> Bool {
        let venue = model.currentVenue
        if venue.kind == .conference {
            return SidebarReportFacts.recommendationMismatch(label: model.recommendationLabel, venue: venue, markdown: report.markdown)
        }
        return SidebarReportFacts.recommendationMismatch(report.recommendation, markdown: report.markdown)
    }

    /// Generate (prominent) while there is no report; then Copy Text (prominent), Export ▾, Revise Voice, Regenerate
    /// and Versions ▾ (D8).
    @ViewBuilder private func buttons(comments: [ReviewComment], report: ReportDraft?) -> some View {
        let canGenerate = !isLaneBusy && !SidebarReportFacts.reportComments(comments).isEmpty
        SidebarFlowLayout(spacing: 6, lineSpacing: 6) {
            if let report {
                copyTextButton
                exportMenu(report)
                reviseVoiceButton(report)
                Button("Regenerate") { generate(report) }
                    .buttonStyle(.bordered)
                    .disabled(!canGenerate)
                    .help("Write the report again from the approved comments (⇧⌘R)")
                versionsMenu(report)
            } else {
                Button("Generate") { generate(nil) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canGenerate)
                    .help("Write the report from the approved comments (⇧⌘R)")
                reviseVoiceButton(nil)
                versionsMenu(nil)
                exportMenu(nil)
            }
        }
        .controlSize(.small)
    }

    /// Copies the report as plain text, for a journal's web form; reads "Copied" for a moment after (D8).
    private var copyTextButton: some View {
        Button {
            copy(model.reportText(format: .plainText), feedback: .copyText)
        } label: {
            // Both labels take part in the size, so that the row does not move when the label changes.
            ZStack {
                Label("Copy Text", systemImage: "doc.on.doc").opacity(copied == .copyText ? 0 : 1)
                Label("Copied", systemImage: "checkmark").opacity(copied == .copyText ? 1 : 0)
            }
        }
        .buttonStyle(.borderedProminent)
        .help("Copy the report as plain text")
        .accessibilityLabel(copied == .copyText ? "Copied" : "Copy Text")
    }

    private func reviseVoiceButton(_ report: ReportDraft?) -> some View {
        Button("Revise Voice") { model.reviseReportVoice() }
            .buttonStyle(.bordered)
            .disabled(isLaneBusy || (report?.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
            .help("Ask the model to reword the report so that it reads as yours, fixing the style check's findings")
    }

    private var regenerateConfirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You have edited this report. Regenerating replaces the text; your edited version stays under Versions.")
                .font(Theme.bodyFont)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel") { confirmsRegenerate = false }
                Button("Regenerate") {
                    confirmsRegenerate = false
                    model.generateReport()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func versionsMenu(_ report: ReportDraft?) -> some View {
        let versions = report?.versions ?? []
        return Menu("Versions") {
            ForEach(Array(versions.indices.reversed()), id: \.self) { index in
                Button(Self.versionTitle(versions[index])) {
                    model.restoreReportVersion(at: index)
                    showsPreview = false
                }
            }
        }
        .fixedSize()
        .disabled(versions.isEmpty || isLaneBusy)
        .help(versions.isEmpty ? "No earlier versions yet" : "Restore an earlier version; the text it replaces is kept as a version")
    }

    /// Copy Markdown; the journal's two boxes (D33); the four files.
    private func exportMenu(_ report: ReportDraft?) -> some View {
        let markdown = report?.markdown ?? ""
        return Menu {
            Button("Copy Markdown") { copy(model.reportText(format: .markdown), feedback: .exportMenu) }
            Section {
                Button("Copy Comments to the Authors") { copy(SidebarReportFacts.authorsText(markdown), feedback: .exportMenu) }
                    .disabled(SidebarReportFacts.authorsMarkdown(markdown).isEmpty)
                Button(SidebarReportFacts.confidentialCopyTitle(model.currentVenue.kind)) {
                    copy(SidebarReportFacts.editorText(markdown), feedback: .exportMenu)
                }
                .disabled(SidebarReportFacts.editorMarkdown(markdown).isEmpty)
            }
            Divider()
            Button("Markdown File…") { export(.markdown) }
            Button("Text File…") { export(.plainText) }
            Button("Word Document…") { export(.docx) }
            Button("PDF…") { export(.pdf) }
        } label: {
            if copied == .exportMenu {
                Label("Copied", systemImage: "checkmark")
            } else {
                Text("Export")
            }
        }
        .fixedSize()
        .disabled(report == nil)
        .help(model.currentVenue.kind == .conference
              ? "Copy or save the report; the two copies for a review system leave out what only the program committee may read"
              : "Copy or save the report; the two copies for a journal system leave out what only the editor may read")
    }

    // ---- editor ----

    private func editorArea(report: ReportDraft?, streaming: RunKind?, hasApprovedComments: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Report")
                    .font(Theme.metadataFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let report, report.userEdited, streaming == nil {
                    Text("edited")
                        .font(Theme.metadataFont)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Picker("View", selection: $showsPreview) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .disabled(report == nil || streaming != nil)
            }
            .padding(.horizontal, Theme.sidebarPadding)
            .padding(.vertical, 6)
            Divider()
            if streaming != nil {
                SidebarMarkdownEditor(text: model.streamingReportText, isEditable: false, followsEnd: true)
            } else if let report {
                if showsPreview {
                    SidebarMarkdownPreviewView(markdown: report.markdown)
                } else {
                    SidebarMarkdownEditor(text: report.markdown, isEditable: true, reveal: reveal,
                                          onEdit: { model.updateReportMarkdown($0) })
                }
            } else {
                emptyEditor(hasApprovedComments: hasApprovedComments)
            }
        }
    }

    /// No report yet. Without an approved comment, a way back to the comments that wait for a decision (D8).
    private func emptyEditor(hasApprovedComments: Bool) -> some View {
        VStack(spacing: 10) {
            Text(hasApprovedComments ? "No report yet. Generate one from the approved comments."
                                     : "Approve at least one comment, then generate the report.")
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !hasApprovedComments {
                Button("Show Pending Comments") {
                    model.filter = .pending
                    model.sidebarTab = .comments
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show the comments that still wait for a decision")
            }
        }
        .padding(Theme.sidebarPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ---- style check ----

    /// Folded at first; the header keeps the number of findings. Each finding: its rule's title and the passage, then
    /// the message; a click selects the passage in the editor (D8).
    private func styleCheck(_ report: ReportDraft) -> some View {
        let findings = model.lintFindings
        return DisclosureGroup(isExpanded: $showsStyleCheck) {
            if findings.isEmpty {
                Text("Nothing to flag.")
                    .font(Theme.metadataFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } else {
                ViewThatFits(in: .vertical) {
                    findingRows(findings, in: report.markdown)
                    ScrollView { findingRows(findings, in: report.markdown) }
                }
                .frame(maxHeight: 120)
                .padding(.top, 4)
            }
        } label: {
            HStack(spacing: 6) {
                Text("Style check")
                    .font(Theme.metadataFont.weight(.semibold))
                if !findings.isEmpty {
                    // The shared tag (D16): orange on an orange tint, legible where white on orange was not.
                    CommonTag("\(findings.count)", color: .orange)
                        .accessibilityLabel(findings.count == 1 ? "1 finding" : "\(findings.count) findings")
                }
            }
        }
        .padding(.horizontal, Theme.sidebarPadding)
        .padding(.vertical, 6)
    }

    private func findingRows(_ findings: [LintFinding], in markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(findings) { finding in
                Button {
                    select(finding, in: markdown)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(SidebarReportFacts.ruleTitle(finding.rule))
                                .font(Theme.metadataFont.weight(.semibold))
                                .foregroundStyle(.primary)
                                .fixedSize()
                            if let excerpt = SidebarReportFacts.excerpt(of: finding, in: markdown) {
                                Text(SidebarText.quoted(excerpt))
                                    .font(Theme.metadataFont)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(finding.message)
                            .font(Theme.metadataFont)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Select this passage in the report")
            }
        }
    }

    // ---- bindings and actions ----

    private var notes: Binding<String> {
        Binding(get: { model.session?.meta.reviewerNotes ?? "" },
                set: { value in
                    guard var meta = model.session?.meta else { return }
                    meta.reviewerNotes = value
                    model.updateMeta(meta)
                })
    }

    private var recommendationChoice: Binding<Recommendation?> {
        Binding(get: { model.session?.report?.recommendation }, set: { model.setRecommendation($0) })
    }

    /// A conference's recommendation, a label of the venue's scale (step 5, G.9).
    private var recommendationLabelChoice: Binding<String?> {
        Binding(get: { model.recommendationLabel }, set: { model.setRecommendation(label: $0) })
    }

    /// Regenerating a report the referee edited asks first (section 6.10).
    private func generate(_ report: ReportDraft?) {
        if report?.userEdited == true {
            confirmsRegenerate = true
        } else {
            model.generateReport()
        }
    }

    /// Puts `text` on the pasteboard and lets `feedback` read "Copied" for `Theme.feedbackDuration` (D8, D33).
    private func copy(_ text: String, feedback: CopyFeedback) {
        SidebarPasteboard.copy(text)
        copied = feedback
        copySerial += 1
    }

    private func export(_ format: ExportFormat) {
        exportProblem = SidebarReportExport.run(format, model: model)
    }

    private func select(_ finding: LintFinding, in markdown: String) {
        showsPreview = false
        reveal = SidebarEditorReveal(serial: (reveal?.serial ?? 0) + 1, range: SidebarReportFacts.clampedRange(of: finding, in: markdown))
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.metadataFont)
            .foregroundStyle(.secondary)
    }

    /// "Before regenerate · 23 Nov 2026 at 10:15".
    static func versionTitle(_ version: ReportVersion) -> String {
        let note = version.note.prefix(1).uppercased() + version.note.dropFirst()
        return note + " · " + version.savedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
