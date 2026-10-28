#if SWIFT_PACKAGE
import AppKit
import SwiftUI
import WidgetKit
import CoCanKit
import CoCanStyle

/// 离屏画出三种尺寸在浅色、深色下的样子和几种状态，核对排版用。
/// 尺寸是 macOS 桌面小组件的常见尺寸；系统真正给的大小随屏幕略有不同。
enum WidgetSnapshots {
    static let families: [(family: WidgetFamily, label: String, size: CGSize)] = [
        (.systemSmall, "小", CGSize(width: 170, height: 170)),
        (.systemMedium, "中", CGSize(width: 364, height: 170)),
        (.systemLarge, "大", CGSize(width: 364, height: 382)),
    ]

    @MainActor
    static func render(arguments: [String]) {
        // `--theme warm|cool`：画哪套配色（不写盘）
        if let index = arguments.firstIndex(of: "--theme"), index + 1 < arguments.count,
           let mode = ThemeMode(rawValue: arguments[index + 1]) {
            Palette.apply(mode, persist: false)
        }
        let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "widget-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        let all = families.map(\.family)
        let base = ChargerEntry.preview(date: now)

        var pending = base
        pending.pending = PendingConfirmation(psn: "DEMO0001", port: 2, expiresAt: now.addingTimeInterval(8))
        var sent = base
        sent.notice = WidgetNotice(psn: "DEMO0001", text: "正在关闭 C4…", isError: false, postedAt: now,
                                   expiresAt: now.addingTimeInterval(15))
        var notRunning = base
        notRunning.notice = WidgetNotice(psn: "DEMO0001", text: "菜单栏 app 没在运行，打开「小电拼」后再试", isError: true,
                                         postedAt: now, expiresAt: now.addingTimeInterval(10))
        var noMCP = WidgetSnapshot.demo(now: now)
        noMCP.devices[0].controllable = false
        var offline = WidgetSnapshot.demo(now: now)
        offline.devices[0].online = false
        offline.devices[0].readAt = now.addingTimeInterval(-90)
        var directFailed = ChargerEntry(date: now, snapshot: .demo(now: now.addingTimeInterval(-40 * 60)), psn: nil)
        directFailed.appRunning = false
        directFailed.directFailed = true
        var appQuit = base
        appQuit.appRunning = false
        // Mac 不在家，菜单栏 app 改读云端：没在供电的口开关状态未知，开关不能点
        var cloud = WidgetSnapshot.demo(now: now)
        cloud.devices[0].viaCloud = true
        for index in cloud.devices[0].ports.indices where cloud.devices[0].ports[index].volts < 3 {
            cloud.devices[0].ports[index].poweredOn = nil
        }

        let cases: [(name: String, entry: ChargerEntry, families: [WidgetFamily])] = [
            ("正常", base, all),
            ("第二台-睡眠充", ChargerEntry(date: now, snapshot: .demo(now: now), psn: "DEMO0002"), all),
            ("待确认关闭", pending, [.systemMedium, .systemLarge]),
            ("已发送", sent, [.systemLarge]),
            ("app没运行", notRunning, [.systemLarge]),
            ("没配MCP", ChargerEntry(date: now, snapshot: noMCP, psn: nil), [.systemLarge]),
            ("离线", ChargerEntry(date: now, snapshot: offline, psn: nil), all),
            ("读数过时", ChargerEntry(date: now, snapshot: .demo(now: now.addingTimeInterval(-40 * 60)), psn: nil), all),
            ("app没开-小组件直读", .directPreview(date: now), all),
            ("app没开-直读失败", directFailed, [.systemLarge]),
            ("app刚退出", appQuit, [.systemLarge]),
            ("云端读数", ChargerEntry(date: now, snapshot: cloud, psn: nil), all),
            ("没有数据", ChargerEntry(date: now, snapshot: nil, psn: nil), all),
            ("没有设备", ChargerEntry(date: now, snapshot: WidgetSnapshot(updatedAt: now, devices: []), psn: nil),
             [.systemSmall]),
        ]
        for item in cases {
            for scheme in [ColorScheme.light, .dark] {
                for spec in families where item.families.contains(spec.family) {
                    let name = "\(item.name)-\(spec.label)-\(scheme == .dark ? "深色" : "浅色").png"
                    write(item.entry, family: spec.family, size: spec.size, scheme: scheme,
                          to: output.appendingPathComponent(name))
                }
            }
        }
    }

    @MainActor
    private static func write(_ entry: ChargerEntry, family: WidgetFamily, size: CGSize, scheme: ColorScheme, to url: URL) {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let view = ChargerWidgetContent(entry: entry, family: family)
            .frame(width: size.width, height: size.height)
            .background(Palette.card)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.cardStroke))
            .padding(18)
            // 桌面底色
            .background(scheme == .dark ? Color(hex: 0x30323A) : Color(hex: 0xD8DDE5))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("渲染失败：\(url.lastPathComponent)")
            return
        }
        do {
            try data.write(to: url)
            print(url.path)
        } catch {
            print("写入失败：\(url.lastPathComponent)")
        }
    }
}
#endif
