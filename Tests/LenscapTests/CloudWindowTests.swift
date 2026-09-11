import AppKit
import XCTest
@testable import Lenscap

@MainActor
final class CloudWindowTests: XCTestCase {
    func testCloudLibraryIsResizableAndReusesItsWindow() throws {
        CloudLibraryWindowController.open()
        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "Lenscap Cloud" })
        defer { window.close() }
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 700)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 480)
        window.orderOut(nil)
        CloudLibraryWindowController.open()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSApplication.shared.windows.filter { $0.title == "Lenscap Cloud" }.count, 1)
    }
}
