import AppKit
import SwiftUI

/// Tabbed macOS settings window. A single instance is reused; `open()` re-fronts it.
@MainActor
final class SettingsWindowController {
    private static var window: NSWindow?

    static func open() {
        if window == nil {
            window = makeWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window construction

    private static func makeWindow() -> NSWindow {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab("General", symbol: "gearshape", height: 470, view: GeneralSettingsView()))
        tabs.addTabViewItem(tab("Screenshots", symbol: "camera.viewfinder", height: 330, view: ScreenshotsSettingsView()))
        tabs.addTabViewItem(tab("Recording", symbol: "record.circle", height: 320, view: RecordingSettingsView()))
        tabs.addTabViewItem(tab("Shortcuts", symbol: "command", height: 480, view: ShortcutsSettingsView()))
        tabs.addTabViewItem(tab("About", symbol: "info.circle", height: 340, view: AboutSettingsView()))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "General"
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private static func tab(_ label: String, symbol: String, height: CGFloat, view: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.frame(width: 560, height: height))
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

/// Keeps the window title in sync with the selected toolbar tab.
private final class SettingsTabViewController: NSTabViewController {
    override func viewWillAppear() {
        super.viewWillAppear()
        if tabViewItems.indices.contains(selectedTabViewItemIndex) {
            view.window?.title = tabViewItems[selectedTabViewItemIndex].label
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let tabViewItem {
            view.window?.title = tabViewItem.label
        }
    }
}
