import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Draws annotations into a CGContext (image-pixel space, bottom-left origin),
/// produces blur/pixelate patches, computes bounds/hit tests, and flattens the
/// full document for export.
enum AnnotationRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Vector drawing

    /// Draws every non-filter annotation in array order.
    static func drawVectors(_ annotations: [Annotation], in ctx: CGContext) {
        for annotation in annotations where !annotation.isRegionFilter {
            draw(annotation, in: ctx)
        }
    }

    static func draw(_ annotation: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch annotation.kind {
        case .arrow:
            drawArrow(annotation, in: ctx)
        case .line:
            ctx.setStrokeColor(annotation.color.cgColor)
            ctx.setLineWidth(annotation.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: annotation.start)
            ctx.addLine(to: annotation.end)
            ctx.strokePath()
        case .rectangle:
            ctx.setStrokeColor(annotation.color.cgColor)
            ctx.setLineWidth(annotation.lineWidth)
            ctx.setLineJoin(.round)
            ctx.stroke(annotation.rect)
        case .ellipse:
            ctx.setStrokeColor(annotation.color.cgColor)
            ctx.setLineWidth(annotation.lineWidth)
            ctx.strokeEllipse(in: annotation.rect)
        case .pen:
            strokePolyline(annotation.points, color: annotation.color.cgColor,
                           width: annotation.lineWidth, in: ctx)
        case .highlighter:
            ctx.setBlendMode(.multiply)
            strokePolyline(annotation.points,
                           color: annotation.color.withAlphaComponent(0.4).cgColor,
                           width: annotation.lineWidth * 4, in: ctx)
        case .text:
            drawText(annotation, in: ctx)
        case .counter:
            drawCounter(annotation, in: ctx)
        case .blur, .pixelate:
            break
        }
    }

    private static func strokePolyline(_ points: [CGPoint], color: CGColor, width: CGFloat, in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: first)
        if points.count == 1 {
            ctx.addLine(to: first)
        } else {
            for point in points.dropFirst() {
                ctx.addLine(to: point)
            }
        }
        ctx.strokePath()
    }

    /// Tapered arrow: thin at the tail, widening into a triangular head. Filled.
    private static func drawArrow(_ annotation: Annotation, in ctx: CGContext) {
        let start = annotation.start
        let end = annotation.end
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 1 else { return }
        let dir = CGPoint(x: dx / length, y: dy / length)
        let perp = CGPoint(x: -dir.y, y: dir.x)

        let width = annotation.lineWidth
        let headLength = min(length * 0.4, width * 3.2 + 10)
        let headHalf = width * 1.5 + 4
        let shaftHalf = width * 0.65
        let tailHalf = max(0.75, width * 0.2)
        let headBase = CGPoint(x: end.x - dir.x * headLength, y: end.y - dir.y * headLength)

        func offset(_ point: CGPoint, _ amount: CGFloat) -> CGPoint {
            CGPoint(x: point.x + perp.x * amount, y: point.y + perp.y * amount)
        }

        let path = CGMutablePath()
        path.move(to: offset(start, tailHalf))
        path.addLine(to: offset(headBase, shaftHalf))
        path.addLine(to: offset(headBase, headHalf))
        path.addLine(to: end)
        path.addLine(to: offset(headBase, -headHalf))
        path.addLine(to: offset(headBase, -shaftHalf))
        path.addLine(to: offset(start, -tailHalf))
        path.closeSubpath()

        ctx.setFillColor(annotation.color.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    private static func drawText(_ annotation: Annotation, in ctx: CGContext) {
        guard !annotation.text.isEmpty else { return }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        annotation.text.draw(at: annotation.start, withAttributes: textAttributes(for: annotation))
        NSGraphicsContext.current = previous
    }

    static func textAttributes(for annotation: Annotation) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = annotation.fontSize * 0.06
        shadow.shadowOffset = NSSize(width: 0, height: -annotation.fontSize * 0.03)
        return [
            .font: NSFont.systemFont(ofSize: annotation.fontSize, weight: .semibold),
            .foregroundColor: annotation.color,
            .shadow: shadow,
        ]
    }

    private static func drawCounter(_ annotation: Annotation, in ctx: CGContext) {
        let radius = counterRadius(for: annotation)
        let circle = CGRect(x: annotation.start.x - radius, y: annotation.start.y - radius,
                            width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -radius * 0.12),
                      blur: radius * 0.3,
                      color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(annotation.color.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()

        let label = "\(annotation.number)"
        let textColor: NSColor = annotation.color.isLight ? .black : .white
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius * 1.05, weight: .bold),
            .foregroundColor: textColor,
        ]
        let size = label.size(withAttributes: attributes)
        let origin = CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        label.draw(at: origin, withAttributes: attributes)
        NSGraphicsContext.current = previous
    }

    static func counterRadius(for annotation: Annotation) -> CGFloat {
        max(12, annotation.fontSize * 0.7)
    }

    // MARK: - Blur / pixelate patches

    /// Filtered patch of `base` for a blur/pixelate annotation. `rect` is in
    /// image space (bottom-left origin) and gets clamped to the image bounds.
    static func filteredPatch(base: CGImage, annotation: Annotation) -> (rect: CGRect, image: CGImage)? {
        let height = CGFloat(base.height)
        let width = CGFloat(base.width)
        let clamped = annotation.rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        // Convert bottom-left rect to CGImage's top-left cropping space.
        let cropRect = CGRect(x: clamped.minX, y: height - clamped.maxY,
                              width: clamped.width, height: clamped.height).integral
        guard let patch = base.cropping(to: cropRect) else { return nil }

        let input = CIImage(cgImage: patch)
        let output: CIImage
        switch annotation.kind {
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = input.clampedToExtent()
            filter.scale = Float(max(8, min(clamped.width, clamped.height) / 14))
            filter.center = CGPoint(x: input.extent.midX, y: input.extent.midY)
            guard let result = filter.outputImage else { return nil }
            output = result.cropped(to: input.extent)
        default:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(max(8, min(clamped.width, clamped.height) / 16))
            guard let result = filter.outputImage else { return nil }
            output = result.cropped(to: input.extent)
        }
        guard let cgOut = ciContext.createCGImage(output, from: input.extent) else { return nil }
        return (clamped, cgOut)
    }

    // MARK: - Bounds & hit testing

    static func boundingBox(of annotation: Annotation) -> CGRect {
        switch annotation.kind {
        case .arrow, .line:
            let pad = annotation.lineWidth * 2 + 4
            return annotation.rect.insetBy(dx: -pad, dy: -pad)
        case .rectangle, .ellipse:
            let pad = annotation.lineWidth / 2 + 2
            return annotation.rect.insetBy(dx: -pad, dy: -pad)
        case .blur, .pixelate:
            return annotation.rect
        case .pen, .highlighter:
            guard let first = annotation.points.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for point in annotation.points.dropFirst() {
                box = box.union(CGRect(origin: point, size: .zero))
            }
            let pad = annotation.lineWidth * (annotation.kind == .highlighter ? 2.5 : 1) + 2
            return box.insetBy(dx: -pad, dy: -pad)
        case .text:
            let size = annotation.text.isEmpty
                ? CGSize(width: 10, height: annotation.fontSize)
                : annotation.text.size(withAttributes: textAttributes(for: annotation))
            return CGRect(origin: annotation.start, size: size).insetBy(dx: -4, dy: -4)
        case .counter:
            let radius = counterRadius(for: annotation)
            return CGRect(x: annotation.start.x - radius, y: annotation.start.y - radius,
                          width: radius * 2, height: radius * 2)
        }
    }

    /// Topmost annotation containing `point`; `tolerance` is in image pixels.
    static func hitTest(_ point: CGPoint, annotations: [Annotation], tolerance: CGFloat) -> Annotation? {
        for annotation in annotations.reversed() {
            if hits(annotation, at: point, tolerance: tolerance) {
                return annotation
            }
        }
        return nil
    }

    private static func hits(_ annotation: Annotation, at point: CGPoint, tolerance: CGFloat) -> Bool {
        switch annotation.kind {
        case .arrow, .line:
            let reach = annotation.lineWidth * 1.6 + tolerance
            return distance(from: point, toSegment: annotation.start, annotation.end) <= reach
        case .pen, .highlighter:
            let width = annotation.lineWidth * (annotation.kind == .highlighter ? 2 : 0.5)
            let reach = width + tolerance
            guard annotation.points.count > 1 else {
                guard let only = annotation.points.first else { return false }
                return hypot(point.x - only.x, point.y - only.y) <= reach
            }
            for index in 0..<(annotation.points.count - 1) {
                if distance(from: point, toSegment: annotation.points[index], annotation.points[index + 1]) <= reach {
                    return true
                }
            }
            return false
        default:
            return boundingBox(of: annotation).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * abx + (point.y - a.y) * aby) / lengthSquared
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
        return hypot(point.x - proj.x, point.y - proj.y)
    }

    // MARK: - Flattening

    /// Base + filter patches + vector annotations at full resolution, then the
    /// background wrap. This is the single export path.
    static func flatten(base: CGImage,
                        annotations: [Annotation],
                        background: BackgroundStyle,
                        pixelScale: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))

        for annotation in annotations where annotation.isRegionFilter {
            if let patch = filteredPatch(base: base, annotation: annotation) {
                ctx.draw(patch.image, in: patch.rect)
            }
        }
        drawVectors(annotations, in: ctx)

        guard let flat = ctx.makeImage() else { return nil }
        return BackgroundStyler.wrap(flat, style: background, pixelScale: pixelScale)
    }
}

// MARK: - NSColor helpers

extension NSColor {
    /// Rough perceptual lightness check for choosing contrasting label colors.
    var isLight: Bool {
        guard let rgb = usingColorSpace(.deviceRGB) else { return false }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.65
    }
}
