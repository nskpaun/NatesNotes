import SwiftUI
import AppKit

/// Small icon button used in the sync panel and note chrome.
struct GlyphButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 12.5
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? Theme.sTextTertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Theme.sHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .pressable()
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .help(help)
    }
}

/// Sends an action down the responder chain — how the menu bar and chrome
/// buttons reach the focused text view.
func sendToResponder(_ selector: Selector) {
    NSApp.sendAction(selector, to: nil, from: nil)
}

extension Date {
    var shortRelative: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            return f.string(from: self)
        }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        let f = DateFormatter()
        if cal.component(.year, from: self) == cal.component(.year, from: Date()) {
            f.dateFormat = "MMM d"
        } else {
            f.dateFormat = "MMM d, yyyy"
        }
        return f.string(from: self)
    }
}
