import AppKit
import SwiftUI

/// Owns one annotation editor window. Multiple editors can be open at once;
/// each keeps itself alive in `activeControllers` until its window closes.
@MainActor
final class AnnotationEditorController: NSObject, NSWindowDelegate {
    private static var activeControllers: [AnnotationEditorController] = []

    private let state: EditorState
    private let window: NSWindow

    static func open(image: NSImage, sourceURL: URL?) {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            HUD.show("Could not open the editor for this image")
            return
        }
        let pixelScale = image.size.width > 0
            ? max(1, (CGFloat(cgImage.width) / image.size.width).rounded())
            : 1
        let controller = AnnotationEditorController(cgImage: cgImage,
                                                    pixelScale: pixelScale,
                                                    sourceURL: sourceURL)
        activeControllers.append(controller)
        controller.show()
    }

    private init(cgImage: CGImage, pixelScale: CGFloat, sourceURL: URL?) {
        state = EditorState(baseImage: cgImage, pixelScale: pixelScale, sourceURL: sourceURL)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.idealContentSize(for: cgImage,
                                                                                          pixelScale: pixelScale)),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()

        window.title = sourceURL?.lastPathComponent ?? "Annotate"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 420)
        window.contentView = NSHostingView(rootView: EditorRootView(state: state))
        window.delegate = self
        state.window = window
    }

    private func show() {
        window.center()
        // Cascade so stacked editors don't hide each other.
        let offset = CGFloat((Self.activeControllers.count - 1) % 6) * 24
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + offset,
                                      y: window.frame.origin.y - offset))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // The canvas is created lazily by SwiftUI; focus it once it exists.
        DispatchQueue.main.async { [weak self] in
            guard let self, let canvas = self.state.canvas else { return }
            self.window.makeFirstResponder(canvas)
        }
    }

    /// Window sized to show the image comfortably at up to ~1:1 points.
    private static func idealContentSize(for image: CGImage, pixelScale: CGFloat) -> NSSize {
        let toolbarHeight: CGFloat = 92
        let chrome: CGFloat = 48
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maxCanvas = NSSize(width: available.width * 0.8,
                               height: available.height * 0.8 - toolbarHeight)
        let pointSize = NSSize(width: CGFloat(image.width) / pixelScale,
                               height: CGFloat(image.height) / pixelScale)
        let scale = min(1, maxCanvas.width / max(1, pointSize.width),
                        maxCanvas.height / max(1, pointSize.height))
        let width = max(680, pointSize.width * scale + chrome)
        let height = max(420, pointSize.height * scale + toolbarHeight + chrome)
        return NSSize(width: width, height: height)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        Self.activeControllers.removeAll { $0 === self }
    }
}

// MARK: - Root view

private struct EditorRootView: View {
    @ObservedObject var state: EditorState

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(state: state)
            Divider()
            AnnotationCanvasRepresentable(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 660, minHeight: 380)
    }
}
