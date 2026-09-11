import XCTest
@testable import LenscapCloudCore

final class CloudUploadOutboxTests: XCTestCase {
    func testURLSessionTransportIsPubliclyConstructible() {
        _ = URLSessionCloudUploadTransport()
    }

    func testCompleteUploadDecodesCaptureEnvelope() async throws {
        let id = UUID()
        let capture = CloudCapture(id: id, filename: "shot.png", kind: .screenshot, contentType: "image/png",
                                   byteCount: 5, sha256: "hash", createdAt: Date(timeIntervalSince1970: 0),
                                   uploadedAt: Date(timeIntervalSince1970: 1), status: .uploaded)
        let session = stubSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
            XCTAssertEqual(request.url?.path, "/v1/uploads/\(id.uuidString)/complete")
            return (200, try! cloudJSON(["capture": capture]))
        }

        let result = try await URLSessionCloudUploadTransport(session: session).completeUpload(
            configuration: testConfiguration, id: id
        )
        XCTAssertEqual(result, capture)
    }

    func testCompleteUploadDecodesFractionalISO8601Dates() async throws {
        let id = UUID()
        let json = Data("""
        {"capture":{"id":"\(id.uuidString)","filename":"shot.png","kind":"screenshot","contentType":"image/png","byteCount":5,"sha256":"hash","createdAt":"2026-08-27T23:11:21.123Z","uploadedAt":"2026-08-27T23:11:22.456Z","status":"uploaded"}}
        """.utf8)
        let session = stubSession { _ in (200, json) }

        let result = try await URLSessionCloudUploadTransport(session: session).completeUpload(
            configuration: testConfiguration, id: id
        )
        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.status, .uploaded)
    }

    func testPresignedUploadForwardsOnlyProvidedHeaders() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("payload".utf8).write(to: file)
        let session = stubSession { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/png")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            return (200, Data())
        }
        let upload = CloudPresignedUpload(url: URL(string: "https://storage.invalid/object")!, method: "PUT",
                                          headers: ["Content-Type": "image/png", "If-None-Match": "*"])

        try await URLSessionCloudUploadTransport(session: session).uploadFile(fileURL: file, upload: upload)
    }

    func testPresignedQuotaErrorIsSafeAndActionable() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("payload".utf8).write(to: file)
        let session = stubSession { _ in (507, Data("<Error><Code>QuotaExceeded</Code></Error>".utf8)) }
        let upload = CloudPresignedUpload(url: URL(string: "https://storage.invalid/object")!, method: "PUT", headers: [:])

        do {
            try await URLSessionCloudUploadTransport(session: session).uploadFile(fileURL: file, upload: upload)
            XCTFail("Expected quota error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Neon storage quota reached; your queued copy was kept for retry or cleanup.")
        }
    }

    func testStorageQuotaFailureRetainsDurableSpoolForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let outbox = try CloudUploadOutbox(configuration: testConfiguration, directory: root, transport: QuotaTransport())
        _ = try await outbox.enqueue(data: Data("payload".utf8), id: id, filename: "shot.png",
                                     kind: .screenshot, contentType: "image/png")

        await outbox.processPending()
        let snapshots = await outbox.snapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.status, .retrying)
        XCTAssertEqual(snapshot.lastError, "Neon storage quota reached; your queued copy was kept for retry or cleanup.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("spool/\(id.uuidString).payload").path))
    }

    func testLostPUTResponseThenRestartCompletesExistingConditionalObject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let transport = ConditionalReplayTransport()
        let first = try CloudUploadOutbox(configuration: testConfiguration, directory: root, transport: transport)
        _ = try await first.enqueue(data: Data("payload".utf8), id: id, filename: "shot.png",
                                    kind: .screenshot, contentType: "image/png")
        await first.processPending()
        let firstSnapshots = await first.snapshots()
        XCTAssertEqual(firstSnapshots.first?.status, .retrying)

        let resumed = try CloudUploadOutbox(configuration: testConfiguration, directory: root, transport: transport)
        try await resumed.retryNow(id: id)
        await resumed.processPending()
        let resumedSnapshots = await resumed.snapshots()
        XCTAssertEqual(resumedSnapshots.first?.status, .uploaded)
        let completions = await transport.completeCount()
        XCTAssertEqual(completions, 2)
    }

    func testCorruptedSpoolIsRetainedAndNeverSent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let transport = CountingCreateTransport()
        let outbox = try CloudUploadOutbox(configuration: testConfiguration, directory: root, transport: transport)
        _ = try await outbox.enqueue(data: Data("original".utf8), id: id, filename: "shot.png",
                                     kind: .screenshot, contentType: "image/png")
        let spool = root.appendingPathComponent("spool/\(id.uuidString).payload")
        try Data("replaced".utf8).write(to: spool, options: .atomic)

        await outbox.processPending()
        let snapshots = await outbox.snapshots()
        XCTAssertEqual(snapshots.first?.status, .failed)
        let creates = await transport.createCount()
        XCTAssertEqual(creates, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.path))
    }

    func testDeleteCaptureAcceptsEmptyNoContentResponse() async throws {
        let session = stubSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (204, Data())
        }
        try await URLSessionCloudUploadTransport(session: session).deleteCapture(configuration: testConfiguration, id: UUID())
    }

    func testEnqueueDataPersistsPendingWorkAndProcessesItOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordingTransport()
        let outbox = try CloudUploadOutbox(
            configuration: .init(baseURL: URL(string: "https://example.invalid")!, token: "device-token"),
            directory: root,
            transport: transport
        )

        let id = UUID()
        _ = try await outbox.enqueue(data: Data("image".utf8), id: id, filename: "shot.png",
                                     kind: .screenshot, contentType: "image/png")
        let pending = await outbox.snapshots()
        XCTAssertEqual(pending.first?.status, .pending)

        await outbox.processPending()
        let snapshots = await outbox.snapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.status, .uploaded)
        let uploadedIDs = await transport.uploadedIDs
        XCTAssertEqual(uploadedIDs, [id])
    }

    func testRepeatedEnqueueWithSameIDAndContentReturnsExistingPendingRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try CloudUploadOutbox(
            configuration: .init(baseURL: URL(string: "https://example.invalid")!, token: "device-token"),
            directory: root, transport: RecordingTransport()
        )
        let id = UUID()

        let first = try await outbox.enqueue(data: Data("same".utf8), id: id, filename: "shot.png",
                                             kind: .screenshot, contentType: "image/png")
        let second = try await outbox.enqueue(data: Data("same".utf8), id: id, filename: "shot.png",
                                              kind: .screenshot, contentType: "image/png")

        XCTAssertEqual(second.id, first.id)
        let snapshots = await outbox.snapshots()
        XCTAssertEqual(snapshots.count, 1)
    }

    func testConflictingDuplicateDoesNotDestroyOriginalPendingPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordingTransport()
        let outbox = try CloudUploadOutbox(
            configuration: .init(baseURL: URL(string: "https://example.invalid")!, token: "device-token"),
            directory: root, transport: transport
        )
        let id = UUID()
        _ = try await outbox.enqueue(data: Data("original".utf8), id: id, filename: "shot.png",
                                     kind: .screenshot, contentType: "image/png")

        await XCTAssertThrowsErrorAsync {
            _ = try await outbox.enqueue(data: Data("replacement".utf8), id: id, filename: "shot.png",
                                        kind: .screenshot, contentType: "image/png")
        }
        await outbox.processPending()
        let uploadedIDs = await transport.uploadedIDs
        XCTAssertEqual(uploadedIDs, [id])
    }

    func testFailureSurvivesRestartAndManualRetryKeepsSameID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let configuration = CloudConfiguration(baseURL: URL(string: "https://example.invalid")!, token: "device-token")
        let failing = FailOnceTransport()
        let first = try CloudUploadOutbox(configuration: configuration, directory: root, transport: failing)
        _ = try await first.enqueue(data: Data("offline".utf8), id: id, filename: "shot.png",
                                    kind: .screenshot, contentType: "image/png")
        await first.processPending(now: Date(timeIntervalSince1970: 1))
        let failedSnapshots = await first.snapshots()
        let failed = try XCTUnwrap(failedSnapshots.first)
        XCTAssertEqual(failed.status, .retrying)
        XCTAssertNotNil(failed.lastError)

        let resumed = try CloudUploadOutbox(configuration: configuration, directory: root, transport: failing)
        try await resumed.retryNow(id: id)
        await resumed.processPending(now: Date(timeIntervalSince1970: 2))
        let completedSnapshots = await resumed.snapshots()
        let completed = try XCTUnwrap(completedSnapshots.first)
        XCTAssertEqual(completed.status, .uploaded)
        let completedIDs = await failing.completedIDs()
        XCTAssertEqual(completedIDs, [id])
    }

    func testOverlappingProcessCallsDoNotUploadTheSameRecordTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SlowTransport()
        let outbox = try CloudUploadOutbox(configuration: testConfiguration, directory: root, transport: transport)
        _ = try await outbox.enqueue(data: Data("one".utf8), filename: "shot.png", kind: .screenshot, contentType: "image/png")

        async let first: Void = outbox.processPending()
        async let second: Void = outbox.processPending()
        _ = await (first, second)

        let createCount = await transport.createCount()
        XCTAssertEqual(createCount, 1)
    }
}

