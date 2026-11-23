import Foundation
import RefereeCore
import AppCore

/// One filter of the Comments tab (plan.md section 9.3), with the number of comments it would show. Pure.
///
/// Step 5 (D11): one row of four chips, `All · Pending · Approved · Rejected`, and a fifth chip that is a menu of the
/// kinds, Strengths included: "Kind ▾" while no kind is filtered, else the kind in force and its count.
///
/// The counts are taken over every comment of the session, whatever filter is in force, so a chip says what choosing
/// it would show. A chip filters exactly as `ReviewSessionModel.visibleComments` does (a status, or a kind).
struct SidebarFilterChip: Equatable, Identifiable {
    var filter: CommentFilter
    var title: String
    var count: Int
    var id: String { title }

    /// The four status chips, in order.
    static let order: [(filter: CommentFilter, title: String)] = [
        (.all, "All"), (.pending, "Pending"), (.approved, "Approved"), (.rejected, "Rejected"),
    ]

    /// The items of the Kind menu, in order.
    static let kinds: [(kind: CommentKind, title: String)] = [
        (.major, "Major"), (.minor, "Minor"), (.question, "Questions"), (.strength, "Strengths"),
    ]

    static func chips(for comments: [ReviewComment]) -> [SidebarFilterChip] {
        order.map { entry in
            SidebarFilterChip(filter: entry.filter, title: entry.title, count: comments.filter { matches($0, entry.filter) }.count)
        }
    }

    /// The Kind menu's items with their counts: "Major (7)" and so on.
    static func kindItems(for comments: [ReviewComment]) -> [SidebarFilterChip] {
        kinds.map { entry in
            SidebarFilterChip(filter: .kind(entry.kind), title: entry.title, count: comments.filter { $0.kind == entry.kind }.count)
        }
    }

    /// "Major (7)", as the Kind menu lists an item.
    var menuTitle: String { "\(title) (\(count))" }

    /// The kind item in force under `filter`, if a kind is filtered: the chip then reads "{Kind} {count}", filled.
    static func kindInForce(_ filter: CommentFilter, comments: [ReviewComment]) -> SidebarFilterChip? {
        guard case .kind = filter else { return nil }
        return kindItems(for: comments).first { $0.filter == filter }
    }

    /// The filter after choosing a kind in the menu: that kind, or every comment again when it was already in force.
    static func filter(choosing kind: CommentKind, current: CommentFilter) -> CommentFilter {
        current == .kind(kind) ? .all : .kind(kind)
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

    /// The progress row once every comment is decided (D6): "All 25 decided".
    static func allDecidedText(total: Int) -> String {
        "All \(total) decided"
    }

    /// Whether every comment is decided, and there is at least one (D6).
    static func isAllDecided(decided: Int, total: Int) -> Bool {
        total > 0 && decided == total
    }
}

/// What the Comments tab says about the document and a review in progress (D6). Pure.
enum SidebarCommentsFacts {
    /// The line of document facts under the empty state: "4 pages · 9 references · no margin line numbers". Singular
    /// for one ("1 page", "1 reference"); "no reference list found" for none; the references left out while the index is
    /// not built (`referenceCount` nil). Without a text layer: "1 page · no text layer: comments can be tied to pages
    /// only".
    static func documentFacts(pageCount: Int, referenceCount: Int?, hasTextLayer: Bool, hasMarginLineNumbers: Bool) -> String {
        var parts = [pageCount == 1 ? "1 page" : "\(pageCount) pages"]
        guard hasTextLayer else {
            parts.append("no text layer: comments can be tied to pages only")
            return parts.joined(separator: " · ")
        }
        if let referenceCount {
            switch referenceCount {
            case 0: parts.append("no reference list found")
            case 1: parts.append("1 reference")
            default: parts.append("\(referenceCount) references")
            }
        }
        parts.append(hasMarginLineNumbers ? "margin line numbers found" : "no margin line numbers")
        return parts.joined(separator: " · ")
    }

    /// The facts of the model's document; nil before a paper is loaded.
    @MainActor static func documentFacts(of model: ReviewSessionModel) -> String? {
        guard let paper = model.paper else { return nil }
        return documentFacts(pageCount: paper.ref.pageCount, referenceCount: model.citations?.entries.count,
                             hasTextLayer: paper.text.hasTextLayer, hasMarginLineNumbers: paper.text.hasMarginLineNumbers)
    }

    /// The AI comments a review has delivered so far: those created at or after the run's start.
    static func receivedCount(of comments: [ReviewComment], since start: Date) -> Int {
        comments.filter { comment in
            guard case .ai = comment.origin else { return false }
            return comment.createdAt >= start
        }.count
    }

    /// The label over the drafts: "Writing…", or "Writing… · 2 received" once a running review has delivered comments.
    static func writingLabel(received: Int) -> String {
        received > 0 ? "Writing… · \(received) received" : "Writing…"
    }

    /// The start of the review that is running, if one is.
    @MainActor static func reviewStart(of model: ReviewSessionModel) -> Date? {
        if case .running(.review, _, let startedAt) = model.runState { return startedAt }
        return nil
    }
}
