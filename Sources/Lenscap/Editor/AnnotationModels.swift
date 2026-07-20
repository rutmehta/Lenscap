import AppKit

// MARK: - Tools

/// Every tool selectable in the editor toolbar.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case line
    case rectangle
    case ellipse
    case pen
    case highlighter
    case text
    case counter
    case blur
    case pixelate
    case crop

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .blur: return "drop.halffull"
        case .pixelate: return "mosaic"
        case .crop: return "crop"
        }
    }

    var helpText: String {
        switch self {
        case .select: return "Select & Move (V)"
        case .arrow: return "Arrow (A)"
        case .line: return "Line (L)"
        case .rectangle: return "Rectangle (R)"
        case .ellipse: return "Ellipse (O)"
        case .pen: return "Freehand Pen (P)"
        case .highlighter: return "Highlighter (H)"
        case .text: return "Text (T)"
        case .counter: return "Counter Badge (N)"
        case .blur: return "Blur Region (B)"
        case .pixelate: return "Pixelate Region (X)"
        case .crop: return "Crop (C)"
        }
    }

    /// Lowercase keyboard shortcut, no modifiers.
    var shortcutKey: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .blur: return "b"
        case .pixelate: return "x"
        case .crop: return "c"
        }
    }
}

// MARK: - Annotation

/// A single annotation. All geometry lives in base-image pixel space with a
/// bottom-left origin (matching CoreGraphics), so exports are 1:1.
struct Annotation: Identifiable {
    enum Kind {
        case arrow
        case line
        case rectangle
        case ellipse
        case pen
        case highlighter
        case text
        case counter
        case blur
        case pixelate
    }

    let id: UUID
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var text: String = ""
    var fontSize: CGFloat = 24
    var number: Int = 1

    init(kind: Kind, start: CGPoint, end: CGPoint) {
        self.id = UUID()
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// Normalized rect spanned by start/end.
    var rect: CGRect {
        CGRect(x: min(start.x, end.x),
               y: min(start.y, end.y),
               width: abs(start.x - end.x),
               height: abs(start.y - end.y))
    }

    var isRegionFilter: Bool {
        kind == .blur || kind == .pixelate
    }

    mutating func translate(by delta: CGPoint) {
        start.x += delta.x
        start.y += delta.y
        end.x += delta.x
        end.y += delta.y
        for index in points.indices {
            points[index].x += delta.x
            points[index].y += delta.y
        }
    }
}
