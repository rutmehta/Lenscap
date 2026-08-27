import AppKit
import UniformTypeIdentifiers

/// Saving, encoding, and clipboard handling for captured images.
enum ImageWriter {
    /// Saves per current settings and returns the file URL, or nil on failure.
    /// `scale` is the source display's points → pixels factor; falls back to
    /// NSScreen.main when the caller doesn't know it.
    static func save(cgImage: CGImage, scale: CGFloat? = nil) -> URL? {
        let settings = SettingsStore.shared
        let directory = settings.saveDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var image = cgImage
        var scaleSuffix = ""
        let screenScale = scale ?? NSScreen.main?.backingScaleFactor ?? 2
        if settings.downscaleRetina, screenScale > 1 {
            if let downscaled = downscale(cgImage, by: 1 / screenScale) {
                image = downscaled
            }
        } else if screenScale > 1 {
            scaleSuffix = "@\(Int(screenScale.rounded()))x"
        }

        let ext = settings.fileFormat == "jpg" ? "jpg" : "png"
        let url = newFileURL(in: directory, prefix: settings.filenamePrefix, suffix: scaleSuffix, ext: ext)
        guard let data = encode(image, format: settings.fileFormat, jpegQuality: settings.jpegQuality) else {
            return nil
        }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    static func newFileURL(in directory: URL, prefix: String, suffix: String = "", ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        // "/" (and ":", which Finder maps to "/") would silently break the save path.
        let safePrefix = prefix
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = "\(safePrefix) \(formatter.string(from: Date()))\(suffix)"
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }

    static func encode(_ cgImage: CGImage, format: String, jpegQuality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if format == "jpg" {
            return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
        }
        return rep.representation(using: .png, properties: [:])
    }

    static func pngData(_ cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    @discardableResult
    static func copyToClipboard(cgImage: CGImage, fileURL: URL?,
                                pasteboard: NSPasteboard = .general) -> Bool {
        // Keep both representations on one item to avoid duplicate pasted attachments.
        let item = NSPasteboardItem()
        guard let data = pngData(cgImage), item.setData(data, forType: .png) else {
            return false
        }
        if let fileURL {
            guard item.setString(fileURL.absoluteString, forType: .fileURL) else {
                return false
            }
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func downscale(_ cgImage: CGImage, by factor: CGFloat) -> CGImage? {
        let width = Int(CGFloat(cgImage.width) * factor)
        let height = Int(CGFloat(cgImage.height) * factor)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
