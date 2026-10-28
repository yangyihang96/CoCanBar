// 用官网糖标（`Sources/CoCanBar/CandyMark.swift`）生成两版 app 图标：
// 暖色是橙红渐变（Support/AppIcon.icns），冷色是蓝色渐变（Support/AppIconCool.icns）。
// 面板左上角的品牌标按当前配色读其中一版（见 `BrandMark`），Finder 里仍用暖色那版。
//
// 顶层代码只能在 main.swift 里，所以要拷到临时目录和糖标一起编译：
//
//   mkdir -p /tmp/icongen && cp Sources/CoCanBar/CandyMark.swift /tmp/icongen/ \
//     && cp scripts/make-app-icon.swift /tmp/icongen/main.swift \
//     && swiftc -O /tmp/icongen/CandyMark.swift /tmp/icongen/main.swift -o /tmp/icongen/gen \
//     && /tmp/icongen/gen
//
// 按 macOS 图标网格：画布 1024、主体 824、圆角 185、logo 宽 56%。
import AppKit

private struct Variant {
    let name: String
    let top: NSColor
    let bottom: NSColor
    let output: String
}

private let variants: [Variant] = [
    Variant(name: "暖色", top: NSColor(srgbRed: 1.00, green: 0.60, blue: 0.29, alpha: 1),   // #FF9A4A
            bottom: NSColor(srgbRed: 1.00, green: 0.28, blue: 0.10, alpha: 1),              // #FF4719
            output: "Support/AppIcon.icns"),
    Variant(name: "冷色", top: NSColor(srgbRed: 0.44, green: 0.65, blue: 1.00, alpha: 1),   // #6FA5FF
            bottom: NSColor(srgbRed: 0.18, green: 0.48, blue: 0.96, alpha: 1),              // #2F7BF6
            output: "Support/AppIconCool.icns"),
]

private func makeIcon(pixels: Int, top: NSColor, bottom: NSColor) -> NSImage {
    let size = CGFloat(pixels)
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        let width = rect.width
        // 内容区按 macOS 图标网格留边（1024 下留 100）
        let inset = width * 100 / 1024
        let content = rect.insetBy(dx: inset, dy: inset)
        let radius = width * 185 / 1024
        let square = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.addPath(square)
        context.clip()
        // 竖向渐变：上浅下深
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: content.maxY),
                                   end: CGPoint(x: 0, y: content.minY), options: [])
        // 左上角一层柔和高光
        if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [NSColor(white: 1, alpha: 0.22).cgColor,
                                          NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
            let center = CGPoint(x: content.minX + content.width * 0.28, y: content.maxY - content.height * 0.18)
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: content.width * 0.78, options: [])
        }
        context.restoreGState()

        // 白色糖标居中等比缩放
        let logoWidth = content.width * 0.56
        let logoHeight = logoWidth / CandyMark.aspectRatio
        let logoRect = CGRect(x: content.midX - logoWidth / 2, y: content.midY - logoHeight / 2,
                              width: logoWidth, height: logoHeight)
        context.addPath(CandyMark.cgPath(fitInto: logoRect, flipY: true))
        context.setFillColor(NSColor.white.cgColor)
        context.fillPath()
        return true
    }
}

private func iconset(for variant: Variant) -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(variant.output)-\(UUID().uuidString).iconset")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            let image = makeIcon(pixels: pixels, top: variant.top, bottom: variant.bottom)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            try? png.write(to: directory.appendingPathComponent(name))
        }
    }
    return directory
}

for variant in variants {
    let directory = iconset(for: variant)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", directory.path, "-o", variant.output]
    try? process.run()
    process.waitUntilExit()
    try? FileManager.default.removeItem(at: directory)
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("生成失败：\(variant.output)\n".utf8))
        exit(process.terminationStatus)
    }
    print("已生成 \(variant.name)：\(variant.output)")
}
