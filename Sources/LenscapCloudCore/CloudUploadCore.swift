import CryptoKit
import Foundation

public enum CloudCaptureKind: String, Codable, Sendable {
    case screenshot, video, gif
}

public enum CloudCaptureStatus: String, Codable, Sendable {
    case pending, uploaded
}

public struct CloudConfiguration: Sendable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public struct CloudUploadMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let filename: String
    public let kind: CloudCaptureKind
    public let contentType: String
    public let byteCount: Int64
    public let sha256: String
    public let createdAt: Date

    public init(id: UUID, filename: String, kind: CloudCaptureKind, contentType: String,
                byteCount: Int64, sha256: String, createdAt: Date) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.createdAt = createdAt
    }
}

public struct CloudCapture: Codable, Sendable, Equatable {
    public let id: UUID
    public let filename: String
    public let kind: CloudCaptureKind
    public let contentType: String
    public let byteCount: Int64
    public let sha256: String
    public let createdAt: Date
    public let uploadedAt: Date?
    public let status: CloudCaptureStatus

    public init(id: UUID, filename: String, kind: CloudCaptureKind, contentType: String,
                byteCount: Int64, sha256: String, createdAt: Date, uploadedAt: Date?,
                status: CloudCaptureStatus) {
        self.id = id; self.filename = filename; self.kind = kind; self.contentType = contentType
        self.byteCount = byteCount; self.sha256 = sha256; self.createdAt = createdAt
        self.uploadedAt = uploadedAt; self.status = status
    }
}

public struct CloudPresignedUpload: Codable, Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public init(url: URL, method: String, headers: [String: String]) {
        self.url = url; self.method = method; self.headers = headers
    }
}

public struct CloudCreateUploadResponse: Codable, Sendable {
    public let capture: CloudCapture
    public let alreadyUploaded: Bool
    public let upload: CloudPresignedUpload?
    public init(capture: CloudCapture, alreadyUploaded: Bool, upload: CloudPresignedUpload?) {
        self.capture = capture; self.alreadyUploaded = alreadyUploaded; self.upload = upload
    }
}

public struct CloudCapturePage: Codable, Sendable {
    public let captures: [CloudCapture]
    public let nextCursor: String?
    public init(captures: [CloudCapture], nextCursor: String?) { self.captures = captures; self.nextCursor = nextCursor }
}

public struct CloudURLResponse: Codable, Sendable {
    public let url: URL
    public let expiresAt: Date
    public init(url: URL, expiresAt: Date) { self.url = url; self.expiresAt = expiresAt }
}

public struct CloudLimits: Codable, Sendable {
    public let databaseBytes: Int64
    public let maxFileBytes: Int64
    public let objectStorageBytes: Int64?
    public let objectStorageScope: String?
    public init(databaseBytes: Int64, maxFileBytes: Int64, objectStorageBytes: Int64?, objectStorageScope: String? = nil) {
        self.databaseBytes = databaseBytes; self.maxFileBytes = maxFileBytes
        self.objectStorageBytes = objectStorageBytes; self.objectStorageScope = objectStorageScope
    }
}

public struct CloudUsage: Codable, Sendable {
    public let captureCount: Int
    public let storageBytes: Int64
    public let pendingUploadCount: Int
    public let databaseBytes: Int64
    public let limits: CloudLimits
    public let provider: String
    public let plan: String
    public let beta: Bool
    public init(captureCount: Int, storageBytes: Int64, pendingUploadCount: Int, databaseBytes: Int64,
                limits: CloudLimits, provider: String, plan: String, beta: Bool) {
        self.captureCount = captureCount; self.storageBytes = storageBytes; self.pendingUploadCount = pendingUploadCount
        self.databaseBytes = databaseBytes; self.limits = limits; self.provider = provider; self.plan = plan; self.beta = beta
    }
}

public protocol CloudUploadTransport: Sendable {
    func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse
    func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws
    func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture
    func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage
    func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse
    func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse
    func usage(configuration: CloudConfiguration) async throws -> CloudUsage
    func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws
}

/// HTTPS transport for the Lenscap cloud API. Device credentials are attached
/// only to API requests; a presigned object-storage URL receives only its own
/// server-provided headers.
public struct URLSessionCloudUploadTransport: CloudUploadTransport {
    private let session: URLSession

