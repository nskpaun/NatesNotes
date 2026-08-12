import SwiftUI

struct TitleBar: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var app: AppState
    @ObservedObject var sync: SyncController
    var onDraw: () -> Void

    private var locked: Bool { app.mode == .lockedIn }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 12) {
                // Space for the traffic lights, which the system draws.
                Color.clear.frame(width: 66, height: 1)

                Button(action: app.toggleSidebar) {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.sTextTertiary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pressable()
                .help("Toggle sidebar — ⌘\\")

                Text(store.selected?.title ?? "Nate's Notes")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.sTextSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .id(store.selectedID)
                    .transition(.opacity)

                ModeChip(app: app)

                Spacer(minLength: 8)

                SegmentedPair(onDraw: onDraw)

                SearchPill { app.openPalette() }

                SyncStatusButton(sync: sync)
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.titleBarHeight)

            LiveDivider(axis: .horizontal, active: locked, period: 3.8)
        }
        .background(Theme.sWindow.opacity(0.6))
    }
}

/// The mode toggle. Switching it re-tints the whole app, so it gets the most
/// deliberate motion in the chrome: the glyph swaps with a spin, the pill
/// re-colours, and in Locked-In it keeps a slow glow.
struct ModeChip: View {
    @ObservedObject var app: AppState
    @State private var hovering = false

    private var locked: Bool { app.mode == .lockedIn }

    var body: some View {
        Button {
            app.toggleMode()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: app.mode.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(locked ? 0 : -180))
                    .scaleEffect(locked ? 1 : 0.92)
                    .animation(Motion.spring, value: locked)
                Text(app.mode.label)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
            }
            .foregroundStyle(Theme.sTextPrimary)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.sAccent.opacity(hovering ? 0.28 : 0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.sAccent.opacity(0.55), lineWidth: 1)
            )
            .pulseGlow(active: locked)
        }
        .buttonStyle(.plain)
        .pressable(scale: 0.94)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .help("Switch mode — ⇧⌘M")
    }
}

/// Note / Draw. "Draw" opens the modal rather than swapping the pane.
private struct SegmentedPair: View {
    var onDraw: () -> Void
    @State private var hoveringDraw = false

    var body: some View {
        HStack(spacing: 3) {
            Text("Note")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.sTextPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )

            Button(action: onDraw) {
                Text("Draw")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hoveringDraw ? Theme.sTextPrimary : Theme.sTextTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(hoveringDraw ? Color.white.opacity(0.06) : .clear)
                    )
            }
            .buttonStyle(.plain)
            .pressable()
            .onHover { hoveringDraw = $0 }
            .animation(Motion.fade, value: hoveringDraw)
            .help("New sketch — ⇧⌘D")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
    }
}

private struct SearchPill: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .medium))
                Text("Search notes…")
                    .font(.system(size: 11.5))
                    .fixedSize()
                Text("⌘K")
                    .font(Font(Theme.mono(10)))
                    .opacity(0.75)
            }
            .foregroundStyle(hovering ? Theme.sTextSecondary : Theme.sTextTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.08 : 0.045))
            )
        }
        .buttonStyle(.plain)
        .pressable()
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
    }
}
