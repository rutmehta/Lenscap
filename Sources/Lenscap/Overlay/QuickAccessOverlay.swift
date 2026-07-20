import AppKit

/// Floating post-capture thumbnail in the corner of the screen with quick actions.
/// Skeleton — shows a HUD confirmation; the full overlay lives in a follow-up pass.
@MainActor
final class QuickAccessOverlayController {
    static let shared = QuickAccessOverlayController()

    private init() {}

    func show(_ item: CaptureItem) {
        if item.fileURL != nil {
            HUD.show("Capture saved", symbol: "checkmark.circle")
        } else {
            HUD.show("Captured", symbol: "checkmark.circle")
        }
    }
}
