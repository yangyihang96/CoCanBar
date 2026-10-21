import SwiftUI
import CoCanKit
import CoCanStyle

/// 设置窗口的「调节」页：官方 MCP 能设置的项都在这里。排版和配色照 KangCharge 的主窗口（见 `SettingsStyle`）：
/// 页首是设备名和连接状态；第一排是充电模式、功率图、端口开关和设备信息，第二排是温控、状态屏和临时功率分配，
/// 最后是充电曲线和在充设备。CP02S 的屏显模式、待机显示、整点报时在状态屏卡片里（设备报了才显示）。
/// 面板上的「调节」菜单只放常用的几项。
struct ControlsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.devices.isEmpty {
            ContentUnavailableView {
                Label("还没有设备", systemImage: "powerplug")
            } description: {
                Text("先在「设备」页添加小电拼。")
            } actions: {
                Pill(title: "去添加", filled: true, large: true) { model.settingsTab = .devices }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsStyle.cream)
        } else if let device = model.settingsDevice.flatMap(model.device) ?? model.devices.first {
            DeviceControls(device: device)
                .id(device.psn)
        }
    }
}

/// 一台设备的全部调节项。执行中和结果在底部弹出提示（几秒后自动收起）。
struct DeviceControls: View {
    @Environment(AppModel.self) private var model
    let device: DeviceConfig

    @State private var strategyDraft: ChargingStrategy?
    @State private var confirmStrategy = false
    @State private var pendingOff: PortMetrics?
    /// 刚点过的开关先按新状态显示，读数刷新后回到实际状态。
    @State private var switching: [Int: Bool] = [:]
    @State private var allocation: [Int] = []
    /// 草稿已经按设备的当前分配填过（之后读数刷新不再覆盖用户的修改）。
    @State private var allocationFilled = false
    @State private var showAllocation = false

    private var state: DeviceRuntime { model.runtime[device.psn] ?? DeviceRuntime() }
    private var control: ControlState { state.control }
    private var configured: Bool { model.mcpConfigured.contains(device.psn) }
    private var online: Bool { model.isOnline(device.psn) }
    private var cloud: Bool { model.isCloud(device.psn) }
    private var canSend: Bool { configured && state.busy == nil }
    private var ports: [PortMetrics] { (state.metrics?.ports ?? []).sorted { $0.id < $1.id } }
    private var facts: MachineFacts { model.facts(device.psn) }
    private var lastStrategy: ChargingStrategy? { device.lastStrategy.flatMap(ChargingStrategy.init(rawValue:)) }
    private var every: String { String(format: "%g", model.pollInterval) }
    /// 小电拼的驱动这些能力都有，卡片和以前一样都在。别的驱动缺哪项，对应的卡片就不画。
    private var capabilities: ChargerCapabilities { device.capabilities }

