import AppKit
import RefereeCore
import AppCore

// Keyboard triage (plan.md section 9.4): which key means what, and what each meaning does to the model. The key
// monitor of ShellReviewWindowController calls these two functions only when the review window is key and no text is
// being edited; a scene of Wave 3 drives them with real key events.

public enum TriageIntent: Equatable { case next, previous, approve, reject, resetStatus, discuss, edit, reveal, newComment, setKind(CommentKind), dismiss }

public enum TriageKeymap {
    /// Return (and the keypad's Enter) and Esc by key code; letters and digits by the characters they type, so the
    /// letters follow the keyboard layout. Only plain keys: with Command, Control, Option or Shift held there is no
    /// intent (those go through the menu). Caps Lock and the keypad do not count as modifiers.
    ///
    /// J next · K previous · A approve · R or X reject · U back to pending · D discuss · E edit · Return reveal ·
    /// N new own comment · 1 2 3 4 major, minor, question, strength · Esc dismiss.
    public static func intent(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> TriageIntent? {
        let held = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard held.isEmpty else { return nil }
        switch keyCode {
        case returnKey, keypadEnterKey: return .reveal
        case escapeKey: return .dismiss
        default: break
        }
        switch characters.lowercased() {
        case "j": return .next
        case "k": return .previous
        case "a": return .approve
        case "r", "x": return .reject
        case "u": return .resetStatus
        case "d": return .discuss
        case "e": return .edit
        case "n": return .newComment
        case "1": return .setKind(.major)
        case "2": return .setKind(.minor)
        case "3": return .setKind(.question)
        case "4": return .setKind(.strength)
        default: return nil
        }
    }

    /// The model call of each intent (section 9.4). Decisions, kinds, the thread and the editor act on the selected
    /// comment and do nothing without one; the sidebar reacts to the properties set here.
    @MainActor public static func apply(_ intent: TriageIntent, to model: ReviewSessionModel) {
        switch intent {
        case .next:
            model.selectNextComment(pendingOnly: false)
        case .previous:
            model.selectPreviousComment()
        case .approve:
            if let id = model.selectedCommentID { model.setStatus(.approved, for: id) }
        case .reject:
            if let id = model.selectedCommentID { model.setStatus(.rejected, for: id) }
        case .resetStatus:
            if let id = model.selectedCommentID { model.setStatus(.pending, for: id) }
        case .discuss:
            guard let id = model.selectedCommentID else { return }
            model.sidebarTab = .comments
            model.openThreadCommentID = id
        case .edit:
            guard let id = model.selectedCommentID else { return }
            model.sidebarTab = .comments
            model.editingCommentID = id
        case .reveal:
            model.revealSelectedCommentInPDF()
        case .newComment:
            model.beginComposingComment()
        case .setKind(let kind):
            if let id = model.selectedCommentID { model.setKind(kind, for: id) }
        case .dismiss:
            model.dismissTransientUI()
        }
    }

    static let returnKey: UInt16 = 36
    static let keypadEnterKey: UInt16 = 76
    static let escapeKey: UInt16 = 53
}
