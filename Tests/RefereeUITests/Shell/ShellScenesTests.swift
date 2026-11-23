import AppKit
import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// The Shell's scenes (plan.md section 10.1) and the small pieces of the app around the windows.
@Suite @MainActor struct ShellScenesTests {
    @Test func theRequiredScenesExistWithTheirKinds() {
        let scenes = Dictionary(ShellScenes.all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let required: [(String, SnapshotScene.Kind)] = [
            ("placeholder", .review), ("welcome", .welcome), ("review-empty", .review), ("consent", .review), ("banner-error", .review),
            ("settings-providers", .settings), ("settings-prompts", .settings), ("settings-privacy", .settings),
        ]
        for (name, kind) in required {
            #expect(scenes[name]?.kind == kind, "scene \(name)")
        }
        #expect(ShellScenes.all.first?.name == "placeholder")
    }

    /// The scenes the design review names for the Shell, and the one of step 5b.
    @Test func theDesignScenesOfStep5Exist() {
        let names = Set(ShellScenes.all.map(\.name))
        for name in ["design-review-split-destinations", "design-review-provider-offline", "design-review-choose-model", "design-review-custom-menu"] {
            #expect(names.contains(name), "scene \(name)")
        }
        #expect(ShellScenes.all.filter { $0.name == "review-destination-menu" }.first?.fixtureSession == "sample.json")   // D34
    }

    /// Step 5, G.9: the venue menu and Settings ▸ Venues.
    @Test func theVenueScenesExist() {
        let scenes = Dictionary(ShellScenes.all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(scenes["design-venue-menu"]?.kind == .review)
        #expect(scenes["settings-venues"]?.kind == .settings)
    }

    /// Every review scene names a fixture that exists; no scene names a session without a PDF.
    @Test func everySceneCanBePrepared() {
        for scene in ShellScenes.all {
            if scene.kind == .review || scene.kind == .referenceViewer {
                guard let pdf = scene.fixturePDF else {
                    Issue.record("scene \(scene.name) names no fixture PDF")
                    continue
                }
                #expect(FileManager.default.fileExists(atPath: Fixtures.url("pdf/\(pdf)").path), "scene \(scene.name)")
            }
            if let session = scene.fixtureSession {
                #expect(scene.fixturePDF != nil, "scene \(scene.name)")
                #expect(FileManager.default.fileExists(atPath: Fixtures.url("sessions/\(session)").path), "scene \(scene.name)")
            }
            #expect(scene.verify != nil, "scene \(scene.name) checks nothing")
        }
    }

    @Test func theCommandLineNamesFilesToOpen() throws {
        let root = Fixtures.root
        let files = ShellAppDelegate.files(in: ["-NSDocumentRevisionsDebugMode", "YES", "Fixtures/pdf/ay_nolinks.pdf", "--flag",
                                                "Fixtures/pdf/no_such.pdf", "Fixtures/pdf", Fixtures.url("pdf/s1_ruler.pdf").path],
                                           relativeTo: root)
        #expect(files.map(\.lastPathComponent) == ["ay_nolinks.pdf", "s1_ruler.pdf"])
        #expect(files.allSatisfy { $0.path.hasPrefix("/") && $0.baseURL == nil })
    }

    @Test func recentReviewsSayHowFarTheTriageIs() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let pending = SessionSummary(id: "a", fileName: "a.pdf", title: "A title", updatedAt: date, commentCount: 12, pendingCount: 3, hasReport: false)
        let done = SessionSummary(id: "b", fileName: "b.pdf", title: "  ", updatedAt: date, commentCount: 1, pendingCount: 0, hasReport: true)
        let empty = SessionSummary(id: "c", fileName: "c.pdf", updatedAt: date, commentCount: 0, pendingCount: 0, hasReport: false)
        #expect(ShellRecentReviewRow.progress(pending) == "12 comments · 3 pending")
        #expect(ShellRecentReviewRow.progress(done) == "1 comment · report drafted")
        #expect(ShellRecentReviewRow.progress(empty) == "No comments yet")
        #expect(ShellRecentReviewRow.title(pending) == "A title")
        #expect(ShellRecentReviewRow.title(done) == "b.pdf")
        #expect(ShellRecentReviewRow.title(empty) == "c.pdf")
        // D26: only the pending count stands out.
        #expect(ShellRecentReviewRow.progressParts(pending).map(\.standsOut) == [false, true])
        #expect(ShellRecentReviewRow.progressParts(done).map(\.standsOut) == [false, false])
        let line = ShellRecentReviewRow.progressText(pending)
        #expect(String(line.characters) == "12 comments · 3 pending")
        #expect(line.runs.filter { $0.foregroundColor != nil }.map { String(line[$0.range].characters) } == ["3 pending"])
    }

    /// D26: a review whose file is gone, or whose place is not known, is found before the window shows the list.
    @Test func theRecentReviewsWhoseFileIsGoneAreFound() async {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let here = SessionSummary(id: "here", fileName: "ay_nolinks.pdf", lastKnownPath: Fixtures.url("pdf/ay_nolinks.pdf").path, updatedAt: date,
                                  commentCount: 1, pendingCount: 0, hasReport: false)
        let gone = SessionSummary(id: "gone", fileName: "x.pdf", lastKnownPath: "/no/such/folder/x.pdf", updatedAt: date, commentCount: 0,
                                  pendingCount: 0, hasReport: false)
        let unknown = SessionSummary(id: "unknown", fileName: "y.pdf", updatedAt: date, commentCount: 0, pendingCount: 0, hasReport: false)
        #expect(await ShellWindowManager.missingFiles(of: [here, gone, unknown]) == ["gone", "unknown"])
        #expect(ShellDeleteReviewData.message(fileName: "x.pdf") == "Delete the review data of “x.pdf”?")
    }

    @Test func thePhaseTextNamesThePart() {
        #expect(ShellReviewButton.phaseText(kind: .review, phase: .reading(part: 2, of: 5)) == "Reading part 2 of 5…")
        #expect(ShellReviewButton.phaseText(kind: .review, phase: .reading(part: 1, of: 1)) == "Reading the paper…")
        #expect(ShellReviewButton.phaseText(kind: .review, phase: .wholePaperPass) == "Reading the whole paper…")
        #expect(ShellReviewButton.phaseText(kind: .review, phase: nil) == "Preparing the review…")
        #expect(ShellReviewButton.phaseText(kind: .report, phase: nil) == "Writing the report…")
    }

    /// D9: the phase without its "…", and the time since the job started.
    @Test func theProgressSaysHowLongTheJobHasRun() {
        #expect(ShellReviewButton.progressText(kind: .review, phase: .reading(part: 2, of: 5), elapsed: 192) == "Reading part 2 of 5 · 3:12")
        #expect(ShellReviewButton.progressText(kind: .review, phase: .reading(part: 1, of: 1), elapsed: 4.9) == "Reading the paper · 0:04")
        #expect(ShellReviewButton.progressText(kind: .report, phase: nil, elapsed: 61) == "Writing the report · 1:01")
        #expect(ShellReviewButton.elapsedText(0) == "0:00")
        #expect(ShellReviewButton.elapsedText(-3) == "0:00")
        #expect(ShellReviewButton.elapsedText(3_599) == "59:59")
        #expect(ShellReviewButton.elapsedText(3_600) == "1:00:00")
        #expect(ShellReviewButton.elapsedText(4_000) == "1:06:40")
    }

    /// D9: a gauge for a review read in parts: parts done of the parts and the whole-paper pass.
    @Test func aReviewInPartsHasAGauge() {
        #expect(ShellReviewButton.gauge(kind: .review, phase: .reading(part: 1, of: 3))?.value == 0)
        #expect(ShellReviewButton.gauge(kind: .review, phase: .reading(part: 1, of: 3))?.total == 4)
        #expect(ShellReviewButton.gauge(kind: .review, phase: .reading(part: 3, of: 3))?.value == 2)
        #expect(ShellReviewButton.gauge(kind: .review, phase: .reading(part: 1, of: 1)) == nil)
        #expect(ShellReviewButton.gauge(kind: .review, phase: .wholePaperPass) == nil)
        #expect(ShellReviewButton.gauge(kind: .report, phase: nil) == nil)
    }

    /// D20 and D30: "Review Again" once the session holds AI comments, prominent only before the first comment; the
    /// question before a second review only for a provider that is not on this Mac.
    @Test func aSecondReviewIsNamedAndAskedAbout() async throws {
        let fresh = try await ShellTestModels.openedOnTheSnapshotRegistry(settings: SnapshotSupport.settings())
        await ShellSceneSupport.wait { fresh.sendPlan != nil }
        #expect(ShellReviewButton.title(fresh) == "Review")
        #expect(ShellReviewButton.isProminent(fresh))
        #expect(ShellReviewButton.reviewAgainQuestion(fresh) == nil)

        let reviewed = try await ShellTestModels.openedOnTheSnapshotRegistry(settings: SnapshotSupport.settings(),
                                                                            comments: [ShellTestData.comment("Earlier", page: 0)])
        await ShellSceneSupport.wait { reviewed.sendPlan != nil }
        #expect(ShellReviewButton.title(reviewed) == "Review Again")
        #expect(!ShellReviewButton.isProminent(reviewed))
        #expect(ShellReviewButton.reviewAgainQuestion(reviewed) == nil)            // "mock" is on this Mac: no question
        reviewed.setActiveProvider(ProviderRef(providerID: "mock-remote", model: nil))
        await ShellSceneSupport.wait { reviewed.activeProvider?.id == "mock-remote" && reviewed.sendPlan != nil }
        #expect(ShellReviewButton.reviewAgainQuestion(reviewed)
                == "The model reads the paper again: about 18,000 tokens to this Mac. New comments are added next to the existing ones; nothing is removed.")
    }

