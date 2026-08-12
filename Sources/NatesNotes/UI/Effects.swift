import SwiftUI

/// A light that travels around the window edge, leaving a coloured wake.
///
/// The sweep angle animates rather than the shape, so the border stays put
/// while the glow orbits it. In Locked-In mode this is the app's heartbeat.
struct GlowRing: View {
    var cornerRadius: CGFloat = Theme.windowCorner
    var lineWidth: CGFloat = 1.3
    var period: Double = 5.5
    var active: Bool

    @State private var phase: Double = 0

    private var sweep: AngularGradient {
        let accent = Theme.mode.accent
        let bright = Theme.mode.accentBright
        return AngularGradient(
            gradient: Gradient(stops: [
                Gradient.Stop(color: .clear, location: 0.00),
                Gradient.Stop(color: .clear, location: 0.58),
                Gradient.Stop(color: Color(accent).opacity(0.85), location: 0.72),
                Gradient.Stop(color: Color(bright), location: 0.80),
                Gradient.Stop(color: Color(accent).opacity(0.85), location: 0.88),
                Gradient.Stop(color: .clear, location: 0.97),
                Gradient.Stop(color: .clear, location: 1.00)
            ]),
            center: .center,
            angle: .degrees(phase))
    }

    var body: some View {
        ZStack {
            // The crisp ring itself.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(sweep, lineWidth: lineWidth)
            // A soft bloom just outside it, so the light reads as light.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(sweep, lineWidth: lineWidth * 3.5)
                .blur(radius: 9)
                .opacity(0.55)
        }
        .opacity(active ? 1 : 0)
        .animation(Motion.mode, value: active)
        .allowsHitTesting(false)
        .onAppear { start() }
        .onChange(of: active) { _ in start() }
    }

    private func start() {
        guard active else { return }
        phase = 0
        withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
            phase = 360
        }
    }
}

/// A short comet of light running along a hairline divider.
struct RunningLight: View {
    enum Axis { case horizontal, vertical }

    var axis: Axis
    var period: Double = 4.2
    var delay: Double = 0
    var active: Bool
    /// Fraction of the edge the comet occupies.
    var length: CGFloat = 0.26

    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let travel = axis == .horizontal ? geometry.size.width : geometry.size.height
            let span = travel * length
            let gradient = LinearGradient(
                colors: [.clear,
                         Color(Theme.mode.accent).opacity(0.85),
                         Color(Theme.mode.accentBright),
                         Color(Theme.mode.accent).opacity(0.85),
                         .clear],
                startPoint: axis == .horizontal ? .leading : .top,
                endPoint: axis == .horizontal ? .trailing : .bottom)

            Rectangle()
                .fill(gradient)
                .frame(width: axis == .horizontal ? span : nil,
                       height: axis == .vertical ? span : nil)
                // Travels from fully off one end to fully off the other.
                .offset(x: axis == .horizontal ? -span + progress * (travel + span * 2) : 0,
                        y: axis == .vertical ? -span + progress * (travel + span * 2) : 0)
        }
        .clipped()
        .opacity(active ? 1 : 0)
        .animation(Motion.mode, value: active)
        .allowsHitTesting(false)
        .onAppear { start() }
        .onChange(of: active) { _ in start() }
    }

    private func start() {
        guard active else { return }
        progress = 0
        withAnimation(.linear(duration: period).repeatForever(autoreverses: false).delay(delay)) {
            progress = 1
        }
    }
}

/// Hairline divider that carries a running light in Locked-In mode.
struct LiveDivider: View {
    var axis: RunningLight.Axis
    var active: Bool
    var period: Double = 4.2
    var delay: Double = 0

    var body: some View {
        ZStack {
            Theme.sHairline
            RunningLight(axis: axis, period: period, delay: delay, active: active)
        }
        .frame(width: axis == .vertical ? 1 : nil,
               height: axis == .horizontal ? 1 : nil)
    }
}

/// Breathing scale + glow, used on the mode chip so the current state feels alive.
struct PulseModifier: ViewModifier {
    var active: Bool
    var period: Double = 2.6
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .shadow(color: Color(Theme.mode.accent).opacity(active ? (on ? 0.5 : 0.18) : 0),
                    radius: on ? 14 : 6)
            .onAppear { start() }
            .onChange(of: active) { _ in start() }
    }

    private func start() {
        guard active else { on = false; return }
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
            on = true
        }
    }
}

extension View {
    func pulseGlow(active: Bool) -> some View {
        modifier(PulseModifier(active: active))
    }

    /// Scales down slightly while pressed — the standard tactile response here.
    func pressable(scale: CGFloat = 0.96) -> some View {
        modifier(PressableModifier(scale: scale))
    }
}

struct PressableModifier: ViewModifier {
    var scale: CGFloat
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? scale : 1)
            .animation(Motion.snappy, value: pressed)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 40) { pressing in
                pressed = pressing
            } perform: {}
    }
}

/// Fades and lifts content in, for staggered list entrances.
struct RiseIn: ViewModifier {
    var index: Int
    var active: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                guard active else { shown = true; return }
                withAnimation(Motion.stagger(index)) { shown = true }
            }
    }
}

extension View {
    func riseIn(_ index: Int, active: Bool = true) -> some View {
        modifier(RiseIn(index: index, active: active))
    }
}
