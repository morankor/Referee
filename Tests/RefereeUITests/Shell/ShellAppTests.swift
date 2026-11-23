import AppKit
import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

/// The parts of the app around the windows that can be checked without showing one: the main menu of plan.md
/// section 9.1, and how a document is recognised.
@Suite @MainActor struct ShellAppTests {
    /// The menus, and the delegate their app commands target: a menu item holds its target weakly, as the app holds
    /// its delegate in `ShellAppDelegate.running`, so the test keeps it too.
    private func menus() -> (menus: ShellMainMenu.Menus, delegate: ShellAppDelegate) {
        let delegate = ShellAppDelegate(makeDependencies: { _ in ShellTestModels.dependencies() }, arguments: [])
        return (ShellMainMenu.build(appDelegate: delegate), delegate)
    }

    private func item(_ menus: ShellMainMenu.Menus, _ menu: String, _ title: String) -> NSMenuItem? {
        menus.main.items.first { $0.submenu?.title == menu }?.submenu?.items.first { $0.title == title }
    }

    @Test func theMenusAreThoseOfSection91() {
        let (menus, delegate) = menus()
        #expect(menus.main.items.compactMap { $0.submenu?.title } == ["Referee", "File", "Edit", "Review", "View", "Window", "Help"])
        let keys: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("Referee", "Settings…", ",", .command), ("Referee", "Quit Referee", "q", .command),
            ("File", "Open…", "o", .command), ("File", "Close", "w", .command), ("File", "Export Report…", "e", [.command, .shift]),
            ("Edit", "Find…", "f", .command), ("Edit", "Find Next", "g", .command), ("Edit", "Find Previous", "g", [.command, .shift]),
            ("Edit", "Undo", "z", .command), ("Edit", "Copy", "c", .command), ("Edit", "Select All", "a", .command),
            ("Review", "Run Review", "r", .command), ("Review", "Stop", ".", .command), ("Review", "Generate Report", "r", [.command, .shift]),
            ("Review", "Approve", "a", []), ("Review", "Reject", "r", []), ("Review", "Discuss", "d", []), ("Review", "Edit", "e", []),
            ("Review", "Next Comment", "j", []), ("Review", "Previous Comment", "k", []), ("Review", "Next Pending Comment", "p", []),
            ("Review", "New Comment", "n", []),
            ("View", "Comments", "1", .command), ("View", "Chat", "2", .command), ("View", "Report", "3", .command),
            ("View", "Hide Navigator", "s", [.command, .control]), ("View", "Hide Sidebar", "0", [.command, .option]),
            ("View", "Zoom In", "+", .command), ("View", "Zoom Out", "-", .command), ("View", "Fit Width", "0", .command),
        ]
        for (menu, title, key, modifiers) in keys {
            let found = item(menus, menu, title)
            #expect(found?.keyEquivalent == key, "\(menu) ▸ \(title)")
            #expect(found?.keyEquivalentModifierMask == modifiers, "\(menu) ▸ \(title)")
        }
        let review = menus.main.items.first { $0.submenu?.title == "Review" }?.submenu?.items.map(\.title) ?? []
        #expect(review.firstIndex(of: "Next Pending Comment") == review.firstIndex(of: "Previous Comment").map { $0 + 1 })   // D25: after it
        #expect(!review.contains("Cancel"))                                                                                    // D9: "Stop"
        #expect(item(menus, "File", "Open Recent")?.submenu?.identifier == ShellMainMenu.openRecentIdentifier)
        #expect(item(menus, "File", "Delete Review Data…") != nil)
        #expect(item(menus, "Help", "Referee Help") != nil)
        #expect(menus.windows.title == "Window")
        #expect(menus.help.title == "Help")
        #expect(item(menus, "Referee", "Settings…")?.target === delegate)
    }

    /// A command without a target goes up the responder chain to the key window's controller; one with the delegate as
    /// target goes there. Either way the receiver implements it.
    @Test func everyCommandReachesSomethingThatImplementsIt() {
        let (menus, delegate) = menus()
        let standard: [AnyClass] = [NSApplication.self, NSWindow.self, NSTextView.self]
        var checked = 0
        for top in menus.main.items {
            for entry in top.submenu?.items ?? [] where entry.submenu == nil {
                guard let action = entry.action else { continue }
                checked += 1
                if let target = entry.target {
                    #expect(target.responds(to: action), "\(entry.title)")
                } else {
                    let implemented = standard.contains { $0.instancesRespond(to: action) }
                        || ShellReviewWindowController.instancesRespond(to: action)
                    #expect(implemented, "\(entry.title)")
                }
            }
        }
        #expect(checked > 30)
        #expect(delegate.responds(to: #selector(ShellAppDelegate.shellShowSettings(_:))))
    }

    @Test func aDocumentIsKnownByTheHashOfItsBytes() async throws {
        let paper = try makeSamplePaper()
        #expect(await ShellWindowManager.sha256(of: Fixtures.url("pdf/ay_round_nolinks.pdf")) == paper.ref.sha256)
        #expect(await ShellWindowManager.sha256(of: URL(fileURLWithPath: "/no/such/folder/paper.pdf")) == nil)
    }
}
