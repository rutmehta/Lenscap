import AppKit
import LenscapPermission
import XCTest
@testable import Lenscap

@MainActor
final class SettingsWindowLayoutTests: XCTestCase {
    func testSettingsWindowHasRoomForNavigationAndReadableControls() throws {
        let window = try openSettingsWindow()
        defer { window.close() }

        let content = try XCTUnwrap(window.contentView)
        XCTAssertGreaterThanOrEqual(content.bounds.width, 760)
        XCTAssertGreaterThanOrEqual(content.bounds.height, 560)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 760)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 560)
    }

    func testSettingsWindowKeepsAProductTitleWhenReopened() throws {
        let window = try openSettingsWindow()
        defer { window.close() }

        XCTAssertEqual(window.title, "Lenscap Settings")
        window.orderOut(nil)
        SettingsWindowController.open()
        XCTAssertEqual(window.title, "Lenscap Settings")
        XCTAssertTrue(window.isVisible)
    }

    func testCaptureEntryDoesNotResurfacePreviouslyOpenedSettings() throws {
        let window = try openSettingsWindow()
        defer { window.close() }
        XCTAssertTrue(window.isVisible)

        XCTAssertTrue(AppCoordinator.shared.beginScreenCapture(permissionProvider: GrantedCapturePermission(), retry: {}))
        NSApplication.shared.activate(ignoringOtherApps: true)

        XCTAssertFalse(window.isVisible, "Capture activation must not bring the retained Settings window forward.")

        SettingsWindowController.open()
        XCTAssertTrue(window.isVisible, "Settings must remain available when explicitly requested.")
    }

    private func openSettingsWindow() throws -> NSWindow {
        let app = NSApplication.shared
        SettingsWindowController.open()
        return try XCTUnwrap(app.windows.first {
            $0.title == "General" || $0.title == "Lenscap Settings"
        })
    }
}

private struct GrantedCapturePermission: ScreenCapturePermissionProviding {
    var canCapture: Bool { true }
    func requestAccess() -> Bool { true }
}
