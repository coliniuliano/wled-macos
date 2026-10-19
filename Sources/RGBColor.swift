import SwiftUI
import AppKit

/// Bridges WLED's 8-bit RGB triples to SwiftUI's `Color`, kept apart from the
/// model layer so `Models.swift` stays free of UI types.
extension RGB {
    var color: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// SwiftUI hands back a `Color` in an arbitrary space; WLED wants sRGB.
    init(_ color: Color) {
        let sRGB = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            r: Int((sRGB.redComponent   * 255).rounded()),
            g: Int((sRGB.greenComponent * 255).rounded()),
            b: Int((sRGB.blueComponent  * 255).rounded())
        )
    }

    /// HSB decomposition, used to place the colour wheel's thumb.
    var hsb: (h: Double, s: Double, b: Double) {
        let color = NSColor(
            srgbRed: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            alpha: 1
        )
        return (color.hueComponent, color.saturationComponent, color.brightnessComponent)
    }

    init(h: Double, s: Double, b: Double) {
        let sRGB = NSColor(hue: h, saturation: s, brightness: b, alpha: 1)
            .usingColorSpace(.sRGB) ?? .white
        self.init(
            r: Int((sRGB.redComponent   * 255).rounded()),
            g: Int((sRGB.greenComponent * 255).rounded()),
            b: Int((sRGB.blueComponent  * 255).rounded())
        )
    }

    /// The menu bar strip: two whites, then straight through the spectrum in
    /// ROYGBIV order. The whites lead because they are not part of the rainbow
    /// and interrupt it anywhere else.
    static let quickSwatches: [RGB] = [
        RGB(r: 255, g: 255, b: 255),   // white
        RGB(r: 255, g: 180, b: 100),   // warm white
        RGB(r: 255, g: 0,   b: 0),     // red
        RGB(r: 255, g: 100, b: 0),     // orange
        RGB(r: 255, g: 220, b: 0),     // yellow
        RGB(r: 0,   g: 255, b: 60),    // green
        RGB(r: 0,   g: 230, b: 230),   // cyan
        RGB(r: 0,   g: 90,  b: 255),   // blue
        RGB(r: 75,  g: 0,   b: 220),   // indigo
        RGB(r: 160, g: 0,   b: 255),   // violet
        RGB(r: 255, g: 0,   b: 160),   // pink
    ]

    /// The main window grid: same spectrum order, finer steps.
    static let swatches: [RGB] = [
        RGB(r: 255, g: 255, b: 255), RGB(r: 255, g: 200, b: 120),
        RGB(r: 255, g: 0,   b: 0),   RGB(r: 255, g: 80,  b: 0),
        RGB(r: 255, g: 170, b: 0),   RGB(r: 255, g: 230, b: 0),
        RGB(r: 0,   g: 255, b: 80),  RGB(r: 0,   g: 255, b: 180),
        RGB(r: 0,   g: 200, b: 255), RGB(r: 0,   g: 90,  b: 255),
        RGB(r: 110, g: 0,   b: 255), RGB(r: 255, g: 0,   b: 170),
    ]
}
