import AppKit
import Combine
import SwiftUI

/// The editing surface: shows the (optionally beautified) screenshot fit to the
/// window, routes mouse input to the active tool, and draws annotations live.
/// Geometry note: annotations live in image-pixel space (bottom-left origin);
/// this view converts to/from view points via `geometry()`.
@MainActor
final class AnnotationCanvasView: NSView {
    private let state: EditorState
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Interaction state

    private enum DragAction {
        case none
        case draw
        case move
        case cropDraw
        case cropMove
    }

    private var dragAction: DragAction = .none
    private var draft: Annotation?
    private var lastDragPoint: CGPoint = .zero
    private var cropAnchor: CGPoint = .zero
    private var hasMovedSelection = false

    /// Pending crop rect in image space, nil when no crop is in progress.
    private var cropRect: CGRect?

    // MARK: - Text editing state

    private var textField: NSTextField?
    private var editingAnnotationID: UUID?
    private var pendingTextOrigin: CGPoint = .zero

    // MARK: - Filter patch cache

    private var patchCache: [UUID: (rect: CGRect, image: CGImage)] = [:]
    private var cachedBase: CGImage?

    // MARK: - Init

    init(state: EditorState) {
        self.state = state
        super.init(frame: .zero)
        state.canvas = self
        wantsLayer = true

        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &cancellables)

