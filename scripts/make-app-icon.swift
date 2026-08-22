#!/usr/bin/env swift
//
// Draws Resources/AppIcon.icns from code, so the logo is reproducible and no
// binary asset has to be edited by hand.
//
//   swift scripts/make-app-icon.swift [output.icns]
//
// The mark echoes the menu bar glyph (`bolt.horizontal.circle.fill`): a white
// horizontal bolt on a disc, over a teal→blue gradient tile. Teal and blue are
// the OpenAI and DeepSeek brand colors used in the panel, i.e. "switching
// between providers".
import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Resources/AppIcon.icns"

// Apple's app-icon grid: the art sits inside the canvas with a margin, with a
// continuous-corner radius of ~22.4% of the art's side.
let artInset: CGFloat = 0.098
let cornerRatio: CGFloat = 0.224

/// Horizontal lightning bolt, in a unit square with y pointing up.
let boltPoints: [CGPoint] = [
    CGPoint(x: 0.00, y: 0.36),
    CGPoint(x: 0.47, y: 0.36),
    CGPoint(x: 0.28, y: 0.00),
    CGPoint(x: 1.00, y: 0.64),
    CGPoint(x: 0.53, y: 0.64),
    CGPoint(x: 0.72, y: 1.00)
]

func gradient(_ colors: [(CGFloat, CGFloat, CGFloat, CGFloat)], _ locations: [CGFloat]) -> CGGradient {
    let space = CGColorSpaceCreateDeviceRGB()
    let components = colors.flatMap { [$0.0, $0.1, $0.2, $0.3] }
    return CGGradient(colorSpace: space, colorComponents: components,
                      locations: locations, count: locations.count)!
}

/// Superellipse ("squircle"), closer to macOS tiles than a circular-corner rect.
func squircle(in rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let k = radius * 0.42   // control-point pull for the continuous corner
    let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    path.move(to: CGPoint(x: minX, y: minY + radius))
    path.addCurve(to: CGPoint(x: minX + radius, y: minY),
                  control1: CGPoint(x: minX, y: minY + k),
                  control2: CGPoint(x: minX + k, y: minY))
    path.addLine(to: CGPoint(x: maxX - radius, y: minY))
    path.addCurve(to: CGPoint(x: maxX, y: minY + radius),
                  control1: CGPoint(x: maxX - k, y: minY),
                  control2: CGPoint(x: maxX, y: minY + k))
    path.addLine(to: CGPoint(x: maxX, y: maxY - radius))
    path.addCurve(to: CGPoint(x: maxX - radius, y: maxY),
                  control1: CGPoint(x: maxX, y: maxY - k),
                  control2: CGPoint(x: maxX - k, y: maxY))
    path.addLine(to: CGPoint(x: minX + radius, y: maxY))
    path.addCurve(to: CGPoint(x: minX, y: maxY - radius),
                  control1: CGPoint(x: minX + k, y: maxY),
                  control2: CGPoint(x: minX, y: maxY - k))
    path.closeSubpath()
    return path
}

func drawIcon(side: Int) -> CGImage {
    let size = CGFloat(side)
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let art = CGRect(x: size * artInset, y: size * artInset,
                     width: size * (1 - 2 * artInset), height: size * (1 - 2 * artInset))
    let tile = squircle(in: art, radius: art.width * cornerRatio)

    // Soft contact shadow, as on stock macOS icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                      blur: size * 0.03,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    context.addPath(tile)
    context.setFillColor(CGColor(red: 0.10, green: 0.45, blue: 0.85, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Tile: teal (OpenAI) → blue (DeepSeek), the panel's own accent pair.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(
        gradient([(0.06, 0.83, 0.73, 1.0),   // teal, the OpenAI card
                  (0.10, 0.58, 0.94, 1.0),
                  (0.15, 0.33, 0.98, 1.0)],  // blue, the DeepSeek card
                 [0, 0.48, 1]),
        start: CGPoint(x: art.minX, y: art.maxY),
        end: CGPoint(x: art.maxX, y: art.minY),
        options: []
    )
    // Top light.
    context.drawLinearGradient(
        gradient([(1, 1, 1, 0.26), (1, 1, 1, 0.0)], [0, 1]),
        start: CGPoint(x: art.midX, y: art.maxY),
        end: CGPoint(x: art.midX, y: art.midY),
        options: []
    )
    context.restoreGState()

    // Inner disc, echoing the filled-circle menu bar symbol.
    let discRadius = art.width * 0.360
    let disc = CGRect(x: art.midX - discRadius, y: art.midY - discRadius,
                      width: discRadius * 2, height: discRadius * 2)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    context.fillEllipse(in: disc)
    context.setLineWidth(max(size * 0.006, 0.5))
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
    context.strokeEllipse(in: disc.insetBy(dx: size * 0.003, dy: size * 0.003))

    // The bolt: switching, in white for maximum contrast at small sizes.
    let boltWidth = art.width * 0.58
    let boltHeight = boltWidth * 0.62
    let boltRect = CGRect(x: art.midX - boltWidth / 2, y: art.midY - boltHeight / 2,
                          width: boltWidth, height: boltHeight)
    let bolt = CGMutablePath()
    for (index, point) in boltPoints.enumerated() {
        let mapped = CGPoint(x: boltRect.minX + point.x * boltRect.width,
                             y: boltRect.minY + point.y * boltRect.height)
        if index == 0 { bolt.move(to: mapped) } else { bolt.addLine(to: mapped) }
    }
    bolt.closeSubpath()
    context.saveGState()
    context.setShadow(offset: .zero, blur: size * 0.02,
                      color: CGColor(red: 0, green: 0.08, blue: 0.30, alpha: 0.35))
    context.addPath(bolt)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    return context.makeImage()!
}

// Every representation macOS asks for, drawn at its native size (no upscaling).
let representations: [(name: String, side: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for representation in representations {
    let image = drawIcon(side: representation.side)
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: representation.side, height: representation.side)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("PNG encoding failed\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(representation.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("✓ \(outputPath)")
