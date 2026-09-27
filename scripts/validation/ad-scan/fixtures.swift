import Foundation
import AppKit
import CoreText
@main struct Fixtures {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        for kind in ["ordinary", "advertisement", "subtitle", "corner", "brand"] {
            let context = CGContext(data: nil, width: 960, height: 540, bitsPerComponent: 8, bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.025, green: 0.07, blue: 0.13, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
            func text(_ string: String, _ x: Double, _ y: Double, _ size: Double) {
                let attributed = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Semibold" as CFString, size, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
                context.textPosition = CGPoint(x: x, y: y); CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            switch kind {
            case "advertisement": text("澳门新葡京", 280, 305, 64); text("线上娱乐  注册即送", 250, 230, 44)
            case "subtitle": text("澳门新葡京  线上娱乐 注册即送", 110, 45, 36)
            case "corner": text("澳门新葡京", 15, 490, 22); text("线上娱乐 注册即送", 15, 462, 20)
            case "brand": text("澳门新葡京", 280, 305, 64)
            default: text("普通剧情画面", 250, 270, 56)
            }
            if kind != "subtitle" { text("正常对白字幕 保持原时间轴", 230, 40, 30) }
            let image = NSBitmapImageRep(cgImage: context.makeImage()!)
            try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(kind + ".png"))
        }
    }
}
