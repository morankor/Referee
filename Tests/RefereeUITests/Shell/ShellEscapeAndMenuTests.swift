import AppKit
import PDFKit
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// Wave 3's changes to the window's keys (plan.md section 9.4 and Appendix G.7): the order in which Esc closes things,
/// with the find bar between the model's transient UI and the selection; and the find and zoom items of the main menu,
/// which carry their keys only while a review window is key, so that a reference viewer's own find and zoom get them.
@Suite @MainActor struct ShellEscapeAndMenuTests {
    @Test func escClosesTheModelsTransientUIThenTheFindBarThenTheSelection() async throws {
        let model = try await ReaderTestSupport.openModel()
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        #expect(!reader.dismissFind())                                  // no find bar: nothing to close

        let page = try #require(reader.pdfView.document?.page(at: 0))
        let string = try #require(page.string) as NSString
        let herding = try #require(page.selection(for: string.range(of: "Herding has been studied")))
        reader.pdfView.setCurrentSelection(herding, animate: false)
        await ReaderTestSupport.wait { model.selection != nil }
        try #require(model.selection != nil)
        reader.showFind()                                               // the bar without a query: the selection stays the model's
        model.beginComposingComment()

        ShellReviewWindowController.dismiss(model: model, reader: reader)
        #expect(model.composing == nil)                                 // the model's transient UI first
        #expect(reader.finder.isVisible)
        #expect(model.selection != nil)

        ShellReviewWindowController.dismiss(model: model, reader: reader)
        #expect(!reader.finder.isVisible)                               // then the find bar
        #expect(model.selection != nil)

        ShellReviewWindowController.dismiss(model: model, reader: reader)
        #expect(model.selection == nil)                                 // and only then the selection

        reader.showFind()
        #expect(reader.dismissFind())
        #expect(!reader.finder.isVisible)
    }

    @Test func aThreadOrAnEditorClosesBeforeTheFindBar() async throws {
        let comment = ReaderTestSupport.comment(rects: [PageRect(pageIndex: 0, x: 120, y: 600, width: 200, height: 12)])
        let model = try await ReaderTestSupport.openModel(comments: [comment])
        let (reader, window) = try await ReaderTestSupport.attachedReader(model)
        defer { window.close() }
        reader.showFind()
        model.openThreadCommentID = comment.id
        model.editingCommentID = comment.id
        ShellReviewWindowController.dismiss(model: model, reader: reader)
        #expect(model.editingCommentID == nil)
        #expect(model.openThreadCommentID == comment.id)
        #expect(reader.finder.isVisible)
        ShellReviewWindowController.dismiss(model: model, reader: reader)
        #expect(model.openThreadCommentID == nil)
        #expect(reader.finder.isVisible)
        ShellReviewWindowController.dismiss(model: model, reader: reader)
        #expect(!reader.finder.isVisible)
    }

    @Test func theReaderKeysAreInTheMenuOnlyWhileAReviewWindowIsKey() throws {
        _ = NSApplication.shared
        let delegate = ShellAppDelegate(makeDependencies: { _ in ShellTestModels.dependencies() }, arguments: [])
        let menus = ShellMainMenu.build(appDelegate: delegate)
        let readerItems = Self.items(of: menus.main).compactMap { $0 as? ShellReaderMenuItem }
        #expect(readerItems.map(\.title) == ["Find…", "Find Next", "Find Previous", "Zoom In", "Zoom In", "Zoom Out", "Fit Width"])
        let keys = readerItems.map(\.keyEquivalent)
        let modifiers = readerItems.map(\.keyEquivalentModifierMask)
        #expect(keys == ["f", "g", "g", "+", "=", "-", "0"])           // built with their keys (section 9.1)

        ShellMainMenu.setReaderKeys(enabled: false, in: menus.main)
        #expect(readerItems.allSatisfy { $0.keyEquivalent.isEmpty && $0.keyEquivalentModifierMask.isEmpty })
        // The menu no longer takes these keys, so they reach the key window, where a reference viewer has its own.
        for key in ["f", "g", "+", "=", "-", "0"] {
            #expect(!menus.main.performKeyEquivalent(with: try Self.commandKey(key)), "⌘\(key)")
        }
        let copy = menus.main.items.first { $0.submenu?.title == "Edit" }?.submenu?.items.first { $0.title == "Copy" }
        #expect(copy?.keyEquivalent == "c")                             // the other items keep theirs

        ShellMainMenu.setReaderKeys(enabled: true, in: menus.main)
        #expect(readerItems.map(\.keyEquivalent) == keys)
        #expect(readerItems.map(\.keyEquivalentModifierMask) == modifiers)

        #expect(!ShellMainMenu.reviewWindowIsKey(nil))
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        plain.isReleasedWhenClosed = false
        #expect(!ShellMainMenu.reviewWindowIsKey(plain))
    }

    private static func items(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items(of:)) ?? []) }
    }

    private static func commandKey(_ key: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                      characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
    }
}
