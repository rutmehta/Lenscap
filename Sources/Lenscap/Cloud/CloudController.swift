import AppKit
import Combine
import CryptoKit
import Foundation
import LenscapCloudCore

/// Main-actor facade between Lenscap UI/capture hooks and the durable cloud outbox.
@MainActor
final class CloudController: ObservableObject {
    static let shared = CloudController()

    @Published private(set) var isConfigured = false
    @Published private(set) var connectionError: String?
    @Published private(set) var snapshots: [CloudUploadSnapshot] = []
    @Published private(set) var usage: CloudUsage?
    @Published private(set) var captures: [CloudCapture] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var isUploading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?

    /// Includes terminal failures: they still need user attention and must not
    /// be presented as a fully synchronized library.
    var pendingCount: Int { snapshots.filter { $0.status != .uploaded }.count }
    var failedCount: Int { snapshots.filter { $0.status == .failed }.count }
    var queuedBytes: Int64 {
        snapshots.filter { $0.status != .uploaded }.reduce(0) { $0 + $1.metadata.byteCount }
    }

    private let supportDirectory: URL
    private let transportFactory: @Sendable () -> any CloudUploadTransport
    private var configuration: CloudConfiguration?
    private var outbox: CloudUploadOutbox?
    private var retryTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var workRequested = false
    private var activationID = UUID()
    private var activeRefreshID: UUID?
    private var deletedIDs: Set<UUID> = []

