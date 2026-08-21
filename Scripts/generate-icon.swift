#!/usr/bin/env swift
// generate-icon.swift — renders the Lenscap app icon and packages it as
// Assets/AppIcon.icns.
//
// Usage:  swift Scripts/generate-icon.swift
//
// Design: standard macOS icon grid — an 824pt rounded-rect (radius ≈ 0.22 ×
// side) centered in the 1024pt canvas with the usual transparent margin and a
// soft drop shadow. Motif: a camera lens seen straight on with its cap off —
// light neutral barrel ring, dark glass with an off-center specular arc — on a
// quiet graphite background with a barely-there vertical gradient. Every size
// is re-rendered from vectors (no bitmap downscaling), then iconutil compiles
// the .icns.

import AppKit
import CoreGraphics
import ImageIO
import Foundation

// MARK: - Palette (quiet graphite / slate, light neutral barrel)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(UInt32, CGFloat)], locations: [CGFloat]) -> CGGradient {
    CGGradient(
        colorsSpace: srgb,
        colors: stops.map { rgb($0.0, $0.1) } as CFArray,
        locations: locations
    )!
}

// MARK: - Drawing (all coordinates in the 1024pt master space, origin bottom-left)

func drawIcon(in ctx: CGContext, pixelSize: Int) {
    let scale = CGFloat(pixelSize) / 1024.0
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // --- Canvas: standard macOS grid. 824pt squircle centered in 1024. ---
    let margin: CGFloat = 100
    let plate = CGRect(x: margin, y: margin, width: 1024 - 2 * margin, height: 1024 - 2 * margin)
    let cornerRadius = plate.width * 0.22
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
    )

    // Soft drop shadow behind the plate (like every stock macOS icon).
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.30)
    )
    ctx.addPath(platePath)
    ctx.setFillColor(rgb(0x22262B))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: barely-there vertical gradient, two close graphite tones.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0x2E3238, 1), (0x22262B, 1)], locations: [0, 1]),
        start: CGPoint(x: 512, y: plate.maxY),
        end: CGPoint(x: 512, y: plate.minY),
        options: []
    )

    // Thin light ring echoing the squircle, inset from the edge. Barely there.
    let inset: CGFloat = 26
    let echoRect = plate.insetBy(dx: inset, dy: inset)
    let echoRadius = cornerRadius - inset * 0.8
    ctx.addPath(CGPath(
        roundedRect: echoRect, cornerWidth: echoRadius, cornerHeight: echoRadius, transform: nil
    ))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.05))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // --- The lens, straight on. Center of the plate. ---
    let c = CGPoint(x: 512, y: 512)
    func circle(_ radius: CGFloat) -> CGRect {
        CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
    }

    // Ground shadow so the barrel sits on the plate rather than floating.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: rgb(0x000000, 0.35))
    ctx.setFillColor(rgb(0x14171B))
    ctx.fillEllipse(in: circle(304))
    ctx.restoreGState()

    // Outer barrel ring: light neutral, lit slightly from above.
    ctx.saveGState()
    ctx.addEllipse(in: circle(304))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0xD9DCE0, 1), (0xA9AEB5, 1)], locations: [0, 1]),
        start: CGPoint(x: c.x, y: c.y + 304),
        end: CGPoint(x: c.x, y: c.y - 304),
        options: []
    )
    ctx.restoreGState()
    // Hairline to seat the ring against the background.
    ctx.setStrokeColor(rgb(0x000000, 0.18))
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: circle(303))

    // Barrel throat: dark step between the metal ring and the glass.
    ctx.setFillColor(rgb(0x191C21))
    ctx.fillEllipse(in: circle(252))

    // Lens glass: deep neutral radial gradient, center of light pushed
    // up-and-left so the glass reads as curved.
    ctx.saveGState()
    ctx.addEllipse(in: circle(238))
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([(0x33383F, 1), (0x1B1F24, 1), (0x0F1215, 1)], locations: [0, 0.55, 1]),
        startCenter: CGPoint(x: c.x - 70, y: c.y + 80), startRadius: 0,
        endCenter: c, endRadius: 250,
        options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Inner element: the smaller front group, a shade darker.
    ctx.setFillColor(rgb(0x121519))
    ctx.fillEllipse(in: circle(148))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.06))
    ctx.setLineWidth(3)
    ctx.strokeEllipse(in: circle(148))

    // Specular highlight: one short arc, upper-left, on the glass.
    ctx.saveGState()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.45))
    ctx.setLineWidth(20)
    ctx.setLineCap(.round)
    ctx.addArc(
        center: c, radius: 192,
        startAngle: .pi * 0.58, endAngle: .pi * 0.88, clockwise: false
    )
    ctx.strokePath()
    // A smaller, fainter echo just inside it.
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
    ctx.setLineWidth(10)
    ctx.addArc(
        center: c, radius: 120,
        startAngle: .pi * 0.60, endAngle: .pi * 0.78, clockwise: false
    )
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState() // plate clip
    ctx.restoreGState() // scale
}

// MARK: - Rendering + PNG output

func renderPNG(pixelSize: Int, to url: URL) {
    guard let ctx = CGContext(
        data: nil, width: pixelSize, height: pixelSize,
        bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create CGContext for \(pixelSize)px") }

    drawIcon(in: ctx, pixelSize: pixelSize)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("could not encode \(url.lastPathComponent)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("could not write \(url.lastPathComponent)")
    }
}

// MARK: - Pipeline: iconset -> iconutil -> Assets/AppIcon.icns

let fm = FileManager.default
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let assetsDir = repoRoot.appendingPathComponent("Assets")
let iconsetDir = assetsDir.appendingPathComponent("AppIcon.iconset")
let icnsURL = assetsDir.appendingPathComponent("AppIcon.icns")

try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// (base point size, scale) pairs required for a complete iconset.
let entries: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
for (points, scale) in entries {
    let suffix = scale == 2 ? "@2x" : ""
    let url = iconsetDir.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    renderPNG(pixelSize: points * scale, to: url)
    print("  wrote \(url.lastPathComponent)")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}

try? fm.removeItem(at: iconsetDir)

let bytes = (try fm.attributesOfItem(atPath: icnsURL.path)[.size] as? Int) ?? 0
print("Wrote \(icnsURL.path) (\(bytes) bytes)")