    /// D19: a narrow window hides the navigator, a wide one brings it back, a choice by hand ends the rule.
    @Test func theNavigatorStepsAsideInANarrowWindow() {
        let state = ShellReviewWindowState()
        state.adaptNavigator(toWidth: 1_280)
        #expect(state.showsNavigator)
        state.adaptNavigator(toWidth: 1_000)
        #expect(!state.showsNavigator)
        state.adaptNavigator(toWidth: 1_200)                     // between the two: as it is
        #expect(!state.showsNavigator)
        state.adaptNavigator(toWidth: 1_240)
        #expect(state.showsNavigator)
        state.adaptNavigator(toWidth: 1_099)
        #expect(!state.showsNavigator)
        state.toggleNavigator()                                  // shown by hand: the rule leaves it alone
        #expect(state.showsNavigator)
        state.adaptNavigator(toWidth: 1_000)
        #expect(state.showsNavigator)
        state.toggleNavigator()
        state.adaptNavigator(toWidth: 1_600)
        #expect(!state.showsNavigator)
    }

    /// A hidden sidebar shows when the model opens something in it, and is never hidden by itself.
    @Test func theSidebarShowsWhenSomethingOpensInIt() {
        let session = UUID()
        let idle = ShellSidebarDemand(sessionID: session, composing: false, editingCommentID: nil, openThreadCommentID: nil, conversations: 1,
                                      tab: .comments)
        func after(_ change: (inout ShellSidebarDemand) -> Void) -> ShellSidebarDemand {
            var new = idle
            change(&new)
            return new
        }
        #expect(ShellSidebarDemand.opensSomething(from: idle, to: after { $0.composing = true }))           // Comment, N
        #expect(ShellSidebarDemand.opensSomething(from: idle, to: after { $0.editingCommentID = UUID() }))  // E, Add as Comment
        #expect(ShellSidebarDemand.opensSomething(from: idle, to: after { $0.openThreadCommentID = UUID() }))
        #expect(ShellSidebarDemand.opensSomething(from: idle, to: after { $0.conversations = 2 }))         // Ask AI's new conversation
        #expect(ShellSidebarDemand.opensSomething(from: idle, to: after { $0.tab = .chat }))               // ask() and ⌘2 switch the tab
        // Closing things, or another session's conversations (a document opened), show nothing.
        let busy = after { $0.composing = true; $0.editingCommentID = UUID(); $0.openThreadCommentID = UUID() }
        #expect(!ShellSidebarDemand.opensSomething(from: busy, to: idle))
        #expect(!ShellSidebarDemand.opensSomething(from: idle, to: after { $0.conversations = 0 }))
        #expect(!ShellSidebarDemand.opensSomething(from: idle, to: after { $0.sessionID = UUID(); $0.conversations = 5 }))
        #expect(!ShellSidebarDemand.opensSomething(from: idle, to: idle))
        #expect(Set(ShellScenes.all.map(\.name)).contains("design-review-sidebar-returns"))
    }

