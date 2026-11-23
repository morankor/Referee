import AppKit

/// The main menu (plan.md section 9.1), built in code. Commands of a review window have no target: they go up the
/// responder chain to the key window's delegate, its `ShellReviewWindowController`, so they act on the key window and
/// are disabled when no review window is key. The app's own commands go to the application delegate. Undo, Redo, Cut,
/// Copy, Paste and Select All use the standard selectors, so text fields work.
///
/// The single keys of section 9.4 are shown next to their commands. The key monitor handles them before the menu
/// sees them; the items are disabled while text is being edited, so that a letter typed into a field stays there.
/// Find and zoom carry their keys only while a review window is key, so that a reference viewer's own find and zoom
/// get ⌘F, ⌘G, ⌘+, ⌘− and ⌘0 (`setReaderKeys`, Wave 3).
@MainActor enum ShellMainMenu {
    static let openRecentIdentifier = NSUserInterfaceItemIdentifier("Referee.OpenRecent")

    /// The menu bar, and the three menus AppKit fills in itself.
    struct Menus {
        var main: NSMenu
        var services: NSMenu
        var windows: NSMenu
        var help: NSMenu
    }

    /// Makes the menu bar the application's.
    static func install(appDelegate: ShellAppDelegate) {
        let menus = build(appDelegate: appDelegate)
        NSApp.mainMenu = menus.main
        NSApp.servicesMenu = menus.services
        NSApp.windowsMenu = menus.windows
        NSApp.helpMenu = menus.help
    }

