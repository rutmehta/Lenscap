import Foundation

/// The decision a user-initiated capture should make about Screen Recording
/// permission. Callers decide what UI to present based on this.
public enum ScreenCaptureGateDecision: Equatable, Sendable {
    /// Screen Recording access is currently granted — run the capture.
    case proceed
    /// Access is missing — surface the durable permission UI before capturing.
    case needsPermission
}

/// Injectable abstraction over the real TCC / CoreGraphics screen-capture
/// permission surface so controller logic can be unit-tested without touching
/// live TCC state.
public protocol ScreenCapturePermissionProviding {
    /// Live preflight of the current process: `true` when Screen Recording is
    /// granted (maps to `CGPreflightScreenCaptureAccess()` for the default app).
    var canCapture: Bool { get }
    /// Best-effort prompt of the system authorization dialog. Returns `true`
    /// only once macOS has granted the process access; otherwise the user must
    /// still act in System Settings. Only call from a user-initiated action.
    func requestAccess() -> Bool
}

/// Pure, testable controller that gates every user-initiated capture on *live*
/// Screen Recording permission. It never caches a one-shot boolean — every gate
/// re-reads `CGPreflight`, so the stale-default trap (where the app thought it
/// had asked once and gave up) cannot recur. This type has no UI knowledge;
/// presenters decide what to show from the returned `ScreenCaptureGateDecision`.
public final class ScreenCapturePermissionController {
    public let provider: ScreenCapturePermissionProviding

    public init(provider: ScreenCapturePermissionProviding) {
        self.provider = provider
    }

    /// True when Screen Recording is currently granted (always a live read).
    public var canCapture: Bool { provider.canCapture }

    /// Gate a new user-initiated capture. Re-checks live state every call.
    @discardableResult
    public func gateForCapture() -> ScreenCaptureGateDecision {
        provider.canCapture ? .proceed : .needsPermission
    }

    /// The user tapped "Request Access": fire the system dialog once. Returns
    /// the resulting grant state; callers may re-gate afterwards.
    @discardableResult
    public func requestAccess() -> Bool {
        provider.requestAccess()
    }

    /// Called after the user returns from System Settings or taps "Retry".
    /// Re-checks live state; a grant observed here yields `.proceed`.
    @discardableResult
    public func evaluateAfterReturn() -> ScreenCaptureGateDecision {
        gateForCapture()
    }
}
