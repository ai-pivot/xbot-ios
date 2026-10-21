import AppKit
import Foundation

let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.19, green: 0.40, blue: 0.32, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.setLineWidth(82); context.setLineCap(.round)
for angle in [0.0, Double.pi / 3, 2 * Double.pi / 3] {
    let dx = cos(angle) * 242, dy = sin(angle) * 242
    context.move(to: CGPoint(x: 512 - dx, y: 512 - dy)); context.addLine(to: CGPoint(x: 512 + dx, y: 512 + dy)); context.strokePath()
}
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Sources/XbotApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