    /// The default is ephemeral: media metadata and bearer-authenticated API
    /// responses must not be retained in the shared session's disk cache.
    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    public func createUpload(configuration: CloudConfiguration, metadata: CloudUploadMetadata) async throws -> CloudCreateUploadResponse {
        try await send(configuration: configuration, path: "/v1/uploads", method: "POST", body: metadata)
    }

    public func uploadFile(fileURL: URL, upload: CloudPresignedUpload) async throws {
        var request = URLRequest(url: upload.url)
        request.httpMethod = upload.method
        for (name, value) in upload.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw storageUploadError(response: response, data: data)
        }
    }

    public func completeUpload(configuration: CloudConfiguration, id: UUID) async throws -> CloudCapture {
        let response: CompleteUploadResponse = try await send(configuration: configuration, path: "/v1/uploads/\(id.uuidString)/complete", method: "POST")
        return response.capture
    }

    public func listCaptures(configuration: CloudConfiguration, limit: Int, cursor: String?) async throws -> CloudCapturePage {
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent("v1/captures"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items
        return try await send(configuration: configuration, url: try url(components), method: "GET")
    }

    public func download(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse {
        try await send(configuration: configuration, path: "/v1/captures/\(id.uuidString)/download", method: "GET")
    }

    public func share(configuration: CloudConfiguration, id: UUID) async throws -> CloudURLResponse {
        try await send(configuration: configuration, path: "/v1/captures/\(id.uuidString)/share", method: "POST")
    }

    public func usage(configuration: CloudConfiguration) async throws -> CloudUsage {
        try await send(configuration: configuration, path: "/v1/usage", method: "GET")
    }

    public func deleteCapture(configuration: CloudConfiguration, id: UUID) async throws {
        let url = configuration.baseURL.appendingPathComponent("v1/captures/\(id.uuidString)")
        let (_, response) = try await session.data(for: apiRequest(configuration: configuration, url: url, method: "DELETE"))
        try validate(response: response, data: nil)
    }

    private func send<Response: Decodable>(configuration: CloudConfiguration, path: String, method: String) async throws -> Response {
        try await send(configuration: configuration, url: configuration.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), method: method)
    }

    private func send<Response: Decodable>(configuration: CloudConfiguration, path: String, method: String, body: some Encodable) async throws -> Response {
        var request = apiRequest(configuration: configuration, url: configuration.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), method: method)
        request.httpBody = try JSONEncoder.cloud.encode(body)
        return try await execute(request)
    }

    private func send<Response: Decodable>(configuration: CloudConfiguration, url: URL, method: String) async throws -> Response {
        try await execute(apiRequest(configuration: configuration, url: url, method: method))
    }

    private func apiRequest(configuration: CloudConfiguration, url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func execute<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard let result = try? JSONDecoder.cloud.decode(Response.self, from: data) else { throw CloudUploadError.invalidResponse }
        return result
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let data, let apiError = try? JSONDecoder.cloud.decode(APIErrorEnvelope.self, from: data) {
                throw CloudUploadError.server(code: apiError.error.code, message: apiError.error.message)
            }
            throw CloudUploadError.transport("The cloud request failed.")
        }
    }

    private func storageUploadError(response: URLResponse, data: Data) -> CloudUploadError {
        let status = (response as? HTTPURLResponse)?.statusCode
        let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        if status == 507 || body.contains("quota") || body.contains("insufficientstorage") {
            return .transport("Neon storage quota reached; your queued copy was kept for retry or cleanup.")
        }
        if status == 413 { return .transport("This file exceeds the 5 GiB cloud upload limit.") }
        if status == 429 || status == 503 {
            return .transport("Cloud storage is busy; your queued copy was kept and will retry.")
        }
        if status == 403 {
            return .transport("Cloud upload access expired or was denied; your queued copy was kept and will retry.")
        }
        if status == 412 { return .preconditionFailed }
        return .transport("Cloud storage upload failed; your queued copy was kept and will retry.")
    }

    private func url(_ components: URLComponents) throws -> URL {
        guard let url = components.url else { throw CloudUploadError.invalidResponse }
        return url
    }

    private struct APIErrorEnvelope: Decodable { let error: APIError }
    private struct APIError: Decodable { let code: String; let message: String }
    private struct CompleteUploadResponse: Decodable { let capture: CloudCapture }
}

