import AppKit
import Combine
import SwiftUI

/// The settings window: a SwiftUI body under a native toolbar of tabs.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let router = SettingsRouter.shared
    private var subscription: AnyCancellable?

    init(engine: EngineController, indexer: PersonalIndexer) {
        let host = NSHostingController(rootView: SettingsView(engine: engine, indexer: indexer))
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.setContentSize(NSSize(width: 640, height: 540))
        if !window.setFrameUsingName("FlowstateSettings") { window.center() }
        window.setFrameAutosaveName("FlowstateSettings")
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "FlowstateSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        subscription = router.$tab.sink { [weak self] tab in
            self?.window?.title = tab.title
            self?.window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(tab: SettingsTab? = nil) {
        if let tab { router.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func select(_ sender: NSToolbarItem) {
        if let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) { router.tab = tab }
    }

    // MARK: - NSToolbarDelegate

    private var identifiers: [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(select(_:))
        return item
    }
}
