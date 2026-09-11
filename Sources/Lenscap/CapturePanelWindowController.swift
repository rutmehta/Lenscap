import AppKit

/// An explicit entry point for an accessory app, without turning Settings into its home screen.
@MainActor
final class CapturePanelWindowController {
    private static var window: NSWindow?
    private static let panel = MenuBarPanelViewController()

    static func open() {
        let window = prepareWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    static func hideForCapture() {
        window?.orderOut(nil)
    }

    static func prepareWindow() -> NSWindow {
        panel.isRecording = ScreenRecorder.shared.isRecording
        if let window { return window }
        panel.loadViewIfNeeded()
        let newWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: panel.preferredContentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.contentViewController = panel
        newWindow.setContentSize(panel.preferredContentSize)
        newWindow.title = "Lenscap"
        newWindow.identifier = NSUserInterfaceItemIdentifier("LenscapCapturePanel")
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        panel.onAction = { action in
            hideForCapture()
            perform(action)
        }
        window = newWindow
        return newWindow
    }

    static func setRecording(_ recording: Bool) {
        panel.isRecording = recording
    }

    static func panelViewForSnapshot() -> NSView {
        panel.loadViewIfNeeded()
        panel.view.layoutSubtreeIfNeeded()
        return panel.view
    }

    private static func perform(_ action: MenuBarPanelViewController.Action) {
        let coordinator = AppCoordinator.shared
        switch action {
        case .captureArea: coordinator.captureArea()
        case .captureWindow: coordinator.captureWindow()
        case .captureFullscreen: coordinator.captureFullscreen()
        case .scrollingCapture: coordinator.startScrollingCapture()
        case .captureText: coordinator.captureText()
        case .recordVideo: coordinator.toggleRecording(mode: .video)
        case .recordGIF: coordinator.toggleRecording(mode: .gif)
        case .history: coordinator.openHistory()
        case .settings: coordinator.openSettings()
        }
    }
}
