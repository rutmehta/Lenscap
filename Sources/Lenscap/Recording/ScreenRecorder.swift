import AppKit
import AVFoundation
import ScreenCaptureKit

enum RecordingMode {
    case video
    case gif
}

/// SCStream-based screen recording: H.264 .mp4 (with optional system audio) or animated GIF.
@MainActor
final class ScreenRecorder: NSObject {
    static let shared = ScreenRecorder()

    private(set) var isRecording = false

    private var stream: SCStream?
    private var output: RecordingStreamOutput?
    private var hud: RecordingHUDController?
    private var mode: RecordingMode = .video
    private var isStarting = false
    private var gifLimitHit = false

    // MARK: - Start

    func start(selection: SelectionResult?, mode: RecordingMode) async {
        guard !isRecording, !isStarting else { return }
        guard let screen = selection?.screen ?? NSScreen.main else {
            HUD.show("No screen available to record", symbol: "record.circle")
            return
        }
        isStarting = true
        defer { isStarting = false }
        self.mode = mode
        gifLimitHit = false

        let settings = SettingsStore.shared
        let recordsFullScreen = selection == nil || selection?.wantsFullScreen == true

        do {
            let content = try await CaptureEngine.shareableContent()
            let display = try CaptureEngine.display(for: screen, in: content)
            let filter = Self.filterExcludingOwnWindows(display: display, content: content)

            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()

            var pixelSize: CGSize
            if !recordsFullScreen, let selection {
                // Convert to display-local, top-left-origin space (same as CaptureEngine.captureRect).
                let screenFrame = screen.frame
                let local = CGRect(x: selection.rect.minX - screenFrame.minX,
                                   y: screenFrame.maxY - selection.rect.maxY,
                                   width: selection.rect.width,
                                   height: selection.rect.height)
                config.sourceRect = local
                pixelSize = CGSize(width: local.width * scale, height: local.height * scale)
            } else {
                pixelSize = CGSize(width: CGFloat(display.width) * scale,
                                   height: CGFloat(display.height) * scale)
            }
            if mode == .gif {
                // Keep GIFs manageable: longest side capped at 960 px.
                let longest = max(pixelSize.width, pixelSize.height)
                if longest > 960 {
                    let factor = 960 / longest
                    pixelSize = CGSize(width: pixelSize.width * factor, height: pixelSize.height * factor)
                }
            }
            config.width = Self.evenPixels(pixelSize.width)
            config.height = Self.evenPixels(pixelSize.height)

            let fps = max(1, mode == .video ? settings.videoFPS : settings.gifFPS)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.showsCursor = settings.showCursorInRecordings
            config.queueDepth = 5
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let wantsAudio = mode == .video && settings.recordSystemAudio
            if wantsAudio {
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 44_100
                config.channelCount = 2
            }

            let out: RecordingStreamOutput
            switch mode {
            case .video:
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Lenscap-\(UUID().uuidString).mp4")
                out = try RecordingStreamOutput(videoTo: tempURL,
                                                size: CGSize(width: config.width, height: config.height),
                                                includeAudio: wantsAudio)
            case .gif:
                out = RecordingStreamOutput(gifMaxDuration: 30)
                out.onGIFLimitReached = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.isRecording, !self.gifLimitHit else { return }
                        self.gifLimitHit = true
                        HUD.show("GIF limit reached (30s) — stopping", symbol: "timer")
                        await self.stopAndSave()
                    }
                }
            }
            out.onStreamStopped = { [weak self] error in
                Task { @MainActor in
                    self?.handleStreamFailure(error)
                }
            }
            // Track the output now so the catch below can cancel it (deleting the
            // already-created temp .mp4) when SCStream setup or startCapture fails.
            output = out

            let newStream = SCStream(filter: filter, configuration: config, delegate: out)
            try newStream.addStreamOutput(out, type: .screen, sampleHandlerQueue: out.sampleQueue)
            if wantsAudio {
                try newStream.addStreamOutput(out, type: .audio, sampleHandlerQueue: out.sampleQueue)
            }

            await showCountdown()
            try await newStream.startCapture()

