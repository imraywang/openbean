// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// 「声豆」图形：豆子轮廓 + 三道声波。坐标沿用设计稿的 100×100 网格（y 向下）。
/// App 图标由 Scripts/make-app-icon.swift 生成，这里只画菜单栏的单色模板图标。
enum BeanArt {
    /// 豆子轮廓，已按设计稿旋转 -35°；菜单栏里放大 1.1 倍给声波留空间
    static let bean: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 52, y: 15))
        p.addCurve(to: CGPoint(x: 78, y: 50), control1: CGPoint(x: 71, y: 15), control2: CGPoint(x: 78, y: 32))
        p.addCurve(to: CGPoint(x: 52, y: 85), control1: CGPoint(x: 78, y: 68), control2: CGPoint(x: 71, y: 85))
        p.addCurve(to: CGPoint(x: 24, y: 62), control1: CGPoint(x: 34, y: 85), control2: CGPoint(x: 24, y: 73))
        p.addCurve(to: CGPoint(x: 29, y: 50), control1: CGPoint(x: 24, y: 56), control2: CGPoint(x: 29, y: 54))
        p.addCurve(to: CGPoint(x: 24, y: 38), control1: CGPoint(x: 29, y: 46), control2: CGPoint(x: 24, y: 44))
        p.addCurve(to: CGPoint(x: 52, y: 15), control1: CGPoint(x: 24, y: 27), control2: CGPoint(x: 34, y: 15))
        p.closeSubpath()
        var t = CGAffineTransform(translationX: 50, y: 50).rotated(by: -35 * .pi / 180)
            .scaledBy(x: 1.1, y: 1.1).translatedBy(x: -50, y: -50)
        return p.copy(using: &t)!
    }()

    /// 三道声波（中线）
    static let bars: CGPath = {
        let p = CGMutablePath()
        for (x, y0, y1) in [(37.0, 44.0, 56.0), (51, 35, 65), (65, 41, 59)] {
            p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1))
        }
        return p
    }()

    enum State { case disconnected, connected, listening, syncing }

    /// 菜单栏模板图标（18pt，系统负责深浅色和按下高亮）
    static func menuIcon(_ state: State) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            // 设计稿视框 6…94 → 18pt
            c.scaleBy(x: 18 / 88, y: 18 / 88)
            c.translateBy(x: -6, y: -6)
            c.setLineWidth(6)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            c.setStrokeColor(.black)
            c.setFillColor(.black)

            if state == .disconnected { c.setAlpha(0.55) }
            if state == .listening {
                c.addPath(bean); c.drawPath(using: .fillStroke)
                c.setBlendMode(.clear)
                c.addPath(bars); c.strokePath()
                c.setBlendMode(.normal)
            } else {
                c.addPath(bean); c.strokePath()
                c.setLineWidth(5.5)
                c.addPath(bars); c.strokePath()
                c.setLineWidth(6)
            }
            c.setAlpha(1)

            switch state {
            case .disconnected:
                // 斜杠：先切一道缝再画线
                c.setBlendMode(.clear)
                c.setLineWidth(16)
                c.move(to: CGPoint(x: 14, y: 14)); c.addLine(to: CGPoint(x: 86, y: 86)); c.strokePath()
                c.setBlendMode(.normal)
                c.setLineWidth(6)
                c.move(to: CGPoint(x: 14, y: 14)); c.addLine(to: CGPoint(x: 86, y: 86)); c.strokePath()
            case .syncing:
                // 右下角下载箭头
                c.setBlendMode(.clear)
                c.fillEllipse(in: CGRect(x: 54, y: 54, width: 48, height: 48))
                c.setBlendMode(.normal)
                c.move(to: CGPoint(x: 78, y: 60)); c.addLine(to: CGPoint(x: 78, y: 92))
                c.move(to: CGPoint(x: 67, y: 81)); c.addLine(to: CGPoint(x: 78, y: 92)); c.addLine(to: CGPoint(x: 89, y: 81))
                c.strokePath()
            default:
                break
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "OpenBean"
        return img
    }

    static let menuIcons: [State: NSImage] = [
        .disconnected: menuIcon(.disconnected), .connected: menuIcon(.connected),
        .listening: menuIcon(.listening), .syncing: menuIcon(.syncing),
    ]
}
