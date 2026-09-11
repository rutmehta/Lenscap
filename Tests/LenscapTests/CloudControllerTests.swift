import XCTest
@testable import Lenscap
@testable import LenscapCloudCore

@MainActor
final class CloudControllerTests: XCTestCase {
    func testActivateAndEnqueueStagesBeforeStartingNetworkUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ControllerTransport()
        let controller = CloudController(supportDirectory: directory, transportFactory: { transport })

        controller.activate(configuration: CloudConfiguration(baseURL: URL(string: "https://api.example.invalid")!, token: "token"))
        await controller.enqueue(data: Data("image".utf8), id: UUID(), filename: "shot.png",
                                 kind: .screenshot, contentType: "image/png", createdAt: Date())

        XCTAssertTrue(controller.isConfigured)
        XCTAssertEqual(controller.snapshots.count, 1)
        XCTAssertEqual(controller.snapshots.first?.status, .pending)
        XCTAssertNil(controller.lastError)
    }

    func testEnqueueDuringBlockedWorkerIsProcessedAfterFirstUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = BlockingTransport()
        let controller = CloudController(supportDirectory: directory, transportFactory: { transport })
        controller.activate(configuration: configuration)

        await controller.enqueue(data: Data("first".utf8), id: UUID(), filename: "first.png", kind: .screenshot,
                                 contentType: "image/png", createdAt: Date())
        await transport.waitUntilFirstCreate()
        await controller.enqueue(data: Data("second".utf8), id: UUID(), filename: "second.png", kind: .screenshot,
                                 contentType: "image/png", createdAt: Date())
        await transport.releaseFirstCreate()

        try await waitUntil { !controller.isUploading && controller.snapshots.count == 2 }
        XCTAssertTrue(controller.snapshots.allSatisfy { $0.status == .uploaded })
    }

    func testUploadFailureIsVisibleAndCountsAsOutstandingWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = CloudController(supportDirectory: directory, transportFactory: { FailingControllerTransport() })
        controller.activate(configuration: configuration)
        await controller.enqueue(data: Data("image".utf8), id: UUID(), filename: "shot.png", kind: .screenshot,
                                 contentType: "image/png", createdAt: Date())

        try await waitUntil { !controller.isUploading && controller.pendingCount == 1 && controller.lastError != nil }
        XCTAssertEqual(controller.failedCount, 0)
        XCTAssertEqual(controller.pendingCount, 1)
        XCTAssertEqual(controller.lastError, "Quota reached")
    }

    func testIdleActivationDoesNotCallCloudAPI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CountingTransport()
        let controller = CloudController(supportDirectory: directory, transportFactory: { transport })
        controller.activate(configuration: configuration)
        try await Task.sleep(nanoseconds: 20_000_000)
        let calls = await transport.apiCalls()
        XCTAssertEqual(calls, 0)
    }

    func testDeletedCaptureDoesNotReturnAfterLaterUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StaleLibraryTransport()
        let controller = CloudController(supportDirectory: directory, transportFactory: { transport })
        controller.activate(configuration: configuration)
        await controller.enqueue(data: Data("a".utf8), id: UUID(), filename: "a.png", kind: .screenshot,
                                 contentType: "image/png", createdAt: Date())
        try await waitUntil { controller.captures.count == 1 }
        let deleted = try XCTUnwrap(controller.captures.first)
        await controller.delete(deleted)
        XCTAssertFalse(controller.captures.contains { $0.id == deleted.id })
        XCTAssertNotNil(controller.usage)

        await controller.enqueue(data: Data("b".utf8), id: UUID(), filename: "b.png", kind: .screenshot,
                                 contentType: "image/png", createdAt: Date())
        try await waitUntil { controller.captures.contains { $0.filename == "b.png" } }
        XCTAssertFalse(controller.captures.contains { $0.id == deleted.id })
    }
}