    /// D32: what the Dock says after a job that ended in the background.
    @Test func theDockCountsTheNewCommentsOrTicksAReport() {
        let run = RunRecord(id: UUID(), kind: .review, provider: ProviderRef(providerID: "mock", model: nil), destination: "", sentPDF: false,
                            requestCount: 1, startedAt: ShellTestData.date, status: .completed)
        let report = RunRecord(id: UUID(), kind: .report, provider: ProviderRef(providerID: "mock", model: nil), destination: "", sentPDF: false,
                               requestCount: 1, startedAt: ShellTestData.date, status: .completed)
        func comment(_ origin: CommentOrigin) -> ReviewComment {
            var comment = ShellTestData.comment("C", page: 0)
            comment.origin = origin
            return comment
        }
        let document = DocumentRef(sha256: "a", fileName: "a.pdf", byteCount: 1, pageCount: 1)
        var session = ReviewSession(schemaVersion: 1, id: UUID(), document: document, meta: ManuscriptMeta(reviewerNotes: ""),
                                    comments: [comment(.ai(runID: run.id)), comment(.ai(runID: run.id)), comment(.ai(runID: UUID())), comment(.user)],
                                    runs: [run], createdAt: ShellTestData.date, updatedAt: ShellTestData.date)
        #expect(ShellDockBadge.label(after: .review, session: session) == "2")
        #expect(ShellDockBadge.label(after: .report, session: session) == nil)
        session.runs.append(report)
        #expect(ShellDockBadge.label(after: .report, session: session) == "✓")
        session.runs[1].status = .failed("The provider is overloaded.")
        #expect(ShellDockBadge.label(after: .report, session: session) == nil)
        #expect(ShellDockBadge.label(after: .discussion, session: session) == nil)
        #expect(ShellDockBadge.combine("2", with: "3") == "5")
        #expect(ShellDockBadge.combine("✓", with: "3") == "3")
        #expect(ShellDockBadge.combine(nil, with: "✓") == "✓")
    }

