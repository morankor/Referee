import AppKit
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP11 writes the key map (section 9.4).

public enum TriageIntent: Equatable { case next, previous, approve, reject, resetStatus, discuss, edit, reveal, newComment, setKind(CommentKind), dismiss }

public enum TriageKeymap {
    /// Placeholder: no key means anything yet.
    public static func intent(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> TriageIntent? { nil }

    /// Placeholder: does nothing.
    @MainActor public static func apply(_ intent: TriageIntent, to model: ReviewSessionModel) {}
}
