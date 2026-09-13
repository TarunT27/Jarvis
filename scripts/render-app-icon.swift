// Renders Resources/Jarvis.icns from the same geometry JarvisMark draws, so the icon
// and the in-app mark cannot drift apart. The source artwork is vector maths, not a
// bitmap, so every size is rendered rather than downscaled - and the small sizes use
// the compact five-bar build, exactly as the app does.
//
//   swiftc -O scripts/render-app-icon.swift -o /tmp/render-icon
//   /tmp/render-icon /tmp/Jarvis.iconset
//   iconutil -c icns /tmp/Jarvis.iconset -o Resources/Jarvis.icns

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The same geometry JarvisMark draws, so the icon and the in-app mark cannot drift.
struct Build {
    let heights: [CGFloat]; let barWidth: CGFloat; let gap: CGFloat
    let hub: CGFloat; let aperture: CGFloat; let edge: Bool
}
let compact  = Build(heights: [0.38, 0.68, 0.96, 0.68, 0.38], barWidth: 0.14, gap: 0.05,
                     hub: 0, aperture: 0, edge: false)
let standard = Build(heights: [0.26, 0.51, 0.74, 0.94, 0.74, 0.51, 0.26], barWidth: 0.105, gap: 0.038,
                     hub: 0.32, aperture: 0.22, edge: false)
let full     = Build(heights: [0.26, 0.51, 0.74, 0.94, 0.74, 0.51, 0.26], barWidth: 0.105, gap: 0.038,
                     hub: 0.30, aperture: 0.185, edge: true)

func build(forMarkSide side: CGFloat) -> Build {
    if side < 24 { return compact }
    if side < 48 { return standard }
    return full
}

let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255,
                                            CGFloat((hex >> 8) & 255) / 255,
                                            CGFloat(hex & 255) / 255, a])!
}
let champagne = rgb(0xD7C8B6), lilac = rgb(0xC6BDBE)
// Bronze, from the palette's deepBronze family. Antique bronze #A88D6A was the
// obvious choice and is wrong: champagne on it measures 1.92:1 and the mark
// disappears. This pair gives the mark 4.14:1 at the top of the plate and 6.0 at
// the bottom.
let plateTop = rgb(0x71563D), plateBottom = rgb(0x4E3E2C)
let plateRim = rgb(0x8A7157, 0.6)

/// The mark alone, on transparency, with the aperture genuinely punched out.
func markImage(side: CGFloat) -> CGImage {
    let px = Int(side.rounded())
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
    let b = build(forMarkSide: side)

    let path = CGMutablePath()
    if b.hub > 0 {
        let d = side * b.hub
        path.addEllipse(in: CGRect(x: (side - d) / 2, y: (side - d) / 2, width: d, height: d))
    }
    let w = side * b.barWidth, gap = side * b.gap
    let total = w * CGFloat(b.heights.count) + gap * CGFloat(b.heights.count - 1)
    var x = (side - total) / 2
    for h in b.heights {
        let barHeight = side * h
        let rect = CGRect(x: x, y: (side - barHeight) / 2, width: w, height: barHeight)
        path.addRoundedRect(in: rect, cornerWidth: w / 2, cornerHeight: w / 2)
        x += w + gap
    }
    ctx.addPath(path); ctx.clip()

    if b.edge {
        // The cool edge is a gradient stop, as in JarvisMark - it scales instead of
        // landing on a fraction of a pixel.
        let gradient = CGGradient(colorsSpace: space, colors: [champagne, champagne, lilac] as CFArray,
                                  locations: [0, 0.93, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: side, y: 0), options: [])
    } else {
        ctx.setFillColor(champagne); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
    ctx.resetClip()

    if b.aperture > 0 {
        let d = side * b.aperture
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: (side - d) / 2, y: (side - d) / 2, width: d, height: d))
        ctx.setBlendMode(.normal)
    }
    return ctx.makeImage()!
}

/// One icon: the macOS plate, with the mark centred on it.
func icon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)

    // Apple's macOS grid: the plate is ~80% of the canvas, corner radius ~22.45% of it.
    let art = s * 0.8058, inset = (s - art) / 2
    let plate = CGRect(x: inset, y: inset, width: art, height: art)
    let radius = art * 0.2245
    let rounded = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(rounded); ctx.clip()
    let plateGradient = CGGradient(colorsSpace: space, colors: [plateTop, plateBottom] as CFArray,
                                   locations: [0, 1])!
    ctx.drawLinearGradient(plateGradient, start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.minY), options: [])
    ctx.restoreGState()

    // A hairline rim keeps the plate from dissolving into a dark Dock background.
    ctx.saveGState()
    ctx.addPath(rounded)
    ctx.setStrokeColor(plateRim); ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    let markSide = (art * 0.66).rounded()
    let mark = markImage(side: markSide)
    ctx.draw(mark, in: CGRect(x: (s - markSide) / 2, y: (s - markSide) / 2,
                              width: markSide, height: markSide))
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
// The names iconutil expects.
let plan: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (size, name) in plan {
    write(icon(size: size), to: out.appendingPathComponent("\(name).png"))
}
print("wrote \(plan.count) icon images to \(out.path)")
