import AppKit

/// Deterministic visual regression route. Set LENSCAP_SNAPSHOT_DIR when launching
/// the assembled binary and it writes the live panel, selection overlay, and quick
/// access views as PNGs. These are rendered from the production views themselves;
/// no simulated or hand-authored screenshots are involved.
@MainActor
enum DebugSnapshotController {
    static func captureIfRequested() {
        guard let rawDirectory = ProcessInfo.processInfo.environment["LENSCAP_SNAPSHOT_DIR"],
              !rawDirectory.isEmpty else { return }
        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let panel = AppCoordinator.shared.statusBar?.panelViewForSnapshot() {
            save(view: panel, to: directory.appendingPathComponent("menu-bar-panel.png"), size: NSSize(width: 348, height: 484))
        }

        if let screen = NSScreen.main {
            let selection = SelectionView(frame: NSRect(x: 0, y: 0, width: 900, height: 560),
                                          controller: nil, screen: screen,
                                          prompt: "Drag to select an area — ⎋ to cancel")
            selection.setDebugSelection(start: NSPoint(x: 185, y: 155),
                                        current: NSPoint(x: 700, y: 430))
            save(view: selection, to: directory.appendingPathComponent("capture-selection.png"),
                 size: NSSize(width: 900, height: 560))
        }

        let item = CaptureItem(kind: .screenshot, image: sampleImage(), fileURL: nil)
        let quickAccess = QuickAccessOverlayController.shared
        quickAccess.show(item)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        if let view = quickAccess.contentViewForSnapshot() {
            save(view: view, to: directory.appendingPathComponent("quick-access.png"), size: view.frame.size)
        }
        quickAccess.dismissForSnapshot()
    }

    private static func save(view: NSView, to url: URL, size: NSSize) {
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func sampleImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 720, height: 420))
        image.lockFocus()
        NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.22, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 720, height: 420).fill()
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.80, alpha: 1),
            NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.68, alpha: 1),
        ])
        gradient?.draw(in: NSRect(x: 32, y: 32, width: 656, height: 356), angle: 24)
        let title = "Lenscap capture"
        title.draw(at: NSPoint(x: 64, y: 314), withAttributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        image.unlockFocus()
        return image
    }
}