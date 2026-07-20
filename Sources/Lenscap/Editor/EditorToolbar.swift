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
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                toolGroup([.select, .arrow, .line, .rectangle, .ellipse, .pen, .highlighter])

                groupDivider

                toolGroup([.text, .counter])

                groupDivider

                toolGroup([.blur, .pixelate])

                groupDivider

                HStack(spacing: 2) {
                    toolButton(.crop)
                    backgroundButton
                }

                groupDivider

                HStack(spacing: 2) {
                    historyButton("arrow.uturn.backward", enabled: state.canUndo,
                                  help: "Undo (⌘Z)") { state.undo() }
                    historyButton("arrow.uturn.forward", enabled: state.canRedo,
                                  help: "Redo (⇧⌘Z)") { state.redo() }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Button("Copy") { state.copyToClipboard() }
                        .help("Copy flattened image (⌘C)")
                    Button("Save") { state.save() }
                        .help("Save (⌘S)")
                    Button("Save As…") { state.saveAs() }
                        .help("Save As (⇧⌘S)")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                DragThumbnail(state: state)
                    .frame(width: 44, height: 28)
                    .help("Drag the annotated image out as a PNG file")
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                        swatchButton(swatch)
                    }
                }

                Button {
                    ColorPanelBridge.shared.open(for: state)
                } label: {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("More colors…")

                groupDivider

                sliderCluster(symbol: "lineweight",
                              help: "Stroke width",
                              value: Binding(get: { Double(state.strokeWidth) },
                                             set: { state.strokeWidth = CGFloat($0) }),
                              range: 2...10,
                              display: Int(state.strokeWidth))

                groupDivider

                sliderCluster(symbol: "textformat.size",
                              help: "Text & counter size",
                              value: Binding(get: { Double(state.fontSize) },
                                             set: { state.fontSize = CGFloat($0) }),
                              range: 10...72,
                              display: Int(state.fontSize))

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var groupDivider: some View {
        Divider().frame(height: 18)
    }

    private func toolGroup(_ tools: [AnnotationTool]) -> some View {
        HStack(spacing: 2) {
            ForEach(tools) { tool in
                toolButton(tool)
            }
        }
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let isSelected = state.tool == tool
        return Button {
            state.tool = tool
        } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .help(tool.helpText)
    }

    private func historyButton(_ symbol: String, enabled: Bool, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }

    private func sliderCluster(symbol: String, help: String,
                               value: Binding<Double>,
                               range: ClosedRange<Double>,
                               display: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: 1)
                .controlSize(.small)
                .frame(width: 104)
                .help(help)
            Text("\(display)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
        }
    }

    private var backgroundButton: some View {
        let isActive = state.background.isEnabled
        return Button {
            showsBackgroundPopover.toggle()
        } label: {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor : Color.clear)
        )
        .animation(.easeOut(duration: 0.15), value: isActive)
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
                .frame(width: 15, height: 15)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 1.5 : 0)
                        .padding(-3)
                )
                .frame(width: 21, height: 21)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
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

            HStack(spacing: 8) {
                Text("Padding")
                    .frame(width: 56, alignment: .leading)
                Slider(value: Binding(get: { Double(state.background.padding) },
                                      set: { state.background.padding = CGFloat($0) }),
                       in: 0...120)
                    .controlSize(.small)
                Text("\(Int(state.background.padding))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("Corners")
                    .frame(width: 56, alignment: .leading)
                Slider(value: Binding(get: { Double(state.background.cornerRadius) },
                                      set: { state.background.cornerRadius = CGFloat($0) }),
                       in: 0...24)
                    .controlSize(.small)
                Text("\(Int(state.background.cornerRadius))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
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
