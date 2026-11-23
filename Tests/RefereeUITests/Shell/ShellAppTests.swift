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
        #expect(menus.main.items.compactMap { $0.submenu?.title } == ["Human in the Loop", "File", "Edit", "Review", "View", "Window", "Help"])
        let keys: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("Human in the Loop", "Settings…", ",", .command), ("Human in the Loop", "Hide Human in the Loop", "h", .command),
            ("Human in the Loop", "Quit Human in the Loop", "q", .command),
            ("Window", "Welcome to Human in the Loop", "1", [.command, .shift]),
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
        #expect(item(menus, "Help", "Human in the Loop Help") != nil)
        #expect(menus.windows.title == "Window")
        #expect(menus.help.title == "Help")
        #expect(item(menus, "Human in the Loop", "Settings…")?.target === delegate)
        // Step 5's brand: About is the app delegate's, which shows the panel with the brand's options.
        let about = item(menus, "Human in the Loop", "About Human in the Loop")
        #expect(about?.action == #selector(ShellAppDelegate.shellShowAbout(_:)))
        #expect(about?.target === delegate)
        #expect(menus.main.items.first?.submenu?.items.first === about)
    }

    /// Step 5's brand (docs/brand/brand.md 6.2): the About panel names the app, gives the version without a build
    /// number, and has the tagline over what the app is. A build without a bundle shows the mark as its icon; a bundled
    /// one, its own icon and version.
    @Test func theAboutPanelCarriesTheNameTheVersionAndTheTagline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("referee-about-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Bundled.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "local.referee.app", "CFBundleShortVersionString": "2.3.4"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))

        let unbundled = ShellAppDelegate.aboutPanelOptions(bundle: try #require(Bundle(path: root.path)))
        #expect(unbundled[.applicationName] as? String == "Human in the Loop")
        #expect(unbundled[.applicationVersion] as? String == "0.1.0")                 // scripts/bundle.sh's default
        #expect(unbundled[.version] as? String == "")
        let icon = try #require(unbundled[.applicationIcon] as? NSImage)
        #expect(icon.size == NSSize(width: 128, height: 128))
        let pixels = try #require(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(pixels.width == 256 && pixels.height == 256)

        let bundled = ShellAppDelegate.aboutPanelOptions(bundle: try #require(Bundle(path: root.appendingPathComponent("Bundled.app").path)))
        #expect(bundled[.applicationVersion] as? String == "2.3.4")
        #expect(bundled[.applicationIcon] == nil)                                       // the bundle's AppIcon.icns

        let credits = try #require(unbundled[.credits] as? NSAttributedString)
        #expect(credits.string == "AI drafts. You referee.\nA PDF reader for refereeing papers with AI.")
        let tagline = credits.attributes(at: 0, effectiveRange: nil)
        #expect((tagline[.font] as? NSFont)?.pointSize == 13)
        #expect((tagline[.paragraphStyle] as? NSParagraphStyle)?.alignment == .center)
        let descriptor = credits.attributes(at: credits.length - 1, effectiveRange: nil)
        #expect((descriptor[.font] as? NSFont)?.pointSize == 11)
        #expect(descriptor[.foregroundColor] as? NSColor == .secondaryLabelColor)
    }

    /// Step 5's brand (docs/brand/brand.md 6.1): the welcome window's title is kept but not shown, and a first run lists
    /// how the app works, each step with a symbol the system has. The Help window has a scene of its own (6.3).
    @Test func theWelcomeWindowCarriesTheBrand() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        WelcomeView.dress(window)
        #expect(window.title == "Welcome to Human in the Loop")
        #expect(window.titleVisibility == .hidden)
        #expect(WelcomeView.howItWorksTitle == "How it works")
        #expect(WelcomeView.howItWorks.map(\.text) == [
            "The AI reads the paper and drafts comments in the sidebar.",
            "You approve, reject, discuss or edit each one, with single keys.",
            "The report is drafted from the comments you approved, for you to edit.",
        ])
        for step in WelcomeView.howItWorks {
            #expect(NSImage(systemSymbolName: step.symbol, accessibilityDescription: nil) != nil, "no symbol \(step.symbol)")
        }
        #expect(WelcomeView.howItWorksPromise == "Nothing reaches the report until you approve it.")
        #expect(ShellScenes.all.contains { $0.name == "help" && $0.kind == .welcome })
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
