import AppKit

/// Temporarily hides desktop icons behind wallpaper-colored overlay windows.
/// Skeleton — the overlay implementation lives in a follow-up pass.
@MainActor
final class DesktopIconsHider {
    static let shared = DesktopIconsHider()

    private(set) var isHidden = false

    private init() {}

    func toggle() {
        HUD.show("Hide desktop icons is not implemented yet", symbol: "eye.slash")
    }
}
