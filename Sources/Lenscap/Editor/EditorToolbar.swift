import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Toolbar

/// Top toolbar: tools, colors, stroke/font sliders, background popover,
/// undo/redo, and export actions.
struct EditorToolbar: View {
    @ObservedObject var state: EditorState
    @State private var showsBackgroundPopover = false

    private static let swatches: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .black, .white,
    ]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { tool in
                    toolButton(tool)
                }

                Divider().frame(height: 20).padding(.horizontal, 6)

                backgroundButton

                Divider().frame(height: 20).padding(.horizontal, 6)

                Button {
                    state.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!state.canUndo)
                .help("Undo (⌘Z)")

                Button {
                    state.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(.borderless)
                .disabled(!state.canRedo)
                .help("Redo (⇧⌘Z)")

                Spacer(minLength: 8)

                Button("Copy") { state.copyToClipboard() }
                    .help("Copy flattened image (⌘C)")
                Button("Save") { state.save() }
                    .help("Save (⌘S)")
                Button("Save As…") { state.saveAs() }
                    .help("Save As (⇧⌘S)")

                DragThumbnail(state: state)
                    .frame(width: 44, height: 28)
                    .help("Drag the annotated image out as a PNG file")
            }

            HStack(spacing: 10) {
                ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                    swatchButton(swatch)
                }

                Button {
                    ColorPanelBridge.shared.open(for: state)
                } label: {
                    Image(systemName: "paintpalette")
                }
                .buttonStyle(.borderless)
                .help("More colors…")

                Divider().frame(height: 18)

                Image(systemName: "lineweight")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(state.strokeWidth) },
                                      set: { state.strokeWidth = CGFloat($0) }),
                       in: 2...10, step: 1)
                    .frame(width: 110)
                    .help("Stroke width")
                Text("\(Int(state.strokeWidth))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Divider().frame(height: 18)

                Image(systemName: "textformat.size")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(state.fontSize) },
                                      set: { state.fontSize = CGFloat($0) }),
                       in: 10...72, step: 1)
                    .frame(width: 110)
                    .help("Text & counter size")
                Text("\(Int(state.fontSize))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button {
            state.tool = tool
        } label: {
            Image(systemName: tool.symbolName)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(state.tool == tool ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .help(tool.helpText)
    }

    private var backgroundButton: some View {
        Button {
            showsBackgroundPopover.toggle()
        } label: {
            Image(systemName: "sparkles.rectangle.stack")
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(state.background.isEnabled ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .help("Background & padding")
        .popover(isPresented: $showsBackgroundPopover, arrowEdge: .bottom) {
            BackgroundStylePanel(state: state)
        }
    }

    private func swatchButton(_ swatch: NSColor) -> some View {
        let isSelected = state.color == swatch
        return Button {
            state.color = swatch
        } label: {
            Circle()
                .fill(Color(nsColor: swatch))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Background popover

struct BackgroundStylePanel: View {
    @ObservedObject var state: EditorState

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(BackgroundPreset.allCases) { preset in
                    presetSwatch(preset)
                }
            }

            HStack {
                Text("Padding")
                Slider(value: Binding(get: { Double(state.background.padding) },
                                      set: { state.background.padding = CGFloat($0) }),
                       in: 0...120)
                Text("\(Int(state.background.padding))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
            }

            HStack {
                Text("Corners")
                Slider(value: Binding(get: { Double(state.background.cornerRadius) },
                                      set: { state.background.cornerRadius = CGFloat($0) }),
                       in: 0...24)
                Text("\(Int(state.background.cornerRadius))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
            }

            Toggle("Shadow", isOn: $state.background.shadow)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func presetSwatch(_ preset: BackgroundPreset) -> some View {
        let isSelected = state.background.preset == preset
        return Button {
            state.background.preset = preset
            if preset != .none && state.background.padding == 0 {
                state.background.padding = 32
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(gradient(for: preset))
                if preset == .none {
                    Image(systemName: "slash.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(preset.displayName)
    }

    private func gradient(for preset: BackgroundPreset) -> LinearGradient {
        let colors = preset.colors.map { Color(nsColor: $0) }
        guard !colors.isEmpty else {
            return LinearGradient(colors: [Color(nsColor: .quaternaryLabelColor)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: colors.count == 1 ? [colors[0], colors[0]] : colors,
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Color panel bridge

/// Routes NSColorPanel changes into whichever editor most recently opened it.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private weak var state: EditorState?

    func open(for state: EditorState) {
        self.state = state
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = state.color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        state?.color = sender.color
    }
}

// MARK: - Drag-out thumbnail

/// Small live thumbnail that can be dragged out of the window, delivering the
/// flattened PNG as a temp-file URL drag.
struct DragThumbnail: NSViewRepresentable {
    let state: EditorState

    func makeNSView(context: Context) -> DragThumbnailView {
        DragThumbnailView(state: state)
    }

    func updateNSView(_ nsView: DragThumbnailView, context: Context) {
        nsView.needsDisplay = true
    }
}

@MainActor
final class DragThumbnailView: NSView, NSDraggingSource {
    private let state: EditorState

    init(state: EditorState) {
        self.state = state
        super.init(frame: .zero)
        toolTip = "Drag out as PNG"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
        NSColor.tertiaryLabelColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let base = state.baseImage
        let imageSize = CGSize(width: base.width, height: base.height)
        let inner = box.insetBy(dx: 4, dy: 4)
        guard inner.width > 2, inner.height > 2 else { return }
        let scale = min(inner.width / imageSize.width, inner.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = CGRect(x: inner.midX - drawSize.width / 2,
                              y: inner.midY - drawSize.height / 2,
                              width: drawSize.width, height: drawSize.height)
        NSGraphicsContext.current?.cgContext.interpolationQuality = .medium
        NSGraphicsContext.current?.cgContext.draw(base, in: drawRect)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url = state.writeDragFile() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let dragImage = NSImage(cgImage: state.baseImage,
                                size: NSSize(width: 96, height: 96 * CGFloat(state.baseImage.height) / CGFloat(max(1, state.baseImage.width))))
        item.setDraggingFrame(bounds, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
