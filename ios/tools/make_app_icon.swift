#!/usr/bin/env swift
//
// Generates the Cybus app icon: a simple white bus on a blue gradient.
// Drawn by hand with AppKit (SF Symbols are not licensed for use in app icons).
//
// Usage:  swift make_app_icon.swift <output-1024.png>
// Re-run after tweaking to regenerate the asset.

import AppKit

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.png"

let S = 1024

// Opaque context (alpha "skipped" — App Store rejects app icons with an alpha
// channel, and 24-bit RGB isn't a valid CGContext format, so we use noneSkipLast).
guard let ctx = CGContext(
    data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("could not create context") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let s = CGFloat(S)

// MARK: Background — vertical blue gradient
let top = NSColor(srgbRed: 0.22, green: 0.56, blue: 0.99, alpha: 1).cgColor
let bottom = NSColor(srgbRed: 0.07, green: 0.33, blue: 0.82, alpha: 1).cgColor
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [top, bottom] as CFArray, locations: [0, 1]
)!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

let blue = NSColor(srgbRed: 0.20, green: 0.55, blue: 0.98, alpha: 1)
let dark = NSColor(white: 0.13, alpha: 1)

// MARK: Wheels (drawn first so the body overlaps their tops)
dark.setFill()
for cx in [CGFloat(380), CGFloat(644)] {
    NSBezierPath(ovalIn: NSRect(x: cx - 62, y: 232, width: 124, height: 124)).fill()
}

// MARK: Bus body — white rounded rectangle
let body = NSRect(x: 244, y: 286, width: 536, height: 404)
NSColor.white.setFill()
NSBezierPath(roundedRect: body, xRadius: 74, yRadius: 74).fill()

// MARK: Windows — three blue panes in a row
blue.setFill()
let winY: CGFloat = 486, winH: CGFloat = 150
let firstX: CGFloat = 300, paneW: CGFloat = 128, gap: CGFloat = 28
for i in 0..<3 {
    let x = firstX + CGFloat(i) * (paneW + gap)
    NSBezierPath(roundedRect: NSRect(x: x, y: winY, width: paneW, height: winH),
                 xRadius: 26, yRadius: 26).fill()
}

// MARK: Headlights — two small blue dots near the bottom edge of the body
blue.setFill()
NSBezierPath(ovalIn: NSRect(x: 290, y: 330, width: 46, height: 46)).fill()
NSBezierPath(ovalIn: NSRect(x: 688, y: 330, width: 46, height: 46)).fill()

NSGraphicsContext.restoreGraphicsState()

guard let cg = ctx.makeImage() else { fatalError("could not snapshot image") }
let rep = NSBitmapImageRep(cgImage: cg)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(S)x\(S))")
