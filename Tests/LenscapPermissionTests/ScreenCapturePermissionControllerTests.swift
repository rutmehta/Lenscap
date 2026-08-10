import XCTest
@testable import LenscapPermission

/// A mock permission provider so the controller's state-machine logic can be
/// driven without touching real TCC / CoreGraphics state.
final class MockScreenCapturePermissionProvider: ScreenCapturePermissionProviding {
    /// Toggle this to simulate TCC / CG state changing out from under us.
    var canCaptureValue = false
    var canCapture: Bool { canCaptureValue }

    private(set) var requestCallCount = 0
    func requestAccess() -> Bool {
        requestCallCount += 1
        return canCaptureValue
    }
}

final class ScreenCapturePermissionControllerTests: XCTestCase {
    func testGateProceedsWhenPermissionAlreadyGranted() {
        let provider = MockScreenCapturePermissionProvider()
        provider.canCaptureValue = true
        let controller = ScreenCapturePermissionController(provider: provider)

        XCTAssertEqual(controller.gateForCapture(), .proceed)
        XCTAssertTrue(controller.canCapture)
    }

    func testGateNeedsPermissionWhenDeniedOnFirstLaunch() {
        let provider = MockScreenCapturePermissionProvider()
        provider.canCaptureValue = false
        let controller = ScreenCapturePermissionController(provider: provider)

        XCTAssertEqual(controller.gateForCapture(), .needsPermission)
        XCTAssertFalse(controller.canCapture)
    }

    func testDeniedThenGrantedAfterReturningFromSystemSettings() {
        let provider = MockScreenCapturePermissionProvider()
        provider.canCaptureValue = false
        let controller = ScreenCapturePermissionController(provider: provider)

        // User starts a capture while denied.
        XCTAssertEqual(controller.gateForCapture(), .needsPermission)

        // User grants access in System Settings and comes back / taps Retry.
        provider.canCaptureValue = true
        XCTAssertEqual(controller.evaluateAfterReturn(), .proceed)
    }

    func testGrantedThenRevokedWhileRunningTopsBackToNeedsPermission() {
        let provider = MockScreenCapturePermissionProvider()
        provider.canCaptureValue = true
        let controller = ScreenCapturePermissionController(provider: provider)

        XCTAssertEqual(controller.gateForCapture(), .proceed)

        // macOS revokes Screen Recording while the app is still running.
        provider.canCaptureValue = false
        XCTAssertEqual(controller.gateForCapture(), .needsPermission)
    }

    func testRequestAccessDelegatesToProviderOnce() {
        let provider = MockScreenCapturePermissionProvider()
        let controller = ScreenCapturePermissionController(provider: provider)

        controller.requestAccess()
        controller.requestAccess()
        XCTAssertEqual(provider.requestCallCount, 2)
    }

    func testNeverCachesPermissionFlag() {
        // The stale-default design trapped users because it cached a one-shot
        // boolean. The controller must always read live state.
        let provider = MockScreenCapturePermissionProvider()
        provider.canCaptureValue = false
        let controller = ScreenCapturePermissionController(provider: provider)

        _ = controller.gateForCapture() // returns .needsPermission

        // An external grant (TCC change) must be observed on the next gate.
        provider.canCaptureValue = true
        XCTAssertEqual(controller.gateForCapture(), .proceed)
    }

    func testGateIsDeterministicAcrossRepeatedChecks() {
        let provider = MockScreenCapturePermissionProvider()
        provider.canCaptureValue = true
        let controller = ScreenCapturePermissionController(provider: provider)
        for _ in 0..<100 {
            XCTAssertEqual(controller.gateForCapture(), .proceed)
        }
    }
}
