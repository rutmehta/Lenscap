import AppKit

/// Scrolling capture: select an area, scroll the content, and stitch frames into one tall image.
/// Skeleton — the full implementation lives in a follow-up pass.
@MainActor
final class ScrollingCaptureController {
    static let shared = ScrollingCaptureController()

    private init() {}

    func begin() {
        HUD.show("Scrolling capture is not implemented yet", symbol: "arrow.up.and.down.square")
    }
}
