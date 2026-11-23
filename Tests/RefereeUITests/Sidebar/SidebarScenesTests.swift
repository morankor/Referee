import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// The sidebar's seven scenes of plan.md section 10.1 exist with their fixtures. What they show is checked by their
/// own `verify` in the snapshot run and by looking at the pictures.
@Suite struct SidebarScenesTests {
    @Test @MainActor func theSevenScenesOfSection101() {
        #expect(SidebarScenes.all.map(\.name).filter { !$0.hasPrefix("design-") } == ["sidebar-pending", "sidebar-streaming", "sidebar-states", "sidebar-discussion",
                                                  "sidebar-editing", "sidebar-chat", "sidebar-report"])
    }

    @Test @MainActor func everySceneIsAReviewSceneWhoseFixturesExist() {
        for scene in SidebarScenes.all {
            #expect(scene.kind == .review, "\(scene.name)")
            #expect(scene.verify != nil, "\(scene.name)")
            let pdf = scene.fixturePDF.map { Fixtures.url("pdf/\($0)") }
            #expect(pdf.map { FileManager.default.fileExists(atPath: $0.path) } == true, "\(scene.name)")
            if let session = scene.fixtureSession {
                #expect(FileManager.default.fileExists(atPath: Fixtures.url("sessions/\(session)").path), "\(scene.name)")
            }
        }
    }

    /// The states fixture decodes as the snapshot runner reads it, and holds what the scene needs before anchoring:
    /// one approved, one similar to it, one rejected, one with a page but no passage, one with neither.
    @Test func theStatesSessionDecodesWithOneCommentPerState() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(ReviewSession.self, from: Data(contentsOf: Fixtures.url("sessions/sidebar-states.json")))
        #expect(session.schemaVersion == 1)
        #expect(session.document.fileName == "ay_nolinks.pdf")
        let comments = session.comments
        #expect(comments.count == 5)
        #expect(comments.filter { $0.status == .approved }.count == 1)
        #expect(comments.filter { $0.status == .rejected }.count == 1)
        let similar = try #require(comments.first { $0.similarTo != nil })
        #expect(similar.status == .pending)
        #expect(comments.contains { $0.id == similar.similarTo && $0.kind == similar.kind })
        #expect(comments.contains { $0.anchor.confidence == .pageOnly && $0.anchor.pageIndex == 2 })
        #expect(comments.contains { $0.anchor.confidence == .none && $0.anchor.pageIndex == nil && $0.category == "literature" })
        #expect(Set(comments.map(\.id)).count == comments.count)
    }

    /// design-two-models (step 5b): two review runs by two providers, their comments interleaved, one of the second run
    /// similar to one of the first, and one comment of the referee's own.
    /// Step 5, G.9: design-report-conference's session puts the paper on EC, with a report on EC's scale.
    @Test @MainActor func theConferenceSessionIsAnECPaperWithAConferenceReport() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(ReviewSession.self, from: Data(contentsOf: Fixtures.url("sessions/design-sidebar-conference.json")))
        #expect(SidebarDesignScenes.all.contains { $0.name == "design-report-conference" && $0.fixtureSession == "design-sidebar-conference.json" })
        #expect(session.document.fileName == "ay_nolinks.pdf")
        #expect(session.meta.venueID == "ec")
        #expect(session.meta.targetVenue == DefaultSettings.make().venue(id: "ec").displayName)
        let report = try #require(session.report)
        #expect(report.recommendation == nil && report.recommendationLabel == "Weak reject")
        #expect(report.markdown.contains("## Chance of acceptance") && !report.markdown.contains("Publication probability"))
        #expect(!report.markdown.contains("\u{2014}"))                                         // no em dash for the style check to flag
        let approved = Set(session.comments.filter { $0.status == .approved && $0.includeInReport }.map(\.id))
        #expect(Set(report.basedOnCommentIDs) == approved)
        #expect(session.runs.last?.kind == .report)
    }

    @Test func theTwoModelsSessionHasTwoReviewsByTwoProviders() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(ReviewSession.self, from: Data(contentsOf: Fixtures.url("sessions/design-sidebar-two-models.json")))
        #expect(session.document.fileName == "ay_nolinks.pdf")
        let runs = session.runs
        #expect(runs.map(\.provider) == [ProviderRef(providerID: "claude-cli", model: "sonnet"), ProviderRef(providerID: "codex-cli", model: nil)])
        #expect(runs.map(\.reportedModel) == ["claude-sonnet-4-6", nil])        // step 5c: what Claude Code reported; Codex reports none
        #expect(runs.allSatisfy { $0.kind == .review })
        func run(of comment: ReviewComment) -> ProviderID? {
            guard case .ai(let runID) = comment.origin else { return nil }
            return runs.first { $0.id == runID }?.provider.providerID
        }
        let comments = session.comments
        #expect(comments.count == 7)
        #expect(comments.filter { run(of: $0) == "claude-cli" }.count == 3)
        #expect(comments.filter { run(of: $0) == "codex-cli" }.count == 3)
        #expect(comments.filter { $0.origin == .user }.count == 1)
        let similar = try #require(comments.first { $0.similarTo != nil })
        let earlier = try #require(comments.first { $0.id == similar.similarTo })
        #expect(run(of: similar) == "codex-cli" && run(of: earlier) == "claude-cli")
        #expect(similar.kind == earlier.kind && similar.anchor.quote == earlier.anchor.quote)
        #expect(Set(comments.map(\.id)).count == comments.count)
    }

    @Test @MainActor func theSampleSessionHasTheCommentsTheScenesName() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(ReviewSession.self, from: Data(contentsOf: Fixtures.url("sessions/sample.json")))
        let discussed = try #require(session.comments.first { $0.id == SidebarSceneSupport.id(SidebarScenes.discussedComment) })
        #expect(discussed.thread.count == 2)
        #expect(discussed.proposedRevision != nil)
        #expect(session.comments.contains { $0.id == SidebarSceneSupport.id(SidebarScenes.editedComment) })
        #expect(session.comments.contains { $0.status == .approved && $0.includeInReport })     // the report scene can generate
    }
}
