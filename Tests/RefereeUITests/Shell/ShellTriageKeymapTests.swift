import AppKit
import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// Keyboard triage (plan.md section 9.4): the key table, and what each intent does to a model on fakes.
@Suite struct ShellTriageKeymapTests {
    // ---- the key table ----

    /// Letters and digits by the characters they type; key codes of a US keyboard, which the table does not depend on.
    @Test func everyKeyOfTheTableHasItsIntent() {
        let table: [(String, UInt16, TriageIntent)] = [
            ("j", 38, .next), ("k", 40, .previous), ("a", 0, .approve), ("r", 15, .reject), ("x", 7, .reject),
            ("u", 32, .resetStatus), ("d", 2, .discuss), ("e", 14, .edit), ("n", 45, .newComment),
            ("1", 18, .setKind(.major)), ("2", 19, .setKind(.minor)), ("3", 20, .setKind(.question)), ("4", 21, .setKind(.strength)),
        ]
        for (characters, keyCode, intent) in table {
            #expect(TriageKeymap.intent(characters: characters, keyCode: keyCode, modifiers: []) == intent, "key \(characters)")
        }
    }

    @Test func returnRevealsAndEscapeDismissesByKeyCode() {
        #expect(TriageKeymap.intent(characters: "\r", keyCode: 36, modifiers: []) == .reveal)
        #expect(TriageKeymap.intent(characters: "\u{3}", keyCode: 76, modifiers: [.numericPad, .function]) == .reveal)   // keypad Enter
        #expect(TriageKeymap.intent(characters: "\u{1b}", keyCode: 53, modifiers: []) == .dismiss)
        #expect(TriageKeymap.intent(characters: "", keyCode: 53, modifiers: []) == .dismiss)
    }

    /// A held Command, Control, Option or Shift leaves the key to the menu or to the text it types.
    @Test(arguments: [NSEvent.ModifierFlags.command, .control, .option, .shift, [.command, .shift]])
    func modifiedKeysHaveNoIntent(modifiers: NSEvent.ModifierFlags) {
        #expect(TriageKeymap.intent(characters: "j", keyCode: 38, modifiers: modifiers) == nil)
        #expect(TriageKeymap.intent(characters: "1", keyCode: 18, modifiers: modifiers) == nil)
        #expect(TriageKeymap.intent(characters: "\r", keyCode: 36, modifiers: modifiers) == nil)
        #expect(TriageKeymap.intent(characters: "\u{1b}", keyCode: 53, modifiers: modifiers) == nil)
    }

    @Test func capsLockAndTheKeypadDoNotCountAsModifiers() {
        #expect(TriageKeymap.intent(characters: "A", keyCode: 0, modifiers: .capsLock) == .approve)
        #expect(TriageKeymap.intent(characters: "J", keyCode: 38, modifiers: .capsLock) == .next)
        #expect(TriageKeymap.intent(characters: "2", keyCode: 84, modifiers: .numericPad) == .setKind(.minor))
    }

    @Test func otherKeysHaveNoIntent() {
        for characters in ["b", "z", "5", "0", " ", "?", "jj", "", "ב"] {
            #expect(TriageKeymap.intent(characters: characters, keyCode: 11, modifiers: []) == nil, "\(characters)")
        }
    }

    /// A Latin layout decides the letter: on AZERTY the key with code 0 types "q", so it is not Approve, and the key
    /// that types "a" is.
    @Test func latinLettersFollowTheLayoutNotTheKeyCode() {
        #expect(TriageKeymap.intent(characters: "q", keyCode: 0, modifiers: []) == nil)
        #expect(TriageKeymap.intent(characters: "a", keyCode: 12, modifiers: []) == .approve)
        #expect(TriageKeymap.intent(characters: "j", keyCode: 8, modifiers: []) == .next)          // Dvorak and the like
    }

    /// With a Hebrew, Russian or Greek input source the keys type other letters; their places on a US keyboard decide.
    @Test func lettersOfOtherScriptsCountByTheirKey() {
        #expect(TriageKeymap.intent(characters: "ח", keyCode: 38, modifiers: []) == .next)         // Hebrew: J's key
        #expect(TriageKeymap.intent(characters: "ל", keyCode: 40, modifiers: []) == .previous)     // Hebrew: K's key
        #expect(TriageKeymap.intent(characters: "ש", keyCode: 0, modifiers: []) == .approve)       // Hebrew: A's key
        #expect(TriageKeymap.intent(characters: "ר", keyCode: 15, modifiers: []) == .reject)       // Hebrew: R's key
        #expect(TriageKeymap.intent(characters: "о", keyCode: 38, modifiers: []) == .next)         // Russian: J's key
        #expect(TriageKeymap.intent(characters: "ψ", keyCode: 2, modifiers: []) == .discuss)       // Greek on D's key
        #expect(TriageKeymap.intent(characters: "ג", keyCode: 3, modifiers: []) == nil)            // F's key: no intent
        #expect(TriageKeymap.intent(characters: "ש", keyCode: 0, modifiers: .shift) == nil)
    }

