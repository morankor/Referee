import Foundation
import Testing
import RefereeCore
import AppCore
@testable import RefereeUI

/// The filter chips of the Comments tab (plan.md section 9.3) and their counts (WP10).
@Suite struct SidebarFilterChipTests {
    typealias Sample = SidebarTestData

    static let comments: [ReviewComment] = [
        Sample.comment(status: .pending, kind: .major),
        Sample.comment(status: .pending, kind: .minor),
        Sample.comment(status: .approved, kind: .major),
        Sample.comment(origin: .user, status: .approved, kind: .minor, category: "other"),
        Sample.comment(status: .rejected, kind: .strength),
        Sample.comment(status: .pending, kind: .question),
        Sample.comment(status: .rejected, kind: .question),
    ]

    @Test func theSevenChipsComeInTheOrderOfSection93WithTheirCounts() {
        let chips = SidebarFilterChip.chips(for: Self.comments)
        #expect(chips.map(\.title) == ["All", "Pending", "Approved", "Rejected", "Major", "Minor", "Questions"])
        #expect(chips.map(\.count) == [7, 3, 2, 2, 2, 2, 2])
        #expect(chips.map(\.filter) == [.all, .pending, .approved, .rejected, .kind(.major), .kind(.minor), .kind(.question)])
    }

    @Test func noCommentsGiveZeroEverywhere() {
        #expect(SidebarFilterChip.chips(for: []).map(\.count) == [0, 0, 0, 0, 0, 0, 0])
    }

    @Test func theTriageText() {
        #expect(SidebarFilterChip.triageText(decided: 12, total: 31) == "12 of 31 decided")
        #expect(SidebarFilterChip.triageText(decided: 0, total: 1) == "0 of 1 decided")
    }

    /// Each chip's count is what `visibleComments` shows when the model's filter is that chip's, whatever the filter was
    /// before (the counts are taken over all comments).
    @Test @MainActor func eachChipCountsWhatTheModelShowsUnderItsFilter() async throws {
        let harness = try await SidebarTestHarness.open(comments: Self.comments)
        let model = harness.model
        model.filter = .kind(.question)
        let chips = SidebarFilterChip.chips(for: model.session?.comments ?? [])
        for chip in chips {
            model.filter = chip.filter
            #expect(model.visibleComments.count == chip.count, "\(chip.title)")
            #expect(model.visibleComments.allSatisfy { SidebarFilterChip.matches($0, chip.filter) })
        }
        #expect(SidebarFilterChip.triageText(decided: model.triage.decided, total: model.triage.total) == "4 of 7 decided")
    }
}
