import AppKit
import SwiftUI

/// 制糖工厂的糖果标志，路径直接取自官网 logo（thecandysign.com 顶部导航那个 SVG）。
///
/// 原始 SVG 的 viewBox 是 `0 0 219 24`，第一个 `<path>` 就是这颗糖，占 x 0.048…41.051、y 0.101…23.866。
/// 这里把那段的坐标平移到原点（减去 0.0476 / 0.1012），其余数值原样保留，所以形状和官网完全一致。
/// 设计坐标是「y 向下」（和 SVG、SwiftUI 一致），画到 AppKit 的坐标系里时由 `flipY` 翻过来。
enum CandyMark {
    /// 设计尺寸，也就是那颗糖自己的宽高比（41.00 × 23.76 ≈ 1.73:1）。
    static let designSize = CGSize(width: 41.0033, height: 23.7647)

    /// 按高度算宽度时用。
    static var aspectRatio: CGFloat { designSize.width / designSize.height }

    /// 糖的轮廓（设计坐标，y 向下）。
    static func designPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 39.5849, y: 2.6597))
        path.addCurve(to: CGPoint(x: 32.6335, y: 10.1173),
                      control1: CGPoint(x: 36.0438, y: 3.6196), control2: CGPoint(x: 33.315, y: 6.5129))
        path.addCurve(to: CGPoint(x: 32.4061, y: 10.1143),
                      control1: CGPoint(x: 32.609, y: 10.2473), control2: CGPoint(x: 32.4259, y: 10.245))
        path.addCurve(to: CGPoint(x: 20.5017, y: 0),
                      control1: CGPoint(x: 31.5408, y: 4.3908), control2: CGPoint(x: 26.5424, y: 0))
        path.addCurve(to: CGPoint(x: 8.5971, y: 10.1144),
                      control1: CGPoint(x: 14.4609, y: 0), control2: CGPoint(x: 9.4625, y: 4.391))
        path.addCurve(to: CGPoint(x: 8.3697, y: 10.1175),
                      control1: CGPoint(x: 8.5774, y: 10.2452), control2: CGPoint(x: 8.3943, y: 10.2475))
        path.addCurve(to: CGPoint(x: 1.4183, y: 2.6597),
                      control1: CGPoint(x: 7.6883, y: 6.5131), control2: CGPoint(x: 4.9594, y: 3.6196))
        path.addCurve(to: CGPoint(x: 0, y: 3.7545),
                      control1: CGPoint(x: 0.7021, y: 2.4657), control2: CGPoint(x: 0, y: 3.0215))
        path.addLine(to: CGPoint(x: 0, y: 20.0102))
        path.addCurve(to: CGPoint(x: 1.4183, y: 21.105),
                      control1: CGPoint(x: 0, y: 20.7432), control2: CGPoint(x: 0.7021, y: 21.2992))
        path.addCurve(to: CGPoint(x: 8.3697, y: 13.6471),
                      control1: CGPoint(x: 4.9594, y: 20.1451), control2: CGPoint(x: 7.6883, y: 17.2516))
        path.addCurve(to: CGPoint(x: 8.5971, y: 13.6502),
                      control1: CGPoint(x: 8.3943, y: 13.5171), control2: CGPoint(x: 8.5774, y: 13.5194))
        path.addCurve(to: CGPoint(x: 20.5017, y: 23.7647),
                      control1: CGPoint(x: 9.4625, y: 19.3737), control2: CGPoint(x: 14.4609, y: 23.7647))
        path.addCurve(to: CGPoint(x: 32.4061, y: 13.6504),
                      control1: CGPoint(x: 26.5424, y: 23.7647), control2: CGPoint(x: 31.5408, y: 19.3739))
        path.addCurve(to: CGPoint(x: 32.6335, y: 13.6473),
                      control1: CGPoint(x: 32.4259, y: 13.5196), control2: CGPoint(x: 32.609, y: 13.5173))
        path.addCurve(to: CGPoint(x: 39.5849, y: 21.105),
                      control1: CGPoint(x: 33.315, y: 17.2517), control2: CGPoint(x: 36.0438, y: 20.1451))
        path.addCurve(to: CGPoint(x: 41.0033, y: 20.0102),
                      control1: CGPoint(x: 40.3012, y: 21.2992), control2: CGPoint(x: 41.0033, y: 20.7432))
        path.addLine(to: CGPoint(x: 41.0033, y: 3.7545))
        path.addCurve(to: CGPoint(x: 39.5849, y: 2.6597),
                      control1: CGPoint(x: 41.0033, y: 3.0215), control2: CGPoint(x: 40.3012, y: 2.4657))
        path.closeSubpath()
        return path
    }

    /// 把设计轮廓缩放到矩形里。`flipY` 为真时按 AppKit 的 y 向上画。
    static func cgPath(fitInto rect: CGRect, inset: CGFloat = 0, flipY: Bool) -> CGPath {
        let box = rect.insetBy(dx: inset, dy: inset)
        var transform = CGAffineTransform(translationX: box.minX, y: flipY ? box.maxY : box.minY)
        transform = transform.scaledBy(x: box.width / designSize.width,
                                       y: (flipY ? -1 : 1) * box.height / designSize.height)
        return designPath().copy(using: &transform) ?? designPath()
    }

    /// 直接画到 AppKit 的上下文里（y 向上）。`filled` 为假时只描边，用来区分离线状态。
    static func draw(in context: CGContext, rect: CGRect, filled: Bool) {
        let lineWidth = max(1, (rect.height * 0.09).rounded())
        context.addPath(cgPath(fitInto: rect, inset: filled ? 0 : lineWidth / 2, flipY: true))
        context.setLineJoin(.round)
        context.setLineCap(.round)
        if filled {
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
        } else {
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }
    }

    /// 画成一张模板图（纯黑，系统按深浅色自己着色）。
    static func image(size: NSSize, filled: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, rect: rect, filled: filled)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// SwiftUI 里的同一个标志。
struct CandyMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CandyMark.cgPath(fitInto: rect, flipY: false))
    }
}