    @Test func onlyPDFsAreTakenFromADrop() throws {
        #expect(ReviewWindowView.isPDF(Fixtures.url("pdf/ay_nolinks.pdf")))
        #expect(!ReviewWindowView.isPDF(Fixtures.url("sessions/sample.json")))
        #expect(!ReviewWindowView.isPDF(try #require(URL(string: "https://example.org/paper.pdf"))))
        #expect(ReviewWindowView.isPDF(URL(fileURLWithPath: "/no/such/folder/paper.PDF")))      // by its extension when the file says nothing
    }

    @Test func theDataFolderIsShownWithoutTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shown = ShellPrivacyPane.displayPath(home.appendingPathComponent("Library/Application Support/Human in the Loop"))
        #expect(shown == "~/Library/Application Support/Human in the Loop")
        #expect(ShellPrivacyPane.displayPath(nil) == "Not known")
    }

    @Test func theExportFormatsHaveTheirFileTypes() {
        #expect(ShellExportFormatPicker.contentType(.pdf) == .pdf)
        #expect(ShellExportFormatPicker.contentType(.plainText) == .plainText)
        #expect(ShellExportFormatPicker.contentType(.markdown).tags[.filenameExtension]?.contains("md") == true)
        #expect(ShellExportFormatPicker.contentType(.docx).preferredFilenameExtension == "docx")
        #expect(ExportFormat.allCases.map(ShellExportFormatPicker.fileExtension) == ["md", "txt", "docx", "pdf"])
        #expect(ShellExportFormatPicker.fileName("paper report", for: .markdown) == "paper report.md")
        #expect(ShellExportFormatPicker.fileName("paper report.md", for: .docx) == "paper report.docx")
        #expect(ShellExportFormatPicker.fileName("paper.v2 report", for: .pdf) == "paper.v2 report.pdf")
        #expect(ShellExportFormatPicker.fileName("paper report.markdown", for: .plainText) == "paper report.txt")
        #expect(ShellExportFormatPicker.choices.map(\.0) == ExportFormat.allCases)
    }
}
