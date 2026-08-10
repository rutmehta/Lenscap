import XCTest
@testable import LenscapUXCore

final class QuickAccessLifecycleTests: XCTestCase {
    private var clock = TestClock()

    private func lifecycle() -> QuickAccessLifecycle {
        QuickAccessLifecycle(now: { [clock] in clock.now })
    }

    func testConfiguredTimeoutDismissesAtConfiguredDuration() {
        let state = lifecycle()
        state.show(id: 1, duration: 8)

        clock.advance(by: 7.99)
        XCTAssertFalse(state.timerFired(for: 1))
        XCTAssertEqual(state.visibility, .visible)

        clock.advance(by: 0.01)
        XCTAssertTrue(state.timerFired(for: 1))
        XCTAssertEqual(state.visibility, .hidden)
    }

    func testHoverPausesAndResumesWithExactRemainingTime() {
        let state = lifecycle()
        state.show(id: 1, duration: 8)
        clock.advance(by: 2.25)

        XCTAssertEqual(state.hoverChanged(for: 1, inside: true)!, 5.75, accuracy: 0.000001)
        clock.advance(by: 100)
        XCTAssertEqual(state.remainingTime(for: 1)!, 5.75, accuracy: 0.000001)

        state.hoverChanged(for: 1, inside: false)
        clock.advance(by: 5.749999)
        XCTAssertFalse(state.timerFired(for: 1))
        clock.advance(by: 0.000001)
        XCTAssertTrue(state.timerFired(for: 1))
    }

    func testSuccessfulCopyDismissesCurrentCapture() {
        let state = lifecycle()
        state.show(id: 4, duration: 8)

        XCTAssertTrue(state.copySucceeded(for: 4))
        XCTAssertEqual(state.visibility, .hidden)
        XCTAssertFalse(state.copySucceeded(for: 4))
    }

    func testSuccessfulExternalDropDismissesCurrentCapture() {
        let state = lifecycle()
        state.show(id: 5, duration: 8)
        XCTAssertTrue(state.beginDrag(for: 5))

        XCTAssertTrue(state.finishDrag(for: 5, outcome: .succeeded))
        XCTAssertEqual(state.visibility, .hidden)
    }

    func testCancelledDragRemainsVisibleAndResumesWithRemainingTime() {
        let state = lifecycle()
        state.show(id: 6, duration: 8)
        clock.advance(by: 3.5)
        state.beginDrag(for: 6)
        clock.advance(by: 100)

        XCTAssertFalse(state.finishDrag(for: 6, outcome: .cancelled))
        XCTAssertEqual(state.visibility, .visible)
        XCTAssertEqual(state.remainingTime(for: 6)!, 4.5, accuracy: 0.000001)

        clock.advance(by: 4.499999)
        XCTAssertFalse(state.timerFired(for: 6))
        clock.advance(by: 0.000001)
        XCTAssertTrue(state.timerFired(for: 6))
    }

    func testReplacementInvalidatesOldTimerAndOldCompletion() {
        let state = lifecycle()
        state.show(id: 10, duration: 8)
        clock.advance(by: 2)
        state.show(id: 11, duration: 8)

        clock.advance(by: 6)
        XCTAssertFalse(state.timerFired(for: 10))
        XCTAssertFalse(state.copySucceeded(for: 10))
        XCTAssertEqual(state.currentCaptureID, 11)
        XCTAssertEqual(state.visibility, .visible)

        clock.advance(by: 2)
        XCTAssertTrue(state.timerFired(for: 11))
    }
}

private final class TestClock {
    var now: TimeInterval = 0

    func advance(by interval: TimeInterval) {
        now += interval
    }
}