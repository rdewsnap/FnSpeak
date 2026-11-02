import AppKit

/// The app has no Dock icon by default, but its main menu still supplies ⌘, and
/// the standard editing shortcuts to any Flowstate window that is frontmost.
enum MainMenu {
    static func install(target: AnyObject, settings: Selector, about: Selector) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu(title: "Flowstate")
        app.addItem(withTitle: "About Flowstate", action: about, keyEquivalent: "").target = target
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: settings, keyEquivalent: ",").target = target
        app.addItem(withTitle: "Meetings…", action: Selector(("showMeetings:")), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Flowstate", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Flowstate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}
