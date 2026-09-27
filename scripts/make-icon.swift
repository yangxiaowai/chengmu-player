import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (name, side) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(side) / 1024); transform.concat()
    let backdrop = NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916), xRadius: 206, yRadius: 206)
    NSColor(srgbRed: 0.065, green: 0.075, blue: 0.085, alpha: 1).setFill(); backdrop.fill()
    NSColor(srgbRed: 0.94, green: 0.66, blue: 0.29, alpha: 1).setFill()
    let mark = NSBezierPath(); mark.move(to: NSPoint(x: 384, y: 285)); mark.line(to: NSPoint(x: 733, y: 512)); mark.line(to: NSPoint(x: 384, y: 739)); mark.close(); mark.fill()
    let orbit = NSBezierPath(ovalIn: NSRect(x: 228, y: 228, width: 568, height: 568)); orbit.lineWidth = 12
    NSColor(srgbRed: 0.94, green: 0.66, blue: 0.29, alpha: 0.25).setStroke(); orbit.stroke()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("icon render failed") }
    try png.write(to: folder.appendingPathComponent(name + ".png"))
}
