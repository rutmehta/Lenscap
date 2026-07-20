import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Animated GIF encoding via CGImageDestination, off the main actor.
enum GIFExporter {
    enum GIFError: LocalizedError {
        case destinationFailed

        var errorDescription: String? {
            switch self {
            case .destinationFailed: return "Could not write the GIF file."
            }
        }
    }

    /// Encodes `frames` into an infinitely-looping GIF at `url`, with per-frame
    /// delays derived from the actual capture timestamps.
    static func encode(frames: [CGImage], timestamps: [Double],
                       fallbackDelay: Double, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try write(frames: frames, timestamps: timestamps, fallbackDelay: fallbackDelay, to: url)
        }.value
    }

    private static func write(frames: [CGImage], timestamps: [Double],
                              fallbackDelay: Double, to url: URL) throws {
        guard !frames.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.gif.identifier as CFString,
                                                                frames.count, nil)
        else { throw GIFError.destinationFailed }

        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0], // loop forever
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        for (index, frame) in frames.enumerated() {
            var delay = fallbackDelay
            if index + 1 < timestamps.count {
                delay = timestamps[index + 1] - timestamps[index]
            }
            delay = max(0.02, delay) // GIF renderers clamp anything shorter
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ]
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFError.destinationFailed
        }
    }
}
