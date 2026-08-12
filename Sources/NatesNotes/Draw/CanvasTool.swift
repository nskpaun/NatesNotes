import Foundation

enum CanvasTool: String, CaseIterable, Identifiable {
    case select, hand, rectangle, diamond, ellipse, arrow, line, freedraw, text, eraser

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select:    return "cursorarrow"
        case .hand:      return "hand.raised"
        case .rectangle: return "square"
        case .diamond:   return "diamond"
        case .ellipse:   return "circle"
        case .arrow:     return "arrow.right"
        case .line:      return "line.diagonal"
        case .freedraw:  return "pencil.tip"
        case .text:      return "textformat"
        case .eraser:    return "eraser"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .hand: return "Pan"
        case .rectangle: return "Rectangle"
        case .diamond: return "Diamond"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .freedraw: return "Draw"
        case .text: return "Text"
        case .eraser: return "Eraser"
        }
    }

    /// Single-key shortcuts, matching Excalidraw's muscle memory where possible.
    var key: String {
        switch self {
        case .select: return "1"
        case .hand: return "2"
        case .rectangle: return "3"
        case .diamond: return "4"
        case .ellipse: return "5"
        case .arrow: return "6"
        case .line: return "7"
        case .freedraw: return "8"
        case .text: return "9"
        case .eraser: return "0"
        }
    }

    var elementKind: ElementKind? {
        switch self {
        case .rectangle: return .rectangle
        case .diamond:   return .diamond
        case .ellipse:   return .ellipse
        case .arrow:     return .arrow
        case .line:      return .line
        case .freedraw:  return .freedraw
        case .text:      return .text
        case .select, .hand, .eraser: return nil
        }
    }

    var createsElement: Bool { elementKind != nil }
}

/// The style that new elements inherit, and that edits apply to the selection.
struct DrawStyle: Equatable {
    var strokeColor = "#1F1F1E"
    var fillColor = "transparent"
    var fillStyle: FillStyle = .hachure
    var strokeStyle: StrokeStyle = .solid
    var strokeWidth: CGFloat = 2
    var roughness: CGFloat = 1.2
    var edges: EdgeStyle = .round
    var opacity: CGFloat = 1
    var fontSize: CGFloat = 20
    var handwritten = true

    func applied(to e: inout DrawElement) {
        e.strokeColor = strokeColor
        e.fillColor = fillColor
        e.fillStyle = fillStyle
        e.strokeStyle = strokeStyle
        e.strokeWidth = strokeWidth
        e.roughness = roughness
        e.edges = edges
        e.opacity = opacity
        e.fontSize = fontSize
        e.handwritten = handwritten
    }
}