    /// 右边一栏（端口、设备、临时功率分配、在充设备）的宽度。
    static let sideWidth: CGFloat = 340

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !configured {
                    notice
                }
                // 每一排的卡片一样高：先按内容量出最高的一张，其余的拉到同样高
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        if capabilities.contains(.chargingStrategy) {
                            modeCard
                        }
                        powerCard
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    VStack(spacing: 16) {
                        portsCard
                        deviceCard
                    }
                    .frame(width: Self.sideWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    if capabilities.contains(.temperatureMode) {
                        temperatureCard
                    }
                    if capabilities.contains(.displaySettings) {
                        displayCard
                    }
                    if capabilities.contains(.powerAllocation) {
                        allocationCard
                            .frame(width: Self.sideWidth)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(title: "充电曲线", detail: "每 10 秒一个点")
                        ChargingCurve(device: device, ports: ports, configured: configured, online: online)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .settingsCard()
                    if capabilities.contains(.portIdentity) {
                        VStack(alignment: .leading, spacing: 12) {
                            CardTitle(title: "在充设备", detail: identityStatus)
                            ConnectedDevices(device: device, ports: ports, configured: configured, online: online)
                        }
                        .frame(width: Self.sideWidth - 36, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .settingsCard()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.automatic)
        .background(SettingsStyle.cream)
        .foregroundStyle(SettingsStyle.ink)
        .tint(SettingsStyle.orange)
        .overlay(alignment: .bottom) {
            toast
                .padding(.bottom, 22)
        }
        .animation(.snappy, value: state.message)
        .animation(.snappy, value: state.busy)
        .task {
            strategyDraft = lastStrategy
            await model.loadControls(psn: device.psn)
        }
        // 这一页开着时和面板一样，每隔几秒问一次要不要重新识别接入的设备
        .task(id: configured) {
            guard configured else { return }
            while !Task.isCancelled {
                await model.loadIdentities(psn: device.psn)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onAppear(perform: fillAllocationIfNeeded)
        .onChange(of: ports.isEmpty) { _, _ in fillAllocationIfNeeded() }
        .onChange(of: facts.portMaxPower.count) { _, _ in fillAllocation() }
        .confirmationDialog("关闭 \(pendingOff.map { PortNaming.name(index: $0.id) } ?? "")？",
                            isPresented: Binding(get: { pendingOff != nil }, set: { if !$0 { pendingOff = nil } })) {
            Button("关闭", role: .destructive) {
                if let port = pendingOff { setPort(port, on: false) }
            }
        } message: {
            Text("这个口正在供电，关闭后会断电。")
        }
        .confirmationDialog("切换到「\(strategyDraft?.title ?? "")」？", isPresented: $confirmStrategy) {
            Button("切换") {
                if let strategy = strategyDraft {
                    Task { await model.setStrategy(psn: device.psn, strategy) }
                }
            }
        } message: {
            Text(strategyDraft?.warning ?? "")
        }
        .sheet(isPresented: $showAllocation) {
            AllocationSheet(allocation: $allocation, facts: facts, ports: ports, canApply: canSend && online,
                            fill: fillAllocation) { values in
                Task { await model.setPowerAllocation(psn: device.psn, values) }
            }
            .environment(model)
        }
    }

    // MARK: 页首

    /// 小字的 app 名、大号设备名，下面是连接状态和一行说明；右边是切换设备、刷新和设置。
    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CoCanBar")
                    .font(.system(size: 13, weight: .heavy).italic())
                    .foregroundStyle(SettingsStyle.orange)
                HStack(spacing: 10) {
                    Text(device.name)
                        .font(.system(size: 30, weight: .heavy))
                        .lineLimit(1)
                    Button {
                        model.settingsTab = .devices
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SettingsStyle.gray)
                    }
                    .buttonStyle(.plain)
                    .help("名称、主机和 MCP 地址")
                }
                HStack(spacing: 8) {
                    ConnectionBadge(status: badge, text: online && cloud ? "云端" : nil)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsStyle.gray)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(connectionHelp)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if model.devices.count > 1 {
                    PillSegments(options: model.devices.map { (value: $0.psn, title: $0.name) },
                                 selection: device.psn) { model.settingsDevice = $0 }
                }
                CircleIconButton(symbol: "arrow.clockwise", help: "立即刷新读数、当前设置和接入的设备", action: refreshAll)
                CircleIconButton(symbol: "gearshape", help: "通用设置") { model.settingsTab = .general }
            }
        }
        .padding(.horizontal, 4)
    }

    private var badge: ConnectionBadge.Status { ConnectionBadge.Status(model, psn: device.psn) }

    private var subtitle: String {
        var parts = ["制糖工厂 小电拼"]
        parts.append(cloud ? "云端 MCP 读数" : "局域网 \(device.effectiveHost)")
        if let version = state.metrics?.system?.appVersion { parts.append("固件 \(version)") }
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        if let last = state.lastSuccess {
            parts.append(online ? "更新于 \(last.formatted(time))" : "上次成功 \(last.formatted(time)) · 自动重连中")
        } else if !online {
            parts.append(state.lastError == nil ? "正在连接" : "还没读到数据")
        }
        return parts.joined(separator: " · ")
    }

    private var connectionHelp: String {
        if online {
            return cloud ? "Mac 连不上小电拼的局域网，读数来自云端 MCP，每 15 秒更新。" : "局域网读数，每 \(every) 秒更新。"
        }
        return [state.lastError, state.cloudError.map { "云端：\($0)" }].compactMap { $0 }.joined(separator: "\n")
    }

