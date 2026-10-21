import SwiftUI
import AppKit
import CoCanKit
import CoCanStyle

/// 离屏截图用：预设一张卡片的选中端口和待确认操作。
struct CardPreset {
    var selected: Int?
    var pendingOff: Int?
    var pendingStrategy: ChargingStrategy?
}

/// 点击菜单栏图标后弹出的面板，样式照小程序：奶油底、白卡片、粗黑数字。
/// 顶部是品牌和合计功率，下面每台设备一个分组（灰色标题 + 白卡片）。
/// 各区域高度固定，读数、状态和提示变化时只在原位置换内容，面板不会上下跳。
struct PanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.snapshotMode) private var snapshotMode

    var presets: [String: CardPreset] = [:]

    @State private var windowVisible = false
    @State private var popCount = 0

    static let width: CGFloat = 308

    private var visible: Bool { snapshotMode || windowVisible }

    var body: some View {
        VStack(spacing: 0) {
            header
            cards
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
        }
        .frame(width: Self.width)
        .background { backdrop }
        .environment(\.panelVisible, visible)
        .background {
            if !snapshotMode {
                WindowVisibilityReader { windowVisible = $0 }
            }
        }
        .onChange(of: windowVisible) { _, isVisible in
            guard isVisible else { return }
            popCount += 1
            Task { await model.refreshAll() }
        }
        .task { await model.refreshAll() }
    }

    /// 奶油色底，顶上一层很淡的暖色光晕（小程序首页顶部的渐变）。
    private var backdrop: some View {
        Rectangle()
            .fill(Palette.canvas)
            .overlay(alignment: .top) {
                LinearGradient(colors: [ModeColors.standard.theme.opacity(0.16), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
            }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(popCount: popCount)
            VStack(alignment: .leading, spacing: 3) {
                Text("小电拼")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 5) {
                    StatusBadge(status: overallStatus, text: badgeText)
                    Text(chargingSummary)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: chargingSummary)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.devices.count > 1 {
                VStack(alignment: .trailing, spacing: 1) {
                    DotLabel(text: "合计功率")
                    PowerReadout(watts: onlineTotal, size: 22)
                }
            }
            moreMenu
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    private var onlineDevices: [DeviceConfig] {
        model.devices.filter { model.isOnline($0.psn) }
    }

    private var onlineTotal: Double? {
        let values = onlineDevices.compactMap { model.runtime[$0.psn]?.metrics?.totalWatts }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var overallStatus: StatusBadge.Status {
        if !onlineDevices.isEmpty { return .online }
        let failed = model.devices.contains { model.runtime[$0.psn]?.lastError != nil }
        return model.devices.isEmpty || failed ? .offline : .connecting
    }

    private var badgeText: String {
        let total = model.devices.count
        if total == 0 { return "未添加" }
        let online = onlineDevices.count
        if online == 0 { return overallStatus == .connecting ? "连接中" : (total == 1 ? "离线" : "\(total) 台离线") }
        if online == total { return total == 1 ? "在线" : "\(total) 台在线" }
        return "\(online)/\(total) 在线"
    }

    private var chargingSummary: String {
        if model.devices.isEmpty { return "在设置里添加设备" }
        let online = onlineDevices
        if online.isEmpty { return overallStatus == .connecting ? "正在读取…" : "读不到设备" }
        let charging = online.reduce(0) { $0 + (model.runtime[$1.psn]?.metrics?.chargingCount ?? 0) }
        return charging > 0 ? "\(charging) 口在充" : "没有在充"
    }

    @ViewBuilder
    private var moreMenu: some View {
        let label = Image(systemName: "gearshape")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.heading)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        if snapshotMode {
            label
        } else {
            Menu {
                Button("立即刷新") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r")
                Button("设置…", action: showSettings)
                    .keyboardShortcut(",")
                Divider()
                Button("退出小电拼") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("设置、刷新、退出")
        }
    }

    // MARK: 设备

    @ViewBuilder
    private var cards: some View {
        if model.devices.isEmpty {
            EmptyCard(openSettings: showSettings)
        } else if model.devices.count > 3 {
            // 设备多时限高滚动，面板不会超出屏幕
            ScrollView {
                deviceStack
            }
            .frame(height: DeviceCard.height * 3 + 20)
            .scrollIndicators(.never)
        } else {
            deviceStack
        }
    }

    private var deviceStack: some View {
        VStack(spacing: 10) {
            ForEach(model.devices) { device in
                DeviceCard(device: device, preset: presets[device.psn])
            }
        }
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}

/// 左上角的品牌小图标（就是 app 图标：糖果闪电）。每次打开面板弹一下，对应小程序里糖果图标的放大回弹。
struct BrandMark: View {
    let popCount: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// app 包里的图标；调试构建没有 app 包，就读项目里的图标文件。都读不到时画一个矢量闪电。
    @MainActor private static let icon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { return NSImage(contentsOf: url) }
        #if DEBUG
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Support/AppIcon.icns").standardizedFileURL
        return NSImage(contentsOf: url)
        #else
        return nil
        #endif
    }()

    var body: some View {
        mark
            // 系统开了“减少动态效果”就不弹
            .keyframeAnimator(initialValue: CGFloat(1), trigger: reduceMotion ? 0 : popCount) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0.6, duration: 0.01)
                    SpringKeyframe(1.12, duration: 0.24, spring: .snappy)
                    SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        if let icon = Self.icon {
            // 图标四周有约 10% 的透明边（含自带的投影），放大到 37pt，主体正好 30pt
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 37, height: 37)
                .frame(width: 30, height: 30)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Palette.brandLight, Palette.brand], startPoint: .top, endPoint: .bottom))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Palette.brand.opacity(0.35), radius: 3, y: 1)
        }
    }
}

