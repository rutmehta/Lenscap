import AppKit

/// Stitches a sequence of same-width frames (top-to-bottom scroll captures) into one tall image.
/// Overlap between consecutive frames is estimated by comparing downsampled grayscale row profiles.
enum ImageStitcher {
    struct StitchResult {
        let image: CGImage?
        let cappedAtMax: Bool
    }

    /// Width of the downsampled grayscale profile used for overlap matching.
    private static let profileWidth = 64
    /// Normalized mean-absolute-difference above which an overlap match is rejected.
    private static let matchThreshold = 0.045

    // MARK: - Stitching

    static func stitch(_ frames: [CGImage], maxHeight: Int) -> StitchResult {
        guard let first = frames.first else { return StitchResult(image: nil, cappedAtMax: false) }
        guard frames.count > 1 else {
            return StitchResult(image: first, cappedAtMax: first.height > maxHeight)
        }

        let profiles = frames.map { rowProfile(of: $0) }

        // Overlap of frame i with frame i-1 (index 0 unused).
        var overlaps = [Int](repeating: 0, count: frames.count)
        for i in 1..<frames.count {
            guard let prev = profiles[i - 1], let next = profiles[i] else { continue }
            overlaps[i] = bestOverlap(prev: prev, prevHeight: frames[i - 1].height,
                                      next: next, nextHeight: frames[i].height)
        }

        // Top offset of each frame in the composed image.
        var positions = [Int](repeating: 0, count: frames.count)
        for i in 1..<frames.count {
            positions[i] = positions[i - 1] + frames[i - 1].height - overlaps[i]
        }
        let totalHeight = positions[frames.count - 1] + frames[frames.count - 1].height
        let outHeight = min(totalHeight, maxHeight)

        guard outHeight > 0,
              let context = CGContext(data: nil, width: first.width, height: outHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return StitchResult(image: nil, cappedAtMax: false) }

        context.interpolationQuality = .none
        for (i, frame) in frames.enumerated() {
            guard positions[i] < outHeight else { break }
            // Convert top-down offset to CG's bottom-left origin; clipping handles the capped tail.
            let drawRect = CGRect(x: 0,
                                  y: CGFloat(outHeight - positions[i] - frame.height),
                                  width: CGFloat(frame.width),
                                  height: CGFloat(frame.height))
            context.draw(frame, in: drawRect)
        }
        return StitchResult(image: context.makeImage(), cappedAtMax: totalHeight > maxHeight)
    }

    // MARK: - Frame comparison

    /// True when two frames have byte-identical pixel data (used to detect "reached the bottom").
    static func pixelIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        guard let dataA = a.dataProvider?.data as Data?,
              let dataB = b.dataProvider?.data as Data?
        else { return false }
        return dataA == dataB
    }

    // MARK: - Overlap search

    /// Grayscale rows downsampled to `profileWidth` columns; row 0 is the top of the image.
    private static func rowProfile(of image: CGImage) -> [UInt8]? {
        let height = image.height
        guard height > 0,
              let context = CGContext(data: nil, width: profileWidth, height: height,
                                      bitsPerComponent: 8, bytesPerRow: profileWidth,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: profileWidth, height: height))
        guard let data = context.data else { return nil }
        let buffer = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                         count: profileWidth * height)
        return Array(buffer)
    }

    /// Best vertical overlap (in rows) between the bottom of `prev` and the top of `next`,
    /// or 0 when no candidate matches well enough.
    private static func bestOverlap(prev: [UInt8], prevHeight: Int, next: [UInt8], nextHeight: Int) -> Int {
        let frameHeight = min(prevHeight, nextHeight)
        let minH = max(8, Int(Double(frameHeight) * 0.10))
        let maxH = Int(Double(frameHeight) * 0.95)
        guard maxH > minH,
              prev.count == prevHeight * profileWidth,
              next.count == nextHeight * profileWidth
        else { return 0 }

        // Coarse scan from large to small overlap (ties prefer more overlap), then refine.
        let coarseStep = max(1, (maxH - minH) / 600)
        var bestH = 0
        var bestError = Double.greatestFiniteMagnitude
        var h = maxH
        while h >= minH {
            let error = overlapError(prev: prev, prevHeight: prevHeight, next: next, overlap: h)
            if error < bestError {
                bestError = error
                bestH = h
            }
            h -= coarseStep
        }
        if coarseStep > 1, bestH > 0 {
            for candidate in max(minH, bestH - coarseStep)...min(maxH, bestH + coarseStep) where candidate != bestH {
                let error = overlapError(prev: prev, prevHeight: prevHeight, next: next, overlap: candidate)
                if error < bestError {
                    bestError = error
                    bestH = candidate
                }
            }
        }
        return bestError <= matchThreshold ? bestH : 0
    }

    /// Normalized mean absolute difference between the bottom `overlap` rows of `prev`
    /// and the top `overlap` rows of `next`, sampled with a row stride for speed.
    private static func overlapError(prev: [UInt8], prevHeight: Int, next: [UInt8], overlap: Int) -> Double {
        let width = profileWidth
        let rowStep = max(1, overlap / 64)
        var sum = 0
        var count = 0
        var row = 0
        while row < overlap {
            let prevBase = (prevHeight - overlap + row) * width
            let nextBase = row * width
            for column in 0..<width {
                sum += abs(Int(prev[prevBase + column]) - Int(next[nextBase + column]))
            }
            count += width
            row += rowStep
        }
        guard count > 0 else { return .greatestFiniteMagnitude }
        return Double(sum) / (Double(count) * 255)
    }
}
