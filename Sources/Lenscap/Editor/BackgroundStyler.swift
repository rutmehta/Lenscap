import AppKit

// MARK: - Style model

/// CleanShot-style "beautify" settings: padding, rounded corners, shadow, and a
/// backdrop rendered behind the screenshot. Slider values are in image "points"
/// and get multiplied by the document's pixel scale.
struct BackgroundStyle: Equatable {
    var padding: CGFloat = 0
    var cornerRadius: CGFloat = 0
    var shadow: Bool = false
    var preset: BackgroundPreset = .none

    var isEnabled: Bool {
        padding > 0 || cornerRadius > 0 || shadow || preset != .none
    }
}

enum BackgroundPreset: String, CaseIterable, Identifiable, Equatable {
    case none
    case iris
    case ocean
    case sunset
    case meadow
    case punch
    case slate
    case snow
    case ink

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .iris: return "Iris"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .meadow: return "Meadow"
        case .punch: return "Punch"
        case .slate: return "Slate"
        case .snow: return "Snow"
        case .ink: return "Ink"
        }
    }

    /// Gradient stops top → bottom. Single element means a solid fill.
    var colors: [NSColor] {
        switch self {
        case .none: return []
        case .iris: return [NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.95, alpha: 1),
                            NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.85, alpha: 1)]
        case .ocean: return [NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.92, alpha: 1),
                             NSColor(calibratedRed: 0.10, green: 0.85, blue: 0.80, alpha: 1)]
        case .sunset: return [NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.25, alpha: 1),
                              NSColor(calibratedRed: 0.93, green: 0.25, blue: 0.55, alpha: 1)]
        case .meadow: return [NSColor(calibratedRed: 0.25, green: 0.75, blue: 0.40, alpha: 1),
                              NSColor(calibratedRed: 0.65, green: 0.90, blue: 0.35, alpha: 1)]
        case .punch: return [NSColor(calibratedRed: 0.90, green: 0.20, blue: 0.30, alpha: 1),
                             NSColor(calibratedRed: 0.60, green: 0.10, blue: 0.55, alpha: 1)]
        case .slate: return [NSColor(calibratedRed: 0.22, green: 0.25, blue: 0.30, alpha: 1),
                             NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1)]
        case .snow: return [NSColor(calibratedWhite: 0.96, alpha: 1)]
        case .ink: return [NSColor(calibratedWhite: 0.08, alpha: 1)]
        }
    }
}

// MARK: - Rendering

/// Draws the beautify backdrop + padded, rounded, shadowed screenshot.
/// All routines work in image-pixel space with a bottom-left origin.
enum BackgroundStyler {
    /// Total output size once padding is applied.
    static func outputSize(for imageSize: CGSize, style: BackgroundStyle, pixelScale: CGFloat) -> CGSize {
        let pad = style.padding * pixelScale
        return CGSize(width: imageSize.width + pad * 2, height: imageSize.height + pad * 2)
    }

    /// Draws backdrop, shadow, and the rounded screenshot into `ctx`, with the
    /// output occupying (0,0)...outputSize. Returns the rect the screenshot occupies.
    @discardableResult
    static func draw(screenshot: CGImage, style: BackgroundStyle, pixelScale: CGFloat, in ctx: CGContext) -> CGRect {
        let imageSize = CGSize(width: screenshot.width, height: screenshot.height)
        let pad = style.padding * pixelScale
        let radius = style.cornerRadius * pixelScale
        let full = CGRect(origin: .zero, size: outputSize(for: imageSize, style: style, pixelScale: pixelScale))
        let imageRect = CGRect(x: pad, y: pad, width: imageSize.width, height: imageSize.height)

        drawBackdrop(style.preset, in: full, ctx: ctx)

        let clipRadius = min(radius, min(imageRect.width, imageRect.height) / 2)
        let rounded = CGPath(roundedRect: imageRect,
                             cornerWidth: clipRadius, cornerHeight: clipRadius,
                             transform: nil)

        if style.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * pixelScale),
                          blur: 18 * pixelScale,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.addPath(rounded)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        ctx.draw(screenshot, in: imageRect)
        ctx.restoreGState()
        return imageRect
    }

    /// Flattened screenshot → final export image with the style applied.
    /// Returns the input unchanged when the style is inert.
    static func wrap(_ screenshot: CGImage, style: BackgroundStyle, pixelScale: CGFloat) -> CGImage {
        guard style.isEnabled else { return screenshot }
        let size = outputSize(for: CGSize(width: screenshot.width, height: screenshot.height),
                              style: style, pixelScale: pixelScale)
        guard let ctx = CGContext(data: nil,
                                  width: max(1, Int(size.width.rounded())),
                                  height: max(1, Int(size.height.rounded())),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return screenshot }
        ctx.interpolationQuality = .high
        draw(screenshot: screenshot, style: style, pixelScale: pixelScale, in: ctx)
        return ctx.makeImage() ?? screenshot
    }

    private static func drawBackdrop(_ preset: BackgroundPreset, in rect: CGRect, ctx: CGContext) {
        let colors = preset.colors
        guard !colors.isEmpty else { return }
        if colors.count == 1 {
            ctx.setFillColor(colors[0].cgColor)
            ctx.fill(rect)
            return
        }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors.map(\.cgColor) as CFArray,
                                        locations: nil) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        // Diagonal top-left → bottom-right (bottom-left origin space).
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}
