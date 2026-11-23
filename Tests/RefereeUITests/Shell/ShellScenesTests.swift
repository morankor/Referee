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
    }

    @Test func thePhaseTextNamesThePart() {
        #expect(ShellReviewButton.phaseText(kind: .review, phase: .reading(part: 2, of: 5)) == "Reading part 2 of 5…")
        #expect(ShellReviewButton.phaseText(kind: .review, phase: .reading(part: 1, of: 1)) == "Reading the paper…")
        #expect(ShellReviewButton.phaseText(kind: .review, phase: .wholePaperPass) == "Reading the whole paper…")
        #expect(ShellReviewButton.phaseText(kind: .review, phase: nil) == "Preparing the review…")
        #expect(ShellReviewButton.phaseText(kind: .report, phase: nil) == "Writing the report…")
    }

    @Test func onlyPDFsAreTakenFromADrop() throws {
        #expect(ReviewWindowView.isPDF(Fixtures.url("pdf/ay_nolinks.pdf")))
        #expect(!ReviewWindowView.isPDF(Fixtures.url("sessions/sample.json")))
        #expect(!ReviewWindowView.isPDF(try #require(URL(string: "https://example.org/paper.pdf"))))
        #expect(ReviewWindowView.isPDF(URL(fileURLWithPath: "/no/such/folder/paper.PDF")))      // by its extension when the file says nothing
    }

    @Test func theDataFolderIsShownWithoutTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shown = ShellPrivacyPane.displayPath(home.appendingPathComponent("Library/Application Support/Referee"))
        #expect(shown == "~/Library/Application Support/Referee")
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
