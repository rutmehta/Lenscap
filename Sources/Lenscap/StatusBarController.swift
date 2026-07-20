import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Lenscap")
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func setRecording(_ recording: Bool) {
        if let button = statusItem.button {
            let symbol = recording ? "stop.circle.fill" : "camera.viewfinder"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lenscap")
            button.contentTintColor = recording ? .systemRed : nil
        }
        rebuildMenu()
    }

    func refreshMenuState() {
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let recording = ScreenRecorder.shared.isRecording

        if recording {
            menu.addItem(item("Stop Recording", #selector(stopRecording), symbol: "stop.circle.fill"))
            menu.addItem(.separator())
        }

        menu.addItem(item("Capture Area", #selector(captureArea), symbol: "rectangle.dashed", action: .captureArea))
        menu.addItem(item("Capture Window", #selector(captureWindow), symbol: "macwindow", action: .captureWindow))
        menu.addItem(item("Capture Fullscreen", #selector(captureFullscreen), symbol: "display", action: .captureFullscreen))
        menu.addItem(item("Capture Text (OCR)", #selector(captureText), symbol: "text.viewfinder", action: .captureText))
        menu.addItem(item("Scrolling Capture", #selector(scrollingCapture), symbol: "arrow.up.and.down.square", action: .scrollingCapture))
        menu.addItem(.separator())

        if !recording {
            menu.addItem(item("Record Video", #selector(recordVideo), symbol: "record.circle", action: .recordVideo))
            menu.addItem(item("Record GIF", #selector(recordGIF), symbol: "photo.stack", action: .recordGIF))
            menu.addItem(.separator())
        }

        menu.addItem(item("Pin from Clipboard", #selector(pinFromClipboard), symbol: "pin"))
        let hideIcons = item("Hide Desktop Icons", #selector(toggleDesktopIcons), symbol: "eye.slash")
        hideIcons.state = DesktopIconsHider.shared.isHidden ? .on : .off
        menu.addItem(hideIcons)
        menu.addItem(.separator())

        menu.addItem(item("History…", #selector(openHistory), symbol: "clock.arrow.circlepath", action: .openHistory))
        menu.addItem(item("Settings…", #selector(openSettings), symbol: "gearshape"))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Lenscap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func item(_ title: String, _ selector: Selector, symbol: String, action: HotkeyAction? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let action, let combo = HotkeyManager.shared.combo(for: action) {
            item.keyEquivalent = combo.keyEquivalentCharacter
            item.keyEquivalentModifierMask = combo.cocoaModifiers
        }
        return item
    }

    // MARK: - Actions

    @objc private func captureArea() { AppCoordinator.shared.captureArea() }
    @objc private func captureWindow() { AppCoordinator.shared.captureWindow() }
    @objc private func captureFullscreen() { AppCoordinator.shared.captureFullscreen() }
    @objc private func captureText() { AppCoordinator.shared.captureText() }
    @objc private func scrollingCapture() { AppCoordinator.shared.startScrollingCapture() }
    @objc private func recordVideo() { AppCoordinator.shared.toggleRecording(mode: .video) }
    @objc private func recordGIF() { AppCoordinator.shared.toggleRecording(mode: .gif) }
    @objc private func stopRecording() { AppCoordinator.shared.stopRecordingIfNeeded() }
    @objc private func pinFromClipboard() { AppCoordinator.shared.pinFromClipboard() }
    @objc private func toggleDesktopIcons() { AppCoordinator.shared.toggleDesktopIcons() }
    @objc private func openHistory() { AppCoordinator.shared.openHistory() }
    @objc private func openSettings() { AppCoordinator.shared.openSettings() }
}
