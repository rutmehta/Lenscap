import AppKit

/// Annotation editor window. Skeleton — shows the image; the full tool set
/// (arrows, shapes, text, blur, crop, backgrounds) lives in a follow-up pass.
@MainActor
final class AnnotationEditorController {
    private static var controllers: [NSWindowController] = []

    static func open(image: NSImage, sourceURL: URL?) {
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyDown

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = sourceURL?.lastPathComponent ?? "Annotate"
        window.contentView = imageView
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        controllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