    init(supportDirectory: URL? = nil,
         transportFactory: @escaping @Sendable () -> any CloudUploadTransport = { URLSessionCloudUploadTransport() }) {
        self.supportDirectory = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                              in: .userDomainMask)[0]
            .appendingPathComponent("Lenscap", isDirectory: true)
        self.transportFactory = transportFactory
    }

    deinit { retryTask?.cancel(); uploadTask?.cancel() }

    /// Imports a deliberately dropped setup file before hotkeys/capture start,
    /// then opens only the local durable outbox. It never performs API I/O.
    func start() {
        let setupURL = supportDirectory.appendingPathComponent("cloud-setup.json")
        do {
            _ = try CloudCredentials.importSetupFile(at: setupURL)
            loadStoredCredentials()
        } catch {
            isConfigured = false
            connectionError = Self.message(error)
        }
    }

    /// Explicit Settings action for a user-selected 0600 setup file. Tokens
    /// pass directly to Keychain-backed credentials and never through UI state.
    @discardableResult
    func importConnection(at url: URL) -> Bool {
        do {
            guard try CloudCredentials.importSetupFile(at: url) else { return false }
            loadStoredCredentials()
            return isConfigured
        } catch {
            connectionError = Self.message(error)
            return false
        }
    }

    func activate(configuration: CloudConfiguration) {
        retryTask?.cancel()
        uploadTask?.cancel()
        activationID = UUID()
        activeRefreshID = nil
        workRequested = false
        isUploading = false
        isRefreshing = false
        snapshots = []
        captures = []
        usage = nil
        nextCursor = nil
        lastRefreshedAt = nil
        deletedIDs = []
        self.configuration = configuration
        let directory = supportDirectory
            .appendingPathComponent("Cloud", isDirectory: true)
            .appendingPathComponent(Self.endpointHash(configuration.baseURL), isDirectory: true)
        do {
            outbox = try CloudUploadOutbox(configuration: configuration, directory: directory,
                                           transport: transportFactory())
            isConfigured = true
            connectionError = nil
            lastError = nil
            Task { [weak self] in
                await self?.reloadSnapshotsAndSchedule()
                self?.kickUploadWorker()
            }
        } catch {
            outbox = nil
            self.configuration = nil
            isConfigured = false
            connectionError = Self.message(error)
        }
    }

    func reportStagingError(_ message: String) {
        lastError = message
    }

    func enqueue(data: Data, id: UUID, filename: String, kind: CloudCaptureKind,
                 contentType: String, createdAt: Date) async {
        guard let outbox else { reportStagingError("Personal cloud is not configured."); return }
        do {
            _ = try await outbox.enqueue(data: data, id: id, filename: filename, kind: kind,
                                         contentType: contentType, createdAt: createdAt)
            await reloadSnapshotsAndSchedule()
            kickUploadWorker()
        } catch {
            reportStagingError(Self.message(error))
        }
    }

    func enqueue(fileURL: URL, id: UUID, filename: String? = nil, kind: CloudCaptureKind,
                 contentType: String, createdAt: Date) async {
        guard let outbox else { reportStagingError("Personal cloud is not configured."); return }
        do {
            _ = try await outbox.enqueue(fileURL: fileURL, id: id, filename: filename, kind: kind,
                                         contentType: contentType, createdAt: createdAt)
            await reloadSnapshotsAndSchedule()
            kickUploadWorker()
        } catch {
            reportStagingError(Self.message(error))
        }
    }

    func retryUploads() async {
        guard let outbox else { return }
        for snapshot in snapshots where snapshot.status != .uploaded { try? await outbox.retryNow(id: snapshot.id) }
        await reloadSnapshotsAndSchedule()
        kickUploadWorker()
    }

    func refresh() async {
        guard let configuration, !isRefreshing else { return }
        let activation = activationID
        let refreshID = UUID()
        activeRefreshID = refreshID
        isRefreshing = true
        defer {
            if activeRefreshID == refreshID { isRefreshing = false }
        }
        do {
            let transport = transportFactory()
            async let fetchedUsage = transport.usage(configuration: configuration)
            async let page = transport.listCaptures(configuration: configuration, limit: 50, cursor: nil)
            let (newUsage, firstPage) = try await (fetchedUsage, page)
            guard activation == activationID, refreshID == activeRefreshID else { return }
            usage = newUsage
            captures = firstPage.captures.filter { !deletedIDs.contains($0.id) }
            nextCursor = firstPage.nextCursor
            lastRefreshedAt = Date(); connectionError = nil
        } catch {
            if activation == activationID, refreshID == activeRefreshID { connectionError = Self.message(error) }
        }
    }

    func loadMore() async {
        guard let configuration, let cursor = nextCursor, !isRefreshing else { return }
        let activation = activationID
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let page = try await transportFactory().listCaptures(configuration: configuration, limit: 50, cursor: cursor)
            guard activation == activationID else { return }
            captures.append(contentsOf: page.captures.filter { !deletedIDs.contains($0.id) })
            nextCursor = page.nextCursor; connectionError = nil
        } catch { if activation == activationID { connectionError = Self.message(error) } }
    }

    func open(_ capture: CloudCapture) async {
        guard let configuration else { return }
        do {
            let response = try await transportFactory().download(configuration: configuration, id: capture.id)
            NSWorkspace.shared.open(response.url)
        } catch { lastError = Self.message(error) }
    }

    func copyShareLink(_ capture: CloudCapture) async {
        guard let configuration else { return }
        do {
            let response = try await transportFactory().share(configuration: configuration, id: capture.id)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(response.url.absoluteString, forType: .string) else {
                lastError = "Could not copy the share link."; return
            }
            HUD.show("Share link copied", symbol: "link")
        } catch { lastError = Self.message(error) }
    }

    func delete(_ capture: CloudCapture) async {
        guard let configuration else { return }
        do {
            try await transportFactory().deleteCapture(configuration: configuration, id: capture.id)
            deletedIDs.insert(capture.id)
            captures.removeAll { $0.id == capture.id }
            connectionError = nil
            await refresh()
        } catch { lastError = Self.message(error) }
    }

    private func kickUploadWorker() {
        workRequested = true
        guard !isUploading, let outbox else { return }
        let activation = activationID
        uploadTask = Task { [weak self] in await self?.processUploads(outbox: outbox, activation: activation) }
    }

    private func processUploads(outbox: CloudUploadOutbox, activation: UUID) async {
        guard !isUploading, activation == activationID else { return }
        isUploading = true
        defer {
            if activation == activationID {
                isUploading = false
                uploadTask = nil
            }
        }
        repeat {
            workRequested = false
            let uploadedBefore = Set(snapshots.filter { $0.status == .uploaded }.map(\.id))
            await outbox.processPending()
            guard activation == activationID else { return }
            await reloadSnapshotsAndSchedule()
            let receipts = snapshots.compactMap(\.receipt).filter { !uploadedBefore.contains($0.id) }
            if !receipts.isEmpty {
                await refresh() // One metadata/usage fetch for this completed batch.
                // A completed upload should appear immediately even if the
                // first list read races the backend's index update.
                merge(receipts)
            }
        } while workRequested && activation == activationID
    }

    private func reloadSnapshotsAndSchedule() async {
        guard let outbox else { snapshots = []; retryTask?.cancel(); return }
        snapshots = await outbox.snapshots()
        if let error = snapshots.first(where: { $0.status != .uploaded && $0.lastError != nil })?.lastError {
            lastError = error
        } else {
            lastError = nil
        }
        retryTask?.cancel()
        guard let next = snapshots.compactMap(\.nextAttemptAt).min() else { return }
        let activation = activationID
        retryTask = Task { [weak self] in
            let interval = max(0, next.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, activation == self.activationID else { return }
            self.kickUploadWorker()
        }
    }

    private func merge(_ receipts: [CloudCapture]) {
        for receipt in receipts {
            guard !deletedIDs.contains(receipt.id) else { continue }
            if let index = captures.firstIndex(where: { $0.id == receipt.id }) { captures[index] = receipt }
            else { captures.insert(receipt, at: 0) }
        }
    }

    private static func endpointHash(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func loadStoredCredentials() {
        do {
            guard let credentials = try CloudCredentials.load() else { return }
            activate(configuration: CloudConfiguration(baseURL: credentials.apiURL, token: credentials.deviceToken))
        } catch {
            isConfigured = false
            connectionError = Self.message(error)
        }
    }
}
