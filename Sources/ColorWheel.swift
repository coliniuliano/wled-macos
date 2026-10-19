import SwiftUI
import AppKit

/// An inline hue/saturation wheel. Drawn with gradients rather than a bitmap,
/// so it stays sharp at any size and costs nothing to render.
///
/// Value (HSB brightness) is deliberately pinned at 1.0: WLED has a separate
/// `bri` dimmer, so dimming belongs on that slider. Baking darkness into the
/// colour instead would fight it and make the wheel's own position meaningless.
struct ColorWheel: View {
    let color: RGB
    let onChange: @MainActor (RGB) -> Void

    private static let hues: [Color] = (0...72).map {
        Color(hue: Double($0) / 72, saturation: 1, brightness: 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let radius = size / 2
            let center = CGPoint(x: radius, y: radius)
            let hsb = color.hsb

            ZStack {
                // Hue around the circumference…
                Circle()
                    .fill(AngularGradient(gradient: Gradient(colors: Self.hues), center: .center))

                // …fading to white at the centre for saturation.
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [.white, .white.opacity(0)]),
                            center: .center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )

                Circle()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)

                thumb(hsb: hsb, center: center, radius: radius)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        update(at: value.location, center: center, radius: radius)
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func thumb(hsb: (h: Double, s: Double, b: Double), center: CGPoint, radius: CGFloat) -> some View {
        let angle = hsb.h * 2 * .pi
        let distance = hsb.s * radius
        let position = CGPoint(
            x: center.x + cos(angle) * distance,
            y: center.y + sin(angle) * distance
        )

        return Circle()
            .fill(color.color)
            .frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .position(position)
    }

    private func update(at point: CGPoint, center: CGPoint, radius: CGFloat) {
        let dx = point.x - center.x
        let dy = point.y - center.y

        // Dragging past the rim pins to full saturation rather than cutting out,
        // which is what makes the edge of the wheel feel grabbable.
        let saturation = min(1, hypot(dx, dy) / radius)
        var hue = atan2(dy, dx) / (2 * .pi)
        if hue < 0 { hue += 1 }

        onChange(RGB(h: hue, s: saturation, b: 1))
    }
}
