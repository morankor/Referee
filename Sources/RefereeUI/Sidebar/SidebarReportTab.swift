import SwiftUI
import RefereeCore
import AppCore

/// The Report tab (plan.md sections 6.10 and 9.8). Top: target venue, notes for the report, the count of approved
/// comments, and Generate (or Regenerate), Revise Voice, Versions ▾, Export ▾. Body: the Markdown editor with a
/// Preview toggle; while a report or a voice revision streams it shows `model.streamingReportText`, read-only. Under it:
/// the collapsible "Style check" list of lint findings (clicking one selects its range in the editor) and the
/// recommendation picker, with the consistency warning when it disagrees with the concerns.
///
/// Errors of the review lane are the Shell's banner; an export that fails is said here, in red, since the sidebar
/// shows no banner of its own.
struct SidebarReportTab: View {
    let model: ReviewSessionModel

    @State private var showsPreview = false
    @State private var confirmsRegenerate = false
    @State private var exportProblem: String?
    @State private var reveal: SidebarEditorReveal?
    @State private var showsStyleCheck = true

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
                Divider()
                recommendation(report)
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
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    fieldLabel("Venue")
                    TextField("Target venue", text: venue, prompt: Text("Target journal or venue"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
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
            Text(SidebarReportFacts.approvedSummary(of: comments))
                .font(Theme.metadataFont)
                .foregroundStyle(.secondary)
            SidebarFlowLayout(spacing: 6, lineSpacing: 6) {
                Button(report == nil ? "Generate" : "Regenerate") { generate(report) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLaneBusy || SidebarReportFacts.reportComments(comments).isEmpty)
                    .help("Write the report from the approved comments (⇧⌘R)")
                Button("Revise Voice") { model.reviseReportVoice() }
                    .buttonStyle(.bordered)
                    .disabled(isLaneBusy || (report?.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
                    .help("Ask the model to reword the report so that it reads as yours, fixing the style check's findings")
                versionsMenu(report)
                exportMenu(report)
            }
            .controlSize(.small)
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

    private func exportMenu(_ report: ReportDraft?) -> some View {
        Menu("Export") {
            Button("Copy as Plain Text") { SidebarPasteboard.copy(model.reportText(format: .plainText)) }
            Button("Copy Markdown") { SidebarPasteboard.copy(model.reportText(format: .markdown)) }
            Divider()
            Button("Markdown File…") { export(.markdown) }
            Button("Text File…") { export(.plainText) }
            Button("Word Document…") { export(.docx) }
            Button("PDF…") { export(.pdf) }
        }
        .fixedSize()
        .disabled(report == nil)
        .help("Copy or save the report")
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
                Text(hasApprovedComments ? "No report yet. Generate one from the approved comments."
                                         : "Approve at least one comment, then generate the report.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(Theme.sidebarPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // ---- style check and recommendation ----

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
                .frame(maxHeight: 150)
                .padding(.top, 4)
            }
        } label: {
            HStack(spacing: 6) {
                Text("Style check")
                    .font(Theme.metadataFont.weight(.semibold))
                if !findings.isEmpty {
                    Text("\(findings.count)")
                        .font(Theme.metadataFont.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .background(Color.orange, in: Capsule())
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
                            Text(finding.rule)
                                .font(Theme.metadataFont.monospaced().weight(.semibold))
                                .foregroundStyle(.orange)
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Select this passage in the report")
            }
        }
    }

    private func recommendation(_ report: ReportDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Recommendation")
                    .font(Theme.bodyFont)
                Spacer(minLength: 4)
                Picker("Recommendation", selection: recommendationChoice) {
                    Text("Not set").tag(Recommendation?.none)
                    ForEach(Recommendation.allCases, id: \.self) { value in
                        Text(SidebarReportFacts.title(of: value)).tag(Recommendation?.some(value))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if SidebarReportFacts.recommendationMismatch(report.recommendation, markdown: report.markdown) {
                Label(SidebarReportFacts.mismatchMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.metadataFont)
                    .foregroundStyle(.orange)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.sidebarPadding)
        .padding(.vertical, 8)
    }

    // ---- bindings and actions ----

    private var venue: Binding<String> {
        Binding(get: { model.session?.meta.targetVenue ?? "" },
                set: { value in
                    guard var meta = model.session?.meta else { return }
                    meta.targetVenue = value.isEmpty ? nil : value
                    model.updateMeta(meta)
                })
    }

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

    /// Regenerating a report the referee edited asks first (section 6.10).
    private func generate(_ report: ReportDraft?) {
        if report?.userEdited == true {
            confirmsRegenerate = true
        } else {
            model.generateReport()
        }
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
