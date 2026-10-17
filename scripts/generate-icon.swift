#!/usr/bin/env swift

import AppKit
import CoreGraphics

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rootDir = URL(fileURLWithPath: scriptDir).deletingLastPathComponent().path
let fm = FileManager.default

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let inset = size * 0.05
    let roundedRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = size * 0.22

    let bgPath = CGPath(roundedRect: roundedRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(bgPath)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 67.0/255.0, green: 56.0/255.0, blue: 202.0/255.0, alpha: 1.0), // #4338ca
        CGColor(red: 23.0/255.0, green: 25.0/255.0, blue: 35.0/255.0, alpha: 1.0),  // #171923
    ]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors as CFArray, locations: [0.0, 1.0]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: size),
                                   end: CGPoint(x: size, y: 0),
                                   options: [])
    }

    let s = (size * 0.88) / 64.0
    let xOffset = (size - 64.0 * s) / 2.0
    let yOffset = (size - 64.0 * s) / 2.0

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        return CGPoint(x: xOffset + x * s, y: size - (yOffset + y * s))
    }

    // Draw "Aa" text in upper center
    let fontSize = 24.0 * s
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]
    let str = NSAttributedString(string: "Aa", attributes: attrs)
    let strSize = str.size()
    let textOrigin = CGPoint(x: (size - strSize.width) / 2.0 - 3 * s, y: size * 0.43)
    str.draw(at: textOrigin)

    // Red squiggly underline below "Aa"
    let squiggle = CGMutablePath()
    squiggle.move(to: p(13, 44))
    squiggle.addQuadCurve(to: p(19, 44), control: p(16, 40))
    squiggle.addQuadCurve(to: p(25, 44), control: p(22, 48))
    squiggle.addQuadCurve(to: p(31, 44), control: p(28, 40))
    squiggle.addQuadCurve(to: p(37, 44), control: p(34, 48))

    context.saveGState()
    context.setStrokeColor(CGColor(red: 248.0/255.0, green: 113.0/255.0, blue: 113.0/255.0, alpha: 1.0))
    context.setLineWidth(3.2 * s)
    context.setLineCap(.round)
    context.addPath(squiggle)
    context.strokePath()
    context.restoreGState()

    // Emerald checkmark badge on right
    let checkPath = CGMutablePath()
    checkPath.move(to: p(40, 42))
    checkPath.addLine(to: p(45, 47))
    checkPath.addLine(to: p(54, 35))

    context.saveGState()
    context.setStrokeColor(CGColor(red: 52.0/255.0, green: 211.0/255.0, blue: 153.0/255.0, alpha: 1.0))
    context.setLineWidth(4.0 * s)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(checkPath)
    context.strokePath()
    context.restoreGState()

    image.unlockFocus()
    return image
}

let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

let iconsetPath = "\(rootDir)/AppIcon.iconset"
let icnsPath = "\(rootDir)/AppIcon.icns"
try? fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = renderIcon(size: size)
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        continue
    }
    let path = "\(iconsetPath)/\(name).png"
    try! pngData.write(to: URL(fileURLWithPath: path))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath, "-o", icnsPath]
try! process.run()
process.waitUntilExit()
try? fm.removeItem(atPath: iconsetPath)
