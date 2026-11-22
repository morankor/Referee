import Foundation
import RefereeCore
import AppCore

/// One filter chip of the Comments tab (plan.md section 9.3): `All · Pending · Approved · Rejected · Major · Minor ·
/// Questions`, each with the number of comments it would show. Pure.
///
/// The counts are taken over every comment of the session, whatever filter is in force, so a chip says what choosing
/// it would show. A chip filters exactly as `ReviewSessionModel.visibleComments` does (a status, or a kind).
struct SidebarFilterChip: Equatable, Identifiable {
    var filter: CommentFilter
    var title: String
    var count: Int
    var id: String { title }

    /// The seven chips in the order of section 9.3.
    static let order: [(filter: CommentFilter, title: String)] = [
        (.all, "All"), (.pending, "Pending"), (.approved, "Approved"), (.rejected, "Rejected"),
        (.kind(.major), "Major"), (.kind(.minor), "Minor"), (.kind(.question), "Questions"),
    ]

    static func chips(for comments: [ReviewComment]) -> [SidebarFilterChip] {
        order.map { entry in
            SidebarFilterChip(filter: entry.filter, title: entry.title, count: comments.filter { matches($0, entry.filter) }.count)
        }
    }

    static func matches(_ comment: ReviewComment, _ filter: CommentFilter) -> Bool {
        switch filter {
        case .all: return true
        case .pending: return comment.status == .pending
        case .approved: return comment.status == .approved
        case .rejected: return comment.status == .rejected
        case .kind(let kind): return comment.kind == kind
        }
    }

    /// The text beside the progress bar: "12 of 31 decided" (a decided comment is approved or rejected).
    static func triageText(decided: Int, total: Int) -> String {
        "\(decided) of \(total) decided"
    }
}
