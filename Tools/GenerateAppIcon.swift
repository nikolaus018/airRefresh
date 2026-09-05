#!/usr/bin/env swift
//
//  GenerateAppIcon.swift
//  Draws AirRefresh's app icon and writes every size the asset catalog wants.
//
//  The icon is code rather than a binary blob so it can be reviewed, tweaked in
//  a diff, and regenerated on any Mac with no design tools installed:
//
//      swift Tools/GenerateAppIcon.swift
//
//  Nothing here is an SF Symbol — Apple's licence does not allow those in app
//  icons — the refresh ring is drawn from scratch.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// Apple's icon grid: the artwork fills 824 of a 1024 canvas, centred, with the
/// rest left to the shadow.
let contentRatio: CGFloat = 824.0 / 1024.0

/// A superellipse — the "squircle" macOS actually uses, rather than the
/// rounded rectangle that is usually mistaken for it.
func squircle(in rect: CGRect, exponent: CGFloat = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        // |x/a|^n + |y/b|^n = 1, parameterised so the corners stay smooth.
        let x = cx + a * pow(abs(cosT), 2 / exponent) * (cosT < 0 ? -1 : 1)
        let y = cy + b * pow(abs(sinT), 2 / exponent) * (sinT < 0 ? -1 : 1)
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// One half of the refresh ring: an arc that ends in a tapered arrowhead.
func arrowArc(center: CGPoint,
              radius: CGFloat,
              width: CGFloat,
              from start: CGFloat,
              to end: CGFloat) -> CGPath {
    let path = CGMutablePath()

    // The arc itself, drawn as a stroked wedge so it can be filled in one pass
    // together with the arrowhead.
    let outer = radius + width / 2
    let inner = radius - width / 2
    path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
    path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
    path.closeSubpath()

    // Rounded tail so the gap in the ring does not look chopped off.
    let tail = CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start))
    path.addEllipse(in: CGRect(x: tail.x - width / 2, y: tail.y - width / 2, width: width, height: width))

    // Arrowhead: tip carried a little further around the circle, base spanning
    // the ring radially so it reads as an arrow even at 16 points.
    let half = width * 0.88
    let tipAngle = end + (width * 1.75) / radius
    let tip = CGPoint(x: center.x + radius * cos(tipAngle), y: center.y + radius * sin(tipAngle))
    let radial = CGPoint(x: cos(end), y: sin(end))
    let baseCenter = CGPoint(x: center.x + radius * radial.x, y: center.y + radius * radial.y)
    path.move(to: tip)
    path.addLine(to: CGPoint(x: baseCenter.x + radial.x * half, y: baseCenter.y + radial.y * half))
    path.addLine(to: CGPoint(x: baseCenter.x - radial.x * half, y: baseCenter.y - radial.y * half))
    path.closeSubpath()

    return path
}

// MARK: - Drawing

func drawIcon(size: CGFloat) -> CGImage {
    let scale = size / 1024.0
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not create a \(Int(size))px bitmap context")
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let side = size * contentRatio
    // Nudged up a touch, the way Apple's own icons sit above their shadow.
    let plate = CGRect(x: (size - side) / 2,
                       y: (size - side) / 2 + size * 0.012,
                       width: side, height: side)
    let shape = squircle(in: plate)

    // Shadow under the plate.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.018),
                  blur: size * 0.03,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.85, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient — a deep blue lifting to violet, so it stays distinct from
    // the sea of grey developer-tool icons.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [
                                CGColor(red: 0.36, green: 0.55, blue: 1.00, alpha: 1),
                                CGColor(red: 0.20, green: 0.33, blue: 0.93, alpha: 1),
                                CGColor(red: 0.36, green: 0.22, blue: 0.80, alpha: 1)
                              ] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY),
                           options: [])

    // A soft highlight across the top edge, which is what stops a flat gradient
    // from looking like a placeholder.
    let sheen = CGGradient(colorsSpace: colorSpace,
                           colors: [
                            CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
                            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
                           ] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.midY + plate.height * 0.08),
                           options: [])
    ctx.restoreGState()

    // Inner hairline, for a crisp edge against light and dark wallpapers alike.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(max(1, size * 0.004))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.strokePath()
    ctx.restoreGState()

    // The refresh ring: two arrows chasing each other.
    let center = CGPoint(x: plate.midX, y: plate.midY)
    let radius = side * 0.262
    let width = side * 0.122

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006),
                  blur: size * 0.012,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    for start in [CGFloat.pi * 0.08, CGFloat.pi * 1.08] {
        ctx.addPath(arrowArc(center: center,
                             radius: radius,
                             width: width,
                             from: start,
                             to: start + .pi * 0.72))
        ctx.fillPath()
    }
    ctx.restoreGState()

    _ = canvas
    _ = scale
    guard let image = ctx.makeImage() else { fatalError("Could not render the icon") }
    return image
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSet = root.appending(path: "AirRefresh/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

/// (point size, scale) — every entry macOS asks for.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
                              (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

var entries: [String] = []
for (points, scale) in variants {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    write(drawIcon(size: CGFloat(pixels)), to: iconSet.appending(path: name))
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(points)x\(points)"
        }
    """)
    print("wrote \(name) (\(pixels)px)")
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "AirRefresh/Tools/GenerateAppIcon.swift",
    "version" : 1
  }
}

"""
try! contents.write(to: iconSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
