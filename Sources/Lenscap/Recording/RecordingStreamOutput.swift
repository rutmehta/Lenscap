import AVFoundation
import CoreImage
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .writerFailed: return "Could not start the video writer."
        }
    }
}

/// Receives SCStream sample buffers off the main actor and routes them to either
/// an AVAssetWriter (video mode) or an in-memory frame accumulator (GIF mode).
/// All buffer handling happens on `sampleQueue`.
final class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let sampleQueue = DispatchQueue(label: "dev.lenscap.recording.samples")

    /// Fired once (on `sampleQueue`) when the GIF duration cap is reached.
    var onGIFLimitReached: (() -> Void)?
    /// Fired (off main) when the stream stops on its own with an error.
    var onStreamStopped: ((Error) -> Void)?

    private let isVideo: Bool

    // MARK: - Video writing state

    private let writer: AVAssetWriter?
    private let videoInput: AVAssetWriterInput?
    private let audioInput: AVAssetWriterInput?
    private let videoURL: URL?
    private var sessionStarted = false

    // MARK: - GIF accumulation state

    private let gifMaxDuration: Double
    private var gifFrameStore: [CGImage] = []
    private var gifTimestamps: [Double] = []
    private var gifFirstPTS: Double?
    private var gifLimitFired = false
    private lazy var ciContext = CIContext(options: nil)

    // MARK: - Init

    init(videoTo url: URL, size: CGSize, includeAudio: Bool) throws {
        isVideo = true
        gifMaxDuration = 0
        videoURL = url

        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        assetWriter.add(video)

        var audio: AVAssetWriterInput?
        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            assetWriter.add(input)
            audio = input
        }

        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? RecordingError.writerFailed
        }
        writer = assetWriter
        videoInput = video
        audioInput = audio
        super.init()
    }

    init(gifMaxDuration: Double) {
        isVideo = false
        self.gifMaxDuration = gifMaxDuration
        writer = nil
        videoInput = nil
        audioInput = nil
        videoURL = nil
        super.init()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .screen {
            handleScreenSample(sampleBuffer)
        } else if type == .audio {
            handleAudioSample(sampleBuffer)
        }
    }

    private func handleScreenSample(_ sampleBuffer: CMSampleBuffer) {
        // Only complete frames carry usable image data; idle/blank frames are skipped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete
        else { return }

        if isVideo {
            appendVideoSample(sampleBuffer)
        } else {
            accumulateGIFFrame(sampleBuffer)
        }
    }

    private func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, let videoInput, writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, let writer, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    private func accumulateGIFFrame(_ sampleBuffer: CMSampleBuffer) {
        guard !gifLimitFired else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if let first = gifFirstPTS, pts - first >= gifMaxDuration {
            gifLimitFired = true
            onGIFLimitReached?()
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        if gifFirstPTS == nil { gifFirstPTS = pts }
        gifFrameStore.append(cgImage)
        gifTimestamps.append(pts)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped?(error)
    }

    // MARK: - Finishing

    /// Finalizes the .mp4 and returns its temp URL, or nil if nothing usable was written.
    /// Call only after the stream has fully stopped.
    func finishVideoWriting() async -> URL? {
        guard let writer, let videoURL else { return nil }
        let hasFrames = sampleQueue.sync { sessionStarted }
        guard hasFrames, writer.status == .writing else {
            cancel()
            return nil
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed ? videoURL : nil
    }

    /// Snapshot of accumulated GIF frames. Call only after the stream has fully stopped.
    func gifFrames() -> (frames: [CGImage], timestamps: [Double]) {
        sampleQueue.sync { (gifFrameStore, gifTimestamps) }
    }

    /// Abandons any in-progress video file.
    func cancel() {
        guard let writer else { return }
        if writer.status == .writing {
            writer.cancelWriting()
        }
        if let videoURL {
            try? FileManager.default.removeItem(at: videoURL)
        }
    }
}
