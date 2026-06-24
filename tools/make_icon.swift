import AppKit
import CoreGraphics
import Foundation

// Renders the Solo app icon (single-pane file list motif) to a 1024×1024 PNG.
// Run: swift tools/make_icon.swift  -> writes tools/icon_master.png

let S: CGFloat = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S),
    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("ctx") }

// Use top-left origin coordinates.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r/255, g/255, b/255, a])!
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// ---- App body (rounded squircle with gradient) ----
let bodyInset: CGFloat = 88
let body = CGRect(x: bodyInset, y: bodyInset, width: S - bodyInset*2, height: S - bodyInset*2)
let bodyRadius = body.width * 0.2237

ctx.saveGState()
ctx.addPath(roundedPath(body, bodyRadius))
ctx.clip()
let grad = CGGradient(colorsSpace: colorSpace,
    colors: [rgb(83, 140, 255), rgb(45, 91, 216), rgb(33, 70, 180)] as CFArray,
    locations: [0.0, 0.6, 1.0])!
ctx.drawLinearGradient(grad,
    start: CGPoint(x: body.midX, y: body.minY),
    end: CGPoint(x: body.midX, y: body.maxY),
    options: [])
// Soft top sheen.
let sheen = CGGradient(colorsSpace: colorSpace,
    colors: [rgb(255, 255, 255, 0.22), rgb(255, 255, 255, 0.0)] as CFArray,
    locations: [0.0, 1.0])!
ctx.drawLinearGradient(sheen,
    start: CGPoint(x: body.midX, y: body.minY),
    end: CGPoint(x: body.midX, y: body.minY + body.height * 0.5),
    options: [])
ctx.restoreGState()

// ---- The single pane (white card with a drop shadow) ----
let card = CGRect(x: 268, y: 244, width: 488, height: 536)
let cardRadius: CGFloat = 56

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40,
              color: rgb(10, 30, 80, 0.35))
ctx.addPath(roundedPath(card, cardRadius))
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillPath()
ctx.restoreGState()

// Clip subsequent pane contents to the card.
ctx.saveGState()
ctx.addPath(roundedPath(card, cardRadius))
ctx.clip()

// Header / path strip.
let headerH: CGFloat = 96
let header = CGRect(x: card.minX, y: card.minY, width: card.width, height: headerH)
ctx.setFillColor(rgb(244, 247, 252))
ctx.fill(header)
// Three breadcrumb dots.
let dotY = header.midY
for (i, _) in [0,1,2].enumerated() {
    let dot = CGRect(x: card.minX + 44 + CGFloat(i) * 46 - 11, y: dotY - 11, width: 22, height: 22)
    ctx.setFillColor(rgb(176, 188, 208))
    ctx.fillEllipse(in: dot)
}
// Separator under header.
ctx.setFillColor(rgb(226, 232, 242))
ctx.fill(CGRect(x: card.minX, y: card.minY + headerH, width: card.width, height: 3))

// File rows.
let rowH: CGFloat = 46
let rowGap: CGFloat = 30
let rowLeft = card.minX + 44
let rowRight = card.maxX - 44
let iconSize: CGFloat = 40
let textLeft = rowLeft + iconSize + 24
var y = card.minY + headerH + 40

let rows = 6
let selectedIndex = 1
for i in 0..<rows {
    let rowRect = CGRect(x: card.minX, y: y - 14, width: card.width, height: rowH + 4)
    if i == selectedIndex {
        // Highlighted selection row (full-bleed accent bar).
        ctx.setFillColor(rgb(83, 140, 255))
        ctx.addPath(roundedPath(rowRect.insetBy(dx: 22, dy: 0), 18))
        ctx.fillPath()
    }
    // Leading file icon (small rounded square).
    let icon = CGRect(x: rowLeft, y: y, width: iconSize, height: iconSize)
    ctx.setFillColor(i == selectedIndex ? rgb(255, 255, 255) : rgb(120, 150, 210))
    ctx.addPath(roundedPath(icon, 10))
    ctx.fillPath()
    // Name line.
    let nameW = (rowRight - textLeft) * (i == selectedIndex ? 0.7 : (0.5 + CGFloat((i * 37) % 40) / 100.0))
    let name = CGRect(x: textLeft, y: y + iconSize/2 - 11, width: nameW, height: 22)
    ctx.setFillColor(i == selectedIndex ? rgb(255, 255, 255, 0.95) : rgb(196, 206, 222))
    ctx.addPath(roundedPath(name, 11))
    ctx.fillPath()
    y += rowH + rowGap
}
ctx.restoreGState()

// ---- Write PNG ----
guard let image = ctx.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
let out = URL(fileURLWithPath: "tools/icon_master.png")
try! data.write(to: out)
print("wrote \(out.path)")