    private var notice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(SettingsStyle.orange)
            Text("这台设备还没保存 MCP 地址：可以看读数，开关和调节都不能用。")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Pill(title: "去保存", filled: true) { model.settingsTab = .devices }
        }
        .settingsCard(padding: 14)
    }

    private func refreshAll() {
        Task {
            await model.refresh(device.psn, cloudNow: true)
            async let controls: Void = model.loadControls(psn: device.psn, force: true)
            async let identities: Void = model.loadIdentities(psn: device.psn, force: true)
            _ = await (controls, identities)
        }
    }

    // MARK: 充电模式

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Label {
                    Text("模式")
                        .font(.system(size: 13, weight: .semibold))
                } icon: {
                    Image(systemName: "slider.horizontal.below.rectangle")
                        .foregroundStyle(SettingsStyle.orange)
                }
                .foregroundStyle(SettingsStyle.gray)
                .fixedSize()
                HStack(spacing: 8) {
                    ForEach(ChargingStrategy.allCases) { strategy in
                        Pill(title: strategy.title, symbol: strategy.symbol, filled: lastStrategy == strategy, large: true) {
                            strategyDraft = strategy
                            confirmStrategy = true
                        }
                        .help("\(strategy.title)：\(strategy.detail)")
                    }
                }
                .disabled(!canSend)
                Spacer(minLength: 0)
            }
            Divider()
                .overlay(SettingsStyle.line)
            HStack(spacing: 10) {
                Circle()
                    .fill(charging ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.lightGray))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .bold))
                    Text(lastStrategy.map { "\($0.title) · \($0.detail)（上次由本 app 设置）" }
                         ?? "MCP 读不到设备当前的模式，点上面的按钮切换")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsStyle.gray)
                        .lineLimit(1)
                }
                .help("MCP 读不到设备当前的模式，橙色的是上次由本 app 设置的；在手机上改过也可以再点一次重新下发。"
                      + "小程序里的「苹果全家桶」「自定义」用的是静态分配表，MCP 不能设置。")
                Spacer(minLength: 8)
                if capabilities.contains(.temperatureMode) {
                    Button {
                        guard let mode = control.temperature else { return }
                        Task { await model.setTemperature(psn: device.psn, mode == .powerFirst ? .temperatureFirst : .powerFirst) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: control.temperature?.symbol ?? "thermometer.medium")
                            Text(control.temperature?.displayName ?? "温控")
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsStyle.green)
                    }
                    .buttonStyle(.plain)
                    .help("点按切换性能温控 / 安心温控")
                    .disabled(control.temperature == nil || !canSend)
                }
            }
        }
        .settingsCard()
    }

    private var charging: Bool { online && ports.contains(where: \.isCharging) }

    private var statusTitle: String {
        guard online else { return badge == .connecting ? "正在连接" : "设备离线" }
        return charging ? "正在充电" : "待机中"
    }

    // MARK: 功率图

    private var powerCard: some View {
        let total = state.metrics?.totalWatts
        let budget = Double(facts.maxPowerBudget)
        return VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                PowerDiagram(ports: ports, limits: facts.portMaxPower, live: online)
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时充电功率")
                        .font(.system(size: 14, weight: .semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(total.map(PanelFormat.watts) ?? "—")
                            .font(.system(size: 48, weight: .heavy))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: total ?? 0))
                        Text("W")
                            .font(.system(size: 32, weight: .heavy))
                    }
                    .foregroundStyle(online ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.lightGray))
                }
                .padding(.bottom, 4)
            }
            .overlay(alignment: .bottomTrailing) {
                BudgetBox(used: total ?? 0, budget: budget, live: online)
                    .offset(x: -8, y: 40)
            }
            .frame(minHeight: 290, idealHeight: 290, maxHeight: .infinity)
            .padding(.bottom, 36)
            Divider()
                .overlay(SettingsStyle.line)
            HStack {
                FooterStat(symbol: "clock", title: "充电中", value: "\(ports.filter(\.isCharging).count) / \(ports.count) 口")
                Spacer()
                FooterStat(symbol: "bolt.circle", title: "本次累计", value: sessionEnergy.map { SessionEnergy.format(mWh: $0) } ?? "—")
                Spacer()
                FooterStat(symbol: "gauge.with.dots.needle.33percent", title: "剩余功率",
                           value: total.map { PanelFormat.watts(max(budget - $0, 0)) + "W" } ?? "—")
            }
        }
        .settingsCard(padding: 20)
    }

    /// 各口本次已充的合计，哪个口都没有记录时为 nil。
    private var sessionEnergy: Double? {
        let values = ports.compactMap { model.sessionEnergy(device.psn, port: $0) }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    // MARK: 端口开关

    private var portsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(title: "端口", detail: cloud ? "云端读数，每 15 秒更新" : "开关控制各口供电")
                .padding(.bottom, 8)
            if ports.isEmpty {
                Text(online ? "正在读取端口…" : badge == .connecting ? "正在连接设备…" : "设备离线，读不到端口状态")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsStyle.gray)
                    .padding(.vertical, 6)
            }
            ForEach(ports) { port in
                portRow(port)
                if port.id != ports.last?.id {
                    Divider()
                        .overlay(SettingsStyle.line)
                }
            }
            if cloud {
                Text("云端读不到开关状态、充电时长和分配功率；没在供电的口开没开不知道，用「打开」「关闭」操作。")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsStyle.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .settingsCard()
    }

    private func portRow(_ port: PortMetrics) -> some View {
        let name = PortNaming.name(index: port.id)
        return HStack(spacing: 12) {
            // 离线时是上次的读数，和功率图一样用灰色
            PortTag(name: name, enabled: online && port.isPoweredOn != false)
            VStack(alignment: .leading, spacing: 3) {
                Text(portTitle(port))
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Text(portSubtitle(port))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsStyle.gray)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(port.isPoweredOn == true ? PanelFormat.watts(port.watts) + "W" : "—")
                    .font(.system(size: 15, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(powerStyle(port))
                if let temperature = model.temperature(device.psn, port: port) {
                    TemperatureDot(temperature: temperature)
                }
            }
            powerControl(port, name: name)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .help("\(name) · \(portTitle(port)) · \(portSubtitle(port))")
    }

    private func powerStyle(_ port: PortMetrics) -> AnyShapeStyle {
        guard online else { return AnyShapeStyle(SettingsStyle.gray) }
        return port.isCharging ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.ink)
    }

    /// 认出了接的设备就写型号，否则写端口状态。
    private func portTitle(_ port: PortMetrics) -> String {
        if port.attached, let name = model.identity(device.psn, port: port)?.displayName { return name }
        switch port.isPoweredOn {
        case false?: return port.id == 0 ? "USB-A 口" : "USB-C 口"
        case nil: return port.attached ? "已连接" : "未连接"
        case true?:
            if port.isCharging { return "充电中" }
            return port.attached ? "已连接，未取电" : "空闲"
        }
    }

    private func portSubtitle(_ port: PortMetrics) -> String {
        let limit = facts.portMaxPower.indices.contains(port.id) ? "最高 \(facts.portMaxPower[port.id])W" : nil
        switch port.isPoweredOn {
        case false?:
            return ["端口已关闭", limit].compactMap { $0 }.joined(separator: " · ")
        case nil:
            // 云端读不到开关状态；这次运行里在本机发过命令的话写上
            let command = state.portCommands[port.id].map {
                "\($0.at.formatted(date: .omitted, time: .shortened)) 在本机\($0.on ? "打开" : "关闭")过"
            }
            return ["开关状态未知", command].compactMap { $0 }.joined(separator: " · ")
        case true?:
            guard port.attached else { return ["没接设备", limit].compactMap { $0 }.joined(separator: " · ") }
            return "\(port.protocolName) · " + String(format: "%.2fV %.2fA", port.volts, port.amps)
        }
    }

    /// 开关状态读得到时是橙色开关；云端读不到的口给「打开」「关闭」两个按钮（没在供电，关掉不会断电，不再确认）。
    @ViewBuilder
    private func powerControl(_ port: PortMetrics, name: String) -> some View {
        if !capabilities.contains(.portPower) {
            EmptyView()
        } else if let on = port.isPoweredOn {
            OrangeToggle(isOn: Binding(get: { switching[port.id] ?? on }, set: { toggle(port, on: $0) }),
                         label: "\(name) 供电", scale: 0.9)
                .disabled(!canSend || !online)
                .help(on ? "关闭 \(name)" : "打开 \(name)")
        } else {
            HStack(spacing: 4) {
                Pill(title: "打开") { setPort(port, on: true) }
                Pill(title: "关闭") { setPort(port, on: false) }
            }
            .disabled(!canSend || !online || switching[port.id] != nil)
            .help("云端读不到 \(name) 现在开没开")
        }
    }

    private func toggle(_ port: PortMetrics, on: Bool) {
        if !on, port.isInUse {
            pendingOff = port
            return
        }
        setPort(port, on: on)
    }

    private func setPort(_ port: PortMetrics, on: Bool) {
        switching[port.id] = on
        Task {
            await model.setPort(psn: device.psn, index: port.id, on: on)
            switching[port.id] = nil
        }
    }

    // MARK: 设备信息

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "设备", detail: "整机最大 \(facts.maxPowerBudget)W")
            InfoRow("序列号", device.psn)
            InfoRow("主机", device.effectiveHost)
            InfoRow("读数", cloud ? "云端 MCP，每 15 秒" : "局域网，每 \(every) 秒")
            if let version = state.metrics?.system?.appVersion {
                InfoRow("固件", version)
            }
            InfoRow("各口上限", portLimits)
            InfoRow("MCP 地址", configured ? "已保存在钥匙串" : "未保存")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsCard()
    }

    /// 「A 60W · C1–C4 140W」：相邻同上限的口合在一起写。
    private var portLimits: String {
        var groups: [(names: [String], watts: Int)] = []
        for (index, watts) in facts.portMaxPower.enumerated() {
            let name = PortNaming.name(index: index)
            if let last = groups.last, last.watts == watts {
                groups[groups.count - 1].names.append(name)
            } else {
                groups.append(([name], watts))
            }
        }
        return groups.map { group in
            let names = group.names.count > 2 ? "\(group.names[0])–\(group.names[group.names.count - 1])"
                : group.names.joined(separator: "、")
            return "\(names) \(group.watts)W"
        }
        .joined(separator: " · ")
    }

    // MARK: 温控

    private var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "温控")
            ForEach(TemperatureMode.allCases) { mode in
                temperatureOption(mode)
            }
            if control.loadedAt == nil {
                loadingNote
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsCard()
        .disabled(!canSend)
    }

    private func temperatureOption(_ mode: TemperatureMode) -> some View {
        let selected = control.temperature == mode
        return Button {
            guard mode != control.temperature else { return }
            Task { await model.setTemperature(psn: device.psn, mode) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(SettingsStyle.orange))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(selected ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.orangeSoft)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.system(size: 13, weight: .bold))
                    Text("\(mode.title) · \(mode.detail)")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsStyle.gray)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.lightGray))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AnyShapeStyle(SettingsStyle.orangeSoft.opacity(0.6)) : AnyShapeStyle(SettingsStyle.cream.opacity(0.6))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var loadingNote: some View {
        if let error = control.loadError {
            Label("读取当前设置失败：\(error)", systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(SettingsStyle.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // 没保存 MCP 地址时不会去读；离线时读也读不到
            Text(!configured ? "没保存 MCP 地址，读不到当前设置。" : online ? "正在读取当前设置…" : "设备离线，暂时读不到当前设置。")
                .font(.system(size: 11))
                .foregroundStyle(SettingsStyle.gray)
        }
    }

    // MARK: 状态屏

    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "状态屏")
            OptionLine(title: "亮度") {
                PillSegments(options: DisplayLevel.allCases.map { (value: $0, title: $0.rawValue) },
                             selection: control.display) { level in
                    guard level != control.display else { return }
                    Task { await model.setDisplay(psn: device.psn, level) }
                }
            }
            if control.supportsExtendedDisplay {
                OptionLine(title: "屏显模式") {
                    PillSegments(options: [(value: StatusDisplayMode.idleAnimation, title: "动画优先"), (value: .power, title: "功率优先")],
                                 selection: control.statusMode) { mode in
                        guard mode != control.statusMode else { return }
                        Task { await model.setStatusDisplayMode(psn: device.psn, mode) }
                    }
                }
                OptionLine(title: "待机显示") {
                    PillSegments(options: [(value: IdleDisplay.meteor, title: "流星"), (value: .petals, title: "落花"),
                                           (value: .lifeGame, title: "生命游戏"), (value: .clock, title: "时间")],
                                 selection: control.idleDisplay) { display in
                        guard display != control.idleDisplay else { return }
                        Task { await model.setIdleDisplay(psn: device.psn, display) }
                    }
                }
                OptionLine(title: "整点报时") {
                    OrangeToggle(isOn: Binding(get: { control.hourlyChime ?? false },
                                               set: { enabled in Task { await model.setHourlyChime(psn: device.psn, enabled) } }),
                                 label: "整点报时")
                }
            }
            if control.loadedAt == nil {
                loadingNote
            } else if !control.supportsExtendedDisplay {
                Text("屏显模式、待机显示和整点报时只有 CP02S 支持，这台设备没有报这几项。")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsStyle.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsCard()
        .disabled(!canSend)
    }

    // MARK: 临时功率分配

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "临时功率分配")
            Text("手动指定每个口的功率上限（每口至少 \(MachineFacts.portMinPower)W，合计不超过 \(facts.maxPowerBudget)W）。"
                 + "自由流会按需自动调度，一般不用手动分配。下面是各口现在分到的功率。")
                .font(.system(size: 12))
                .foregroundStyle(SettingsStyle.gray)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(Array(facts.portMaxPower.enumerated()), id: \.offset) { index, limit in
                    let name = PortNaming.name(index: index)
                    let current = ports.first { $0.id == index }?.powerBudgetWatts ?? 0
                    VStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, weight: .bold))
                        Text(current > 0 ? "\(current)W" : "—")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(SettingsStyle.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsStyle.cream))
                    .help(current > 0 ? "\(name) 现在分到 \(current) W，上限 \(limit) W" : "\(name) 上限 \(limit) W")
                }
            }
            // 卡片拉高时按钮留在底部
            Spacer(minLength: 0)
            WideButton(title: "调整分配") {
                fillAllocationIfNeeded()
                showAllocation = true
            }
            .disabled(!canSend || !online)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .settingsCard()
    }

    /// 第一次有读数时按当前分配填好草稿；之后读数刷新不覆盖用户的修改。
    private func fillAllocationIfNeeded() {
        guard !allocationFilled else { return }
        fillAllocation()
        allocationFilled = !ports.isEmpty
    }

    private func fillAllocation() {
        allocation = facts.portMaxPower.indices.map { index in
            let budget = ports.first { $0.id == index }?.powerBudgetWatts ?? 0
            return budget < MachineFacts.portMinPower ? 0 : min(budget, facts.portMaxPower[index])
        }
    }

    // MARK: 提示

    @ViewBuilder
    private var toast: some View {
        if let busy = state.busy {
            SettingsToast(text: busy, kind: .busy)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let message = state.message {
            SettingsToast(text: message, kind: state.messageIsError ? .error : .success)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 「在充设备」标题右边的状态。
    private var identityStatus: String? {
        guard configured, online else { return nil }
        let identity = state.identity
        if identity.loading, identity.loadedAt == nil { return "正在识别…" }
        return identity.loadedAt.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" }
    }
}

/// 页尾的一项统计：橙色图标、名称和灰色的值。
private struct FooterStat: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(SettingsStyle.orange)
            Text(title)
            Text(value)
                .foregroundStyle(SettingsStyle.gray)
                .monospacedDigit()
        }
        .font(.system(size: 13, weight: .semibold))
    }
}