private let testConfiguration = CloudConfiguration(baseURL: URL(string: "https://api.example.invalid")!, token: "device-token")

private func cloudJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}

private func stubSession(handler: @escaping (URLRequest) -> (Int, Data)) -> URLSession {
    StubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

private actor RecordingTransport: CloudUploadTransport {
    private(set) var uploadedIDs: [UUID] = []
    private var metadataByID: [UUID: CloudUploadMetadata] = [:]

    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse {
        metadataByID[metadata.id] = metadata
        return .init(capture: .init(id: metadata.id, filename: metadata.filename, kind: metadata.kind,
                             contentType: metadata.contentType, byteCount: metadata.byteCount,
                             sha256: metadata.sha256, createdAt: metadata.createdAt,
                             uploadedAt: nil, status: .pending),
              alreadyUploaded: false,
              upload: .init(url: URL(string: "https://storage.invalid/upload")!, method: "PUT", headers: [:]))
    }

    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {}

    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture {
        uploadedIDs.append(id)
        let metadata = metadataByID[id]!
        return .init(id: id, filename: metadata.filename, kind: metadata.kind, contentType: metadata.contentType,
                     byteCount: metadata.byteCount, sha256: metadata.sha256, createdAt: metadata.createdAt,
                     uploadedAt: Date(), status: .uploaded)
    }

    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage { .init(captures: [], nextCursor: nil) }
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { fatalError() }
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {}
}

private actor FailOnceTransport: CloudUploadTransport {
    private var shouldFail = true
    private var ids: [UUID] = []
    private var metadataByID: [UUID: CloudUploadMetadata] = [:]

    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse {
        if shouldFail { shouldFail = false; throw CloudUploadError.transport("Offline") }
        metadataByID[metadata.id] = metadata
        return .init(capture: .init(id: metadata.id, filename: metadata.filename, kind: metadata.kind,
                                    contentType: metadata.contentType, byteCount: metadata.byteCount,
                                    sha256: metadata.sha256, createdAt: metadata.createdAt,
                                    uploadedAt: nil, status: .pending), alreadyUploaded: false,
                     upload: .init(url: URL(string: "https://storage.invalid")!, method: "PUT", headers: [:]))
    }
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {}
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture {
        ids.append(id)
        let metadata = metadataByID[id]!
        return .init(id: id, filename: metadata.filename, kind: metadata.kind, contentType: metadata.contentType,
                     byteCount: metadata.byteCount, sha256: metadata.sha256, createdAt: metadata.createdAt,
                     uploadedAt: Date(), status: .uploaded)
    }
    func completedIDs() -> [UUID] { ids }
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage { .init(captures: [], nextCursor: nil) }
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { fatalError() }
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {}
}

private actor SlowTransport: CloudUploadTransport {
    private var metadata: CloudUploadMetadata?
    private var creates = 0
    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse {
        creates += 1; self.metadata = metadata
        try await Task.sleep(nanoseconds: 50_000_000)
        return .init(capture: .init(id: metadata.id, filename: metadata.filename, kind: metadata.kind,
                                    contentType: metadata.contentType, byteCount: metadata.byteCount, sha256: metadata.sha256,
                                    createdAt: metadata.createdAt, uploadedAt: nil, status: .pending), alreadyUploaded: false,
                     upload: .init(url: URL(string: "https://storage.invalid")!, method: "PUT", headers: [:]))
    }
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {}
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture {
        let value = metadata!
        return .init(id: id, filename: value.filename, kind: value.kind, contentType: value.contentType,
                     byteCount: value.byteCount, sha256: value.sha256, createdAt: value.createdAt,
                     uploadedAt: Date(), status: .uploaded)
    }
    func createCount() -> Int { creates }
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage { .init(captures: [], nextCursor: nil) }
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { fatalError() }
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {}
}

private actor QuotaTransport: CloudUploadTransport {
    private var metadata: CloudUploadMetadata?
    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse {
        self.metadata = metadata
        return .init(capture: .init(id: metadata.id, filename: metadata.filename, kind: metadata.kind,
                                    contentType: metadata.contentType, byteCount: metadata.byteCount, sha256: metadata.sha256,
                                    createdAt: metadata.createdAt, uploadedAt: nil, status: .pending), alreadyUploaded: false,
                     upload: .init(url: URL(string: "https://storage.invalid")!, method: "PUT", headers: [:]))
    }
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {
        throw CloudUploadError.transport("Neon storage quota reached; your queued copy was kept for retry or cleanup.")
    }
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture { fatalError() }
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage { .init(captures: [], nextCursor: nil) }
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { fatalError() }
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {}
}

private actor ConditionalReplayTransport: CloudUploadTransport {
    private var metadata: CloudUploadMetadata?
    private var completions = 0
    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse {
        self.metadata = metadata
        return .init(capture: capture(metadata, .pending), alreadyUploaded: false,
                     upload: .init(url: URL(string: "https://storage.invalid")!, method: "PUT", headers: [:]))
    }
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws { throw CloudUploadError.preconditionFailed }
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture {
        completions += 1
        if completions == 1 { throw CloudUploadError.transport("Lost completion response") }
        return capture(metadata!, .uploaded)
    }
    func completeCount() -> Int { completions }
    private func capture(_ value: CloudUploadMetadata, _ status: CloudCaptureStatus) -> CloudCapture {
        .init(id: value.id, filename: value.filename, kind: value.kind, contentType: value.contentType,
              byteCount: value.byteCount, sha256: value.sha256, createdAt: value.createdAt,
              uploadedAt: status == .uploaded ? Date() : nil, status: status)
    }
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage { .init(captures: [], nextCursor: nil) }
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { fatalError() }
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {}
}

private actor CountingCreateTransport: CloudUploadTransport {
    private var creates = 0
    func createCount() -> Int { creates }
    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse { creates += 1; fatalError() }
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {}
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture { fatalError() }
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage { .init(captures: [], nextCursor: nil) }
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse { fatalError() }
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage { fatalError() }
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {}
}