        state.$tool
            .removeDuplicates()
            .sink { [weak self] tool in
                guard let self else { return }
                self.commitTextEditing()
                if tool != .crop { self.cropRect = nil }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: state.tool == .select ? .arrow : .crosshair)
    }

    // MARK: - Geometry

    struct Geometry {
        let scale: CGFloat
        /// Full styled output (background + padding) in view coordinates.
        let outputRect: CGRect
        /// The screenshot area in view coordinates.
        let screenshotRect: CGRect
    }

    func geometry() -> Geometry {
        let outputSize = BackgroundStyler.outputSize(for: state.baseSize,
                                                     style: state.background,
                                                     pixelScale: state.pixelScale)
        let inset = bounds.insetBy(dx: 16, dy: 16)
        guard inset.width > 10, inset.height > 10, outputSize.width > 0, outputSize.height > 0 else {
            return Geometry(scale: 1, outputRect: bounds, screenshotRect: bounds)
        }
        let scale = min(inset.width / outputSize.width, inset.height / outputSize.height, 1)
        let size = CGSize(width: outputSize.width * scale, height: outputSize.height * scale)
        let outputRect = CGRect(x: bounds.midX - size.width / 2,
                                y: bounds.midY - size.height / 2,
                                width: size.width, height: size.height)
        let pad = state.background.padding * state.pixelScale * scale
        let screenshotRect = CGRect(x: outputRect.minX + pad,
                                    y: outputRect.minY + pad,
                                    width: state.baseSize.width * scale,
                                    height: state.baseSize.height * scale)
        return Geometry(scale: scale, outputRect: outputRect, screenshotRect: screenshotRect)
    }

    private func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        let g = geometry()
        return CGPoint(x: (viewPoint.x - g.screenshotRect.minX) / g.scale,
                       y: (viewPoint.y - g.screenshotRect.minY) / g.scale)
    }

    private func viewPoint(from imagePoint: CGPoint) -> CGPoint {
        let g = geometry()
        return CGPoint(x: g.screenshotRect.minX + imagePoint.x * g.scale,
                       y: g.screenshotRect.minY + imagePoint.y * g.scale)
    }

    private func viewRect(from imageRect: CGRect) -> CGRect {
        let g = geometry()
        return CGRect(x: g.screenshotRect.minX + imageRect.minX * g.scale,
                      y: g.screenshotRect.minY + imageRect.minY * g.scale,
                      width: imageRect.width * g.scale,
                      height: imageRect.height * g.scale)
    }

    private func clampToImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), state.baseSize.width),
                y: min(max(0, point.y), state.baseSize.height))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let g = geometry()

        ctx.saveGState()
        ctx.translateBy(x: g.outputRect.minX, y: g.outputRect.minY)
        ctx.scaleBy(x: g.scale, y: g.scale)
        ctx.interpolationQuality = .high
        BackgroundStyler.draw(screenshot: state.baseImage,
                              style: state.background,
                              pixelScale: state.pixelScale,
                              in: ctx)

        // Enter screenshot/annotation space.
        let padPx = state.background.padding * state.pixelScale
        ctx.translateBy(x: padPx, y: padPx)

        // Clip annotations to the same rounded image rect the export uses
        // (flatten renders into a base-sized context, then wrap applies the
        // rounded-corner mask), so preview and export match at the edges.
        let imageRect = CGRect(origin: .zero, size: state.baseSize)
        let clipRadius = min(state.background.cornerRadius * state.pixelScale,
                             min(imageRect.width, imageRect.height) / 2)
        ctx.addPath(CGPath(roundedRect: imageRect,
                           cornerWidth: clipRadius, cornerHeight: clipRadius,
                           transform: nil))
        ctx.clip()

        if !patchCache.isEmpty {
            // Evict patches for deleted/undone annotations.
            let live = Set(state.annotations.lazy.filter(\.isRegionFilter).map(\.id))
            if patchCache.count > live.count {
                patchCache = patchCache.filter { live.contains($0.key) }
            }
        }
        for annotation in state.annotations where annotation.isRegionFilter {
            if let patch = patch(for: annotation) {
                ctx.draw(patch.image, in: patch.rect)
            }
        }

        let visible = state.annotations.filter { $0.id != editingAnnotationID }
        AnnotationRenderer.drawVectors(visible, in: ctx)

        if let draft {
            if draft.isRegionFilter {
                drawFilterDraft(draft, in: ctx, scale: g.scale)
            } else {
                AnnotationRenderer.draw(draft, in: ctx)
            }
        }
        ctx.restoreGState()

        drawSelectionChrome()
        drawCropChrome()
    }

    private func drawFilterDraft(_ draft: Annotation, in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor(NSColor.systemGray.withAlphaComponent(0.35).cgColor)
        ctx.fill(draft.rect)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5 / scale)
        ctx.setLineDash(phase: 0, lengths: [5 / scale, 4 / scale])
        ctx.stroke(draft.rect)
        ctx.restoreGState()
    }

    private func drawSelectionChrome() {
        guard let selected = state.selectedAnnotation else { return }
        let box = viewRect(from: AnnotationRenderer.boundingBox(of: selected)).insetBy(dx: -3, dy: -3)
        let path = NSBezierPath(rect: box)
        path.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.stroke()
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.white.setStroke()
        path.stroke()
    }

    private func drawCropChrome() {
        guard let cropRect else { return }
        let cropView = viewRect(from: cropRect)
        let g = geometry()

        let dim = NSBezierPath(rect: g.screenshotRect)
        dim.appendRect(cropView)
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        dim.fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: cropView)
        border.lineWidth = 1.5
        border.stroke()

        let hint = "⏎ crop   ⎋ cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attributes)
        var origin = CGPoint(x: cropView.midX - size.width / 2, y: cropView.minY - size.height - 8)
        if origin.y < 4 { origin.y = cropView.minY + 6 }
        let background = CGRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 5, yRadius: 5).fill()
        hint.draw(at: origin, withAttributes: attributes)
    }

    // MARK: - Filter patches

    private func patch(for annotation: Annotation) -> (rect: CGRect, image: CGImage)? {
        if cachedBase !== state.baseImage {
            patchCache.removeAll()
            cachedBase = state.baseImage
        }
        if let cached = patchCache[annotation.id], cached.rect == annotation.rect {
            return cached
        }
        guard let fresh = AnnotationRenderer.filteredPatch(base: state.baseImage, annotation: annotation) else {
            return nil
        }
        patchCache[annotation.id] = fresh
        return fresh
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let image = imagePoint(from: point)

        switch state.tool {
        case .select:
            let tolerance = 6 / max(0.01, geometry().scale)
            let hit = AnnotationRenderer.hitTest(image, annotations: state.annotations, tolerance: tolerance)
            if event.clickCount == 2, let hit, hit.kind == .text {
                beginTextEditing(at: hit.start, existing: hit)
                return
            }
            if let hit {
                state.selectedID = hit.id
                dragAction = .move
                lastDragPoint = image
                hasMovedSelection = false
            } else {
                state.selectedID = nil
            }
        case .text:
            beginTextEditing(at: clampToImage(image), existing: nil)
        case .counter:
            state.registerUndoSnapshot()
            var badge = state.makeAnnotation(kind: .counter, start: clampToImage(image), end: clampToImage(image))
            badge.number = state.nextCounterNumber
            state.annotations.append(badge)
        case .crop:
            if let cropRect, cropRect.contains(image) {
                dragAction = .cropMove
                lastDragPoint = image
            } else {
                cropAnchor = clampToImage(image)
                cropRect = CGRect(origin: cropAnchor, size: .zero)
                dragAction = .cropDraw
            }
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .blur, .pixelate:
            var annotation = state.makeAnnotation(kind: drawingKind(for: state.tool), start: image, end: image)
            if annotation.kind == .pen || annotation.kind == .highlighter {
                annotation.points = [image]
            }
            draft = annotation
            dragAction = .draw
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let image = imagePoint(from: point)
        let shift = event.modifierFlags.contains(.shift)

        switch dragAction {
        case .draw:
            guard var draft else { return }
            if draft.kind == .pen || draft.kind == .highlighter {
                draft.points.append(image)
            } else {
                let end = draft.isRegionFilter ? clampToImage(image) : image
                draft.end = constrained(end, from: draft.start, shift: shift, kind: draft.kind)
            }
            self.draft = draft
        case .move:
            guard let selectedID = state.selectedID,
                  let index = state.annotations.firstIndex(where: { $0.id == selectedID }) else { return }
            if !hasMovedSelection {
                state.registerUndoSnapshot()
                hasMovedSelection = true
            }
            let delta = CGPoint(x: image.x - lastDragPoint.x, y: image.y - lastDragPoint.y)
            state.annotations[index].translate(by: delta)
            lastDragPoint = image
        case .cropDraw:
            let clamped = clampToImage(image)
            cropRect = CGRect(x: min(cropAnchor.x, clamped.x),
                              y: min(cropAnchor.y, clamped.y),
                              width: abs(cropAnchor.x - clamped.x),
                              height: abs(cropAnchor.y - clamped.y))
        case .cropMove:
            guard var rect = cropRect else { return }
            rect.origin.x += image.x - lastDragPoint.x
            rect.origin.y += image.y - lastDragPoint.y
            rect.origin.x = min(max(0, rect.origin.x), max(0, state.baseSize.width - rect.width))
            rect.origin.y = min(max(0, rect.origin.y), max(0, state.baseSize.height - rect.height))
            cropRect = rect
            lastDragPoint = image
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragAction = .none
            draft = nil
            needsDisplay = true
        }
        if dragAction == .cropDraw, let rect = cropRect, rect.width <= 3 || rect.height <= 3 {
            cropRect = nil // A plain click; don't leave a zero-size crop dimming everything.
        }
        guard dragAction == .draw, let draft else { return }

        let meaningful: Bool
        switch draft.kind {
        case .pen, .highlighter:
            meaningful = draft.points.count > 1
        case .arrow, .line:
            meaningful = hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) > 3
        default:
            meaningful = draft.rect.width > 3 && draft.rect.height > 3
        }
        guard meaningful else { return }
        state.registerUndoSnapshot()
        state.annotations.append(draft)
    }

    private func drawingKind(for tool: AnnotationTool) -> Annotation.Kind {
        switch tool {
        case .arrow: return .arrow
        case .line: return .line
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .blur: return .blur
        case .pixelate: return .pixelate
        default: return .rectangle
        }
    }

    /// Shift constraints: 45° snapping for lines/arrows, squares for rects & co.
    private func constrained(_ end: CGPoint, from start: CGPoint, shift: Bool, kind: Annotation.Kind) -> CGPoint {
        guard shift else { return end }
        switch kind {
        case .line, .arrow:
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0 else { return end }
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        case .rectangle, .ellipse, .blur, .pixelate:
            let dx = end.x - start.x
            let dy = end.y - start.y
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side),
                           y: start.y + (dy < 0 ? -side : side))
        default:
            return end
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            if cropRect != nil {
                cropRect = nil
            } else {
                state.selectedID = nil
            }
            needsDisplay = true
            return
        case 51, 117: // Delete / forward delete
            state.deleteSelection()
            return
        case 36, 76: // Return / keypad Enter
            if let cropRect {
                state.applyCrop(cropRect)
                self.cropRect = nil
                needsDisplay = true
                return
            }
        default:
            break
        }

        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let character = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = AnnotationTool.allCases.first(where: { $0.shortcutKey == character }) {
            state.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let the inline text editor keep its own key handling.
        guard textField == nil else { return super.performKeyEquivalent(with: event) }
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        switch key {
        case "z":
            shift ? state.redo() : state.undo()
            return true
        case "c":
            state.copyToClipboard()
            return true
        case "s":
            shift ? state.saveAs() : state.save()
            return true
        case "w":
            window?.performClose(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Inline text editing

    func beginTextEditing(at imageOrigin: CGPoint, existing: Annotation?) {
        commitTextEditing()
        let g = geometry()
        pendingTextOrigin = existing?.start ?? imageOrigin
        editingAnnotationID = existing?.id

        let imageFontSize = existing?.fontSize ?? state.fontSize * state.pixelScale
        let viewFontSize = max(9, imageFontSize * g.scale)

        let field = NSTextField(string: existing?.text ?? "")
        field.font = .systemFont(ofSize: viewFontSize, weight: .semibold)
        field.textColor = existing?.color ?? state.color
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        field.focusRingType = .exterior
        field.usesSingleLineMode = true
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldCommitted)

        let origin = viewPoint(from: pendingTextOrigin)
        field.frame = NSRect(x: origin.x - 2, y: origin.y - 4,
                             width: max(140, field.intrinsicContentSize.width + 20),
                             height: viewFontSize * 1.35 + 8)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        needsDisplay = true
    }

    @objc private func textFieldCommitted() {
        commitTextEditing()
    }

    func commitTextEditing() {
        guard let field = textField else { return }
        // Detach before mutating state so end-editing notifications can't re-enter.
        textField = nil
        let editingID = editingAnnotationID
        editingAnnotationID = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)

        if let editingID, let existing = state.annotations.first(where: { $0.id == editingID }) {
            if text != existing.text {
                state.registerUndoSnapshot()
                if text.isEmpty {
                    state.annotations.removeAll { $0.id == editingID }
                    if state.selectedID == editingID { state.selectedID = nil }
                } else {
                    var updated = existing
                    updated.text = text
                    state.updateAnnotation(updated)
                }
            }
        } else if !text.isEmpty {
            state.registerUndoSnapshot()
            var annotation = state.makeAnnotation(kind: .text, start: pendingTextOrigin, end: pendingTextOrigin)
            annotation.text = text
            state.annotations.append(annotation)
        }
        needsDisplay = true
    }

    private func cancelTextEditing() {
        guard let field = textField else { return }
        textField = nil
        editingAnnotationID = nil
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

// MARK: - NSTextFieldDelegate

extension AnnotationCanvasView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEditing()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        var frame = field.frame
        frame.size.width = max(140, field.intrinsicContentSize.width + 20)
        field.frame = frame
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }
}

// MARK: - SwiftUI bridge

struct AnnotationCanvasRepresentable: NSViewRepresentable {
    let state: EditorState

    func makeNSView(context: Context) -> AnnotationCanvasView {
        AnnotationCanvasView(state: state)
    }

    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {
        nsView.needsDisplay = true
    }
}