    /// The menus of section 9.1, without touching the application (the tests read them).
    static func build(appDelegate: ShellAppDelegate) -> Menus {
        let main = NSMenu()
        let services = NSMenu(title: "Services")
        main.addItem(submenu(applicationMenu(appDelegate, services: services)))
        main.addItem(submenu(fileMenu(appDelegate)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(reviewMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu(appDelegate)
        main.addItem(submenu(window))
        let help = helpMenu(appDelegate)
        main.addItem(submenu(help))
        return Menus(main: main, services: services, windows: window, help: help)
    }

    // ---- the menus ----

    private static func applicationMenu(_ delegate: ShellAppDelegate, services: NSMenu) -> NSMenu {
        let menu = NSMenu(title: "Referee")
        menu.addItem(item("About Referee", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(ShellAppDelegate.shellShowSettings(_:)), ",", target: delegate))
        menu.addItem(.separator())
        menu.addItem(submenu(services, title: "Services"))
        menu.addItem(.separator())
        menu.addItem(item("Hide Referee", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Referee", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(_ delegate: ShellAppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open…", #selector(ShellAppDelegate.shellOpenDocument(_:)), "o", target: delegate))
        let recent = NSMenu(title: "Open Recent")
        recent.identifier = openRecentIdentifier
        recent.delegate = delegate
        menu.addItem(submenu(recent, title: "Open Recent"))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Export Report…", #selector(ShellReviewWindowController.shellExportReport(_:)), "e", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Delete Review Data…", #selector(ShellReviewWindowController.shellDeleteReviewData(_:))))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(readerItem("Find…", #selector(ShellReviewWindowController.shellFind(_:)), "f"))
        menu.addItem(readerItem("Find Next", #selector(ShellReviewWindowController.shellFindNext(_:)), "g"))
        menu.addItem(readerItem("Find Previous", #selector(ShellReviewWindowController.shellFindPrevious(_:)), "g", modifiers: [.command, .shift]))
        return menu
    }

    private static func reviewMenu() -> NSMenu {
        let menu = NSMenu(title: "Review")
        menu.addItem(item("Run Review", #selector(ShellReviewWindowController.shellRunReview(_:)), "r"))
        menu.addItem(item("Stop", #selector(ShellReviewWindowController.shellCancel(_:)), "."))       // design review D9
        menu.addItem(item("Generate Report", #selector(ShellReviewWindowController.shellGenerateReport(_:)), "r", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Approve", #selector(ShellReviewWindowController.shellApprove(_:)), "a", modifiers: []))
        menu.addItem(item("Reject", #selector(ShellReviewWindowController.shellReject(_:)), "r", modifiers: []))
        menu.addItem(item("Discuss", #selector(ShellReviewWindowController.shellDiscuss(_:)), "d", modifiers: []))
        menu.addItem(item("Edit", #selector(ShellReviewWindowController.shellEditComment(_:)), "e", modifiers: []))
        menu.addItem(.separator())
        menu.addItem(item("Next Comment", #selector(ShellReviewWindowController.shellNextComment(_:)), "j", modifiers: []))
        menu.addItem(item("Previous Comment", #selector(ShellReviewWindowController.shellPreviousComment(_:)), "k", modifiers: []))
        menu.addItem(item("Next Pending Comment", #selector(ShellReviewWindowController.shellNextPendingComment(_:)), "p", modifiers: []))   // D25
        menu.addItem(item("New Comment", #selector(ShellReviewWindowController.shellNewComment(_:)), "n", modifiers: []))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Comments", #selector(ShellReviewWindowController.shellShowComments(_:)), "1"))
        menu.addItem(item("Chat", #selector(ShellReviewWindowController.shellShowChat(_:)), "2"))
        menu.addItem(item("Report", #selector(ShellReviewWindowController.shellShowReport(_:)), "3"))
        menu.addItem(.separator())
        menu.addItem(item("Hide Navigator", #selector(ShellReviewWindowController.shellToggleNavigator(_:)), "s", modifiers: [.command, .control]))
        menu.addItem(item("Hide Sidebar", #selector(ShellReviewWindowController.shellToggleSidebar(_:)), "0", modifiers: [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(readerItem("Zoom In", #selector(ShellReviewWindowController.shellZoomIn(_:)), "+"))
        // ⌘= zooms in too, as on a keyboard where + needs Shift; the item is hidden but its key works.
        let zoomInEquals = readerItem("Zoom In", #selector(ShellReviewWindowController.shellZoomIn(_:)), "=")
        zoomInEquals.isHidden = true
        zoomInEquals.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInEquals)
        menu.addItem(readerItem("Zoom Out", #selector(ShellReviewWindowController.shellZoomOut(_:)), "-"))
        menu.addItem(readerItem("Fit Width", #selector(ShellReviewWindowController.shellFitWidth(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]))
        return menu
    }

    private static func windowMenu(_ delegate: ShellAppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Welcome to Referee", #selector(ShellAppDelegate.shellShowWelcome(_:)), "1", modifiers: [.command, .shift], target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu(_ delegate: ShellAppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Referee Help", #selector(ShellAppDelegate.shellShowHelp(_:)), "?", target: delegate))
        return menu
    }

    // ---- the keys of the reader items (Wave 3) ----

    /// Find, Find Next, Find Previous and the zoom items act on a review window's PDF. A reference viewer has its own
    /// find and zoom with the same keys (⌘F, ⌘G, ⇧⌘G, ⌘+, ⌘−, ⌘0), and AppKit offers a key to the main menu before the
    /// viewer sees it: an item that matches takes the key even while it is disabled, so the viewer's keys would never
    /// work. These items therefore carry their keys only while a review window is key; the application delegate calls
    /// this whenever another window becomes key.
    static func setReaderKeys(enabled: Bool, in menu: NSMenu?) {
        guard let menu else { return }
        for entry in menu.items {
            if let reader = entry as? ShellReaderMenuItem {
                reader.keyEquivalent = enabled ? reader.readerKey : ""
                reader.keyEquivalentModifierMask = enabled ? reader.readerModifiers : []
            }
            setReaderKeys(enabled: enabled, in: entry.submenu)
        }
    }

    /// Whether the reader items should have their keys: a review window is key.
    static func reviewWindowIsKey(_ keyWindow: NSWindow?) -> Bool {
        keyWindow?.delegate is ShellReviewWindowController
    }

    private static func readerItem(_ title: String, _ action: Selector, _ key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        ShellReaderMenuItem(title: title, action: action, key: key, modifiers: modifiers)
    }

    // ---- building blocks ----

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                             target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }

    private static func submenu(_ menu: NSMenu, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// A menu item that acts on a review window's PDF and remembers its key, so that the key can be taken out of the menu
/// while another kind of window is key and put back afterwards (`ShellMainMenu.setReaderKeys`). It is built with its key.
final class ShellReaderMenuItem: NSMenuItem {
    let readerKey: String
    let readerModifiers: NSEvent.ModifierFlags

    init(title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags) {
        readerKey = key
        readerModifiers = modifiers
        super.init(title: title, action: action, keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
    }

    required init(coder: NSCoder) {
        readerKey = ""
        readerModifiers = []
        super.init(coder: coder)
    }
}
