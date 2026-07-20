import AppKit

/// Temporarily hides desktop icons by covering each screen with a wallpaper-filled
/// window layered just above the icon layer and below normal windows.
///
/// Screen-configuration changes are handled lazily: windows are rebuilt from the
/// current screen list on the next toggle.
@MainActor
final class DesktopIconsHider {
    static let shared = DesktopIconsHider()

    private(set) var isHidden = false
    private var coverWindows: [NSWindow] = []

    private init() {}

    func toggle() {
        if isHidden {
            coverWindows.forEach { $0.orderOut(nil) }
            coverWindows.removeAll()
            isHidden = false
            HUD.show("Desktop icons shown", symbol: "eye")
        } else {
            coverWindows = NSScreen.screens.map { makeCoverWindow(for: $0) }
            coverWindows.forEach { $0.orderFrontRegardless() }
            isHidden = true
            HUD.show("Desktop icons hidden", symbol: "eye.slash")
        }
    }

    // MARK: - Cover windows

    private func makeCoverWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame,
                              styleMask: .borderless,
                              backing: .buffered, defer: false)
        // Just above the desktop icons, below every normal window.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let wallpaper = NSImage(contentsOf: url) {
            view.layer?.contents = wallpaper
            view.layer?.contentsGravity = .resizeAspectFill
            view.layer?.masksToBounds = true
        } else {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        window.contentView = view
        return window
    }
}
