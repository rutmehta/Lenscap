import AppKit
import ScreenCaptureKit

/// Lets the user pick a window to capture by hovering + clicking.
/// Skeleton implementation: captures the frontmost window of the app under the mouse.
@MainActor
final class WindowPickerController {
    static func pickWindow(completion: @escaping @MainActor (SCWindow?) -> Void) {
        Task { @MainActor in
            do {
                let content = try await CaptureEngine.shareableContent()
                let mouse = NSEvent.mouseLocation
                guard let mainScreen = NSScreen.screens.first else {
                    completion(nil)
                    return
                }
                // Global AppKit (bottom-left) → CG global (top-left, anchored to first screen).
                let cgPoint = CGPoint(x: mouse.x, y: mainScreen.frame.maxY - mouse.y)
                let candidates = content.windows.filter { window in
                    window.isOnScreen &&
                    window.windowLayer == 0 &&
                    window.frame.contains(cgPoint) &&
                    window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                }
                completion(candidates.first)
            } catch {
                HUD.show("Could not list windows: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }
}
