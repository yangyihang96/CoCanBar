#if DEBUG
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoCanKit
import CoCanStyle

/// `CoCanBar --snapshot <目录>`：用假数据离屏渲染面板，每个场景出浅色、深色两张 PNG，用来检查排版。
/// 只在调试构建里有；不读设备、不碰钥匙串和网络。
@MainActor
enum PanelSnapshots {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return false }
        applyThemeArgument()
        let directory = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for scenario in scenarios() {
                for scheme in [ColorScheme.light, .dark] {
                    let name = "\(scenario.name)-\(scheme == .dark ? "dark" : "light").png"
                    try render(scenario, scheme: scheme, to: directory.appendingPathComponent(name))
                    print("已生成 \(name)")
                }
            }
        } catch {
            FileHandle.standardError.write(Data("截图失败：\(error)\n".utf8))
        }
        return true
    }

    /// 调试参数 `--theme warm|cool`：这次运行用哪套配色。不写盘，免得改掉用户选的那套。
    static func applyThemeArgument() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--theme"), index + 1 < arguments.count,
              let mode = ThemeMode(rawValue: arguments[index + 1]) else { return }
        Palette.apply(mode, persist: false)
    }

    /// `--demo <场景号>`：返回该场景的演示数据模型（不轮询、不读钥匙串、不发请求）。
    static func demoModelIfRequested() -> AppModel? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo") else { return nil }
        applyThemeArgument()
        let all = scenarios()
        let number = index + 1 < arguments.count ? Int(arguments[index + 1]) ?? 1 : 1
        let scenario = all[min(max(number, 1), all.count) - 1]
        demoPresets = scenario.presets
        return scenario.model
    }

    /// `--demo-window`：把面板放进一个普通窗口显示，检查真实的 AppKit 渲染（系统菜单按钮、转圈、动画）。
    /// 新版 macOS 的菜单栏图标由系统进程托管，程序里点不开 MenuBarExtra 的面板，所以借普通窗口看。
    /// 窗口出来 2 秒后收起、1 秒后放回，用来核对“面板可见”的检测（日志分类 app，debug 级）。
    static func showDemoWindowIfRequested(model: AppModel) {
        guard liveWindowRequested || CommandLine.arguments.contains("--demo-window") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            let host = NSHostingView(rootView: PanelView(presets: demoPresets).environment(model))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "小电拼面板（\(dataLabel)）"
            window.appearance = demoAppearance
            window.isReleasedWhenClosed = false
            window.contentView = host
            placeOnPrimaryScreen(window, top: true)
            // 不抢键盘焦点
            window.orderFrontRegardless()
            demoWindow = window
            try? await Task.sleep(for: .seconds(2))
            window.orderOut(nil)
            try? await Task.sleep(for: .seconds(1))
            window.orderFrontRegardless()
            if CommandLine.arguments.contains("--demo-menu") {
                try? await Task.sleep(for: .seconds(1))
                NotificationCenter.default.post(name: openMenuNotification, object: nil)
            }
        }
    }

    /// `--live-window`：不用演示数据，用真实设备（照常轮询局域网、读钥匙串、调只读的 MCP 工具）把面板放进普通窗口，
    /// 核对实机读数下的排版；可以和 `--demo-settings`、`--demo-capture`、`--demo-light` 一起用。
    /// 窗口里的开关和按钮是真的，点了会控制设备。
    static var liveWindowRequested: Bool { CommandLine.arguments.contains("--live-window") }

    private static var dataLabel: String { liveWindowRequested ? "实机数据" : "演示数据" }

    /// `--demo-menu`：演示窗口放回后，自动弹出第一张卡片的「调节」菜单，用来截图核对菜单弹出的位置。
    static let openMenuNotification = Notification.Name("CoCanBarDemoOpenMenu")

    /// `--demo-settings [devices|general]`：再开一个普通窗口显示设置页。默认是「调节」页；
    /// 「调节」「设备」页加高到不用滚动，检查整页排版；`general` 和真实窗口一样大。
    /// `--demo-settings-device <名称>`：「调节」页看哪台设备（默认第一台），用来核对离线、云端这些状态。
    static func showDemoSettingsIfRequested(model: AppModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-settings") else { return }
        let page = index + 1 < arguments.count ? arguments[index + 1] : ""
        if let at = arguments.firstIndex(of: "--demo-settings-device"), at + 1 < arguments.count,
           let device = model.devices.first(where: { $0.name == arguments[at + 1] }) {
            model.settingsDevice = device.psn
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            let content: AnyView
            switch page {
            case "devices": content = AnyView(DevicesSettings().frame(width: 1080, height: 960))
            case "general": content = AnyView(GeneralSettings().frame(width: 1080, height: 720))
            default: content = AnyView(ControlsSettings().frame(width: 1080, height: 1500))
            }
            // 垫上窗口底色再画：控件的半透明部分直接和底色混合，截出来的图和窗口里一样
            let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor))
                .environment(model))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "小电拼设置（\(dataLabel)）"
            window.appearance = demoAppearance
            window.isReleasedWhenClosed = false
            window.contentView = host
            placeOnPrimaryScreen(window, offsetX: 200)
            window.orderFrontRegardless()
            demoSettingsWindow = window
        }
    }

    /// `--demo-capture <目录>`：演示窗口出来后，在第 4 秒和第 8 秒各把窗口内容画成 PNG（垫上窗口底色；
    /// 不截屏、不需要录屏权限）。两次对比可以分辨排版问题和刚出现时的过渡状态。
    static func captureDemoWindowsIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-capture"), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for second in [4, 8] {
                try? await Task.sleep(for: .seconds(4))
                for (name, window) in [("panel", demoWindow), ("settings", demoSettingsWindow)] {
                    guard let window, let data = capture(window) else { continue }
                    try? data.write(to: directory.appendingPathComponent("window-\(name)-\(second)s.png"))
                }
            }
            print("已导出演示窗口")
        }
    }

    private static func capture(_ window: NSWindow) -> Data? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        // `draw(in:)` 连透明度一起直接覆盖，会把底色冲掉，所以叠在上面画
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: nil)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 放到主显示器（带菜单栏的那块）上。`center()` 会放到当前焦点所在的屏幕，
    /// 那块屏幕正显示全屏 app 时，窗口落在看不见的桌面空间里，面板会一直判定为不可见。
    /// `top` 贴着菜单栏放，和真实面板的位置一样，弹出的菜单也就和实际一样长。
    private static func placeOnPrimaryScreen(_ window: NSWindow, offsetX: CGFloat = 0, top: Bool = false) {
        guard let area = NSScreen.screens.first?.visibleFrame else {
            window.center()
            return
        }
        let y = top ? area.maxY - window.frame.height - 4 : area.midY - window.frame.height / 2
        window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2 + offsetX, y: max(area.minY, y)))
    }

    /// `--demo-light` 用浅色外观，默认深色。
    private static var demoAppearance: NSAppearance? {
        NSAppearance(named: CommandLine.arguments.contains("--demo-light") ? .aqua : .darkAqua)
    }

    private static var demoPresets: [String: CardPreset] = [:]

    private static var demoWindow: NSWindow?
    private static var demoSettingsWindow: NSWindow?

    private struct Scenario {
        let name: String
        let model: AppModel
        var presets: [String: CardPreset] = [:]
    }

    private static func render(_ scenario: Scenario, scheme: ColorScheme, to url: URL) throws {
        let view = PanelView(presets: scenario.presets)
            .background(Palette.snapshotBackdrop)
            .environment(scenario.model)
            .environment(\.snapshotMode, true)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: 假数据（结构照 2026-10-15 两台真机的 metrics.json）

    private static let deskPSN = "1350000000000001"
    private static let sofaPSN = "1320000000000002"
    private static let sparePSN = "1234567890123456"

    private static func port(_ id: Int, state: String = "ACTIVE", attached: Bool = false, mA: Int = 0, mV: Int = 0,
                             fc: Int = 255, budget: Int = 0, seconds: Int = 0) -> PortMetrics {
        PortMetrics(id: id, active: true, state: state, portType: id == 0 ? "A" : "C", attached: attached,
                    chargingDurationSeconds: seconds, fcProtocol: fc, currentMilliamps: mA,
                    voltageMillivolts: mV, inputMillivolts: 30_000, powerBudgetWatts: budget)
    }

    private static var deskPorts: [PortMetrics] {
        [port(0),
         port(1, state: "ATTACHED", attached: true, mA: 3250, mV: 19_968, fc: 16, budget: 100, seconds: 1500),
         port(2, state: "ATTACHED", attached: true, mV: 5000),
         port(3, state: "INACTIVE"),
         port(4, state: "ATTACHED", attached: true, mA: 1359, mV: 5088, fc: 0, budget: 60, seconds: 1784)]
    }

    private static var sofaPorts: [PortMetrics] {
        [port(0),
         port(1, state: "ATTACHED", attached: true, mA: 2010, mV: 9012, fc: 18, budget: 30, seconds: 320),
         port(2), port(3), port(4)]
    }

    private static var idlePorts: [PortMetrics] { (0..<5).map { port($0) } }

    /// 演示用的识别结果（型号是虚构的，不对应真机）：C1 认出了型号和电池，C2 接着但没取电，C4 不走 PD。
    private static var deskIdentities: [Int: PortIdentity] {
        [1: PortIdentity(portID: 1, brand: "Apple", model: "MacBook Air", vendorID: 0x05AC, pdRevision: "PD 3.0",
                         requestedVolts: 20, requestedAmps: 3.25, maxWatts: 70,
                         battery: BatteryInfo(percent: 64, health: 91, designWh: 52.6),
                         cable: CableInfo(maxCurrent: "5A", maxVoltage: "20V", usbSpeed: "USB 3.2 Gen2")),
         2: PortIdentity(portID: 2, usesPD: false),
         4: PortIdentity(portID: 4, usesPD: false)]
    }

    private static var sofaIdentities: [Int: PortIdentity] {
        [1: PortIdentity(portID: 1, brand: "三星", model: "Galaxy S24", vendorID: 0x04E8, pdRevision: "PD 3.0",
                         requestedVolts: 9, requestedAmps: 2, supportsPPS: true, maxWatts: 25,
                         battery: BatteryInfo(percent: 58, health: 96, designWh: 15.4))]
    }

    /// 演示用的芯片温度和本次电量（和下面的曲线大致对得上）。
    private static var deskDetails: [Int: PortDetail] {
        [1: PortDetail(portID: 1, sessionEnergyMWh: 25_540, temperature: .warm),
         2: PortDetail(portID: 2, sessionEnergyMWh: 0, temperature: .cool),
         4: PortDetail(portID: 4, sessionEnergyMWh: 3_420, temperature: .moderate)]
    }

    private static var sofaDetails: [Int: PortDetail] {
        [1: PortDetail(portID: 1, sessionEnergyMWh: 1_600, temperature: .moderate)]
    }

    /// 演示用的云端读数（结构照 2026-10-16 真机的 `get_port_details`，数值和上面的桌子一样）：
    /// C1、C4 在充，C2 接着没取电但有 5V 输出（确定开着），A 和 C3 空着（开没开读不到）。
    private static let deskCloudJSON = """
    {"ports":[
     {"port":1,"connected":false,"fc_protocol":"Not Charging","vout_mv":0,"iout_ma":0,"vin_mv":30270,
      "die_temperature":"moderate","session_id":0,"session_charge_mwh":0},
     {"port":2,"connected":true,"fc_protocol":"PD Fixed 20V","vout_mv":19968,"iout_ma":3250,"vin_mv":30250,
      "die_temperature":"warm","session_id":12,"session_charge_mwh":25540},
     {"port":3,"connected":true,"fc_protocol":"Not Charging","vout_mv":5000,"iout_ma":0,"vin_mv":30250,
      "die_temperature":"cool","session_id":13,"session_charge_mwh":0},
     {"port":4,"connected":false,"fc_protocol":"Not Charging","vout_mv":0,"iout_ma":0,"vin_mv":30210,
      "die_temperature":"moderate","session_id":0,"session_charge_mwh":0},
     {"port":5,"connected":true,"fc_protocol":"USB Legacy Charging","vout_mv":5088,"iout_ma":1359,"vin_mv":30190,
      "die_temperature":"moderate","session_id":10,"session_charge_mwh":3420}
    ]}
    """

    /// 演示用的充电曲线（数值是编的，形状照实测）。最近 30 分钟当作从小电拼内存读到的，更早的当作本 app 记的，
    /// 中间有 20 分钟 app 没开。桌子 C1：25 分钟前插上笔记本，中间降过一段功率；更早充过一台手机。C4 一直是 5V 小电流。
    private static func demoHistory(now: Date) -> [String: [Int: PortHistory]] {
        let end = PortHistory.slot(now).addingTimeInterval(-PortHistory.step)
        /// `ago` 是离现在多少秒，`watts` 按 `ago` 给功率，0 表示没接。
        func points(_ range: ClosedRange<Double>, volts: Double, watts: (Double) -> Double) -> [PowerSample] {
            stride(from: range.upperBound, through: range.lowerBound, by: -PortHistory.step).map { ago in
                let value = max(watts(ago), 0)
                return PowerSample(time: end.addingTimeInterval(-ago), watts: value,
                                   volts: value > 0 ? volts : 0, amps: value > 0 ? value / volts : 0)
            }
        }
        func ripple(_ ago: Double, _ size: Double) -> Double { (sin(ago / 37) * 0.7 + sin(ago / 11) * 0.3) * size }
        func laptop(_ ago: Double) -> Double {
            switch ago {
            case 1500...: return 0
            case 1480...: return 2.5
            case 1440...: return 2.5 + (1480 - ago) / 40 * 60
            case 900...: return 66 + ripple(ago, 0.6)
            case 720...: return 46 + ripple(ago, 1.2)
            default: return 64.9 + ago / 720 * 0.8 + ripple(ago, 0.4)
            }
        }
        func phone(_ ago: Double) -> Double {
            switch ago {
            case 6600...: return 0
            case 5400...: return 19.5 + ripple(ago, 0.5)
            case 4200...: return 3 + (ago - 4200) / 1200 * 16 + ripple(ago, 0.3)
            default: return 0
            }
        }
        let memory: ClosedRange<Double> = 0...1790
        let laptopLAN = points(3900...7190, volts: 9) { phone($0) } + points(1800...2700, volts: 19.968) { laptop($0) }
        let smallLAN = points(3900...7190, volts: 5.088) { _ in 0 } + points(1800...2700, volts: 5.088) { _ in 0 }
        return [
            deskPSN: [
                1: PortHistory(recorded: laptopLAN, fromDevice: points(memory, volts: 19.968, watts: laptop),
                               deviceLoadedAt: now),
                4: PortHistory(recorded: smallLAN, fromDevice: points(memory, volts: 5.088) { $0 > 1784 ? 0 : 6.9 + ripple($0, 0.08) },
                               deviceLoadedAt: now),
            ],
            sofaPSN: [
                1: PortHistory(fromDevice: points(memory, volts: 9.012) { $0 > 320 ? 0 : 18.1 + ripple($0, 0.3) },
                               deviceLoadedAt: now),
            ],
        ]
    }

    private static func online(_ ports: [PortMetrics], control: ControlState = ControlState(),
                               identities: [Int: PortIdentity] = [:], details: [Int: PortDetail] = [:],
                               busy: String? = nil, message: String? = nil, isError: Bool = false) -> DeviceRuntime {
        var state = DeviceRuntime()
        state.metrics = DeviceMetrics(ports: ports, system: nil)
        state.lastSuccess = Date()
        state.control = control
        state.identity = IdentityState(ports: identities, details: details, signature: PortIdentity.signature(of: ports),
                                       loadedAt: Date())
        state.busy = busy
        state.message = message
        state.messageIsError = isError
        return state
    }

    private static func scenarios() -> [Scenario] {
        let desk = DeviceConfig(psn: deskPSN, name: "桌子", lastStrategy: ChargingStrategy.fast.rawValue)
        let sofa = DeviceConfig(psn: sofaPSN, name: "沙发")
        let spare = DeviceConfig(psn: sparePSN, name: "小电拼 3456")

        var loaded = ControlState()
        loaded.temperature = .powerFirst
        loaded.display = .medium
        loaded.loadedAt = Date()
        // `--demo-cp02s`：当作 CP02S，多出屏显模式、待机显示和整点报时，核对状态屏卡片的排版
        if CommandLine.arguments.contains("--demo-cp02s") {
            loaded.statusMode = .power
            loaded.idleDisplay = .clock
            loaded.hourlyChime = true
            loaded.supportsExtendedDisplay = true
        }

        var offline = DeviceRuntime()
        offline.metrics = DeviceMetrics(ports: sofaPorts, system: nil)
        offline.lastSuccess = Date(timeIntervalSinceNow: -120)
        offline.lastError = "请求超时（4 秒）"
        offline.failures = 6

        // Mac 不在家：桌子改读云端，10 分钟前在本机关过 C3；沙发局域网和云端都读不到
        let cloudJSON = JSONValue.parse(deskCloudJSON)
        var cloud = DeviceRuntime()
        cloud.metrics = CloudReading.metrics(from: cloudJSON)
        cloud.lastSuccess = Date()
        cloud.source = .cloud
        cloud.failures = 12
        cloud.lastError = LANError.unresolved("cp02-desk.local").localizedDescription
        cloud.control = loaded
        cloud.identity = IdentityState(ports: deskIdentities, details: PortDetail.parse(cloudJSON),
                                       signature: (cloud.metrics?.ports).map(PortIdentity.signature(of:)), loadedAt: Date())
        cloud.portCommands = [3: PortCommand(on: false, at: Date(timeIntervalSinceNow: -600))]

        var unreachable = offline
        unreachable.lastSuccess = Date(timeIntervalSinceNow: -1800)
        unreachable.lastError = LANError.unresolved("cp02-sofa.local").localizedDescription
        unreachable.cloudFailures = 3
        unreachable.cloudError = "MCP 请求失败：网络连接已中断"

        let both: Set = [deskPSN, sofaPSN]
        let history = demoHistory(now: Date())
        return [
            Scenario(name: "1-正常", model: AppModel(
                snapshotDevices: [desk, sofa],
                runtime: [deskPSN: online(deskPorts, control: loaded, identities: deskIdentities, details: deskDetails),
                          sofaPSN: online(sofaPorts, identities: sofaIdentities, details: sofaDetails)],
                configured: both, history: history)),
            Scenario(name: "2-选中与切换策略", model: AppModel(
                snapshotDevices: [desk, sofa],
                runtime: [deskPSN: online(deskPorts, control: loaded, identities: deskIdentities, details: deskDetails),
                          sofaPSN: online(sofaPorts, identities: sofaIdentities, details: sofaDetails)],
                configured: both, history: history),
                presets: [deskPSN: CardPreset(selected: 1), sofaPSN: CardPreset(pendingStrategy: .slow)]),
            Scenario(name: "3-关口确认与执行中", model: AppModel(
                snapshotDevices: [desk, sofa],
                runtime: [deskPSN: online(deskPorts, control: loaded),
                          sofaPSN: online(sofaPorts, busy: "正在关闭 C1…")],
                configured: both),
                presets: [deskPSN: CardPreset(selected: 4, pendingOff: 4)]),
            Scenario(name: "4-离线与提示", model: AppModel(
                snapshotDevices: [desk, sofa],
                runtime: [deskPSN: online(deskPorts, control: loaded, message: "已打开 C3"), sofaPSN: offline],
                configured: both, history: history)),
            Scenario(name: "5-连接中报错与只读", model: AppModel(
                snapshotDevices: [desk, sofa, spare],
                runtime: [deskPSN: DeviceRuntime(),
                          sofaPSN: online(sofaPorts, message: "MCP 请求失败：服务端返回 502，稍后再试", isError: true),
                          sparePSN: online(idlePorts)],
                configured: both),
                presets: [sparePSN: CardPreset(selected: 0)]),
            Scenario(name: "6-没有设备", model: AppModel(snapshotDevices: [], runtime: [:], configured: [])),
            Scenario(name: "7-云端读数", model: AppModel(
                snapshotDevices: [desk, sofa], runtime: [deskPSN: cloud, sofaPSN: unreachable],
                configured: both, history: history),
                presets: [deskPSN: CardPreset(selected: 3)]),
        ]
    }
}
#endif
