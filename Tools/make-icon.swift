#!/usr/bin/env swift
import AppKit
import Foundation

// Turns the supplied artwork into a macOS .iconset.
//
// The source is a rounded-square icon sitting on an opaque black field. Shipped
// as-is it would appear in the Dock as a black square, so this finds the body,
// re-lays it out on Apple's icon grid (an 824pt body inside a 1024pt canvas),
// and clips it to the system squircle so the corners are properly transparent.
//
//   swift Tools/make-icon.swift <source.png> <output.iconset>

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: make-icon.swift <source.png> <output.iconset>")
    exit(1)
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let source = NSImage(contentsOf: sourceURL),
      let sourceRep = NSBitmapImageRep(data: source.tiffRepresentation!) else {
    print("could not read \(sourceURL.path)")
    exit(1)
}

let width = sourceRep.pixelsWide
let height = sourceRep.pixelsHigh

// MARK: - Find the icon body

// Scan for pixels bright enough to be the icon rather than the surrounding
// black field or its faint bloom.
let threshold: CGFloat = 0.16
var minX = width, minY = height, maxX = 0, maxY = 0

for y in 0..<height {
    for x in 0..<width {
        guard let colour = sourceRep.colorAt(x: x, y: y) else { continue }
        let luminance = 0.2126 * colour.redComponent
            + 0.7152 * colour.greenComponent
            + 0.0722 * colour.blueComponent
        if luminance > threshold {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}

guard maxX > minX, maxY > minY else {
    print("could not find the icon body")
    exit(1)
}

// Square it up around the detected centre so the artwork isn't distorted.
let bodyWidth = maxX - minX + 1
let bodyHeight = maxY - minY + 1
let side = max(bodyWidth, bodyHeight)
let centreX = CGFloat(minX + maxX) / 2
let centreY = CGFloat(minY + maxY) / 2
let crop = CGRect(x: centreX - CGFloat(side) / 2, y: centreY - CGFloat(side) / 2,
                  width: CGFloat(side), height: CGFloat(side))

print("source \(width)×\(height) — body \(bodyWidth)×\(bodyHeight) at (\(minX), \(minY))")

// MARK: - Render onto the macOS icon grid

/// Canvas 1024, body 824 centred: the proportions system icons use, so this
/// sits at the same visual size as its neighbours in the Dock.
func renderCanvas(size: CGFloat) -> NSBitmapImageRep? {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                     pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                     bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: size, height: size)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let bodySide = size * (824.0 / 1024.0)
    let inset = (size - bodySide) / 2
    let body = CGRect(x: inset, y: inset, width: bodySide, height: bodySide)
    // Apple's corner radius for the 824 body, scaled.
    let radius = bodySide * (185.4 / 824.0)

    let mask = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    mask.addClip()

    source.draw(in: body, from: crop, operation: .copy, fraction: 1,
                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Render onto the iOS icon grid

/// iOS masks the icon itself, so this one is the opposite shape of the macOS
/// canvas: full bleed, square corners, and no alpha channel — the App Store
/// rejects one even when it is entirely opaque.
///
/// The artwork already is an icon: a squircle on a black field. So it is drawn
/// edge to edge rather than inset, and the system's own mask trims the corners.
/// Insetting it would nest one rounded square inside another and leave the
/// black field showing in the corners.
func renderIOSCanvas(size: CGFloat) -> NSBitmapImageRep? {
    let pixels = Int(size)
    // Drawn with alpha because CoreGraphics has no RGB-without-alpha context
    // format; it is flattened to opaque below.
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                     pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                     bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: size, height: size)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    // The artwork's own field, sampled from a source corner, so anything the
    // mask leaves in the corners matches the body rather than showing a seam.
    let field = sourceRep.colorAt(x: 2, y: 2) ?? .black
    field.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: size, height: size)).fill()

    source.draw(in: CGRect(x: 0, y: 0, width: size, height: size),
                from: crop, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

    NSGraphicsContext.restoreGraphicsState()

    // Re-draw into a noneSkipLast context so the PNG carries no alpha channel
    // at all. An opaque alpha channel still counts as one, and it is rejected.
    guard let drawn = rep.cgImage,
          let opaque = CGContext(data: nil, width: pixels, height: pixels,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    opaque.draw(drawn, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let flattened = opaque.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: flattened)
}

// MARK: - Write the iOS icon

if arguments.contains("--ios") {
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let rep = renderIOSCanvas(size: 1024),
          let data = rep.representation(using: .png, properties: [:]) else {
        print("failed to render the iOS icon")
        exit(1)
    }
    try data.write(to: outputURL)
    print("wrote 1024×1024 iOS icon to \(outputURL.lastPathComponent)")
    exit(0)
}

// MARK: - Write the iconset

try? FileManager.default.removeItem(at: outputURL)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    guard let rep = renderCanvas(size: variant.size),
          let data = rep.representation(using: .png, properties: [:]) else {
        print("failed to render \(variant.name)")
        exit(1)
    }
    try data.write(to: outputURL.appendingPathComponent("\(variant.name).png"))
}

print("wrote \(variants.count) sizes to \(outputURL.lastPathComponent)")