/// 整机上限和已用比例的小框（功率图右下角）。
private struct BudgetBox: View {
    let used: Double
    let budget: Double
    /// 离线时是上次的读数，用灰色。
    let live: Bool

    private var accent: AnyShapeStyle { live ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.lightGray) }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(Int(budget))W")
                .font(.system(size: 20, weight: .heavy))
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            Rectangle()
                .fill(accent)
                .frame(height: 1.5)
            Text("已使用 \(budget > 0 ? Int((used / budget * 100).rounded()) : 0)%")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(live ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.gray))
                .padding(.vertical, 3)
        }
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(accent, lineWidth: 1.5))
    }
}

/// 「调整分配」弹出的表单：每口一条滑块和合计条，应用前再确认一次。
private struct AllocationSheet: View {
    @Binding var allocation: [Int]
    let facts: MachineFacts
    let ports: [PortMetrics]
    let canApply: Bool
    let fill: () -> Void
    let apply: ([Int]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false

    private var total: Int { allocation.reduce(0, +) }
    private var problem: String? { facts.problem(with: allocation) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("临时功率分配")
                    .font(.system(size: 22, weight: .heavy))
                Text("每个口填 \(MachineFacts.portMinPower) W 到该口上限，最左边是“按策略”（发 0），合计不超过 \(facts.maxPowerBudget) W。")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsStyle.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 14) {
                ForEach(Array(facts.portMaxPower.enumerated()), id: \.offset) { index, limit in
                    AllocationRow(name: PortNaming.name(index: index),
                                  value: binding(index),
                                  limit: limit,
                                  current: ports.first { $0.id == index }?.powerBudgetWatts)
                }
            }
            .settingsCard()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("合计")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsStyle.gray)
                    Spacer()
                    Text("\(total) / \(facts.maxPowerBudget)W")
                        .font(.system(size: 17, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(total > facts.maxPowerBudget ? AnyShapeStyle(SettingsStyle.red) : AnyShapeStyle(SettingsStyle.ink))
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(SettingsStyle.card)
                        Capsule()
                            .fill(total > facts.maxPowerBudget ? SettingsStyle.red : SettingsStyle.orange)
                            .frame(width: proxy.size.width * min(Double(total) / Double(max(facts.maxPowerBudget, 1)), 1))
                    }
                }
                .frame(height: 8)
                .animation(.snappy, value: total)
                if let problem, allocation.count == facts.portMaxPower.count {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsStyle.red)
                }
            }
            Text("按开源固件的实现，应用时所有口会重新握手，正在充电的设备会短暂断开；之后插拔设备或开关任一端口，设备会回到策略分配。")
                .font(.system(size: 11))
                .foregroundStyle(SettingsStyle.gray)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Pill(title: "填入当前分配", action: fill)
                    .disabled(ports.isEmpty)
                Pill(title: "全部按策略") { allocation = Array(repeating: 0, count: facts.portMaxPower.count) }
                Spacer()
                Pill(title: "取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Pill(title: "应用…", filled: true) { confirm = true }
                    .disabled(!canApply || problem != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(SettingsStyle.cream)
        .foregroundStyle(SettingsStyle.ink)
        .tint(SettingsStyle.orange)
        .confirmationDialog("应用这组临时功率分配？", isPresented: $confirm) {
            Button("应用") {
                apply(allocation)
                dismiss()
            }
        } message: {
            Text("\(summary)。所有端口会重新握手，正在充电的设备会短暂断开。")
        }
    }

    private func binding(_ index: Int) -> Binding<Int> {
        Binding(get: { allocation.indices.contains(index) ? allocation[index] : 0 },
                set: { value in
                    guard allocation.indices.contains(index) else { return }
                    allocation[index] = value
                })
    }

    private var summary: String {
        let parts = allocation.enumerated().map { index, watts in
            "\(PortNaming.name(index: index)) \(watts == 0 ? "按策略" : "\(watts) W")"
        }
        return parts.joined(separator: " · ") + "，合计 \(total) W"
    }
}

