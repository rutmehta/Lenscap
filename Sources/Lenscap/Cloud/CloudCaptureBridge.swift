import AppKit
import LenscapCloudCore

enum CloudCaptureEncoding {
    static func screenshot(_ image: CGImage, format: String, jpegQuality: Double,
                           scale: CGFloat, downscale: Bool) -> Data? {
        let output = downscale && scale > 1
            ? (ImageWriter.downscale(image, by: 1 / scale) ?? image) : image
        return ImageWriter.encode(output, format: format, jpegQuality: jpegQuality)
    }

    static func contentType(kind: CaptureItem.Kind, filename: String) -> String {
        switch kind {
        case .video: return "video/mp4"
        case .gif: return "image/gif"
        case .screenshot:
            let ext = (filename as NSString).pathExtension.lowercased()
            return ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png"
        }
    }
}

/// Keeps capture callbacks fast while retaining the immutable image until its
/// private upload spool has been written. Normal Quit waits for staging only,
/// never for the network; the outbox resumes unfinished uploads at next launch.
@MainActor
final class CloudCaptureBridge {
    static let shared = CloudCaptureBridge()
    private var staging: [UUID: Task<Void, Never>] = [:]
    var isStaging: Bool { !staging.isEmpty }

    func screenshot(_ image: CGImage, savedURL: URL?, scale: CGFloat?,
                    id: UUID, createdAt: Date) {
        let cloud = CloudController.shared
        guard cloud.isConfigured else { return }
        let settings = SettingsStore.shared
        let format = settings.fileFormat == "jpg" ? "jpg" : "png"
        let quality = settings.jpegQuality
        let downscale = settings.downscaleRetina
        let screenScale = scale ?? NSScreen.main?.backingScaleFactor ?? 2
        let suffix = !downscale && screenScale > 1 ? "@\(Int(screenScale.rounded()))x" : ""
        let filename = savedURL?.lastPathComponent ?? ImageWriter.newFileURL(
            in: settings.saveDirectory, prefix: settings.filenamePrefix, suffix: suffix, ext: format).lastPathComponent
        staging[id] = Task { [weak self] in
            let data = await Task.detached(priority: .utility) {
                CloudCaptureEncoding.screenshot(image, format: format, jpegQuality: quality,
                                                scale: screenScale, downscale: downscale)
            }.value
            if let data {
                await cloud.enqueue(data: data, id: id, filename: filename, kind: .screenshot,
                                    contentType: format == "jpg" ? "image/jpeg" : "image/png", createdAt: createdAt)
            } else {
                cloud.reportStagingError("Could not prepare this screenshot for cloud upload.")
                HUD.show("Cloud upload could not be queued", symbol: "exclamationmark.triangle")
            }
            self?.staging.removeValue(forKey: id)
        }
    }

    func finalizedFile(_ url: URL, kind: CaptureItem.Kind, id: UUID = UUID(), createdAt: Date = Date()) {
        let cloud = CloudController.shared
        guard cloud.isConfigured, let cloudKind = CloudCaptureKind(rawValue: kind.rawValue) else { return }
        let contentType = CloudCaptureEncoding.contentType(kind: kind, filename: url.lastPathComponent)
        staging[id] = Task { [weak self] in
            await cloud.enqueue(fileURL: url, id: id, kind: cloudKind,
                                contentType: contentType, createdAt: createdAt)
            self?.staging.removeValue(forKey: id)
        }
    }

    func savedImage(_ data: Data, url: URL) {
        let cloud = CloudController.shared
        guard cloud.isConfigured else { return }
        let id = UUID()
        let createdAt = Date()
        staging[id] = Task { [weak self] in
            await cloud.enqueue(data: data, id: id, filename: url.lastPathComponent, kind: .screenshot,
                                contentType: CloudCaptureEncoding.contentType(kind: .screenshot, filename: url.lastPathComponent),
                                createdAt: createdAt)
            self?.staging.removeValue(forKey: id)
        }
    }

    func waitForStaging() async {
        while !staging.isEmpty {
            let tasks = Array(staging.values)
            for task in tasks { await task.value }
        }
    }
}
