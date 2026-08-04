// Renders a 1024×1024 app icon (waveform on a gradient) to a PNG.
// Usage: swift Scripts/make_icon.swift <output.png>
import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}
let s = CGFloat(size)
let rect = CGRect(x: 0, y: 0, width: s, height: s)

// Rounded-rect (macOS "squircle"-ish) clip.
let clip = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
ctx.addPath(clip)
ctx.clip()

// Diagonal indigo → violet gradient.
let colors = [
    CGColor(red: 0.36, green: 0.42, blue: 0.98, alpha: 1),
    CGColor(red: 0.58, green: 0.30, blue: 0.92, alpha: 1)
] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

// Soft top highlight.
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
ctx.fill(CGRect(x: 0, y: s * 0.55, width: s, height: s * 0.45))

// Five rounded "waveform" bars, centered.
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
let heights: [CGFloat] = [0.30, 0.52, 0.78, 0.52, 0.30]
let barW = s * 0.085
let gap = s * 0.075
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (s - totalW) / 2
for h in heights {
    let barH = s * h
    let y = (s - barH) / 2
    let bar = CGPath(roundedRect: CGRect(x: x, y: y, width: barW, height: barH),
                     cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
    ctx.addPath(bar)
    ctx.fillPath()
    x += barW + gap
}

guard let cg = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: cg)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