/// 一个口的分配：滑块最左一格是“按策略”（发 0），往右是 15 W 到该口上限，按 1 W 取整。
/// 滑块不设步进：设了步进 macOS 会画出上百条刻度。
private struct AllocationRow: View {
    let name: String
    @Binding var value: Int
    let limit: Int
    let current: Int?

    private var floor: Int { MachineFacts.portMinPower - 1 }

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 12, weight: .heavy))
                .frame(width: 30, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value == 0 ? floor : value) },
                set: { raw in
                    let watts = Int(raw.rounded())
                    value = watts <= floor ? 0 : min(watts, limit)
                }), in: Double(floor)...Double(limit))
                .tint(SettingsStyle.orange)
                .controlSize(.small)
            Text(value == 0 ? "按策略" : "\(value)W")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? AnyShapeStyle(SettingsStyle.gray) : AnyShapeStyle(SettingsStyle.orange))
                .frame(width: 52, alignment: .trailing)
            Stepper("\(name) 功率", value: $value, in: 0...limit, step: 5)
                .labelsHidden()
                .onChange(of: value) { oldValue, newValue in
                    // 1–14 W 不合法：往上跳到 15 W；往下先停在 15 W，再往下回到“按策略”
                    guard newValue > 0, newValue < MachineFacts.portMinPower else { return }
                    value = oldValue == 0 || oldValue > MachineFacts.portMinPower ? MachineFacts.portMinPower : 0
                }
            Text(current.map { "当前 \($0)W" } ?? "当前 –")
                .font(.system(size: 11))
                .foregroundStyle(SettingsStyle.gray)
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
    }
}