            stream = newStream
            output = out
            isRecording = true
            AppCoordinator.shared.statusBar?.setRecording(true)

            let hudController = RecordingHUDController()
            hudController.show(on: screen, avoiding: recordsFullScreen ? nil : selection?.rect)
            hud = hudController
        } catch {
            output?.cancel()
            output = nil
            stream = nil
            isRecording = false
            AppCoordinator.shared.statusBar?.setRecording(false)
            HUD.show("Recording failed: \(error.localizedDescription)", symbol: "record.circle")
        }
    }

    // MARK: - Stop

    func stopAndSave() async {
        guard isRecording, let output else { return }
        isRecording = false
        AppCoordinator.shared.statusBar?.setRecording(false)
        hud?.hide()
        hud = nil

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        self.output = nil

        switch mode {
        case .video: await finalizeVideo(output)
        case .gif: await finalizeGIF(output)
        }
    }

    // MARK: - Finalization

    private func finalizeVideo(_ output: RecordingStreamOutput) async {
        guard let tempURL = await output.finishVideoWriting() else {
            HUD.show("Recording failed to save", symbol: "record.circle")
            return
        }
        let settings = SettingsStore.shared
        let directory = settings.saveDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = ImageWriter.newFileURL(in: directory, prefix: settings.filenamePrefix, ext: "mp4")
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            HUD.show("Could not save recording: \(error.localizedDescription)", symbol: "record.circle")
            return
        }
        let thumbnail = await Self.videoThumbnail(for: destination)
        AppCoordinator.shared.ingestRecording(url: destination, kind: .video, thumbnail: thumbnail)
    }

    private func finalizeGIF(_ output: RecordingStreamOutput) async {
        let (frames, timestamps) = output.gifFrames()
        guard !frames.isEmpty else {
            HUD.show("No frames captured", symbol: "photo.stack")
            return
        }
        HUD.show("Encoding GIF…", symbol: "photo.stack", duration: 60)

        let settings = SettingsStore.shared
        let directory = settings.saveDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = ImageWriter.newFileURL(in: directory, prefix: settings.filenamePrefix, ext: "gif")
        let fallbackDelay = 1.0 / Double(max(1, settings.gifFPS))
        do {
            try await GIFExporter.encode(frames: frames, timestamps: timestamps,
                                         fallbackDelay: fallbackDelay, to: destination)
        } catch {
            HUD.show("GIF encoding failed: \(error.localizedDescription)", symbol: "photo.stack")
            return
        }
        HUD.show("GIF saved", symbol: "photo.stack")
        let first = frames[0]
        let thumbnail = NSImage(cgImage: first, size: NSSize(width: first.width, height: first.height))
        AppCoordinator.shared.ingestRecording(url: destination, kind: .gif, thumbnail: thumbnail)
    }

    // MARK: - Failures

    /// Stream died underneath us (display disconnect, permission revoked, …).
    private func handleStreamFailure(_ error: Error) {
        guard isRecording else { return }
        isRecording = false
        AppCoordinator.shared.statusBar?.setRecording(false)
        hud?.hide()
        hud = nil
        output?.cancel()
        output = nil
        stream = nil
        HUD.show("Recording stopped: \(error.localizedDescription)", symbol: "record.circle")
    }

    // MARK: - Helpers

    private func showCountdown() async {
        for count in [3, 2, 1] {
            HUD.show("\(count)", symbol: "record.circle", duration: 0.55)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Excludes every window of this app (recording HUD, toasts, quick access) from capture.
    private static func filterExcludingOwnWindows(display: SCDisplay,
                                                  content: SCShareableContent) -> SCContentFilter {
        let pid = getpid()
        // Excluding the application covers windows created after the filter too (e.g. the recording HUD).
        if let ownApp = content.applications.first(where: { $0.processID == pid }) {
            return SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
        }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        return SCContentFilter(display: display, excludingWindows: ownWindows)
    }

    /// Video encoders want even dimensions.
    private static func evenPixels(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded()) & ~1)
    }

    private static func videoThumbnail(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
