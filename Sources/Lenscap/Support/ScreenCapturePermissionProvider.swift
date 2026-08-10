import CoreGraphics
import Foundation
import LenscapPermission

/// The real Screen Recording permission provider for this app process, backed
/// directly by CoreGraphics / TCC. Kept separate from the pure controller so
/// the controller can be unit-tested without touching live TCC state.
struct LiveScreenCapturePermissionProvider: ScreenCapturePermissionProviding {
    var canCapture: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestAccess() -> Bool {
        // CGRequestScreenCaptureAccess prompts the system dialog. macOS returns
        // true only once the process is authorized; in practice the user usually
        // has to finish granting in System Settings, so callers re-gate after.
        CGRequestScreenCaptureAccess()
    }
}
