import AppKit

/// The normal status-item click opens the complete native menu, including Settings.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: "Lenscap")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Lenscap")
            button.image?.isTemplate = true
            button.toolTip = "Lenscap — capture, history, and settings"
        }

        menu.delegate = self
        rebuildMenu()
        statusItem.menu = menu
    }

    func setRecording(_ recording: Bool) {
        CapturePanelWindowController.setRecording(recording)
        if let button = statusItem.button {
            let symbol = recording ? "stop.circle.fill" : "camera.viewfinder"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lenscap")
            button.contentTintColor = recording ? .systemRed : nil
        }
        rebuildMenu()
    }

    func refreshMenuState() {
        rebuildMenu()
        CapturePanelWindowController.setRecording(ScreenRecorder.shared.isRecording)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    /// The snapshot route renders the same view hosted in the standalone capture window.
    func panelViewForSnapshot() -> NSView {
        CapturePanelWindowController.panelViewForSnapshot()
    }

    private func rebuildMenu() {
        let replacement = Self.makeMenu(isRecording: ScreenRecorder.shared.isRecording,
                                        actionTarget: self, updatesTarget: UpdaterController.shared,
                                        quitTarget: NSApp)
        menu.removeAllItems()
        for item in replacement.items {
            replacement.removeItem(item)
            menu.addItem(item)
        }
    }

    static func makeMenu(isRecording: Bool, actionTarget: AnyObject,
                         updatesTarget: AnyObject, quitTarget: AnyObject) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ selector: Selector, symbol: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = actionTarget
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        menu.addItem(item("Capture Panel…", #selector(openCapturePanel), symbol: "camera.viewfinder"))
        menu.addItem(.separator())
        if isRecording {
            menu.addItem(item("Stop Recording", #selector(stopRecording), symbol: "stop.circle.fill"))
            menu.addItem(.separator())
        }
        menu.addItem(item("Capture Area", #selector(captureArea), symbol: "rectangle.dashed"))
        menu.addItem(item("Window", #selector(captureWindow), symbol: "macwindow"))
        menu.addItem(item("Fullscreen", #selector(captureFullscreen), symbol: "display"))
        menu.addItem(item("Scrolling", #selector(scrollingCapture), symbol: "arrow.up.and.down.square"))
        menu.addItem(item("OCR", #selector(captureText), symbol: "text.viewfinder"))
        menu.addItem(.separator())
        if !isRecording {
            menu.addItem(item("Record Video", #selector(recordVideo), symbol: "record.circle"))
            menu.addItem(item("Record GIF", #selector(recordGIF), symbol: "photo.stack"))
            menu.addItem(.separator())
        }
        menu.addItem(item("History", #selector(openHistory), symbol: "clock.arrow.circlepath"))
        menu.addItem(item("Cloud Library…", #selector(openCloudLibrary), symbol: "icloud"))
        let settings = item("Settings…", #selector(openSettings), symbol: "gearshape")
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(.separator())
        let updates = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(UpdaterController.checkForUpdates(_:)),
                                 keyEquivalent: "")
        updates.target = updatesTarget
        menu.addItem(updates)
        let quit = NSMenuItem(title: "Quit Lenscap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = quitTarget
        menu.addItem(quit)
        return menu
    }

    // MARK: - Explicit native-menu actions

    @objc private func openCapturePanel() { CapturePanelWindowController.open() }
    @objc private func captureArea() { AppCoordinator.shared.captureArea() }
    @objc private func captureWindow() { AppCoordinator.shared.captureWindow() }
    @objc private func captureFullscreen() { AppCoordinator.shared.captureFullscreen() }
    @objc private func captureText() { AppCoordinator.shared.captureText() }
    @objc private func scrollingCapture() { AppCoordinator.shared.startScrollingCapture() }
    @objc private func recordVideo() { AppCoordinator.shared.toggleRecording(mode: .video) }
    @objc private func recordGIF() { AppCoordinator.shared.toggleRecording(mode: .gif) }
    @objc private func stopRecording() { AppCoordinator.shared.stopRecordingIfNeeded() }
    @objc private func openHistory() { AppCoordinator.shared.openHistory() }
    @objc private func openCloudLibrary() { AppCoordinator.shared.openCloudLibrary() }
    @objc private func openSettings() { AppCoordinator.shared.openSettings() }
}