/// 功率读数：小程序那种粗黑数字配浅灰单位，变化时数字滚动。
struct PowerReadout: View {
    let watts: Double?
    let size: CGFloat
    var dimmed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.1) {
            Text(watts.map(PanelFormat.watts) ?? "--")
                // 没有读数时的占位用细一点的字重，粗体的横杠像一块色块
                .font(.system(size: size, weight: watts == nil ? .medium : .heavy))
                .monospacedDigit()
                .foregroundStyle(watts == nil || dimmed ? AnyShapeStyle(Palette.unit) : AnyShapeStyle(Palette.ink))
                .contentTransition(.numericText(value: watts ?? 0))
            Text("W")
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundStyle(Palette.unit)
        }
        .lineLimit(1)
        .fixedSize()
        .animation(.snappy(duration: 0.35), value: watts)
    }
}

struct EmptyCard: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "powerplug")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Palette.brand)
                .padding(.bottom, 2)
            Text("还没有设备")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.ink)
            Text("在设置里扫描局域网，或粘贴从小程序「龙虾服务」复制的内容。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开设置", action: openSettings)
                .buttonStyle(PillButtonStyle(prominent: true))
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(CardBackground())
    }
}

/// 卡片底部详情条里显示的内容，按优先级取一个。
private enum StripContent {
    case busy(String)
    case confirmOff(String)
    case confirmStrategy(ChargingStrategy)
    case message(String, isError: Bool)
    case port(PortMetrics)
    case offline(String)
    case connecting
    case summary

    /// 换成不同的内容时才播切换动画；同一内容里的读数原地滚动。
    var key: String {
        switch self {
        case .busy(let text): return "busy-\(text)"
        case .confirmOff(let name): return "off-\(name)"
        case .confirmStrategy(let strategy): return "strategy-\(strategy.rawValue)"
        case .message(let text, _): return "message-\(text)"
        case .port(let port): return "port-\(port.id)"
        case .offline: return "offline"
        case .connecting: return "connecting"
        case .summary: return "summary"
        }
    }
}