private let configuration = CloudConfiguration(baseURL: URL(string: "https://api.example.invalid")!, token: "token")
private let emptyUsage = CloudUsage(captureCount: 0, storageBytes: 0, pendingUploadCount: 0, databaseBytes: 0,
                                    limits: .init(databaseBytes: 0, maxFileBytes: 5 * 1024 * 1024 * 1024,
                                                  objectStorageBytes: 5_000_000_000),
                                    provider: "test", plan: "test", beta: true)

@MainActor
private func waitUntil(_ predicate: @escaping () -> Bool) async throws {
    for _ in 0..<200 where !predicate() { try await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertTrue(predicate(), "Timed out waiting for controller state")
}

private actor ControllerTransport: CloudUploadTransport {
    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        fatalError()
    }
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {}
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture { fatalError() }
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage { .init(captures: [], nextCursor: nil) }
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { emptyUsage }
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {}
}

private actor FailingControllerTransport: CloudUploadTransport {
    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse {
        throw CloudUploadError.server(code: "quota_exceeded", message: "Quota reached")
    }
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {}
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture { fatalError() }
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage { .init(captures: [], nextCursor: nil) }
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { emptyUsage }
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {}
}

private actor CountingTransport: CloudUploadTransport {
    private var calls = 0
    func apiCalls() -> Int { calls }
    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse { calls += 1; fatalError() }
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {}
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture { calls += 1; fatalError() }
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage { calls += 1; return .init(captures: [], nextCursor: nil) }
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { calls += 1; fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { calls += 1; fatalError() }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { calls += 1; fatalError() }
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws { calls += 1 }
}

private actor BlockingTransport: CloudUploadTransport {
    private var metadata: [UUID: CloudUploadMetadata] = [:]
    private var firstGate: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var isFirst = true
    func waitUntilFirstCreate() async { await withCheckedContinuation { started = $0 } }
    func releaseFirstCreate() { firstGate?.resume(); firstGate = nil }
    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse {
        self.metadata[metadata.id] = metadata
        if isFirst {
            isFirst = false
            started?.resume(); started = nil
            await withCheckedContinuation { firstGate = $0 }
        }
        return .init(capture: capture(for: metadata, status: .pending, uploadedAt: nil), alreadyUploaded: false,
                     upload: .init(url: URL(string: "https://storage.invalid")!, method: "PUT", headers: [:]))
    }
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {}
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture { capture(for: metadata[id]!, status: .uploaded, uploadedAt: Date()) }
    private func capture(for value: CloudUploadMetadata, status: CloudCaptureStatus, uploadedAt: Date?) -> CloudCapture {
        .init(id: value.id, filename: value.filename, kind: value.kind, contentType: value.contentType,
              byteCount: value.byteCount, sha256: value.sha256, createdAt: value.createdAt,
              uploadedAt: uploadedAt, status: status)
    }
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage { .init(captures: [], nextCursor: nil) }
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { emptyUsage }
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {}
}

private actor StaleLibraryTransport: CloudUploadTransport {
    private var metadata: [UUID: CloudUploadMetadata] = [:]
    private var library: [CloudCapture] = []
    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse {
        self.metadata[metadata.id] = metadata
        return .init(capture: capture(metadata, status: .pending), alreadyUploaded: false,
                     upload: .init(url: URL(string: "https://storage.invalid")!, method: "PUT", headers: [:]))
    }
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {}
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture {
        let result = capture(metadata[id]!, status: .uploaded)
        library.removeAll { $0.id == id }; library.append(result)
        return result
    }
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage {
        .init(captures: library, nextCursor: nil)
    }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { emptyUsage }
    // Deliberately leave `library` stale to model an in-flight/index race.
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {}
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    private func capture(_ value: CloudUploadMetadata, status: CloudCaptureStatus) -> CloudCapture {
        .init(id: value.id, filename: value.filename, kind: value.kind, contentType: value.contentType,
              byteCount: value.byteCount, sha256: value.sha256, createdAt: value.createdAt,
              uploadedAt: status == .uploaded ? Date() : nil, status: status)
    }
}
