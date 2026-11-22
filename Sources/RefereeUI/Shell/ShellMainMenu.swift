import AppKit

/// The main menu (plan.md section 9.1), built in code. Commands of a review window have no target: they go up the
/// responder chain to the key window's delegate, its `ShellReviewWindowController`, so they act on the key window and
/// are disabled when no review window is key. The app's own commands go to the application delegate. Undo, Redo, Cut,
/// Copy, Paste and Select All use the standard selectors, so text fields work.
///
/// The single keys of section 9.4 are shown next to their commands. The key monitor handles them before the menu
/// sees them; the items are disabled while text is being edited, so that a letter typed into a field stays there.
@MainActor enum ShellMainMenu {
    static let openRecentIdentifier = NSUserInterfaceItemIdentifier("Referee.OpenRecent")

    static func make(appDelegate: ShellAppDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(applicationMenu(appDelegate)))
        main.addItem(submenu(fileMenu(appDelegate)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(reviewMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu(appDelegate)
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu(appDelegate)
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    // ---- the menus ----

    private static func applicationMenu(_ delegate: ShellAppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Referee")
        menu.addItem(item("About Referee", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(ShellAppDelegate.shellShowSettings(_:)), ",", target: delegate))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu(services, title: "Services"))
        NSApp.servicesMenu = services
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
        menu.addItem(item("Find…", #selector(ShellReviewWindowController.shellFind(_:)), "f"))
        menu.addItem(item("Find Next", #selector(ShellReviewWindowController.shellFindNext(_:)), "g"))
        menu.addItem(item("Find Previous", #selector(ShellReviewWindowController.shellFindPrevious(_:)), "g", modifiers: [.command, .shift]))
        return menu
    }

    private static func reviewMenu() -> NSMenu {
        let menu = NSMenu(title: "Review")
        menu.addItem(item("Run Review", #selector(ShellReviewWindowController.shellRunReview(_:)), "r"))
        menu.addItem(item("Cancel", #selector(ShellReviewWindowController.shellCancel(_:)), "."))
        menu.addItem(item("Generate Report", #selector(ShellReviewWindowController.shellGenerateReport(_:)), "r", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Approve", #selector(ShellReviewWindowController.shellApprove(_:)), "a", modifiers: []))
        menu.addItem(item("Reject", #selector(ShellReviewWindowController.shellReject(_:)), "r", modifiers: []))
        menu.addItem(item("Discuss", #selector(ShellReviewWindowController.shellDiscuss(_:)), "d", modifiers: []))
        menu.addItem(item("Edit", #selector(ShellReviewWindowController.shellEditComment(_:)), "e", modifiers: []))
        menu.addItem(.separator())
        menu.addItem(item("Next Comment", #selector(ShellReviewWindowController.shellNextComment(_:)), "j", modifiers: []))
        menu.addItem(item("Previous Comment", #selector(ShellReviewWindowController.shellPreviousComment(_:)), "k", modifiers: []))
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
        menu.addItem(item("Zoom In", #selector(ShellReviewWindowController.shellZoomIn(_:)), "+"))
        // ⌘= zooms in too, as on a keyboard where + needs Shift; the item is hidden but its key works.
        let zoomInEquals = item("Zoom In", #selector(ShellReviewWindowController.shellZoomIn(_:)), "=")
        zoomInEquals.isHidden = true
        zoomInEquals.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInEquals)
        menu.addItem(item("Zoom Out", #selector(ShellReviewWindowController.shellZoomOut(_:)), "-"))
        menu.addItem(item("Fit Width", #selector(ShellReviewWindowController.shellFitWidth(_:)), "0"))
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
