import SwiftUI
import AppKit

/// Bridges the AppKit canvas into SwiftUI and republishes the bits the chrome
/// needs (tool, style, selection, zoom) as observable state.
final class CanvasController: ObservableObject, CanvasViewDelegate {
    let view = CanvasView()

    /// Set while mirroring the canvas's own state back into the panel, so the
    /// echo doesn't get re-applied to the selection.
    private var isSyncing = false

    @Published var tool: CanvasTool = .select {
        didSet { if !isSyncing { view.tool = tool } }
    }
    @Published var style = DrawStyle() {
        didSet { if !isSyncing { view.applyStyleToSelection(style) } }
    }
    @Published var hasSelection = false
    @Published var zoom: CGFloat = 1
    @Published var showGrid = true { didSet { view.showGrid = showGrid } }
    @Published var lockTool = false

    var onChange: ((Drawing) -> Void)?

    init(drawing: Drawing = Drawing()) {
        view.drawing = drawing
        view.delegate = self
        view.style = style
    }

    func load(_ drawing: Drawing) {
        view.drawing = drawing
        view.selection = []
        hasSelection = false
    }

    var drawing: Drawing { view.drawing }

    func canvasDidChange(_ canvas: CanvasView) {
        onChange?(canvas.drawing)
        objectWillChange.send()
    }

    func canvasDidChangeSelection(_ canvas: CanvasView) {
        isSyncing = true
        defer { isSyncing = false }

        hasSelection = !canvas.selection.isEmpty
        zoom = canvas.zoomLevel
        if tool != canvas.tool { tool = canvas.tool }

        // Mirror the selected element's style into the panel.
        if let first = canvas.drawing.elements.first(where: { canvas.selection.contains($0.id) }) {
            var s = style
            s.strokeColor = first.strokeColor
            s.fillColor = first.fillColor
            s.fillStyle = first.fillStyle
            s.strokeStyle = first.strokeStyle
            s.strokeWidth = first.strokeWidth
            s.roughness = first.roughness
            s.edges = first.edges
            s.opacity = first.opacity
            s.fontSize = first.fontSize
            if s != style {
                style = s
                view.style = s
            }
        }
        objectWillChange.send()
    }

    func canvasDidFinishCreating(_ canvas: CanvasView) {
        if !lockTool && tool != .select && tool != .hand && tool != .eraser {
            tool = .select
        }
        objectWillChange.send()
    }

    // Command passthroughs
    func undo() { view.undo() }
    func redo() { view.redo() }
    func deleteSelection() { view.deleteSelection() }
    func duplicateSelection() { view.duplicateSelection() }
    func bringForward() { view.bringForward() }
    func sendBackward() { view.sendBackward() }
    func zoomToFit() { view.zoomToFit(); zoom = view.zoomLevel }
    func setZoom(_ z: CGFloat) { view.setZoom(z); zoom = view.zoomLevel }
    func focus() { view.window?.makeFirstResponder(view) }
}

private struct CanvasRepresentable: NSViewRepresentable {
    let controller: CanvasController

    func makeNSView(context: Context) -> CanvasView {
        let v = controller.view
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

// MARK: - The editor

struct DrawingEditor: View {
    @ObservedObject var controller: CanvasController
    /// Drives the staggered entrance of the floating islands.
    var chromeIn: Bool = true
    var onDone: (() -> Void)?
    var title: String = "Drawing"

    @State private var showProperties = true

    private var propertiesVisible: Bool {
        showProperties && (controller.hasSelection || controller.tool.createsElement)
    }

    var body: some View {
        ZStack(alignment: .top) {
            CanvasRepresentable(controller: controller)
                .ignoresSafeArea()

            // Floating chrome, Excalidraw-style islands over the canvas.
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    if propertiesVisible {
                        PropertiesPanel(controller: controller)
                            .frame(width: 208)
                            .opacity(chromeIn ? 1 : 0)
                            .offset(x: chromeIn ? 0 : -22)
                            .animation(Motion.spring.delay(0.10), value: chromeIn)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 60)
                .padding(.horizontal, 14)

                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                ToolbarIsland(controller: controller, chromeIn: chromeIn,
                              onDone: onDone, title: title)
                    .padding(.top, 12)
                    .opacity(chromeIn ? 1 : 0)
                    .offset(y: chromeIn ? 0 : -18)
                    .animation(Motion.spring, value: chromeIn)
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    ZoomIsland(controller: controller)
                    HistoryIsland(controller: controller)
                    Spacer(minLength: 0)
                    HintBar(tool: controller.tool)
                }
                .padding(14)
                .opacity(chromeIn ? 1 : 0)
                .offset(y: chromeIn ? 0 : 16)
                .animation(Motion.spring.delay(0.16), value: chromeIn)
            }
        }
        .background(Theme.sPanel)
        .animation(.easeOut(duration: 0.16), value: propertiesVisible)
        .onAppear { controller.focus() }
    }
}

