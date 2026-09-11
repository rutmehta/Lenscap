import AVFoundation
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import Lenscap

final class RecordingStreamOutputTests: XCTestCase {
    func testVideoSizeBoundsAndPreservesAspectWithoutUpscaling() {
        let cases: [(CGSize, CGSize)] = [
            (CGSize(width: 4112, height: 2658), CGSize(width: 3340, height: 2160)),
            (CGSize(width: 2658, height: 4112), CGSize(width: 2160, height: 3340)),
            (CGSize(width: 1920, height: 1080), CGSize(width: 1920, height: 1080)),
            (CGSize(width: 4000, height: 4000), CGSize(width: 2160, height: 2160)),
            (CGSize(width: 7680, height: 2160), CGSize(width: 3840, height: 1080)),
            (CGSize(width: 641, height: 359), CGSize(width: 640, height: 358)),
        ]

        for (source, expected) in cases {
            XCTAssertEqual(RecordingStreamOutput.videoSize(for: source), expected, "\(source)")
        }
    }

    func testLargeScreenRecordingIsColoredBrowserSafeAndFastStart() async throws {
        let sourceSize = CGSize(width: 4112, height: 2658)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LenscapRecordingWriter-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("recording.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try RecordingStreamOutput(videoTo: url, size: sourceSize, includeAudio: false)
        let first = try solidFrame(size: sourceSize, presentationTime: .zero)
        let second = try solidFrame(size: sourceSize, presentationTime: CMTime(value: 1, timescale: 30))
        writer.sampleQueue.sync {
            writer.handleScreenSample(first)
            writer.handleScreenSample(second)
        }
        let finishedURL = await writer.finishVideoWriting()
        let output = try XCTUnwrap(finishedURL)

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let dimensions = try await track.load(.naturalSize)
        XCTAssertLessThanOrEqual(max(dimensions.width, dimensions.height), 3840)
        XCTAssertLessThanOrEqual(min(dimensions.width, dimensions.height), 2160)
        let channels = try await firstFrameChannels(in: asset)
        XCTAssertGreaterThan(channels.blue, 150)
        XCTAssertGreaterThan(channels.green, 40)
        XCTAssertGreaterThan(channels.red, 10)
        XCTAssertGreaterThan(Int(channels.blue), Int(channels.green) + 40)
        XCTAssertGreaterThan(Int(channels.green), Int(channels.red) + 25)

        let bytes = try Data(contentsOf: output)
        let moov = try XCTUnwrap(bytes.firstRange(of: Data("moov".utf8)))
        let mdat = try XCTUnwrap(bytes.firstRange(of: Data("mdat".utf8)))
        XCTAssertLessThan(moov.lowerBound, mdat.lowerBound)
        XCTAssertLessThanOrEqual(try h264Level(in: bytes), 52)
    }

    private func solidFrame(size: CGSize, presentationTime: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                           kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            let pixels = base.advanced(by: row * bytesPerRow)
            for column in stride(from: 0, to: Int(size.width) * 4, by: 4) {
                pixels[column] = 220 // B
                pixels[column + 1] = 100 // G
                pixels[column + 2] = 40 // R
                pixels[column + 3] = 255 // A
            }
        }

        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                      imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                                  imageBuffer: buffer,
                                                                  formatDescription: try XCTUnwrap(format),
                                                                  sampleTiming: &timing,
                                                                  sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        attachment[SCStreamFrameInfo.status] = SCFrameStatus.complete.rawValue
        return result
    }

    private func firstFrameChannels(in asset: AVAsset) async throws -> (blue: UInt8, green: UInt8, red: UInt8) {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
                                              outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        defer { CMSampleBufferInvalidate(sample) }
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return (pixels[0], pixels[1], pixels[2])
    }

    private func h264Level(in bytes: Data) throws -> UInt8 {
        let avcC = try XCTUnwrap(bytes.firstRange(of: Data("avcC".utf8)))
        let levelIndex = avcC.lowerBound + 7 // box type, then configurationVersion/profile/compatibility/level
        return bytes[levelIndex]
    }
}
