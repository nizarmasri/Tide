import AppKit

/// The menu bar menus shown while the Downloads window is open, with the full shortcut table
/// from DESIGN.md §5.
@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        // Tide
        let app = submenu(main, "Tide")
        app.addItem(item("About Tide", #selector(AppDelegate.showAbout(_:)), target: target))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: target))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(item("Hide Tide", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit Tide", #selector(NSApplication.terminate(_:)), "q"))

        // File
        let file = submenu(main, "File")
        file.addItem(item("Add Link…", #selector(AppDelegate.addLink(_:)), "n", target: target))
        file.addItem(item("Open Torrent File…", #selector(AppDelegate.openTorrent(_:)), "o", target: target))
        file.addItem(item("Import Existing Download…", #selector(AppDelegate.importExisting(_:)), "i", [.command, .shift], target: target))
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))

        // Edit
        let edit = submenu(main, "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Find…", #selector(AppDelegate.findInDownloads(_:)), "f", target: target))

        // View
        let view = submenu(main, "View")
        view.addItem(item("Compact Rows", #selector(AppDelegate.toggleCompact(_:)), target: target))
        view.addItem(item("Show Info", #selector(AppDelegate.toggleInspector(_:)), "i", target: target))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        // Downloads
        let dl = submenu(main, "Downloads")
        dl.addItem(item("Pause", #selector(AppDelegate.pauseSelected(_:)), ".", target: target))
        dl.addItem(item("Resume", #selector(AppDelegate.resumeSelected(_:)), "/", target: target))
        dl.addItem(item("Pause All", #selector(AppDelegate.pauseAll(_:)), ".", [.command, .option], target: target))
        dl.addItem(item("Resume All", #selector(AppDelegate.resumeAll(_:)), "/", [.command, .option], target: target))
        dl.addItem(.separator())
        dl.addItem(item("Slow Mode", #selector(AppDelegate.toggleSlowMode(_:)), "l", [.command, .shift], target: target))
        dl.addItem(.separator())
        dl.addItem(item("Show in Finder", #selector(AppDelegate.revealSelected(_:)), "r", target: target))
        dl.addItem(item("Quick Look", #selector(AppDelegate.quickLookSelected(_:)), "y", target: target))
        dl.addItem(item("Copy Magnet Link", #selector(AppDelegate.copyLinkSelected(_:)), "c", [.command, .option], target: target))
        dl.addItem(.separator())
        dl.addItem(item("Move Up", #selector(AppDelegate.moveUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option], target: target))
        dl.addItem(item("Move Down", #selector(AppDelegate.moveDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option], target: target))
        dl.addItem(item("Verify Data", #selector(AppDelegate.verifySelected(_:)), target: target))
        dl.addItem(.separator())
        dl.addItem(item("Remove…", #selector(AppDelegate.removeSelected(_:)), "\u{8}", [], target: target))
        dl.addItem(item("Remove and Move to Trash…", #selector(AppDelegate.trashSelected(_:)), "\u{8}", [.command], target: target))

        // Window
        let window = submenu(main, "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Downloads", #selector(AppDelegate.showDownloads(_:)), "0", target: target))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        let help = submenu(main, "Help")
        NSApp.helpMenu = help

        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        holder.submenu = m
        main.addItem(holder)
        return m
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.target = target
        return i
    }
}
