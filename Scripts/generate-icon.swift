#!/usr/bin/env swift
// Renders the Enso app icon (an ensō brush circle with a charge-limit tick)
// and writes Assets/AppIcon.icns. Run: swift Scripts/generate-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

// Full-bleed squircle background (macOS supplies no mask for .icns).
let inset: CGFloat = 100
let bgRect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.12, alpha: 1),
])!
gradient.draw(in: squircle, angle: -90)

// Ensō: an open brush circle. Arc with a gap at the upper right,
// stroke width tapering suggested by two overlapping arcs.
let center = CGPoint(x: size / 2, y: size / 2)
let radius: CGFloat = 265

func strokeArc(from start: CGFloat, to end: CGFloat, width: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.96, alpha: alpha).cgColor)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius,
               startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
}

// Main body of the stroke (gap between 55° and 80°).
strokeArc(from: 80, to: 415 - 360 + 360, width: 58, alpha: 1.0)   // 80° → 415° (55°+360)
// A thinner trailing overlap to suggest the brush lifting off.
strokeArc(from: 20, to: 55, width: 40, alpha: 0.55)

// Charge-limit tick: a green dot at the 80% position along the ring
// (measured clockwise from top).
let angle = (90 - 0.8 * 360) * CGFloat.pi / 180
let dotCenter = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
ctx.setFillColor(NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.42, alpha: 1).cgColor)
let dotR: CGFloat = 46
ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2))

image.unlockFocus()

// Write master PNG, build iconset, convert to icns.
let fm = FileManager.default
let assets = URL(fileURLWithPath: "Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
let master = assets.appendingPathComponent("AppIcon-1024.png")
try png.write(to: master)

let sizes: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]
for (px, name) in sizes {
    let out = iconset.appendingPathComponent("icon_\(name).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", out.path]
    task.standardOutput = FileHandle.nullDevice
    try task.run(); task.waitUntilExit()
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
print("wrote Assets/AppIcon.icns")
