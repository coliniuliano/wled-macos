// Renders AppIcon.icns from code, so the icon is reproducible and reviewable
// in the repo rather than an opaque binary nobody can regenerate.
//
//   swift Tools/make-icon.swift Resources
//
// Needs no Xcode: CoreGraphics draws the PNGs, iconutil packs them.

import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024

/// Apple's app icons leave a margin and use a continuous-curvature squircle.
/// A rounded rect at this radius is indistinguishable at icon sizes.
let margin: CGFloat = 100
let plateRect = CGRect(x: margin, y: margin,
                       width: canvas - margin * 2,
                       height: canvas - margin * 2)
let plateRadius: CGFloat = 185

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: a)
}

/// The same spectrum the app's swatch strip uses, so the icon and the UI agree.
let spectrum: [CGColor] = [
    rgb(255, 0, 0), rgb(255, 110, 0), rgb(255, 215, 0),
    rgb(0, 230, 90), rgb(0, 220, 230), rgb(0, 110, 255), rgb(165, 0, 255),
]

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: colors as CFArray, locations: nil)!
}

func draw(into ctx: CGContext) {
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // --- plate -------------------------------------------------------------
    let plate = CGPath(roundedRect: plateRect,
                       cornerWidth: plateRadius, cornerHeight: plateRadius,
                       transform: nil)
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(32, 36, 50), rgb(10, 11, 17)]),
        start: CGPoint(x: 0, y: canvas), end: CGPoint(x: 0, y: 0),
        options: []
    )
    // A faint top sheen keeps the plate from reading as flat black.
    ctx.drawLinearGradient(
        gradient([rgb(255, 255, 255, 0.10), rgb(255, 255, 255, 0)]),
        start: CGPoint(x: 0, y: canvas - margin),
        end: CGPoint(x: 0, y: canvas * 0.62),
        options: []
    )
    ctx.restoreGState()

    // --- the strip ---------------------------------------------------------
    // One bold element rather than many small ones: at 16pt a row of discrete
    // LEDs turns to mush, while a single bar still reads as colour on dark.
    let stripWidth: CGFloat = 600
    let stripHeight: CGFloat = 150
    let strip = CGRect(x: (canvas - stripWidth) / 2,
                       y: (canvas - stripHeight) / 2,
                       width: stripWidth, height: stripHeight)
    let stripPath = CGPath(roundedRect: strip,
                           cornerWidth: stripHeight / 2,
                           cornerHeight: stripHeight / 2, transform: nil)

    // Bloom. Shadows are a uniform colour, so the halo is built from three
    // offset passes — warm from the red end, cool from the violet end, and a
    // white core — which spills coloured light the way a lit strip actually
    // does. Clipped to the plate so the glow never escapes the icon.
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    // No white pass: a neutral bloom greys the whole plate and the icon goes
    // muddy. Only the spectrum's own ends spill, which keeps the corners dark.
    let blooms: [(CGSize, CGFloat, CGColor)] = [
        (CGSize(width: -85, height: 0), 95, rgb(255, 45, 0, 0.85)),
        (CGSize(width: 85, height: 0), 95, rgb(95, 60, 255, 0.85)),
        (.zero, 80, rgb(0, 210, 130, 0.45)),
    ]
    for (offset, blur, colour) in blooms {
        ctx.saveGState()
        ctx.setShadow(offset: offset, blur: blur, color: colour)
        ctx.addPath(stripPath)
        ctx.setFillColor(rgb(255, 255, 255, 0.95))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Spectrum fill.
    ctx.saveGState()
    ctx.addPath(stripPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(spectrum),
        start: CGPoint(x: strip.minX, y: 0),
        end: CGPoint(x: strip.maxX, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    // Top-to-bottom shading gives the bar a little body.
    ctx.drawLinearGradient(
        gradient([rgb(255, 255, 255, 0.28), rgb(255, 255, 255, 0),
                  rgb(0, 0, 0, 0.22)]),
        start: CGPoint(x: 0, y: strip.maxY),
        end: CGPoint(x: 0, y: strip.minY),
        options: []
    )
    ctx.restoreGState()
}

func image(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / canvas
    ctx.scaleBy(x: scale, y: scale)
    draw(into: ctx)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// --- build the iconset -------------------------------------------------------
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// base point size -> (filename, pixel size)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),      ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),      ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),   ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),   ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),   ("icon_512x512@2x.png", 1024),
]
for (name, px) in variants {
    write(image(size: px), to: iconset.appendingPathComponent(name))
}
print("wrote \(variants.count) sizes to \(iconset.path)")
