import Foundation
import Testing
import PDFKit
import RefereeCore
import AppCore
import TestSupport
import Composition
import Persistence

/// Gate 1 (plan.md section 11.4), rows "mock review end to end", "model end to end", "snapshot graph" and "file
/// safety": the window model on the live graph, with the mock provider in place of a model.
@Suite struct IntegrationReviewTests {
    static let headings = ["Summary assessment", "Recommendation", "Publication probability", "Major concerns", "Minor concerns",
                           "Questions for the authors"]

    /// Opens the paper and runs a review through the mock; returns when the run is recorded.
    @MainActor static func reviewed(_ graph: LiveGraph, fixture: String = "ay_round_nolinks") async throws -> ReviewSessionModel {
        let model = ReviewSessionModel(dependencies: graph.dependencies, settings: try await graph.mockSettings())
        await model.open(url: Fixture.url(fixture))
        try #require(model.phase == .ready)
        try #require(await waitUntil { model.canStartReview }, "the review cannot start: \(String(describing: model.sendPlan))")
        model.startReview()
        try #require(await waitUntil { model.session?.runs.count == 1 && model.runState == .idle }, "the review did not end")
        return model
    }

    // ---- mock review end to end ----

    @Test @MainActor func aMockReviewGivesSixAnchoredCommentsAndTheSessionComesBack() async throws {
        let graph = await LiveGraph.make()
        defer { graph.remove() }
        let model = try await Self.reviewed(graph)
        let session = try #require(model.session)
        #expect(session.runs.first?.status == .completed)
        #expect(session.comments.count == 6)
        let exact = session.comments.filter { $0.anchor.confidence == .exact }
        #expect(exact.count >= 5, "\(session.comments.map(\.anchor.confidence))")
        #expect(exact.allSatisfy { !$0.anchor.rects.isEmpty && $0.anchor.rects.allSatisfy { $0.x >= 100 } })
        await model.flushPendingSave()

        // Saved, and reloadable by a store that knows nothing of this window (the app after a restart).
        let reloaded = try #require(try await FileSessionStore(directory: graph.home.appendingPathComponent("sessions"))
            .loadSession(sha256: session.document.sha256))
        #expect(reloaded.comments.map(\.id) == session.comments.map(\.id))
        #expect(reloaded.comments.map(\.anchor.spans) == session.comments.map(\.anchor.spans))
        #expect(reloaded.runs.map(\.id) == session.runs.map(\.id))
        #expect(FileManager.default.fileExists(atPath: graph.sessionFolder(session.document.sha256).appendingPathComponent("session.json").path))
        await model.close()
    }

    // ---- model end to end ----

    @Test @MainActor func approvingEverythingAndGeneratingTheReportGivesAPaginatedPDF() async throws {
        let graph = await LiveGraph.make()
        defer { graph.remove() }
        let model = try await Self.reviewed(graph)
        for comment in model.session?.comments ?? [] { model.setStatus(.approved, for: comment.id) }
        #expect(model.triage.decided == 6)
        model.generateReport()
        try #require(await waitUntil { model.session?.report != nil && model.runState == .idle }, "no report")
        let markdown = try #require(model.session?.report?.markdown)
        for heading in Self.headings {
            #expect(markdown.contains("## \(heading)"), "\(heading)")
        }
        #expect(model.session?.report?.basedOnCommentIDs.count == 6)
        #expect(!model.lintFindings.isEmpty)                             // the sample report has three deliberate hits

        let file = graph.home.appendingPathComponent("report.pdf")
        try model.exportReport(format: .pdf, to: file)
        let document = try #require(PDFDocument(url: file))
        #expect(document.pageCount >= 1)
        for index in 0..<document.pageCount {
            #expect((document.page(at: index)?.string ?? "").count > 50, "page \(index + 1) has no text")
        }
        await model.close()
    }

    // ---- snapshot graph ----

    @Test @MainActor func theSnapshotGraphReviewsOnMocksOnly() async throws {
        let graph = await LiveGraph.make(["REFEREE_SNAPSHOT": "1"], mock: false)
        defer { graph.remove() }
        // By construction nothing here can start a URLSession task or a process: every provider is a mock or a static
        // row, and the resolver is the fake one.
        #expect(graph.dependencies.providers.all.allSatisfy { $0 is MockLLMProvider || $0 is StaticProvider })
        #expect(graph.dependencies.resolver is FakeResolver)

        let settings = SnapshotSupport.settings()
        for (id, status) in [("mock-remote", "completed"), ("mock-fail", "failed")] {
            var chosen = settings
            chosen.defaults.review = ProviderRef(providerID: id, model: "mock")
            chosen.privacy.confirmFirstSendPerDocument = false              // no consent card in a test
            let model = ReviewSessionModel(dependencies: graph.dependencies, settings: chosen)
            await model.open(url: Fixture.url("ay_round_nolinks"))
            #expect(model.activeProvider?.id == id)
            try #require(await waitUntil { model.canStartReview }, "\(id) cannot start")
            model.startReview()
            try #require(await waitUntil { model.session?.runs.isEmpty == false && model.runState == .idle }, "\(id) did not end")
            let run = try #require(model.session?.runs.last)
            switch (status, run.status) {
            case ("completed", .completed):
                #expect(run.destination == "mock.example.org")
                #expect(model.session?.comments.count == 6)
            case ("failed", .failed):
                #expect(model.session?.comments.count == 2)              // the third block has no title or body (section 5.9)
                #expect(model.banner?.action == .retry)
            default:
                Issue.record("\(id): expected \(status), got \(run.status)")
            }
            await model.deleteReviewData()                                // the next provider starts from an empty session
        }
    }

    // ---- file safety ----

    @Test @MainActor func theFixtureIsUntouchedAndDeletingTheReviewRemovesItsFolder() async throws {
        let graph = await LiveGraph.make()
        defer { graph.remove() }
        let url = Fixture.url("ay_round_nolinks")
        let before = try Data(contentsOf: url)
        let model = try await Self.reviewed(graph)
        for comment in model.session?.comments ?? [] { model.setStatus(.approved, for: comment.id) }
        model.generateReport()
        try #require(await waitUntil { model.session?.report != nil && model.runState == .idle })
        await model.flushPendingSave()                                   // (no reference lookup here: it would reach Crossref)
        let sha256 = try #require(model.session?.document.sha256)
        #expect(FileManager.default.fileExists(atPath: graph.sessionFolder(sha256).path))
        #expect(try Data(contentsOf: url) == before)

        await model.deleteReviewData()
        #expect(!FileManager.default.fileExists(atPath: graph.sessionFolder(sha256).path))
        #expect(model.phase == .empty)
        try await Task.sleep(for: .milliseconds(300))                    // nothing writes the folder back afterwards
        #expect(!FileManager.default.fileExists(atPath: graph.sessionFolder(sha256).path))
        #expect(try Data(contentsOf: url) == before)
    }

    // ---- the seams Gate 1 opened in the graph ----

    @Test func theDebugTranscriptFolderComesFromTheEnvironmentGiven() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("referee-gate1-dump-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let graph = await LiveGraph.make(["REFEREE_DEBUG_DUMP": folder.path])
        defer { graph.remove() }
        #expect(graph.dependencies.dataDirectory?.standardizedFileURL == graph.home.standardizedFileURL)
        let paper = try await graph.dependencies.paperService.load(url: Fixture.url("ay_round_nolinks"))
        let settings = try await graph.mockSettings()
        let context = EngineContext(provider: ProviderRef(providerID: "mock", model: "mock"), providerSettings: try #require(settings.providers["mock"]),
                                    prompts: settings.prompts, rubric: settings.rubric, meta: ManuscriptMeta(reviewerNotes: ""))
        for try await _ in graph.dependencies.engine.ask(paper: paper, conversation: Conversation(id: UUID(), createdAt: Date()),
                                                         question: "Why?", context: context) {}
        await graph.dependencies.paperService.unload(paper.ref)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 1 && files.first?.hasSuffix("-question.txt") == true, "\(files)")

        // Without the variable no transcript is written, whatever the process environment holds.
        let quiet = await LiveGraph.make()
        defer { quiet.remove() }
        let other = try await quiet.dependencies.paperService.load(url: Fixture.url("ay_round_nolinks"))
        for try await _ in quiet.dependencies.engine.ask(paper: other, conversation: Conversation(id: UUID(), createdAt: Date()),
                                                         question: "Why?", context: context) {}
        await quiet.dependencies.paperService.unload(other.ref)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }
}
