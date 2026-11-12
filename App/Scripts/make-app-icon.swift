// SPDX-License-Identifier: Apache-2.0
// 生成 App 图标（「声豆」）：swift App/Scripts/make-app-icon.swift
// 输出到 App/OpenBean/Resources/Assets.xcassets/AppIcon.appiconset。图形和设计稿一致（100×100 网格，y 向下）。

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "App/OpenBean/Resources/Assets.xcassets/AppIcon.appiconset")

func beanPath(scale: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 52, y: 15))
    p.addCurve(to: CGPoint(x: 78, y: 50), control1: CGPoint(x: 71, y: 15), control2: CGPoint(x: 78, y: 32))
    p.addCurve(to: CGPoint(x: 52, y: 85), control1: CGPoint(x: 78, y: 68), control2: CGPoint(x: 71, y: 85))
    p.addCurve(to: CGPoint(x: 24, y: 62), control1: CGPoint(x: 34, y: 85), control2: CGPoint(x: 24, y: 73))
    p.addCurve(to: CGPoint(x: 29, y: 50), control1: CGPoint(x: 24, y: 56), control2: CGPoint(x: 29, y: 54))
    p.addCurve(to: CGPoint(x: 24, y: 38), control1: CGPoint(x: 29, y: 46), control2: CGPoint(x: 24, y: 44))
    p.addCurve(to: CGPoint(x: 52, y: 15), control1: CGPoint(x: 24, y: 27), control2: CGPoint(x: 34, y: 15))
    p.closeSubpath()
    // SVG：rotate(-35 50 50) translate(50 50) scale(s) translate(-50 -50)
    var t = CGAffineTransform(translationX: 50, y: 50)
        .rotated(by: -35 * .pi / 180)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -50, y: -50)
    return p.copy(using: &t)!
}

func render(px: Int) -> CGImage {
    let n = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // y 向下，和设计稿一致
    ctx.translateBy(x: 0, y: n); ctx.scaleBy(x: 1, y: -1)

    // macOS 图标网格：1024 画布里 824 的圆角方块，四周留阴影
    let inset = n * 100 / 1024, side = n * 824 / 1024
    let body = CGRect(x: inset, y: inset, width: side, height: side)
    let shape = CGPath(roundedRect: body, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -n * 10 / 1024), blur: n * 20 / 1024,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.addPath(shape); ctx.setFillColor(CGColor(red: 0.18, green: 0.29, blue: 0.94, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [CGColor(red: 0x4A / 255, green: 0x66 / 255, blue: 1, alpha: 1),
                                   CGColor(red: 0x2D / 255, green: 0x4B / 255, blue: 0xF0 / 255, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])

    // 图形：64px 及以下用小尺寸版（豆子放大、声波加粗）
    let small = px <= 64
    ctx.translateBy(x: body.minX, y: body.minY)
    ctx.scaleBy(x: side / 100, y: side / 100)
    ctx.addPath(beanPath(scale: small ? 1.14 : 1))
    ctx.setFillColor(.white); ctx.fillPath()
    let bars: [CGRect] = small
        ? [CGRect(x: 31, y: 40, width: 10, height: 20), CGRect(x: 45, y: 31, width: 10, height: 38), CGRect(x: 59, y: 37, width: 10, height: 26)]
        : [CGRect(x: 35, y: 42, width: 7, height: 16), CGRect(x: 46.5, y: 32, width: 7, height: 36), CGRect(x: 58, y: 39, width: 7, height: 22)]
    ctx.setFillColor(CGColor(red: 0x2D / 255, green: 0x4B / 255, blue: 0xF0 / 255, alpha: 1))
    for b in bars {
        ctx.addPath(CGPath(roundedRect: b, cornerWidth: b.width / 2, cornerHeight: b.width / 2, transform: nil))
    }
    ctx.fillPath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

var images: [[String: String]] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(px: pt * scale), nil)
    CGImageDestinationFinalize(dest)
    images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)", "filename": name])
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("已生成 \(images.count) 个图标到 \(out.path)")