/// 「在充设备」：每个接了设备的口一行，显示识别出的型号、电量、PD 档位和线材。
/// 结果来自官方 MCP（PD 握手里的厂商号、产品号和电池信息），面板或这一页开着时自动更新。
private struct ConnectedDevices: View {
    @Environment(AppModel.self) private var model
    let device: DeviceConfig
    let ports: [PortMetrics]
    let configured: Bool
    let online: Bool

    private var attached: [PortMetrics] { ports.filter { $0.attached && $0.isPoweredOn == true } }
    private var identity: IdentityState { model.runtime[device.psn]?.identity ?? IdentityState() }
    /// 插拔后、重新读到之前，没有结果的口显示“正在识别”而不是“未识别”。
    private var pending: Bool { identity.loading || identity.signature != PortIdentity.signature(of: ports) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !configured {
                placeholder("lock", "保存 MCP 地址后才能识别接入的设备")
            } else if !online {
                placeholder("wifi.exclamationmark", "设备离线，读不到接入的设备")
            } else if attached.isEmpty {
                placeholder("powerplug", "没有接入设备")
            } else {
                if let error = identity.loadError {
                    Label("识别失败：\(error)", systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsStyle.red)
                }
                ForEach(attached) { port in
                    row(port)
                    if port.id != attached.last?.id {
                        Divider()
                            .overlay(SettingsStyle.line)
                    }
                }
            }
            Text("识别靠设备在 PD 握手里报的厂商号和产品号：型号由官方服务端识别，认不出时只显示厂商；"
                 + "不走 PD 的设备认不出来。电量和线材信息由设备上报，仅供参考。")
                .font(.system(size: 11))
                .foregroundStyle(SettingsStyle.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(SettingsStyle.gray)
            .padding(.vertical, 4)
    }

    private func row(_ port: PortMetrics) -> some View {
        let info = model.identity(device.psn, port: port)
        return HStack(alignment: .top, spacing: 12) {
            PortTag(name: PortNaming.name(index: port.id), enabled: true, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title(info))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(info?.displayName == nil ? AnyShapeStyle(SettingsStyle.gray) : AnyShapeStyle(SettingsStyle.ink))
                    Spacer(minLength: 6)
                    if let battery = info?.battery {
                        BatteryLabel(percent: battery.percent)
                    }
                }
                ForEach(lines(port, info), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsStyle.gray)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
    }

    private func title(_ info: PortIdentity?) -> String {
        if let name = info?.displayName { return name }
        return info == nil && pending ? "正在识别…" : "未识别的设备"
    }

    private func lines(_ port: PortMetrics, _ info: PortIdentity?) -> [String] {
        var lines = identityLines(port, info)
        // 本次电量和芯片温度不靠识别，不走 PD 的设备也有
        let energy = model.sessionEnergy(device.psn, port: port).map { "本次已充 " + SessionEnergy.format(mWh: $0) }
        let temperature = model.temperature(device.psn, port: port).map { "芯片温度 " + $0.label }
        let activity = [energy, temperature].compactMap { $0 }
        if !activity.isEmpty { lines.append(activity.joined(separator: " · ")) }
        return lines
    }

    private func identityLines(_ port: PortMetrics, _ info: PortIdentity?) -> [String] {
        guard let info else {
            return port.isCharging && !port.usesPD
                ? ["协议：\(port.protocolName)，不走 PD，认不出型号"] : []
        }
        var lines: [String] = []
        if let id = info.idText {
            lines.append(id)
        } else if info.recognizedByServer {
            // 服务端认出来时不再给厂商号
        } else if info.usesPD {
            lines.append("设备没在 PD 握手里报厂商号和产品号，认不出型号")
        } else if port.isCharging {
            lines.append("协议：\(port.protocolName)，不走 PD，认不出型号")
        } else {
            lines.append("没有在取电，暂时认不出")
        }
        if let battery = info.battery {
            lines.append("电量 \(battery.percent)% · 健康 \(battery.health)% · 设计容量 "
                         + String(format: "%.1f Wh", battery.designWh))
        }
        if let pd = info.pdSummary { lines.append(pd) }
        // A 口没有 E-Marker 这回事
        if info.usesPD, port.id != 0 {
            lines.append("线材：" + (info.cable?.summary ?? "没有 E-Marker，最高 3A"))
        }
        return lines
    }
}

/// 电量：电池图标加百分比，低于 20% 变红，其余绿色。
private struct BatteryLabel: View {
    let percent: Int

    private var symbol: String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        Label {
            Text("\(percent)%")
                .monospacedDigit()
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(percent < 20 ? SettingsStyle.red : SettingsStyle.green)
        .accessibilityLabel("电量 \(percent)%")
    }
}
