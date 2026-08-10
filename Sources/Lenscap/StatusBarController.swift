import AppKit

/// Owns the menu-bar status item. A normal click opens the compact control panel;
/// a right click (or Control-click) opens the compatibility menu with utility
/// commands such as updates and Quit.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let fallbackMenu = NSMenu()
    private let popover = NSPopover()
    private let panelController = MenuBarPanelViewController()
    private var recording = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Lenscap")
            button.image?.isTemplate = true
            button.toolTip = "Lenscap — open capture panel"
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panelController.onAction = { [weak self] action in
            self?.perform(action)
        }
        popover.contentViewController = panelController
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .vibrantLight)

        fallbackMenu.delegate = self
        rebuildFallbackMenu()
    }

    func setRecording(_ recording: Bool) {
        self.recording = recording
        panelController.isRecording = recording
        if let button = statusItem.button {
            let symbol = recording ? "stop.circle.fill" : "camera.viewfinder"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lenscap")
            button.contentTintColor = recording ? .systemRed : nil
        }
        rebuildFallbackMenu()
    }

    func refreshMenuState() {
        rebuildFallbackMenu()
        panelController.isRecording = recording
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildFallbackMenu()
    }

    /// Used only by the deterministic snapshot route; it is the same view installed
    /// in the live popover, not a hand-drawn approximation.
    func panelViewForSnapshot() -> NSView {
        panelController.loadViewIfNeeded()
        panelController.view.layoutSubtreeIfNeeded()
        return panelController.view
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || event?.type == .rightMouseDown
        let isControlClick = event?.modifierFlags.contains(.control) == true
        if isRightClick || isControlClick {
            showFallbackMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        panelController.isRecording = ScreenRecorder.shared.isRecording
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showFallbackMenu(from button: NSStatusBarButton) {
        rebuildFallbackMenu()
        let point = NSPoint(x: button.bounds.midX, y: button.bounds.minY)
        fallbackMenu.popUp(positioning: nil, at: point, in: button)
    }

    private func rebuildFallbackMenu() {
        fallbackMenu.removeAllItems()
        let currentRecording = ScreenRecorder.shared.isRecording
        if currentRecording {
            fallbackMenu.addItem(item("Stop Recording", #selector(stopRecording), symbol: "stop.circle.fill"))
            fallbackMenu.addItem(.separator())
        }
        fallbackMenu.addItem(item("Capture Area", #selector(captureArea), symbol: "rectangle.dashed"))
        fallbackMenu.addItem(item("Window", #selector(captureWindow), symbol: "macwindow"))
        fallbackMenu.addItem(item("Fullscreen", #selector(captureFullscreen), symbol: "display"))
        fallbackMenu.addItem(item("Scrolling", #selector(scrollingCapture), symbol: "arrow.up.and.down.square"))
        fallbackMenu.addItem(item("OCR", #selector(captureText), symbol: "text.viewfinder"))
        fallbackMenu.addItem(.separator())
        if !currentRecording {
            fallbackMenu.addItem(item("Record Video", #selector(recordVideo), symbol: "record.circle"))
            fallbackMenu.addItem(item("Record GIF", #selector(recordGIF), symbol: "photo.stack"))
            fallbackMenu.addItem(.separator())
        }
        fallbackMenu.addItem(item("History", #selector(openHistory), symbol: "clock.arrow.circlepath"))
        fallbackMenu.addItem(item("Settings", #selector(openSettings), symbol: "gearshape"))
        fallbackMenu.addItem(.separator())

        let updates = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(UpdaterController.checkForUpdates(_:)),
                                 keyEquivalent: "")
        updates.target = UpdaterController.shared
        fallbackMenu.addItem(updates)

        let quit = NSMenuItem(title: "Quit Lenscap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        fallbackMenu.addItem(quit)
    }

    private func item(_ title: String, _ selector: Selector, symbol: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.target = self
        menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return menuItem
    }

    private func perform(_ action: MenuBarPanelViewController.Action) {
        switch action {
        case .captureArea: captureArea()
        case .captureWindow: captureWindow()
        case .captureFullscreen: captureFullscreen()
        case .scrollingCapture: scrollingCapture()
        case .captureText: captureText()
        case .recordVideo: recordVideo()
        case .recordGIF: recordGIF()
        case .history: openHistory()
        case .settings: openSettings()
        }
        popover.performClose(nil)
    }

    // MARK: - Actions shared by the panel and fallback menu

    @objc private func captureArea() { AppCoordinator.shared.captureArea() }
    @objc private func captureWindow() { AppCoordinator.shared.captureWindow() }
    @objc private func captureFullscreen() { AppCoordinator.shared.captureFullscreen() }
    @objc private func captureText() { AppCoordinator.shared.captureText() }
    @objc private func scrollingCapture() { AppCoordinator.shared.startScrollingCapture() }
    @objc private func recordVideo() { AppCoordinator.shared.toggleRecording(mode: .video) }
    @objc private func recordGIF() { AppCoordinator.shared.toggleRecording(mode: .gif) }
    @objc private func stopRecording() { AppCoordinator.shared.stopRecordingIfNeeded() }
    @objc private func openHistory() { AppCoordinator.shared.openHistory() }
    @objc private func openSettings() { AppCoordinator.shared.openSettings() }
}
