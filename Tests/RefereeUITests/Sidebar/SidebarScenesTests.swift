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
        #expect(SidebarScenes.all.map(\.name) == ["sidebar-pending", "sidebar-streaming", "sidebar-states", "sidebar-discussion",
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