    /// AZERTY's top row types "&", "é", "\"" and "'" without Shift; the key, not the character, gives the kind.
    @Test func digitsCountByTheirKey() {
        #expect(TriageKeymap.intent(characters: "&", keyCode: 18, modifiers: []) == .setKind(.major))
        #expect(TriageKeymap.intent(characters: "é", keyCode: 19, modifiers: []) == .setKind(.minor))
        #expect(TriageKeymap.intent(characters: "\"", keyCode: 20, modifiers: []) == .setKind(.question))
        #expect(TriageKeymap.intent(characters: "'", keyCode: 21, modifiers: []) == .setKind(.strength))
        #expect(TriageKeymap.intent(characters: "4", keyCode: 86, modifiers: .numericPad) == .setKind(.strength))
        #expect(TriageKeymap.intent(characters: "5", keyCode: 23, modifiers: []) == nil)
    }

    // ---- applying intents to a model ----

    @Test @MainActor func nextAndPreviousWalkTheVisibleComments() async throws {
        let comments = [ShellTestData.comment("First", page: 0), ShellTestData.comment("Second", page: 1), ShellTestData.comment("Third", page: 2)]
        let model = try await ShellTestModels.opened(with: comments)
        let ids = model.visibleComments.map(\.id)
        #expect(ids == comments.map(\.id))

        TriageKeymap.apply(.next, to: model)
        #expect(model.selectedCommentID == ids[0])
        TriageKeymap.apply(.next, to: model)
        #expect(model.selectedCommentID == ids[1])
        TriageKeymap.apply(.previous, to: model)
        #expect(model.selectedCommentID == ids[0])
        let serial = model.readerCommand?.serial ?? 0
        TriageKeymap.apply(.reveal, to: model)                  // Return: the passage again
        #expect((model.readerCommand?.serial ?? 0) > serial)
        #expect(model.readerCommand?.command == .goToPage(0))
    }

    /// J, A, J, R with "advance after decision" off, then U, K: the sequence of Wave 3's scene check-triage-keys.
    @Test @MainActor func decisionsActOnTheSelectedComment() async throws {
        let comments = [ShellTestData.comment("First", page: 0), ShellTestData.comment("Second", page: 1)]
        let model = try await ShellTestModels.opened(with: comments, autoAdvance: false)
        let ids = model.visibleComments.map(\.id)
        func status(_ index: Int) -> CommentStatus? { model.session?.comments.first { $0.id == ids[index] }?.status }

        TriageKeymap.apply(.approve, to: model)                 // nothing selected: nothing happens
        #expect(status(0) == .pending)
        for key in [TriageIntent.next, .approve, .next, .reject] { TriageKeymap.apply(key, to: model) }
        #expect(status(0) == .approved)
        #expect(status(1) == .rejected)
        #expect(model.selectedCommentID == ids[1])
        TriageKeymap.apply(.resetStatus, to: model)
        TriageKeymap.apply(.previous, to: model)
        #expect(status(1) == .pending)
        #expect(model.selectedCommentID == ids[0])
    }

    @Test @MainActor func approvingAdvancesToTheNextPendingCommentWhenThatIsOn() async throws {
        let comments = [ShellTestData.comment("First", page: 0), ShellTestData.comment("Decided", page: 1, status: .approved),
                        ShellTestData.comment("Third", page: 2)]
        let model = try await ShellTestModels.opened(with: comments, autoAdvance: true)
        TriageKeymap.apply(.next, to: model)
        TriageKeymap.apply(.approve, to: model)
        #expect(model.selectedCommentID == comments[2].id)      // the approved one in between is passed over
    }

    @Test @MainActor func kindsThreadEditorAndComposingFollowTheKeys() async throws {
        let comments = [ShellTestData.comment("Only", page: 0, kind: .minor)]
        let model = try await ShellTestModels.opened(with: comments)
        let id = comments[0].id

        TriageKeymap.apply(.discuss, to: model)                 // nothing selected: nothing opens
        TriageKeymap.apply(.edit, to: model)
        #expect(model.openThreadCommentID == nil)
        #expect(model.editingCommentID == nil)

        TriageKeymap.apply(.next, to: model)
        for (intent, kind) in [(TriageIntent.setKind(.major), CommentKind.major), (.setKind(.question), .question), (.setKind(.strength), .strength),
                               (.setKind(.minor), .minor)] {
            TriageKeymap.apply(intent, to: model)
            #expect(model.session?.comments.first?.kind == kind)
        }
        model.sidebarTab = .chat
        TriageKeymap.apply(.discuss, to: model)
        #expect(model.openThreadCommentID == id)
        #expect(model.sidebarTab == .comments)
        TriageKeymap.apply(.edit, to: model)
        #expect(model.editingCommentID == id)

        TriageKeymap.apply(.dismiss, to: model)                 // Esc: the editor first, then the thread
        #expect(model.editingCommentID == nil)
        #expect(model.openThreadCommentID == id)
        TriageKeymap.apply(.dismiss, to: model)
        #expect(model.openThreadCommentID == nil)

        TriageKeymap.apply(.newComment, to: model)
        #expect(model.composing != nil)
        TriageKeymap.apply(.dismiss, to: model)
        #expect(model.composing == nil)
    }
}
