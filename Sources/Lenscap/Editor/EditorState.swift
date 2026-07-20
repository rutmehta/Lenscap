import AppKit
import Combine
import UniformTypeIdentifiers

/// Shared document + tool state for one editor window. Owns the annotation
/// array, snapshot-based undo/redo, and the export actions.
@MainActor
final class EditorState: ObservableObject {
    // MARK: - Tool state

    @Published var tool: AnnotationTool = .arrow
    @Published var color: NSColor = .systemRed
    @Published var strokeWidth: CGFloat = 4
    @Published var fontSize: CGFloat = 24
    @Published var background = BackgroundStyle()

    // MARK: - Document state

    @Published var annotations: [Annotation] = []
    @Published var selectedID: UUID?
    @Published private(set) var baseImage: CGImage
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Points → pixels multiplier of the source image (2 for Retina captures
    /// saved with point metadata, 1 when point size == pixel size).
    let pixelScale: CGFloat
    var sourceURL: URL?
    weak var window: NSWindow?
    weak var canvas: AnnotationCanvasView?

    private struct Snapshot {
        let annotations: [Annotation]
        let baseImage: CGImage
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(baseImage: CGImage, pixelScale: CGFloat, sourceURL: URL?) {
        self.baseImage = baseImage
        self.pixelScale = pixelScale
        self.sourceURL = sourceURL
    }

    var baseSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    var selectedAnnotation: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    /// Template annotation carrying the current style, scaled to image pixels.
    func makeAnnotation(kind: Annotation.Kind, start: CGPoint, end: CGPoint) -> Annotation {
        var annotation = Annotation(kind: kind, start: start, end: end)
        annotation.color = color
        annotation.lineWidth = strokeWidth * pixelScale
        annotation.fontSize = fontSize * pixelScale
        return annotation
    }

    var nextCounterNumber: Int {
        (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }

    // MARK: - Undo / redo

    /// Call once before any mutation of annotations or the base image.
    func registerUndoSnapshot() {
        undoStack.append(Snapshot(annotations: annotations, baseImage: baseImage))
        redoStack.removeAll()
        if undoStack.count > 100 {
            undoStack.removeFirst()
        }
        updateUndoFlags()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, baseImage: baseImage))
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, baseImage: baseImage))
        restore(snapshot)
    }

    private func restore(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        baseImage = snapshot.baseImage
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Editing operations

    func deleteSelection() {
        guard let selectedID else { return }
        registerUndoSnapshot()
        annotations.removeAll { $0.id == selectedID }
        self.selectedID = nil
    }

    func updateAnnotation(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    /// Crops the base image to `rect` (image space, bottom-left origin) and
    /// shifts every annotation to match.
    func applyCrop(_ rect: CGRect) {
        let bounds = CGRect(origin: .zero, size: baseSize)
        let clamped = rect.intersection(bounds).integral
        guard clamped.width >= 2, clamped.height >= 2 else { return }
        // Convert to the CGImage's top-left cropping space.
        let cropRect = CGRect(x: clamped.minX,
                              y: CGFloat(baseImage.height) - clamped.maxY,
                              width: clamped.width,
                              height: clamped.height)
        guard let cropped = baseImage.cropping(to: cropRect) else { return }
        registerUndoSnapshot()
        baseImage = cropped
        let delta = CGPoint(x: -clamped.minX, y: -clamped.minY)
        for index in annotations.indices {
            annotations[index].translate(by: delta)
        }
    }

    // MARK: - Export

    func flattenedImage() -> CGImage? {
        AnnotationRenderer.flatten(base: baseImage,
                                   annotations: annotations,
                                   background: background,
                                   pixelScale: pixelScale)
    }

    func copyToClipboard() {
        guard let flat = flattenedImage(), let data = ImageWriter.pngData(flat) else {
            HUD.show("Copy failed")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        HUD.show("Copied to clipboard", symbol: "doc.on.clipboard")
    }

    func save() {
        guard let flat = flattenedImage() else {
            HUD.show("Save failed")
            return
        }
        let settings = SettingsStore.shared
        if let sourceURL {
            let format = sourceURL.pathExtension.lowercased() == "jpg" ? "jpg" : "png"
            guard let data = ImageWriter.encode(flat, format: format, jpegQuality: settings.jpegQuality),
                  (try? data.write(to: sourceURL)) != nil else {
                HUD.show("Save failed")
                return
            }
        } else {
            let directory = settings.saveDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let format = settings.fileFormat == "jpg" ? "jpg" : "png"
            let url = ImageWriter.newFileURL(in: directory, prefix: settings.filenamePrefix, ext: format)
            guard let data = ImageWriter.encode(flat, format: format, jpegQuality: settings.jpegQuality),
                  (try? data.write(to: url)) != nil else {
                HUD.show("Save failed")
                return
            }
            sourceURL = url
            window?.title = url.lastPathComponent
            HistoryStore.shared.add(url: url, kind: .screenshot)
        }
        HUD.show("Saved", symbol: "checkmark.circle")
    }

    func saveAs() {
        guard let flat = flattenedImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.directoryURL = SettingsStore.shared.saveDirectory
        panel.nameFieldStringValue = sourceURL?.lastPathComponent
            ?? ImageWriter.newFileURL(in: SettingsStore.shared.saveDirectory,
                                      prefix: SettingsStore.shared.filenamePrefix,
                                      ext: "png").lastPathComponent

        let complete: (URL) -> Void = { [weak self] url in
            let format = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
                ? "jpg" : "png"
            guard let data = ImageWriter.encode(flat, format: format,
                                                jpegQuality: SettingsStore.shared.jpegQuality),
                  (try? data.write(to: url)) != nil else {
                HUD.show("Save failed")
                return
            }
            self?.sourceURL = url
            self?.window?.title = url.lastPathComponent
            HUD.show("Saved", symbol: "checkmark.circle")
        }

        if let window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                complete(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            complete(url)
        }
    }

    /// Writes the flattened PNG to a temporary file, for drag-out.
    func writeDragFile() -> URL? {
        guard let flat = flattenedImage(), let data = ImageWriter.pngData(flat) else { return nil }
        let name = sourceURL?.deletingPathExtension().lastPathComponent ?? "Lenscap Annotation"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LenscapDrag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
