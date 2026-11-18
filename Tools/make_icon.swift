#!/usr/bin/env swift
//
//  make_icon.swift — renders the Caelus app icon at every macOS size.
//  Usage: swift Tools/make_icon.swift <AppIcon.appiconset path>
//
//  The mark: a lit globe with an orbital ellipse that passes behind it and in
//  front of it, carrying a single tracked object. Drawn at 1024², then
//  downsampled with sips so the small sizes stay crisp.
//

import AppKit
import CoreGraphics
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Caelus/Resources/Assets.xcassets/AppIcon.appiconset"

let S: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// ── Squircle plate ────────────────────────────────────────────────────────────
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: plate, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

let base = CGGradient(colorsSpace: space,
                      colors: [color(0x16202F), color(0x0A0F18), color(0x05080D)] as CFArray,
                      locations: [0, 0.5, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// ── Geometry ──────────────────────────────────────────────────────────────────
let globeC = CGPoint(x: 512, y: 505)
let globeR: CGFloat = 268
let globeRect = CGRect(x: globeC.x - globeR, y: globeC.y - globeR,
                       width: globeR * 2, height: globeR * 2)

let orbitC = CGPoint(x: 512, y: 512)
let rx: CGFloat = 392, ry: CGFloat = 150
let tilt: CGFloat = -16 * .pi / 180

func orbitPoint(_ t: CGFloat) -> CGPoint {
    let x = rx * cos(t), y = ry * sin(t)
    return CGPoint(x: orbitC.x + x * cos(tilt) - y * sin(tilt),
                   y: orbitC.y + x * sin(tilt) + y * cos(tilt))
}

/// Half of the ellipse in `steps` segments. `front` selects sin(t) > 0.
func orbitArc(front: Bool) -> CGPath {
    let p = CGMutablePath()
    let start = front ? CGFloat(0) : .pi
    let end = front ? CGFloat.pi : 2 * CGFloat.pi
    let steps = 160
    p.move(to: orbitPoint(start))
    for i in 1...steps {
        p.addLine(to: orbitPoint(start + (end - start) * CGFloat(i) / CGFloat(steps)))
    }
    return p
}

// Ambient glow behind everything.
let halo = CGGradient(colorsSpace: space,
                      colors: [color(0x3FA8FF, 0.22), color(0x3FA8FF, 0.0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(halo, startCenter: globeC, startRadius: 0,
                       endCenter: globeC, endRadius: 470, options: [])

// ── Orbit, back half ──────────────────────────────────────────────────────────
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(color(0x4FB3FF, 0.10)); ctx.setLineWidth(46)
ctx.addPath(orbitArc(front: false)); ctx.strokePath()
ctx.setStrokeColor(color(0x7CC8F5, 0.30)); ctx.setLineWidth(7)
ctx.addPath(orbitArc(front: false)); ctx.strokePath()

// ── Globe ─────────────────────────────────────────────────────────────────────
// Atmosphere bloom.
let bloom = CGGradient(colorsSpace: space,
                       colors: [color(0x59C2FF, 0.34), color(0x59C2FF, 0.0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(bloom,
                       startCenter: globeC, startRadius: globeR * 0.92,
                       endCenter: globeC, endRadius: globeR * 1.30, options: [])

ctx.saveGState()
ctx.addEllipse(in: globeRect)
ctx.clip()
// Lit from the upper-left: offset radial gradient.
let lit = CGPoint(x: globeC.x - globeR * 0.34, y: globeC.y + globeR * 0.36)
let sphere = CGGradient(colorsSpace: space,
                        colors: [color(0x3E93C9), color(0x1B5A85), color(0x0B2B44), color(0x04101B)] as CFArray,
                        locations: [0, 0.32, 0.68, 1])!
ctx.drawRadialGradient(sphere, startCenter: lit, startRadius: 0,
                       endCenter: lit, endRadius: globeR * 1.62, options: [])

// Latitude arcs, very faint.
ctx.setStrokeColor(color(0xBFE6FF, 0.07))
ctx.setLineWidth(2.5)
for dy in [CGFloat(-150), -60, 40, 130] {
    let half = (globeR * globeR - dy * dy).squareRoot()
    ctx.move(to: CGPoint(x: globeC.x - half, y: globeC.y + dy))
    ctx.addLine(to: CGPoint(x: globeC.x + half, y: globeC.y + dy))
}
ctx.strokePath()
ctx.restoreGState()

// Terminator shading on the lower-right: darken toward the shadow side.
ctx.saveGState()
ctx.addEllipse(in: globeRect)
ctx.clip()
let shadow = CGGradient(colorsSpace: space,
                        colors: [color(0x000000, 0.0), color(0x000000, 0.62)] as CFArray,
                        locations: [0.42, 1])!
ctx.drawRadialGradient(shadow,
                       startCenter: lit, startRadius: 0,
                       endCenter: lit, endRadius: globeR * 1.9, options: [])
ctx.restoreGState()

// Rim light: bright on the lit limb, fading out around the shadow side.
ctx.saveGState()
ctx.addEllipse(in: globeRect.insetBy(dx: 3, dy: 3))
ctx.setLineWidth(6)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rim = CGGradient(colorsSpace: space,
                     colors: [color(0xC9EBFF, 0.95), color(0x6FC4F0, 0.55), color(0x2C6E96, 0.12)] as CFArray,
                     locations: [0, 0.45, 1])!
ctx.drawLinearGradient(rim,
                       start: CGPoint(x: globeC.x - globeR * 0.8, y: globeC.y + globeR * 0.8),
                       end: CGPoint(x: globeC.x + globeR * 0.9, y: globeC.y - globeR * 0.9),
                       options: [])
ctx.restoreGState()

// ── Orbit, front half ─────────────────────────────────────────────────────────
ctx.setStrokeColor(color(0x4FB3FF, 0.14)); ctx.setLineWidth(46)
ctx.addPath(orbitArc(front: true)); ctx.strokePath()
ctx.setStrokeColor(color(0xBFE8FF, 0.92)); ctx.setLineWidth(8)
ctx.addPath(orbitArc(front: true)); ctx.strokePath()

// ── Tracked object ────────────────────────────────────────────────────────────
let sat = orbitPoint(0.30 * .pi)
let glow = CGGradient(colorsSpace: space,
                      colors: [color(0xFFFFFF, 0.95), color(0x7FD0FF, 0.55), color(0x4FB3FF, 0)] as CFArray,
                      locations: [0, 0.3, 1])!
ctx.drawRadialGradient(glow, startCenter: sat, startRadius: 0, endCenter: sat, endRadius: 132, options: [])
ctx.setFillColor(color(0xFFFFFF, 1))
ctx.fillEllipse(in: CGRect(x: sat.x - 30, y: sat.y - 30, width: 60, height: 60))

// A dimmer companion on the back half.
let sat2 = orbitPoint(1.22 * .pi)
ctx.drawRadialGradient(glow, startCenter: sat2, startRadius: 0, endCenter: sat2, endRadius: 70, options: [])
ctx.setFillColor(color(0x9FD6F5, 0.75))
ctx.fillEllipse(in: CGRect(x: sat2.x - 15, y: sat2.y - 15, width: 30, height: 30))

ctx.restoreGState()

// ── Plate edge ────────────────────────────────────────────────────────────────
ctx.addPath(squircle)
ctx.setStrokeColor(color(0xFFFFFF, 0.09))
ctx.setLineWidth(2)
ctx.strokePath()

// ── Write out ─────────────────────────────────────────────────────────────────
let master = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: master)
let png = rep.representation(using: .png, properties: [:])!
let masterURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caelus_icon_1024.png")
try png.write(to: masterURL)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    let dest = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(s).png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", "\(s)", "\(s)", masterURL.path, "--out", dest.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
}
print("wrote \(sizes.count) icon sizes to \(outDir)")