public enum CloudUploadError: Error, LocalizedError, Sendable, Equatable {
    case fileTooLarge(Int64)
    case inconsistentDuplicate
    case missingSpool
    case invalidReceipt
    case preconditionFailed
    case server(code: String, message: String)
    case invalidResponse
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "This file exceeds the 5 GiB cloud upload limit."
        case .inconsistentDuplicate: return "An upload ID cannot be reused for different content."
        case .missingSpool: return "The queued upload file is missing."
        case .invalidReceipt: return "The cloud service returned a receipt for different capture data."
        case .preconditionFailed: return "The cloud object already exists."
        case let .server(_, message), let .transport(message): return message
        case .invalidResponse: return "The cloud service returned an invalid response."
        }
    }
}

public struct CloudUploadSnapshot: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, retrying, uploaded, failed }
    public let id: UUID
    public let metadata: CloudUploadMetadata
    public let status: Status
    public let attemptCount: Int
    public let nextAttemptAt: Date?
    public let lastError: String?
    public let receipt: CloudCapture?
}

public actor CloudUploadOutbox {
    public static let maximumFileBytes: Int64 = 5 * 1024 * 1024 * 1024

    private struct Record: Codable {
        var metadata: CloudUploadMetadata
        var spoolFilename: String
        var status: CloudUploadSnapshot.Status
        var attemptCount: Int
        var nextAttemptAt: Date?
        var lastError: String?
        var receipt: CloudCapture?
    }

    private let configuration: CloudConfiguration
    private let directory: URL
    private let spoolDirectory: URL
    private let indexURL: URL
    private let transport: any CloudUploadTransport
    private var records: [UUID: Record]
    private var inFlight: Set<UUID> = []

    public init(configuration: CloudConfiguration, directory: URL, transport: any CloudUploadTransport) throws {
        self.configuration = configuration
        self.directory = directory
        self.spoolDirectory = directory.appendingPathComponent("spool", isDirectory: true)
        self.indexURL = directory.appendingPathComponent("outbox.json")
        self.transport = transport
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        self.records = try Self.load(indexURL: indexURL)
    }

    @discardableResult
    public func enqueue(data: Data, id: UUID = UUID(), filename: String, kind: CloudCaptureKind,
                        contentType: String, createdAt: Date = Date()) throws -> CloudUploadSnapshot {
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try verifyDuplicate(id: id, byteCount: Int64(data.count), sha256: sha256)
        if let record = records[id] { return Self.snapshot(record) }
        guard Int64(data.count) <= Self.maximumFileBytes else { throw CloudUploadError.fileTooLarge(Int64(data.count)) }
        let url = spoolDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("payload")
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        do {
            return try register(fileURL: url, id: id, filename: filename, kind: kind,
                                contentType: contentType, createdAt: createdAt)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    @discardableResult
    public func enqueue(fileURL: URL, id: UUID = UUID(), filename: String? = nil, kind: CloudCaptureKind,
                        contentType: String, createdAt: Date = Date()) throws -> CloudUploadSnapshot {
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber,
           size.int64Value > Self.maximumFileBytes {
            throw CloudUploadError.fileTooLarge(size.int64Value)
        }
        let (byteCount, sha256) = try Self.measure(fileURL: fileURL)
        try verifyDuplicate(id: id, byteCount: byteCount, sha256: sha256)
        if let record = records[id] { return Self.snapshot(record) }
        guard byteCount <= Self.maximumFileBytes else { throw CloudUploadError.fileTooLarge(byteCount) }
        let spoolURL = spoolDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("payload")
        try FileManager.default.copyItem(at: fileURL, to: spoolURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: spoolURL.path)
        do {
            return try register(fileURL: spoolURL, id: id,
                                filename: filename ?? fileURL.lastPathComponent, kind: kind,
                                contentType: contentType, createdAt: createdAt)
        } catch {
            try? FileManager.default.removeItem(at: spoolURL)
            throw error
        }
    }

    public func snapshots() -> [CloudUploadSnapshot] {
        records.values.map(Self.snapshot).sorted { $0.metadata.createdAt > $1.metadata.createdAt }
    }

    public func retryNow(id: UUID) throws {
        guard var record = records[id], record.status != .uploaded else { return }
        record.status = .pending; record.nextAttemptAt = nil; record.lastError = nil
        records[id] = record
        try persist()
    }

    public func processPending(now: Date = Date()) async {
        let ids = records.values.filter { record in
            record.status != .uploaded && (record.nextAttemptAt == nil || record.nextAttemptAt! <= now)
        }.map { $0.metadata.id }
        for id in ids { await process(id: id, now: now) }
    }

    private func register(fileURL: URL, id: UUID, filename: String, kind: CloudCaptureKind,
                          contentType: String, createdAt: Date) throws -> CloudUploadSnapshot {
        let (byteCount, sha256) = try Self.measure(fileURL: fileURL)
        guard byteCount <= Self.maximumFileBytes else { throw CloudUploadError.fileTooLarge(byteCount) }
        let metadata = CloudUploadMetadata(id: id, filename: filename, kind: kind, contentType: contentType,
                                           byteCount: byteCount, sha256: sha256, createdAt: createdAt)
        let record = Record(metadata: metadata, spoolFilename: fileURL.lastPathComponent, status: .pending,
                             attemptCount: 0, nextAttemptAt: nil, lastError: nil, receipt: nil)
        records[id] = record
        do {
            try persist() // The pending record reaches disk before any network work can begin.
        } catch {
            records[id] = nil
            throw error
        }
        return Self.snapshot(record)
    }

    private func verifyDuplicate(id: UUID, byteCount: Int64, sha256: String) throws {
        guard let existing = records[id] else { return }
        guard existing.metadata.sha256 == sha256, existing.metadata.byteCount == byteCount else {
            throw CloudUploadError.inconsistentDuplicate
        }
    }

    private func process(id: UUID, now: Date) async {
        guard !inFlight.contains(id), var record = records[id], record.status != .uploaded else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let fileURL = spoolDirectory.appendingPathComponent(record.spoolFilename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            record.status = .failed; record.lastError = CloudUploadError.missingSpool.localizedDescription
            record.nextAttemptAt = nil; records[id] = record; try? persist(); return
        }
        guard let integrity = try? Self.measure(fileURL: fileURL),
              integrity.0 == record.metadata.byteCount, integrity.1 == record.metadata.sha256 else {
            record.status = .failed
            record.lastError = "Queued upload data changed on disk and was not sent. The retained copy needs attention."
            record.nextAttemptAt = nil
            records[id] = record
            try? persist()
            return
        }
        do {
            let created = try await transport.createUpload(configuration: configuration, metadata: record.metadata)
            if !created.alreadyUploaded {
                guard let upload = created.upload else { throw CloudUploadError.invalidResponse }
                do {
                    try await transport.uploadFile(fileURL: fileURL, upload: upload)
                } catch CloudUploadError.preconditionFailed {
                    // Conditional PUT means the immutable object already exists.
                    // Completion still validates the pending record and receipt.
                }
            }
            let receipt = created.alreadyUploaded ? created.capture : try await transport.completeUpload(configuration: configuration, id: id)
            guard receipt.id == record.metadata.id, receipt.sha256 == record.metadata.sha256,
                  receipt.byteCount == record.metadata.byteCount, receipt.status == .uploaded else {
                throw CloudUploadError.invalidReceipt
            }
            record.status = .uploaded; record.receipt = receipt; record.nextAttemptAt = nil; record.lastError = nil
            records[id] = record
            try persist() // Keep the server receipt before reclaiming the spool.
            try? FileManager.default.removeItem(at: fileURL)
        } catch {
            record.attemptCount += 1
            record.status = .retrying
            record.lastError = Self.message(for: error)
            record.nextAttemptAt = now.addingTimeInterval(Self.backoff(for: record.attemptCount))
            records[id] = record
            try? persist()
        }
    }

    private func persist() throws {
        let data = try JSONEncoder.cloud.encode(Array(records.values))
        try data.write(to: indexURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private static func load(indexURL: URL) throws -> [UUID: Record] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [:] }
        return Dictionary(uniqueKeysWithValues: try JSONDecoder.cloud.decode([Record].self, from: Data(contentsOf: indexURL))
            .map { ($0.metadata.id, $0) })
    }

    private static func snapshot(_ record: Record) -> CloudUploadSnapshot {
        .init(id: record.metadata.id, metadata: record.metadata, status: record.status,
              attemptCount: record.attemptCount, nextAttemptAt: record.nextAttemptAt,
              lastError: record.lastError, receipt: record.receipt)
    }

    private static func measure(fileURL: URL) throws -> (Int64, String) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256(); var count: Int64 = 0
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data); count += Int64(data.count)
        }
        return (count, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func backoff(for attempt: Int) -> TimeInterval { min(300, pow(2, Double(min(attempt, 8)))) }
    private static func message(for error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
}

private extension JSONEncoder {
    static var cloud: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}
private extension JSONDecoder {
    static var cloud: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let value = try source.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try source.singleValueContainer(),
                                                   debugDescription: "Expected an ISO-8601 date.")
        }
        return decoder
    }
}
