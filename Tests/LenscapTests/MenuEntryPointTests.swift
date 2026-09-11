import AppKit
import XCTest
@testable import Lenscap

@MainActor
final class MenuEntryPointTests: XCTestCase {
    func testNativeMenuHasExplicitSettingsCommandAndUtilityActions() throws {
        let target = MenuActionSpy()
        let menu = makeMenu(target: target)
        let settings = try XCTUnwrap(menu.item(withTitle: "Settings…"))

        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertEqual(settings.action, #selector(MenuActionSpy.openSettings))
        XCTAssertTrue(settings.target === target)
        XCTAssertNotNil(menu.item(withTitle: "Check for Updates…"))
        XCTAssertNotNil(menu.item(withTitle: "Cloud Library…"))
        XCTAssertNotNil(menu.item(withTitle: "Quit Lenscap"))
        XCTAssertNotNil(menu.item(withTitle: "Capture Panel…"))
        XCTAssertTrue(target.actions.isEmpty, "Constructing the menu must not open Settings.")
    }

    func testCaptureMenuActionsNeverDispatchSettings() throws {
        let target = MenuActionSpy()
        let menu = makeMenu(target: target)
        let expected = [
            ("Capture Area", "area"), ("Window", "window"), ("Fullscreen", "fullscreen"),
            ("Scrolling", "scrolling"), ("OCR", "text"), ("Record Video", "video"),
            ("Record GIF", "gif")
        ]

        for (title, action) in expected {
            let item = try XCTUnwrap(menu.item(withTitle: title))
            menu.performActionForItem(at: menu.index(of: item))
            XCTAssertEqual(target.actions.last, action)
        }
        XCTAssertFalse(target.actions.contains("settings"))
    }

    func testOnlyExplicitSettingsMenuActionDispatchesSettings() throws {
        let target = MenuActionSpy()
        let menu = makeMenu(target: target)
        let settings = try XCTUnwrap(menu.item(withTitle: "Settings…"))

        menu.performActionForItem(at: menu.index(of: settings))

        XCTAssertEqual(target.actions, ["settings"])
    }

    func testRecordingMenuKeepsStopAndSettingsAvailable() throws {
        let target = MenuActionSpy()
        let menu = makeMenu(recording: true, target: target)
        let stop = try XCTUnwrap(menu.item(withTitle: "Stop Recording"))
        XCTAssertNotNil(menu.item(withTitle: "Settings…"))
        XCTAssertNil(menu.item(withTitle: "Record Video"))
        XCTAssertNil(menu.item(withTitle: "Record GIF"))

        menu.performActionForItem(at: menu.index(of: stop))

        XCTAssertEqual(target.actions, ["stop"])
    }

    func testCapturePanelHasExplicitInitialAndPreferredSize() {
        let controller = MenuBarPanelViewController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.preferredContentSize, NSSize(width: 348, height: 484))
        XCTAssertEqual(controller.view.frame.size, controller.preferredContentSize)
    }

    func testPanelFooterFitsWithoutConflictingRequiredHeights() throws {
        let controller = MenuBarPanelViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(origin: .zero, size: NSSize(width: 348, height: 484))
        controller.view.layoutSubtreeIfNeeded()
        let settings = try button("settings", in: controller.view)
        let history = try button("history", in: controller.view)

        for button in [history, settings] {
            // AppKit's intrinsic-size wrappers are not explicit required equalities.
            let requiredHeights = button.constraints.filter {
                $0.isMember(of: NSLayoutConstraint.self)
                    && $0.isActive && $0.priority == .required && $0.firstAttribute == .height
                    && ($0.firstItem as? NSView) === button
                    && $0.relation == .equal && $0.secondItem == nil
            }
            XCTAssertEqual(Set(requiredHeights.map(\.constant)), [32],
                           "A footer button cannot satisfy both a 32-point and 38-point height.")
            let frame = button.convert(button.bounds, to: controller.view)
            XCTAssertTrue(controller.view.bounds.contains(frame))
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
    }

    func testPanelOnlyEmitsSettingsWhenItsSettingsButtonIsClicked() throws {
        let controller = MenuBarPanelViewController()
        var actions: [MenuBarPanelViewController.Action] = []
        controller.onAction = { actions.append($0) }
        controller.loadViewIfNeeded()
        controller.isRecording = true
        controller.isRecording = false
        XCTAssertTrue(actions.isEmpty)

        try button("captureArea", in: controller.view).performClick(nil)
        XCTAssertEqual(actions, [.captureArea])
        try button("settings", in: controller.view).performClick(nil)
        XCTAssertEqual(actions, [.captureArea, .settings])
    }

    func testPreparedCaptureWindowIsReusableAndDoesNotShowSettingsOrChangePolicy() {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        let settingsBefore = app.windows.filter { $0.identifier?.rawValue == "LenscapSettings" }.count
        CapturePanelWindowController.hideForCapture()
        let window = CapturePanelWindowController.prepareWindow()
        defer { window.close() }

        XCTAssertTrue(CapturePanelWindowController.prepareWindow() === window)
        XCTAssertEqual(window.identifier?.rawValue, "LenscapCapturePanel")
        XCTAssertEqual(window.title, "Lenscap")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertEqual(window.contentView?.frame.size, NSSize(width: 348, height: 484))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(app.activationPolicy(), policy)
        XCTAssertEqual(app.windows.filter { $0.identifier?.rawValue == "LenscapSettings" }.count, settingsBefore)

        CapturePanelWindowController.hideForCapture()
        CapturePanelWindowController.setRecording(true)
        CapturePanelWindowController.setRecording(false)
        XCTAssertFalse(window.isVisible, "Capture or state updates must not restore the panel.")
        XCTAssertTrue(CapturePanelWindowController.panelViewForSnapshot() === window.contentViewController?.view)
    }

    private func makeMenu(recording: Bool = false, target: MenuActionSpy) -> NSMenu {
        _ = NSApplication.shared
        return StatusBarController.makeMenu(isRecording: recording, actionTarget: target,
                                            updatesTarget: target, quitTarget: target)
    }

    private func button(_ identifier: String, in view: NSView) throws -> NSButton {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(view), "Missing \(identifier) button")
    }
}

private final class MenuActionSpy: NSObject {
    var actions: [String] = []
    @objc func captureArea() { actions.append("area") }
    @objc func captureWindow() { actions.append("window") }
    @objc func captureFullscreen() { actions.append("fullscreen") }
    @objc func scrollingCapture() { actions.append("scrolling") }
    @objc func captureText() { actions.append("text") }
    @objc func recordVideo() { actions.append("video") }
    @objc func recordGIF() { actions.append("gif") }
    @objc func stopRecording() { actions.append("stop") }
    @objc func openHistory() { actions.append("history") }
    @objc func openCloudLibrary() { actions.append("cloud") }
    @objc func openCapturePanel() { actions.append("panel") }
    @objc func openSettings() { actions.append("settings") }
    @objc func checkForUpdates(_ sender: Any?) { actions.append("updates") }
    @objc func terminate(_ sender: Any?) { actions.append("quit") }
}