// MARK: - Islands

private struct Island<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.sRaised.opacity(0.94))
                    .shadow(color: .black.opacity(0.5), radius: 22, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

private struct ToolbarIsland: View {
    @ObservedObject var controller: CanvasController
    var chromeIn: Bool = true
    var onDone: (() -> Void)?
    var title: String

    var body: some View {
        Island {
            HStack(spacing: 2) {
                ForEach(Array(CanvasTool.allCases.enumerated()), id: \.element) { index, tool in
                    ToolButton(tool: tool, isActive: controller.tool == tool) {
                        controller.tool = tool
                        controller.focus()
                    }
                    .opacity(chromeIn ? 1 : 0)
                    .scaleEffect(chromeIn ? 1 : 0.7)
                    .animation(Motion.spring.delay(0.05 + Double(index) * 0.022), value: chromeIn)
                    if tool == .hand || tool == .line {
                        Divider().frame(height: 20).padding(.horizontal, 4)
                    }
                }

                Divider().frame(height: 20).padding(.horizontal, 4)

                IconToggle(symbol: "grid", isOn: controller.showGrid, help: "Grid") {
                    controller.showGrid.toggle()
                }
                IconToggle(symbol: "lock", isOn: controller.lockTool, help: "Keep tool selected") {
                    controller.lockTool.toggle()
                }

                if let onDone {
                    Divider().frame(height: 20).padding(.horizontal, 4)
                    Button(action: onDone) {
                        Text("Done")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.sAccent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ToolButton: View {
    let tool: CanvasTool
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Theme.sAccent
                                   : (hovering ? Theme.sHover : Color.clear))
                Image(systemName: tool.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? Color(Theme.windowBG) : Theme.sTextSecondary)
                Text(tool.key)
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(isActive ? Color(Theme.windowBG).opacity(0.75)
                                              : Theme.sTextFaint)
                    .offset(x: 10, y: 9)
            }
            .frame(width: 33, height: 32)
            .animation(Motion.snappy, value: isActive)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(tool.title) — \(tool.key)")
    }
}

private struct IconToggle: View {
    let symbol: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? Theme.sAccent.opacity(0.16) : (hovering ? Theme.sHover : Color.clear))
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isOn ? Theme.sAccent : Theme.sTextSecondary)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct ZoomIsland: View {
    @ObservedObject var controller: CanvasController

    var body: some View {
        Island {
            HStack(spacing: 2) {
                smallButton("minus") { controller.setZoom(controller.zoom - 0.1) }
                Button {
                    controller.setZoom(1)
                } label: {
                    Text("\(Int(controller.zoom * 100))%")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.sTextSecondary)
                        .frame(width: 46)
                }
                .buttonStyle(.plain)
                .help("Reset zoom")
                smallButton("plus") { controller.setZoom(controller.zoom + 0.1) }
                Divider().frame(height: 16).padding(.horizontal, 2)
                smallButton("arrow.up.left.and.arrow.down.right") { controller.zoomToFit() }
            }
        }
    }

    private func smallButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.sTextSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HistoryIsland: View {
    @ObservedObject var controller: CanvasController

    var body: some View {
        Island {
            HStack(spacing: 2) {
                Button { controller.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.sTextSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Undo — ⌘Z")

                Button { controller.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.sTextSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Redo — ⇧⌘Z")
            }
        }
    }
}

private struct HintBar: View {
    let tool: CanvasTool

    private var hint: String {
        switch tool {
        case .select:   return "Drag to marquee · ⇧ multi-select · ⌥ drag to pan"
        case .hand:     return "Drag to pan · space also pans"
        case .freedraw: return "Draw freehand"
        case .text:     return "Click to place text · double-click to edit"
        case .eraser:   return "Drag across shapes to erase"
        case .line, .arrow: return "⇧ snaps to 15°"
        default:        return "⇧ constrains to a square"
        }
    }

    var body: some View {
        Text(hint)
            .font(.system(size: 11))
            .foregroundStyle(Theme.sTextTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Theme.sRaised.opacity(0.9))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Properties

private struct PropertiesPanel: View {
    @ObservedObject var controller: CanvasController

    private var style: Binding<DrawStyle> {
        Binding(get: { controller.style }, set: { controller.style = $0 })
    }

    var body: some View {
        Island {
            VStack(alignment: .leading, spacing: 14) {
                SwatchRow(title: "Stroke", colors: Palette.strokes, selected: style.strokeColor)
                SwatchRow(title: "Background", colors: Palette.fills, selected: style.fillColor)

                if style.wrappedValue.fillColor != "transparent" {
                    OptionRow(title: "Fill", options: [
                        ("scribble", FillStyle.hachure), ("number", FillStyle.crossHatch),
                        ("square.fill", FillStyle.solid)
                    ], selection: style.fillStyle)
                }

                OptionRow(title: "Stroke width", options: [
                    ("minus", CGFloat(1)), ("equal", CGFloat(2.5)), ("text.justify", CGFloat(4.5))
                ], selection: style.strokeWidth)

                OptionRow(title: "Stroke style", options: [
                    ("minus", StrokeStyle.solid), ("ellipsis", StrokeStyle.dashed),
                    ("circle.dotted", StrokeStyle.dotted)
                ], selection: style.strokeStyle)

                OptionRow(title: "Sloppiness", options: [
                    ("pencil.line", CGFloat(0.5)), ("pencil", CGFloat(1.4)), ("scribble.variable", CGFloat(2.6))
                ], selection: style.roughness)

                OptionRow(title: "Edges", options: [
                    ("square", EdgeStyle.sharp), ("square.dashed", EdgeStyle.round)
                ], selection: style.edges)

                OptionRow(title: "Font size", options: [
                    ("textformat.size.smaller", CGFloat(15)), ("textformat.size", CGFloat(20)),
                    ("textformat.size.larger", CGFloat(30))
                ], selection: style.fontSize)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Opacity").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.sTextSecondary)
                    Slider(value: style.opacity, in: 0.1...1)
                        .controlSize(.mini)
                }

                if controller.hasSelection {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Actions").font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.sTextSecondary)
                        HStack(spacing: 4) {
                            actionButton("square.3.layers.3d.top.filled", "Bring forward") {
                                controller.bringForward()
                            }
                            actionButton("square.3.layers.3d.bottom.filled", "Send backward") {
                                controller.sendBackward()
                            }
                            actionButton("plus.square.on.square", "Duplicate — ⌘D") {
                                controller.duplicateSelection()
                            }
                            actionButton("trash", "Delete — ⌫") {
                                controller.deleteSelection()
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func actionButton(_ symbol: String, _ help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.sTextSecondary)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sHover))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct SwatchRow: View {
    let title: String
    let colors: [String]
    @Binding var selected: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.sTextSecondary)
            HStack(spacing: 5) {
                ForEach(colors, id: \.self) { hex in
                    Swatch(hex: hex, isSelected: selected == hex) { selected = hex }
                }
            }
        }
    }
}

private struct Swatch: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fillColor)
                if hex == "transparent" {
                    // Diagonal slash reads as "no fill" at swatch size.
                    Path { p in
                        p.move(to: CGPoint(x: 3, y: 17))
                        p.addLine(to: CGPoint(x: 17, y: 3))
                    }
                    .stroke(Color.red.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                }
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isSelected ? Theme.sAccent : Theme.sHairline,
                                  lineWidth: isSelected ? 2 : 1)
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }

    private var fillColor: Color {
        if hex == "transparent" { return Theme.sRaised }
        return Color(NSColor.fromHex(hex) ?? .gray)
    }
}

/// Icon segmented control bound to any equatable value.
private struct OptionRow<T: Equatable>: View {
    let title: String
    let options: [(String, T)]
    @Binding var selection: T

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.sTextSecondary)
            HStack(spacing: 4) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let isOn = selection == option.1
                    Button { selection = option.1 } label: {
                        Image(systemName: option.0)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(isOn ? Theme.sAccent : Theme.sTextSecondary)
                            .frame(width: 28, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isOn ? Theme.sAccent.opacity(0.16) : Theme.sHover)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
