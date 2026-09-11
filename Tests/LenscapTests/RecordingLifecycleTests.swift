import Foundation
import XCTest
@testable import Lenscap

@MainActor
final class RecordingLifecycleTests: XCTestCase {
    func testRepeatedStopsAwaitOneFinalizationOperation() async {
        let coordinator = RecordingFinalizationCoordinator()
        let gate = RecordingTestGate()
        let started = expectation(description: "Finalization started")
        var operationCount = 0
        var secondStopReturned = false
        let first = Task {
            await coordinator.run {
                operationCount += 1
                started.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(coordinator.isFinalizing)
        let second = Task {
            await coordinator.run { operationCount += 1 }
            secondStopReturned = true
        }
        await Task.yield()

        XCTAssertEqual(operationCount, 1)
        XCTAssertFalse(secondStopReturned)
        gate.release()
        await first.value
        await second.value
        XCTAssertEqual(operationCount, 1)
        XCTAssertFalse(coordinator.isFinalizing)
    }

    func testFinalizationBlocksNewRecordingsAndStopWaitsAfterRecordingFlagClears() async {
        let coordinator = RecordingFinalizationCoordinator()
        let recorder = ScreenRecorder(finalization: coordinator)
        let gate = RecordingTestGate()
        let started = expectation(description: "Finalization started")
        var stopReturned = false
        let finishing = Task {
            await coordinator.run {
                started.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.isFinalizing)
        XCTAssertFalse(recorder.canStartRecording)
        let stopping = Task {
            await recorder.stopAndSave()
            stopReturned = true
        }
        await Task.yield()
        XCTAssertFalse(stopReturned)

        gate.release()
        await finishing.value
        await stopping.value
        XCTAssertTrue(stopReturned)
        XCTAssertTrue(recorder.canStartRecording)
    }

    func testQuitDuringFinalizationWaitsForTheSameTaskThenCloudStaging() async {
        let finalization = RecordingFinalizationCoordinator()
        let recorder = ScreenRecorder(finalization: finalization)
        let finalizationGate = RecordingTestGate()
        let stagingGate = RecordingTestGate()
        let started = expectation(description: "Finalization started")
        let stagingStarted = expectation(description: "Cloud staging started")
        let replied = expectation(description: "Termination replied")
        var events: [String] = []
        let finalizing = Task {
            await finalization.run {
                started.fulfill()
                await finalizationGate.wait()
                events.append("finalized")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let shutdown = CaptureShutdownCoordinator(
            needsWait: { recorder.isRecording || recorder.isFinalizing },
            finishRecording: { await recorder.stopAndSave() },
            waitForStaging: {
                events.append("staging")
                stagingStarted.fulfill()
                await stagingGate.wait()
            }
        )

        let waiting = shutdown.requestTermination {
            events.append("reply")
            replied.fulfill()
        }
        XCTAssertTrue(waiting)
        await Task.yield()
        XCTAssertTrue(events.isEmpty)

        finalizationGate.release()
        await finalizing.value
        await fulfillment(of: [stagingStarted], timeout: 1)
        XCTAssertEqual(events, ["finalized", "staging"])
        stagingGate.release()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(events, ["finalized", "staging", "reply"])
    }

    func testRepeatedQuitRequestsDoNotStartDuplicateShutdownWork() async {
        let gate = RecordingTestGate()
        let started = expectation(description: "Shutdown started")
        var finishCount = 0
        var stagingCount = 0
        var replyCount = 0
        let shutdown = CaptureShutdownCoordinator(
            needsWait: { true },
            finishRecording: {
                finishCount += 1
                if finishCount == 1 { started.fulfill() }
                await gate.wait()
            },
            waitForStaging: { stagingCount += 1 }
        )
        let replied = expectation(description: "Shutdown replied")
        XCTAssertTrue(shutdown.requestTermination {
            replyCount += 1
            if replyCount == 1 { replied.fulfill() }
        })
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(shutdown.requestTermination { replyCount += 1 })
        await Task.yield()
        XCTAssertEqual(finishCount, 1)
        gate.release()
        await fulfillment(of: [replied], timeout: 1)
        await Task.yield()
        XCTAssertEqual(stagingCount, 1)
        XCTAssertEqual(replyCount, 1)
    }

    func testIdleQuitDoesNotStartFinalizationOrStaging() {
        var called = false
        let shutdown = CaptureShutdownCoordinator(needsWait: { false },
            finishRecording: { called = true }, waitForStaging: { called = true })

        XCTAssertFalse(shutdown.requestTermination { called = true })
        XCTAssertFalse(called)
    }

    func testFailedDestinationMoveKeepsFinalizedVideoAndExistingDestination() throws {
        try withRecordingFiles { source, destination, bytes in
            let existing = Data("existing recording".utf8)
            try existing.write(to: destination)

            let result = ScreenRecorder.moveFinalizedVideo(at: source, to: destination)

            XCTAssertTrue(result.usedTemporaryLocation)
            XCTAssertEqual(result.url, source)
            XCTAssertEqual(try? Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: destination), existing)
        }
    }

    func testSuccessfulDestinationMoveReturnsSavedVideo() throws {
        try withRecordingFiles { source, destination, bytes in
            let result = ScreenRecorder.moveFinalizedVideo(at: source, to: destination)

            XCTAssertFalse(result.usedTemporaryLocation)
            XCTAssertEqual(result.url, destination)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
        }
    }

    private func withRecordingFiles(_ body: (URL, URL, Data) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LenscapRecordingLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("finalized.mp4")
        let destination = directory.appendingPathComponent("saved.mp4")
        let bytes = Data("finalized video bytes".utf8)
        try bytes.write(to: source)
        try body(source, destination, bytes)
    }
}

@MainActor
private final class RecordingTestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