/// 一台设备：卡片外是灰色标题（名称、在线状态、在充口数），
/// 卡片里是总功率和「调节」菜单、端口功率图、固定高度的详情条。
/// 选中端口、确认关口、切换策略、执行中和结果提示都在详情条里原位切换，不插入新行。
struct DeviceCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.panelVisible) private var panelVisible
    @Environment(\.snapshotMode) private var snapshotMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let device: DeviceConfig

    @State private var selected: Int?
    @State private var pendingOff: Int?
    @State private var pendingStrategy: ChargingStrategy?
    @State private var grown = false
    @Namespace private var selection

    /// 标题 16 + 5 + 卡片（内边距 10 + 总功率 26 + 4 + 端口图 53 + 8 + 详情条 32 + 内边距 11）。
    static let height: CGFloat = 165

    init(device: DeviceConfig, preset: CardPreset? = nil) {
        self.device = device
        _selected = State(initialValue: preset?.selected)
        _pendingOff = State(initialValue: preset?.pendingOff)
        _pendingStrategy = State(initialValue: preset?.pendingStrategy)
    }

    private var state: DeviceRuntime { model.runtime[device.psn] ?? DeviceRuntime() }
    private var online: Bool { model.isOnline(device.psn) }
    /// 读数来自云端（Mac 连不上设备的局域网）。
    private var cloud: Bool { model.isCloud(device.psn) }
    private var configured: Bool { model.mcpConfigured.contains(device.psn) }
    private var ports: [PortMetrics] { (state.metrics?.ports ?? []).sorted { $0.id < $1.id } }
    private var canControl: Bool { configured && online && state.busy == nil }
    private var lastStrategy: ChargingStrategy? { device.lastStrategy.flatMap(ChargingStrategy.init(rawValue:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            heading
                .frame(height: 16)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                topRow
                    .frame(height: 26)
                PortChart(ports: ports,
                          limits: model.facts(device.psn).portMaxPower,
                          colors: ModeColors.of(lastStrategy),
                          stale: !online,
                          selected: selected,
                          grown: grown || snapshotMode,
                          namespace: selection,
                          select: select)
                    .padding(.top, 4)
                strip
                    .padding(.top, 8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 11)
            .background(CardBackground())
        }
        .onAppear { grown = panelVisible }
        .onChange(of: panelVisible) { _, visible in
            // 关掉面板时撤销待确认的操作，免得下次打开时误点；柱子缩回去，下次打开再长出来
            grown = visible
            if !visible {
                pendingOff = nil
                pendingStrategy = nil
            }
        }
        .onChange(of: state.busy != nil) { _, busy in
            if busy {
                pendingOff = nil
                pendingStrategy = nil
            }
        }
        .onChange(of: ports.map(\.id)) { _, ids in
            if let id = selected, !ids.contains(id) { selected = nil }
        }
        .task(id: panelVisible && configured) {
            guard panelVisible, configured else { return }
            await model.loadControls(psn: device.psn)
        }
        // 面板开着时每隔几秒问一次要不要重新识别接入的设备，真正什么时候读由 model 决定
        .task(id: panelVisible && configured) {
            guard panelVisible, configured else { return }
            while !Task.isCancelled {
                await model.loadIdentities(psn: device.psn)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: 标题和总功率

    private var heading: some View {
        HStack(spacing: 6) {
            Text(device.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.heading)
                .lineLimit(1)
            StatusBadge(status: badgeStatus, text: cloud ? "云端" : nil)
            Spacer(minLength: 6)
            Text(statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.snappy, value: statusText)
        }
    }

    private var badgeStatus: StatusBadge.Status {
        if online { return .online }
        return state.lastError == nil ? .connecting : .offline
    }

    private var statusText: String {
        if online {
            let charging = state.metrics?.chargingCount ?? 0
            let text = charging > 0 ? "\(charging) 口在充" : "空闲"
            return cloud ? text + " · 云端读数" : text
        }
        if state.lastError == nil { return "" }
        return state.metrics == nil ? "" : "上次的读数"
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            PowerReadout(watts: state.metrics?.totalWatts, size: 22, dimmed: !online)
            Spacer(minLength: 6)
            ControlsMenu(device: device, onPickStrategy: pickStrategy)
        }
    }

    // MARK: 详情条

    private var stripContent: StripContent {
        if let busy = state.busy { return .busy(busy) }
        if let index = pendingOff { return .confirmOff(PortNaming.name(index: index)) }
        if let strategy = pendingStrategy { return .confirmStrategy(strategy) }
        if let message = state.message { return .message(message, isError: state.messageIsError) }
        if !online {
            if let error = state.lastError { return .offline(error) }
            return .connecting
        }
        if let id = selected, let port = ports.first(where: { $0.id == id }) { return .port(port) }
        return .summary
    }

    private var strip: some View {
        let content = stripContent
        return ZStack {
            stripBody(content)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .id(content.key)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.inset))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.snappy(duration: 0.3), value: content.key)
    }

    @ViewBuilder
    private func stripBody(_ content: StripContent) -> some View {
        switch content {
        case .busy(let text):
            HStack(spacing: 7) {
                Spinner()
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
            }
        case .confirmOff(let name):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.brand)
                twoLines("关闭 \(name)？", "正在供电，关闭后会断电")
                Spacer(minLength: 4)
                Button("取消") { withAnimation(.snappy) { pendingOff = nil } }
                    .buttonStyle(PillButtonStyle())
                Button("关闭", action: confirmOff)
                    .buttonStyle(PillButtonStyle(prominent: true, tint: Palette.danger))
                    .disabled(!canControl)
            }
        case .confirmStrategy(let strategy):
            HStack(spacing: 6) {
                Image(systemName: strategy.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ModeColors.of(strategy).theme)
                twoLines("切换到「\(strategy.title)」？", strategy.briefWarning)
                Spacer(minLength: 4)
                Button("取消") { withAnimation(.snappy) { pendingStrategy = nil } }
                    .buttonStyle(PillButtonStyle())
                Button("切换", action: confirmStrategy)
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(!configured || state.busy != nil)
            }
        case .message(let text, let isError):
            HStack(spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isError ? Palette.danger : Palette.online)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
            }
        case .port(let port):
            portDetail(port)
        case .offline(let error):
            HStack(spacing: 7) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let cloudError = state.cloudError {
                    // 配好 MCP 的设备连不上局域网时会改读云端，这时还离线就是两边都读不到
                    twoLines("局域网和云端都读不到", cloudError)
                } else {
                    twoLines(state.metrics == nil ? "连不上设备" : "离线，显示的是上次的读数", error)
                }
            }
        case .connecting:
            HStack(spacing: 7) {
                Spinner()
                Text("正在连接 \(device.effectiveHost)…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .summary:
            summaryRow
        }
    }

    private func twoLines(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private func portDetail(_ port: PortMetrics) -> some View {
        let name = PortNaming.name(index: port.id)
        let line = portLine(port)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(portTitle(port, name: name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(line)
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: line)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .help(portHelp(port) ?? "")
            Spacer(minLength: 4)
            if let temperature = model.temperature(device.psn, port: port) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TemperatureLabel.color(temperature))
                    .help("芯片温度：\(temperature.label)")
                    .accessibilityLabel("芯片温度\(temperature.label)")
            }
            if device.capabilities.contains(.portPower), port.isPoweredOn != nil {
                PortSwitch(isOn: port.isPoweredOn == true, enabled: canControl, name: name) { toggle(port) }
                    .help(switchHelp(port, name: name))
            } else if device.capabilities.contains(.portPower) {
                PowerButtons(enabled: canControl, name: name) { on in
                    Task { await model.setPort(psn: device.psn, index: port.id, on: on) }
                }
            }
        }
    }

    /// 认出了设备时，标题是“C1 · iPhone 15 Pro · 电量 76%”；没认出时照旧显示协议和已充时长。
    private func portTitle(_ port: PortMetrics, name: String) -> String {
        guard let on = port.isPoweredOn else {
            // 云端读不到开关状态：只说看得到的
            return port.attached ? "\(name) · 已连接，没有供电" : "\(name) · 没接设备"
        }
        if !on { return "\(name) · 已关闭" }
        if let identity = model.identity(device.psn, port: port), let deviceName = identity.displayName {
            var parts = [name, deviceName]
            if let battery = identity.battery {
                parts.append("电量 \(battery.percent)%")
            } else if port.isCharging, port.chargingDurationSeconds > 0 {
                parts.append("已充 \(PanelFormat.duration(port.chargingDurationSeconds))")
            }
            return parts.joined(separator: " · ")
        }
        if port.isCharging {
            var parts = [name, port.protocolName]
            if port.chargingDurationSeconds > 0 {
                parts.append("已充 \(PanelFormat.duration(port.chargingDurationSeconds))")
            }
            return parts.joined(separator: " · ")
        }
        return port.attached ? "\(name) · 已连接，未取电" : "\(name) · 空闲"
    }

    private func portLine(_ port: PortMetrics) -> String {
        if port.isInUse {
            var text = String(format: "%.2f V · %.2f A · %.2f W", port.volts, port.amps, port.watts)
            // 本次电量比分配功率更常看；两样都放会挤掉读数，分配功率留在悬停说明里
            if let energy = model.sessionEnergy(device.psn, port: port) {
                text += " · 本次 " + SessionEnergy.format(mWh: energy)
            } else if port.powerBudgetWatts > 0 {
                text += " · 分配 \(port.powerBudgetWatts) W"
            }
            return text
        }
        if port.isPoweredOn == nil { return unknownPowerLine(port) }
        if !configured { return "只读：保存 MCP 地址后才能开关" }
        return port.isPoweredOn == true ? "没有连接设备" : "打开后才供电"
    }

    /// 云端读不到开关状态时说明一句；本机发过开关命令的话改写这条（这是有依据的）。旁边有两个按钮，要写短，
    /// 读不到状态的说明在悬停说明里。
    private func unknownPowerLine(_ port: PortMetrics) -> String {
        guard let command = state.portCommands[port.id] else { return "云端读不到开关状态" }
        let time = command.at.formatted(date: .omitted, time: .shortened)
        return "\(time) 在本机\(command.on ? "打开" : "关闭")过"
    }

    /// 鼠标停在详情条上时显示识别出的全部信息，以及本次电量、芯片温度和分配功率。
    private func portHelp(_ port: PortMetrics) -> String? {
        var lines: [String] = []
        if let identity = model.identity(device.psn, port: port) {
            let battery = identity.battery.map { "电量 \($0.percent)% · 健康 \($0.health)%" }
            let cable = identity.cable.map { "线材：\($0.summary)" }
            lines += [identity.displayName ?? "未识别的设备", identity.idText, battery, identity.pdSummary, cable]
                .compactMap { $0 }
        }
        if let energy = model.sessionEnergy(device.psn, port: port) {
            lines.append("本次已充 " + SessionEnergy.format(mWh: energy))
        }
        if let temperature = model.temperature(device.psn, port: port) {
            lines.append("芯片温度：\(temperature.label)")
        }
        if port.attached, port.powerBudgetWatts > 0 {
            lines.append("分配 \(port.powerBudgetWatts) W")
        }
        if cloud { lines.append("云端读数（每 15 秒）：没有开关状态、充电时长和分配功率") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func switchHelp(_ port: PortMetrics, name: String) -> String {
        if !configured { return "需要先在设置里保存 MCP 地址" }
        if !online { return "设备离线" }
        return port.isPoweredOn == true ? "关闭 \(name)" : "打开 \(name)"
    }

    @ViewBuilder
    private var summaryRow: some View {
        let control = state.control
        if configured {
            HStack(spacing: 12) {
                if control.temperature != nil || control.display != nil {
                    summaryItem("thermometer.medium", control.temperature?.displayName ?? "温控未知")
                    summaryItem("sun.max", control.display.map { "亮度 \($0.rawValue)" } ?? "亮度未知")
                } else if control.loadError != nil {
                    summaryItem("exclamationmark.circle", "没读到温控和亮度")
                        .foregroundStyle(.secondary)
                } else {
                    summaryItem("ellipsis", "正在读取温控和亮度")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(cloud ? "云端读数，每 15 秒更新" : "点端口看详情")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        } else {
            HStack(spacing: 7) {
                Image(systemName: "lock")
                    .font(.system(size: 10.5, weight: .semibold))
                twoLines("只读模式", "在设置里保存 MCP 地址后可以开关端口、改策略")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func summaryItem(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.brand)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.ink)
        }
        .lineLimit(1)
    }

    // MARK: 操作

    private func select(_ id: Int) {
        model.clearMessage(device.psn)
        // 减少动态效果时选中标记不滑动，直接换位置
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            selected = selected == id ? nil : id
            pendingOff = nil
            pendingStrategy = nil
        }
    }

    private func toggle(_ port: PortMetrics) {
        guard let on = port.isPoweredOn else { return }
        // 关掉正在用的口前先确认
        if port.isInUse {
            withAnimation(.snappy) { pendingOff = port.id }
            return
        }
        Task { await model.setPort(psn: device.psn, index: port.id, on: !on) }
    }

    private func confirmOff() {
        guard let index = pendingOff else { return }
        // 先排队任务再清掉确认：任务一开始就标记忙碌，详情条从确认直接换成“正在关闭…”
        Task { await model.setPort(psn: device.psn, index: index, on: false) }
        pendingOff = nil
    }

    private func pickStrategy(_ strategy: ChargingStrategy) {
        model.clearMessage(device.psn)
        withAnimation(.snappy) {
            pendingOff = nil
            pendingStrategy = strategy
        }
    }

    private func confirmStrategy() {
        guard let strategy = pendingStrategy else { return }
        Task { await model.setStrategy(psn: device.psn, strategy) }
        pendingStrategy = nil
    }
}

/// 卡片右上角的「调节」胶囊（小程序充电图谱右上角那颗模式胶囊）：
/// 点开是充电策略、温控、屏幕亮度，以及到设置「调节」页的入口。
/// 胶囊用 SwiftUI 画、菜单用 AppKit 弹：系统 Menu 控件会盖住胶囊的两头。
struct ControlsMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.snapshotMode) private var snapshotMode
    let device: DeviceConfig
    let onPickStrategy: (ChargingStrategy) -> Void

    @State private var anchor = MenuAnchorHolder()

    private var state: DeviceRuntime { model.runtime[device.psn] ?? DeviceRuntime() }
    private var configured: Bool { model.mcpConfigured.contains(device.psn) }
    private var lastStrategy: ChargingStrategy? {
        device.lastStrategy.flatMap(ChargingStrategy.init(rawValue:))
    }

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9.5, weight: .bold))
                Text("调节")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Palette.card))
            .overlay { Capsule().strokeBorder(Palette.pillStroke, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(PressFadeStyle())
        .background {
            if !snapshotMode {
                MenuAnchor(holder: anchor)
            }
        }
        .disabled(state.busy != nil)
        .opacity(state.busy != nil ? 0.45 : 1)
        .help("充电策略、温控、屏幕亮度、功率分配")
        .accessibilityLabel("调节 \(device.name)")
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PanelSnapshots.openMenuNotification)) { _ in
            if model.devices.first?.psn == device.psn { showMenu() }
        }
        #endif
    }

    /// 每个选项都是勾选项：充电策略读不到当前值（手机上可能改过），
    /// 再点一次已勾选的策略也要能重新下发，所以不按“已选中就忽略”处理。
    private func showMenu() {
        guard let view = anchor.view else { return }
        let menu = ClosureMenu()
        let capabilities = device.capabilities
        if configured {
            // 小电拼三项都有，菜单内容和顺序跟以前一样。缺能力的驱动不放对应的一组。
            if capabilities.contains(.chargingStrategy) {
                menu.section("充电策略")
                for strategy in ChargingStrategy.allCases {
                    // 选了先在卡片上确认，确认后才发送
                    menu.item(strategy.title, detail: strategy.detail, symbol: strategy.symbol,
                              checked: lastStrategy == strategy) {
                        onPickStrategy(strategy)
                    }
                }
            }
            if capabilities.contains(.temperatureMode) {
                menu.section("温控")
                for mode in TemperatureMode.allCases {
                    menu.item(mode.displayName, detail: mode.detail, symbol: mode.symbol,
                              checked: state.control.temperature == mode) {
                        guard mode != state.control.temperature else { return }
                        Task { await model.setTemperature(psn: device.psn, mode) }
                    }
                }
            }
            if capabilities.contains(.displaySettings) {
                menu.separator()
                menu.submenu("屏幕亮度", detail: state.control.display.map { "当前 \($0.rawValue)" },
                             symbol: "sun.max") { levels in
                    for level in DisplayLevel.allCases {
                        levels.item(level.rawValue, checked: state.control.display == level) {
                            guard level != state.control.display else { return }
                            Task { await model.setDisplay(psn: device.psn, level) }
                        }
                    }
                }
            }
            menu.item("端口开关、功率分配和全部调节…", symbol: "slider.horizontal.3") {
                model.showControls(for: device.psn)
                showSettings()
            }
            menu.separator()
            if capabilities.contains(.chargingStrategy) {
                menu.note(lastStrategy == nil ? "MCP 读不到设备当前的策略" : "勾选的是本 app 上次设置的策略")
            }
            if let error = state.control.loadError {
                menu.note("读取温控和亮度失败：\(String(error.prefix(40)))")
            }
        } else {
            menu.note("还没保存 MCP 地址，只能看读数")
            menu.item("打开设置…", symbol: "gearshape") {
                model.settingsTab = .devices
                showSettings()
            }
        }
        anchor.menu = menu
        menu.popUp(below: view)
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}

/// 按下时变淡的纯样式按钮。
struct PressFadeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
