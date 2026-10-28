import AppKit
import Observation
import OSLog
import ServiceManagement
import CoCanKit
import CoCanStyle

let appLog = Logger(subsystem: "com.local.CoCanBar", category: "app")

/// 一台设备的配置（存 UserDefaults，不含任何密钥）。身份和存盘格式在 `SavedDevice`。
typealias DeviceConfig = SavedDevice

extension DeviceConfig {
    /// 小电拼没填主机时用 `cp02-<PSN>.local`。别的驱动以后用自己的默认主机。
    var defaultHost: String { "cp02-\(psn).local" }

    var effectiveHost: String {
        let host = hostOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return host.isEmpty ? defaultHost : host
    }
}

struct ControlState: Equatable {
    var temperature: TemperatureMode?
    var display: DisplayLevel?
    /// 下面三项只有 CP02S 才有（CP02 的 `get_display_config` 只返回亮度）。
    var statusMode: StatusDisplayMode?
    var idleDisplay: IdleDisplay?
    var hourlyChime: Bool?
    var supportsExtendedDisplay = false
    /// 整机和每口的功率上限，读到一次就不再读。
    var facts: MachineFacts?
    var loadedAt: Date?
    /// 最近一次读取失败的原因（显示在控制菜单里，不弹到卡片上）。
    var loadError: String?
    /// 本 app 每设置成功一次加 1；读取期间有新的设置时，丢弃读取结果。
    var revision = 0
}

/// 各口接的设备（MCP 识别结果），以及芯片温度和本次电量。面板或设置页开着时才读。
struct IdentityState: Equatable {
    /// 键是 `PortMetrics.id`。
    var ports: [Int: PortIdentity] = [:]
    /// 键是 `PortMetrics.id`。
    var details: [Int: PortDetail] = [:]
    /// 局域网 `session_charge` 每 mWh 的计数，用 MCP 读数校准过的（见 `SessionEnergy`）。
    var lanUnitsPerMWh: Double?
    /// 上次读取时各口的插拔签名，变了就重读。
    var signature: String?
    var loadedAt: Date?
    /// 插拔后补读一次的时间：PD 身份和电池信息要握手一会儿才齐（小程序说充电约 20 秒后才有数据）。
    var followUpAt: Date?
    var loading = false
    var loadError: String?
}

/// 读数从哪来：局域网 `metrics.json`，或者局域网连不上时的云端 MCP（见 `CloudReading`）。
enum ReadingSource: Equatable {
    case lan, cloud
}

/// 本次运行里在本机成功发出的开关命令。云端读不到开关状态时，拿它给用户一个有依据的参考。
struct PortCommand: Equatable {
    var on: Bool
    var at: Date
}

/// 一台设备的运行时状态（不持久化）。
struct DeviceRuntime: Equatable {
    var metrics: DeviceMetrics?
    /// 最近一次读到读数的时间，`source` 是它的来源。
    var lastSuccess: Date?
    var source = ReadingSource.lan
    var lastError: String?
    var resolvedIP: String?
    var resolvedAt: Date?
    /// 最近一次用首页 PSN 核对过身份的 IP 和时间。
    var verifiedIP: String?
    var verifiedAt: Date?
    /// 局域网连续失败的次数。
    var failures = 0
    /// 上次试云端读数的时间、连续失败的次数和原因。局域网读到时清掉。
    var cloudCheckedAt: Date?
    var cloudFailures = 0
    var cloudError: String?
    /// 键是 `PortMetrics.id`。局域网读到时清掉（那时开关状态是读出来的）。
    var portCommands: [Int: PortCommand] = [:]
    var control = ControlState()
    var identity = IdentityState()
    var busy: String?
    var message: String?
    var messageIsError = false
}

enum SettingsTab: Hashable {
    case controls, devices, general
}

enum AppError: LocalizedError {
    case noMCP
    case mcpMismatch
    case invalidMCP

    var errorDescription: String? {
        switch self {
        case .noMCP: return "还没保存这台设备的 MCP 地址"
        case .mcpMismatch: return "MCP 地址里的 PSN 和这台设备不一致"
        case .invalidMCP: return "没找到官方 MCP 地址：请在小程序「龙虾服务」里点复制，整段粘贴进来"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var devices: [DeviceConfig] = []
    private(set) var runtime: [String: DeviceRuntime] = [:]
    private(set) var mcpConfigured: Set<String> = []
    /// 菜单栏标签只看这两个值，内容不变就不重绘（每次重绘都要重新排版状态栏）。
    private(set) var menuBarTitle = "—"
    private(set) var anyOnline = false

    /// 各口的功率记录（画充电曲线），键是 PSN 和 `PortMetrics.id`。每分钟存一次盘，启动时读回 2 小时内的。
    private(set) var history: [String: [Int: PortHistory]] = [:]
    /// 正在从设备内存读记录的口，和最近一次读取失败的原因。
    private(set) var historyLoading: [String: Set<Int>] = [:]
    private(set) var historyError: [String: String] = [:]

    /// 设置窗口当前的页和「调节」页选中的设备（面板上点“更多调节”时会改它们）。
    var settingsTab: SettingsTab = .controls
    var settingsDevice: String?

    var pollInterval: Double = 3 {
        didSet {
            UserDefaults.standard.set(pollInterval, forKey: Keys.pollInterval)
            startPolling()
        }
    }

    /// 配色：暖色 / 冷色。改动后写进 App Group 容器，并让桌面小组件按新配色重画一次。
    /// 面板和设置页靠 `.id(model.theme)` 重建整棵视图，`Palette` 的静态颜色才会重新取。
    var theme: ThemeMode = Palette.mode {
        didSet {
            guard theme != oldValue else { return }
            Palette.apply(theme)
            widgets?.themeChanged()
            appLog.debug("配色切换为 \(self.theme.rawValue, privacy: .public)")
        }
    }

    @ObservationIgnored private let lan = LANClient()
    @ObservationIgnored private let keychain = KeychainStore()
    @ObservationIgnored private var clients: [String: MCPClient] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// 每次读取领一个递增序号；每台设备只接受比上次写回更新的结果。
    @ObservationIgnored private var refreshCounter = 0
    @ObservationIgnored private var appliedRefresh: [String: Int] = [:]
    /// 每次读取控制状态领一个序号，只有每台设备最新的一次能写回。
    @ObservationIgnored private var loadCounter = 0
    @ObservationIgnored private var currentLoad: [String: Int] = [:]
    /// 每条提示一个序号；到时间只收起自己那条，文字相同的新提示不受影响。
    @ObservationIgnored private var messageCounter = 0
    @ObservationIgnored private var currentMessage: [String: Int] = [:]
    /// 离屏截图用的假数据模型：不轮询、不碰钥匙串和网络。
    @ObservationIgnored private var isSnapshot = false
    /// 启动参数 `--cloud-only`：不读局域网，只用云端读数（在家里也能试离网时的样子）。
    @ObservationIgnored private var cloudOnly = false
    /// 还没满 10 秒的读数（满了才写进 `history`，免得曲线每次读数都重画）。
    @ObservationIgnored private var recorders: [String: [Int: HistoryRecorder]] = [:]
    /// 给桌面小组件写数据、收小组件的开关命令。没有 App Group（SwiftPM 调试构建）时为 nil。
    @ObservationIgnored private var widgets: WidgetBridge?
    /// 充电曲线有没存盘的新点，和上次存盘的时间。
    @ObservationIgnored private var historyDirty = false
    @ObservationIgnored private var historySavedAt = Date.distantPast
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var terminationSignal: DispatchSourceSignal?

    /// 正在运行的模型，快捷指令通过它读数和控制（离屏截图用的假数据模型不算）。
    private(set) static var running: AppModel?

    private enum Keys {
        static let devices = "devices.v1"
        static let pollInterval = "pollInterval"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.devices),
           let saved = try? JSONDecoder().decode([DeviceConfig].self, from: data) {
            devices = saved
        }
        let interval = defaults.double(forKey: Keys.pollInterval)
        pollInterval = interval >= 1 ? interval : 3
        refreshMCPStatus()
        handleLaunchArguments()
        loadSavedHistory()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveHistory(immediately: true) }
        }
        // kill、launchctl 发 SIGTERM 时也走正常退出：存好充电曲线，告诉小组件 app 退出了
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler {
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
        terminate.resume()
        terminationSignal = terminate
        Self.running = self
        widgets = WidgetBridge(model: self)
        startPolling()
    }

    #if DEBUG
    init(snapshotDevices: [DeviceConfig], runtime: [String: DeviceRuntime], configured: Set<String>,
         history: [String: [Int: PortHistory]] = [:]) {
        isSnapshot = true
        devices = snapshotDevices
        self.runtime = runtime
        mcpConfigured = configured
        self.history = history
        updateSummary()
    }
    #endif

    // MARK: - 局域网读数

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // 间隔从一轮开始算：有设备离线时一轮要等解析和请求超时（3–7 秒），不然实际间隔是「设置的秒数 + 超时」，
                // 在线设备的读数也会跟着变慢，极端时超过 isOnline 的窗口闪一下离线。读取比间隔还慢时至少歇 1 秒。
                let started = ContinuousClock.now
                await self.refreshAll()
                let elapsed = started.duration(to: ContinuousClock.now)
                let wait = max(Duration.seconds(self.pollInterval) - elapsed, Duration.seconds(1))
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// `cloudNow`：局域网读不到时马上读一次云端，不等 15 秒的间隔（点了刷新、刚发完命令、快捷指令要读数）。
    func refreshAll(cloudNow: Bool = false) async {
        guard !isSnapshot else { return }
        let psns = devices.map(\.psn)
        await withTaskGroup(of: Void.self) { group in
            for psn in psns {
                group.addTask { await self.refresh(psn, cloudNow: cloudNow) }
            }
        }
    }

    func refresh(_ psn: String, cloudNow: Bool = false) async {
        // 每次都取最新配置，不用调用方手里的旧副本。调用方可以传裸 PSN 或 `candysign:<PSN>`。
        guard let device = device(psn) else { return }
        let psn = device.psn
        refreshCounter += 1
        let ticket = refreshCounter
        var state = runtime[psn] ?? DeviceRuntime()
        var lanFetched = false
        let host = device.effectiveHost
        // IP 可能被 DHCP 换给另一台小电拼，旧地址照样能连通，只靠失败重试发现不了。
        // 所以主机名每分钟重新解析一次，IP 变了或满一分钟就用首页里的 PSN 核对身份。
        let resolveDue = state.resolvedAt.map { Date().timeIntervalSince($0) > 60 } ?? true
        if cloudOnly {
            state.failures += 1
            state.lastError = "启动参数 --cloud-only：不读局域网"
        } else if state.resolvedIP == nil || (resolveDue && !HostResolver.isIPv4Literal(host)) {
            if let ip = await HostResolver.resolveIPv4(host) { state.resolvedIP = ip }
            // 解析失败也记下时间，避免每轮都等满超时
            state.resolvedAt = Date()
        }
        if cloudOnly {
            // 上面已经记成局域网失败
        } else if let ip = state.resolvedIP {
            do {
                let verifyDue = state.verifiedIP != ip || (state.verifiedAt.map { Date().timeIntervalSince($0) > 60 } ?? true)
                if verifyDue {
                    do {
                        let info = try await lan.info(ip: ip)
                        if let found = info.psn, found != psn { throw LANError.wrongDevice(found) }
                    } catch LANError.decoding {
                        // 首页格式变了、核对不了 PSN 时不拦读数
                    }
                    state.verifiedIP = ip
                    state.verifiedAt = Date()
                }
                state.metrics = try await lan.metrics(ip: ip)
                lanFetched = true
                state.lastSuccess = Date()
                state.source = .lan
                state.lastError = nil
                state.failures = 0
                state.cloudCheckedAt = nil
                state.cloudFailures = 0
                state.cloudError = nil
            } catch LANError.wrongDevice(let found) {
                // 不显示别的设备的读数；下一轮立即重新解析
                state.metrics = nil
                state.resolvedIP = nil
                state.resolvedAt = nil
                state.verifiedIP = nil
                state.failures += 1
                state.lastError = LANError.wrongDevice(found).localizedDescription
            } catch {
                state.failures += 1
                state.lastError = error.localizedDescription
                // 连续失败就丢掉缓存的 IP，下次重新解析（DHCP 可能换了地址）
                if state.failures >= 2 { state.resolvedIP = nil }
            }
        } else {
            state.failures += 1
            state.lastError = LANError.unresolved(host).localizedDescription
        }
        // 局域网连续两次读不到（Mac 不在同一个网络、或者设备换了地址）：配好 MCP 的话改读云端，每 15 秒一次
        var cloudDetails: [Int: PortDetail]?
        if !lanFetched, !isSnapshot, mcpConfigured.contains(psn), cloudOnly || cloudNow || state.failures >= 2 {
            let due = state.cloudCheckedAt.map {
                Date().timeIntervalSince($0) >= CloudReading.interval(afterFailures: state.cloudFailures)
            } ?? true
            if cloudNow || due {
                state.cloudCheckedAt = Date()
                do {
                    let reading = try await client(for: psn).cloudReading()
                    if state.source != .cloud || state.cloudError != nil {
                        appLog.notice("局域网读不到，改用云端读数：\(reading.metrics.ports.count, privacy: .public) 个口")
                    }
                    state.metrics = reading.metrics
                    state.lastSuccess = Date()
                    state.source = .cloud
                    state.cloudFailures = 0
                    state.cloudError = nil
                    cloudDetails = reading.details
                } catch {
                    if case MCPError.unauthorized = error { clients[psn] = nil }
                    if state.cloudError == nil {
                        appLog.notice("局域网和云端都读不到：\(error.localizedDescription, privacy: .public)")
                    }
                    state.cloudFailures += 1
                    state.cloudError = error.localizedDescription
                }
            }
        }
        let fetched = lanFetched || cloudDetails != nil
        if lanFetched, runtime[psn]?.source == .cloud { appLog.notice("回到局域网读数") }
        // 等待期间可能删了设备、改了主机，或者更晚发出的读取已经先写回：这些情况下丢弃本次结果
        guard self.device(psn) != nil, ticket > appliedRefresh[psn, default: 0] else { return }
        appliedRefresh[psn] = ticket
        // 控制相关字段可能也在等待期间变了，只回写读数部分
        mutate(psn) {
            $0.metrics = state.metrics
            $0.lastSuccess = state.lastSuccess
            $0.lastError = state.lastError
            $0.resolvedIP = state.resolvedIP
            $0.resolvedAt = state.resolvedAt
            $0.verifiedIP = state.verifiedIP
            $0.verifiedAt = state.verifiedAt
            $0.failures = state.failures
            $0.source = state.source
            $0.cloudCheckedAt = state.cloudCheckedAt
            $0.cloudFailures = state.cloudFailures
            $0.cloudError = state.cloudError
            // 回到局域网时开关状态又是读出来的了，不再需要本机命令作参考
            if lanFetched { $0.portCommands = [:] }
            // 云端读数里本来就有芯片温度和本次电量（服务端换算好的 mWh），直接替换
            if let cloudDetails { $0.identity.details = cloudDetails }
        }
        if fetched, let metrics = state.metrics { recordHistory(psn, metrics, at: Date()) }
        updateSummary()
    }

    func isOnline(_ psn: String) -> Bool {
        guard let state = runtime[psn], let last = state.lastSuccess else { return false }
        let window = state.source == .cloud ? CloudReading.freshness : max(pollInterval * 3, 10)
        return Date().timeIntervalSince(last) < window
    }

    /// 在线，并且读数来自云端（Mac 连不上设备的局域网）。
    func isCloud(_ psn: String) -> Bool {
        runtime[psn]?.source == .cloud && isOnline(psn)
    }

    private func updateSummary() {
        let values = devices.compactMap { device -> Double? in
            isOnline(device.psn) ? runtime[device.psn]?.metrics?.totalWatts : nil
        }
        let title = values.isEmpty ? "—" : Self.format(watts: values.reduce(0, +))
        let online = !values.isEmpty
        if title != menuBarTitle { menuBarTitle = title }
        if online != anyOnline { anyOnline = online }
        widgets?.setNeedsUpdate()
    }

    /// 菜单栏读数：只留数字，不写单位（糖标本身已经说明是电）。和面板同一套舍入（99.95 起不带小数），上千瓦换成 k。
    /// 只会出现 `MenuBarIcon.widthSamples` 里那几种写法，图标宽度不变。
    static func format(watts: Double) -> String {
        watts >= 999.5 ? String(format: "%.1fk", watts / 1000) : PanelFormat.watts(watts)
    }

    // MARK: - MCP 控制

    // 控制函数返回失败原因，nil 表示成功（快捷指令要用）；界面上的提示照常显示。

    @discardableResult
    func setPort(psn requested: String, index: Int, on: Bool) async -> String? {
        let psn = canonical(requested)
        if refuse(psn, .portPower) != nil { return "这台设备不支持这项操作" }
        let name = PortNaming.name(index: index)
        let error = await run(psn, busy: on ? "正在打开 \(name)…" : "正在关闭 \(name)…",
                              success: on ? "已打开 \(name)" : "已关闭 \(name)") {
            try await Self.send(.setPort(index: index, on: on), psn: psn, client: $0)
        }
        if error == nil { mutate(psn) { $0.portCommands[index] = PortCommand(on: on, at: Date()) } }
        await refresh(psn, cloudNow: true)
        return error
    }

    @discardableResult
    func setStrategy(psn requested: String, _ strategy: ChargingStrategy) async -> String? {
        let psn = canonical(requested)
        if refuse(psn, .chargingStrategy) != nil { return "这台设备不支持这项操作" }
        let error = await run(psn, busy: "正在切换到「\(strategy.title)」…", success: "已切换到「\(strategy.title)」") {
            try await Self.send(.setStrategy(strategy), psn: psn, client: $0)
        }
        if error == nil { updateDevice(psn) { $0.lastStrategy = strategy.rawValue } }
        return error
    }

    @discardableResult
    func setTemperature(psn requested: String, _ mode: TemperatureMode) async -> String? {
        let psn = canonical(requested)
        if refuse(psn, .temperatureMode) != nil { return "这台设备不支持这项操作" }
        return await setControl(psn, \.temperature, mode, busy: "正在设置温控…", success: "温控已设为\(mode.title)") {
            try await Self.send(.setTemperature(mode), psn: psn, client: $0)
        }
    }

    @discardableResult
    func setDisplay(psn requested: String, _ level: DisplayLevel) async -> String? {
        let psn = canonical(requested)
        if refuse(psn, .displaySettings) != nil { return "这台设备不支持这项操作" }
        return await setControl(psn, \.display, level, busy: "正在设置屏幕亮度…", success: "屏幕亮度已设为「\(level.rawValue)」") {
            try await Self.send(.setDisplay(level), psn: psn, client: $0)
        }
    }

    /// 能读回当前值的设置：界面上先换成新值，发送失败再改回去，免得选项先跳回旧值、成功后才变。
    @discardableResult
    private func setControl<Value>(_ psn: String, _ field: WritableKeyPath<ControlState, Value?>, _ value: Value,
                                   busy: String, success: String,
                                   _ operation: (MCPClient) async throws -> String) async -> String? {
        if let current = runtime[psn]?.busy { return Self.busyText(current) }
        let previous = runtime[psn]?.control[keyPath: field] ?? nil
        mutate(psn) {
            $0.control[keyPath: field] = value
            // 读取中的旧结果不再覆盖
            $0.control.revision += 1
        }
        let error = await run(psn, busy: busy, success: success, operation)
        if error != nil { mutate(psn) { $0.control[keyPath: field] = previous } }
        return error
    }

    /// 读取温控模式和屏幕亮度（MCP 有对应的 get 工具），60 秒内不重复读。
    /// 面板每次打开都会自动调用，所以失败只记在控制菜单里，不在卡片上弹错误。
    func loadControls(psn requested: String, force: Bool = false) async {
        let psn = canonical(requested)
        let caps = capabilities(for: psn)
        guard caps.contains(.temperatureMode) || caps.contains(.displaySettings) || caps.contains(.powerAllocation) else { return }
        guard !isSnapshot, mcpConfigured.contains(psn) else { return }
        if !force, let loaded = runtime[psn]?.control.loadedAt, Date().timeIntervalSince(loaded) < 60 { return }
        loadCounter += 1
        let ticket = loadCounter
        currentLoad[psn] = ticket
        let revision = runtime[psn]?.control.revision ?? 0
        let knownFacts = runtime[psn]?.control.facts
        do {
            let client = try client(for: psn)
            async let temperature = client.temperatureMode()
            async let display = client.displayConfig()
            // 上限读不到不算失败，分配时退回实测的 CP02 Pro 数值
            async let facts = Self.machineFacts(client, known: knownFacts)
            let (t, d, f) = try await (temperature, display, facts)
            guard currentLoad[psn] == ticket else { return }
            mutate(psn) {
                if let f { $0.control.facts = f }
                // 读取期间用户改过设置时，以刚设置的值为准：读到的（可能已经过时的）值只补上还没有值的项，不覆盖。
                // 以前是整份丢掉，loadedAt 留空，「调节」页会一直显示“正在读取当前设置…”
                let fresh = $0.control.revision == revision
                if fresh || $0.control.temperature == nil { $0.control.temperature = t }
                if fresh || $0.control.display == nil { $0.control.display = d.level }
                if fresh || $0.control.statusMode == nil { $0.control.statusMode = d.statusMode }
                if fresh || $0.control.idleDisplay == nil { $0.control.idleDisplay = d.idleDisplay }
                if fresh || $0.control.hourlyChime == nil { $0.control.hourlyChime = d.hourlyChime }
                // 这项是设备报的能力，不是用户改的
                $0.control.supportsExtendedDisplay = d.supportsExtendedOptions
                $0.control.loadedAt = Date()
                $0.control.loadError = nil
            }
        } catch {
            // 关面板会取消读取，不算失败；已有更新的读取时也不写回
            guard !Task.isCancelled, currentLoad[psn] == ticket else { return }
            mutate(psn) { $0.control.loadError = error.localizedDescription }
        }
    }

    private nonisolated static func machineFacts(_ client: MCPClient, known: MachineFacts?) async -> MachineFacts? {
        if let known { return known }
        return try? await client.machineFacts()
    }

    /// 每口功率上限：读到了用设备的，没读到用实测的 CP02 Pro 数值。
    func facts(_ psn: String) -> MachineFacts {
        runtime[psn]?.control.facts ?? .cp02Pro
    }

    // MARK: - 设备识别

    /// 识别各口接的设备（MCP `get_port_pd_status` + `get_port_details`）。
    /// 面板或设置页开着时每隔几秒调一次，这里决定要不要真的去读：插拔或重新握手后（离上次读至少 5 秒）读一次，
    /// 20 秒后再补读一次，平时每分钟更新一次电量。没接设备时不问云端。`force` 跳过这些间隔（手动刷新）。
    func loadIdentities(psn requested: String, force: Bool = false) async {
        let psn = canonical(requested)
        guard capabilities(for: psn).contains(.portIdentity),
              !isSnapshot, mcpConfigured.contains(psn), isOnline(psn),
              let ports = runtime[psn]?.metrics?.ports else { return }
        let state = runtime[psn]?.identity ?? IdentityState()
        guard !state.loading else { return }
        let now = Date()
        let signature = PortIdentity.signature(of: ports)
        let changed = signature != state.signature
        let followUpDue = state.followUpAt.map { now >= $0 } ?? false
        let age = state.loadedAt.map { now.timeIntervalSince($0) } ?? .infinity
        guard force || (changed && age >= 5) || followUpDue || age >= 60 else { return }
        guard ports.contains(where: \.attached) else {
            mutate(psn) {
                $0.identity = IdentityState(lanUnitsPerMWh: $0.identity.lanUnitsPerMWh, signature: signature, loadedAt: now)
            }
            return
        }
        mutate(psn) {
            $0.identity.loading = true
            if changed {
                $0.identity.followUpAt = now.addingTimeInterval(20)
            } else if followUpDue {
                $0.identity.followUpAt = nil
            }
        }
        do {
            let info = try await client(for: psn).portInfo()
            guard device(psn) != nil else { return }
            // 记下这时局域网读数里同一会话的电量计数，之后用它的增量把电量往后推算
            var details = info.details
            for port in runtime[psn]?.metrics?.ports ?? [] {
                guard let detail = details[port.id], detail.sessionID == port.sessionID else { continue }
                details[port.id]?.lanChargeAtLoad = port.sessionCharge
            }
            mutate(psn) {
                $0.identity.ports = info.identities
                $0.identity.details = details
                if let units = SessionEnergy.calibrate(Array(details.values)) { $0.identity.lanUnitsPerMWh = units }
                $0.identity.signature = signature
                $0.identity.loadedAt = Date()
                $0.identity.loading = false
                $0.identity.loadError = nil
            }
        } catch {
            guard device(psn) != nil else { return }
            if case MCPError.unauthorized = error { clients[psn] = nil }
            // 关面板会取消读取，不算失败，下次打开再读
            let cancelled = Task.isCancelled
            mutate(psn) {
                $0.identity.loading = false
                guard !cancelled else { return }
                $0.identity.signature = signature
                $0.identity.loadedAt = Date()
                $0.identity.loadError = error.localizedDescription
            }
        }
    }

    /// 这个口当前接的设备的识别结果。端口空着、或者结果属于上一次插入的设备时返回 nil。
    func identity(_ psn: String, port: PortMetrics) -> PortIdentity? {
        guard port.attached, let identity = runtime[psn]?.identity.ports[port.id] else { return nil }
        if let session = identity.sessionID, let current = port.sessionID, session != current { return nil }
        return identity
    }

    /// 这个口的芯片温度（随识别结果一起读）。端口空着、或者属于上一次插入时返回 nil。
    func temperature(_ psn: String, port: PortMetrics) -> PortTemperature? {
        guard port.attached, let detail = runtime[psn]?.identity.details[port.id] else { return nil }
        if let session = detail.sessionID, let current = port.sessionID, session != current { return nil }
        return detail.temperature
    }

    /// 本次充电已充的电量（mWh）：MCP 读数加上之后局域网计数的增量。读不到或还是 0 时返回 nil。
    func sessionEnergy(_ psn: String, port: PortMetrics) -> Double? {
        guard port.attached, let state = runtime[psn]?.identity, let detail = state.details[port.id],
              let value = SessionEnergy.estimate(detail, port: port, unitsPerMWh: state.lanUnitsPerMWh),
              value > 0 else { return nil }
        return value
    }

    // MARK: - 充电曲线

    /// 从小电拼内存读这几个口最近 30 分钟的记录（MCP `get_port_stats`，只读）。
    /// 充电曲线显示时调用；本 app 之后一直用局域网读数接着记，所以 5 分钟内读过的口不重读，`force` 时都重读。
    func loadDeviceHistory(psn: String, ports ids: [Int], force: Bool = false) async {
        guard !isSnapshot, mcpConfigured.contains(psn), isOnline(psn) else { return }
        let now = Date()
        let busy = historyLoading[psn] ?? []
        let due = ids.filter { id in
            guard !busy.contains(id) else { return false }
            guard !force, let loaded = history[psn]?[id]?.deviceLoadedAt else { return true }
            return now.timeIntervalSince(loaded) > 300
        }
        guard !due.isEmpty, let client = try? client(for: psn) else { return }
        historyLoading[psn, default: []].formUnion(due)
        // 单独起一个任务，不跟着界面取消：曲线刚打开时端口选择会从「合计」跳到在充的口，
        // 跟着取消的话，已经发出的读取白读，新的读取又因为“正在读”被跳过
        let results = await Task { await Self.fetchHistory(client, ports: due) }.value
        historyLoading[psn]?.subtract(due)
        guard device(psn) != nil else { return }
        let loadedAt = Date()
        var ports = history[psn] ?? [:]
        var failure: Error?
        for (id, result) in results {
            switch result {
            case .success(let samples): ports[id, default: PortHistory()].setDeviceSamples(samples, loadedAt: loadedAt)
            case .failure(let error): failure = error
            }
        }
        history[psn] = ports
        historyDirty = true
        saveHistory()
        if let failure {
            if case MCPError.unauthorized = failure { clients[psn] = nil }
            historyError[psn] = failure.localizedDescription
        } else {
            historyError[psn] = nil
        }
    }

    /// 读几个口的 `get_port_stats`，同时最多两个，免得一下子压给设备太多请求（每个约 1.2 秒）。
    private nonisolated static func fetchHistory(_ client: MCPClient, ports ids: [Int]) async
        -> [Int: Result<[PowerSample], Error>] {
        var pending = ids[...]
        var results: [Int: Result<[PowerSample], Error>] = [:]
        await withTaskGroup(of: (Int, Result<[PowerSample], Error>).self) { group in
            func fetch(_ id: Int) async -> (Int, Result<[PowerSample], Error>) {
                do { return (id, .success(try await client.portHistory(portID: id))) } catch { return (id, .failure(error)) }
            }
            for _ in 0..<2 {
                guard let id = pending.popFirst() else { break }
                group.addTask { await fetch(id) }
            }
            for await (id, result) in group {
                results[id] = result
                if let next = pending.popFirst() { group.addTask { await fetch(next) } }
            }
        }
        return results
    }

    /// 画曲线用的点：`port` 为 nil 时是各口合计。在线时末尾补一个当前读数，曲线跟着实时动。
    func historySamples(psn: String, port: Int?, since start: Date, now: Date = Date()) -> [PowerSample] {
        let all = history[psn] ?? [:]
        let metrics = isOnline(psn) ? runtime[psn]?.metrics : nil
        var samples: [PowerSample]
        var live: PowerSample?
        if let port {
            samples = all[port]?.samples(since: start) ?? []
            if let current = metrics?.ports.first(where: { $0.id == port }) {
                live = PowerSample(time: now, watts: current.watts, volts: current.volts, amps: current.amps)
            }
        } else {
            samples = PortHistory.total(all.values.map { $0.samples(since: start) })
            if let metrics { live = PowerSample(time: now, watts: metrics.totalWatts, volts: 0, amps: 0) }
        }
        if let live, samples.last.map({ live.time > $0.time }) ?? true { samples.append(live) }
        return samples
    }

    /// 每次读到局域网读数就给各口记一笔，10 秒合成一个点。
    private func recordHistory(_ psn: String, _ metrics: DeviceMetrics, at time: Date) {
        var finished: [(Int, PowerSample)] = []
        var portRecorders = recorders[psn] ?? [:]
        for port in metrics.ports {
            var recorder = portRecorders[port.id] ?? HistoryRecorder()
            if let sample = recorder.add(watts: port.watts, volts: port.volts, amps: port.amps, at: time) {
                finished.append((port.id, sample))
            }
            portRecorders[port.id] = recorder
        }
        recorders[psn] = portRecorders
        guard !finished.isEmpty else { return }
        var ports = history[psn] ?? [:]
        for (id, sample) in finished { ports[id, default: PortHistory()].record(sample) }
        history[psn] = ports
        historyDirty = true
        saveHistory()
    }

    private static let historySaveInterval: TimeInterval = 60

    private static var historyURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.local.CoCanBar", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    /// 启动时读回上次存的充电曲线：只留还在列表里的设备、2 小时内的点。
    private func loadSavedHistory() {
        guard !isSnapshot, let url = Self.historyURL, let archive = HistoryArchive.load(from: url) else { return }
        history = archive.pruned(now: Date(), keeping: Set(devices.map(\.psn)))
        let ports = history.values.reduce(0) { $0 + $1.count }
        appLog.notice("充电曲线：读回 \(ports, privacy: .public) 个口的记录")
    }

    /// 有新点时最多每分钟存一次；`immediately` 时（退出 app）不等。
    private func saveHistory(immediately: Bool = false) {
        guard !isSnapshot, historyDirty, let url = Self.historyURL else { return }
        let now = Date()
        guard immediately || now.timeIntervalSince(historySavedAt) >= Self.historySaveInterval else { return }
        do {
            try HistoryArchive(savedAt: now, devices: history).save(to: url)
            historyDirty = false
            historySavedAt = now
            if immediately {
                let ports = history.values.reduce(0) { $0 + $1.count }
                appLog.notice("退出前已保存充电曲线：\(ports, privacy: .public) 个口")
            }
        } catch {
            appLog.error("保存充电曲线失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 临时的端口功率分配，按端口顺序 A、C1…C4（W），0 表示按策略默认。先在本地检查范围再发送。
    func setPowerAllocation(psn requested: String, _ watts: [Int]) async {
        let psn = canonical(requested)
        if refuse(psn, .powerAllocation) != nil { return }
        if let problem = facts(psn).problem(with: watts) {
            showMessage(psn, problem, isError: true)
            return
        }
        await run(psn, busy: "正在应用功率分配…", success: "已应用功率分配，插拔设备或开关端口后会回到策略分配") {
            try await Self.send(.setPowerAllocation(watts), psn: psn, client: $0)
        }
        await refresh(psn)
    }

    func setStatusDisplayMode(psn requested: String, _ mode: StatusDisplayMode) async {
        let psn = canonical(requested)
        if refuse(psn, .displaySettings) != nil { return }
        await setControl(psn, \.statusMode, mode, busy: "正在设置屏显模式…", success: "屏显模式已设为「\(mode.rawValue)」") {
            try await Self.send(.setStatusDisplayMode(mode), psn: psn, client: $0)
        }
    }

    func setIdleDisplay(psn requested: String, _ display: IdleDisplay) async {
        let psn = canonical(requested)
        if refuse(psn, .displaySettings) != nil { return }
        await setControl(psn, \.idleDisplay, display, busy: "正在设置待机显示…", success: "待机显示已设为「\(display.rawValue)」") {
            try await Self.send(.setIdleDisplay(display), psn: psn, client: $0)
        }
    }

    func setHourlyChime(psn requested: String, _ enabled: Bool) async {
        let psn = canonical(requested)
        if refuse(psn, .displaySettings) != nil { return }
        await setControl(psn, \.hourlyChime, enabled, busy: enabled ? "正在打开整点报时…" : "正在关闭整点报时…",
                         success: enabled ? "已打开整点报时" : "已关闭整点报时") {
            try await Self.send(.setHourlyChime(enabled), psn: psn, client: $0)
        }
    }

    /// 从面板跳到设置窗口的「调节」页，并选中这台设备。
    func showControls(for psn: String) {
        settingsDevice = canonical(psn)
        settingsTab = .controls
    }

    /// 用户点了别的端口时收起提示，让详情条显示刚点的内容。
    func clearMessage(_ requested: String) {
        let psn = canonical(requested)
        currentMessage[psn] = nil
        guard runtime[psn]?.message != nil else { return }
        mutate(psn) { $0.message = nil }
    }

    /// 握手并列出工具，用于设置页的“测试连接”。
    func testMCP(psn requested: String) async -> Result<Int, Error> {
        let psn = canonical(requested)
        do {
            let client = try client(for: psn)
            await client.reset()
            return .success(try await client.listTools().count)
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    private func run(_ psn: String, busy: String, success: String,
                     _ operation: (MCPClient) async throws -> String) async -> String? {
        guard !isSnapshot else {
            showMessage(psn, "演示数据，不会发送：\(success)", isError: false)
            return "演示数据，不会发送"
        }
        // 同一台设备一次只发一个写操作（界面上也会禁用，这里再兜一层，防连点）
        if let current = runtime[psn]?.busy { return Self.busyText(current) }
        mutate(psn) {
            $0.busy = busy
            $0.message = nil
        }
        do {
            let client = try client(for: psn)
            _ = try await operation(client)
            mutate(psn) { $0.busy = nil }
            showMessage(psn, success, isError: false)
            return nil
        } catch {
            if case MCPError.unauthorized = error { clients[psn] = nil }
            mutate(psn) { $0.busy = nil }
            showMessage(psn, error.localizedDescription, isError: true)
            return error.localizedDescription
        }
    }

    /// 「正在关闭 C1…」→「上一个操作还没完成（正在关闭 C1），请稍后再试」
    static func busyText(_ busy: String) -> String {
        "上一个操作还没完成（\(busy.trimmingCharacters(in: CharacterSet(charactersIn: "…")))），请稍后再试"
    }

    private func client(for psn: String) throws -> MCPClient {
        // 演示数据模型不读钥匙串
        guard !isSnapshot else { throw AppError.noMCP }
        let id = device(psn)?.chargerID ?? ChargerID(storedKey: psn)
        let account = id.legacyStorageKey
        if let client = clients[account] { return client }
        // 旧安装的钥匙串项用裸 PSN。没有时再看 `candysign:<PSN>`，不把现有项搬到新键（搬家会再弹一次授权）。
        guard let raw = try keychain.read(charger: id) else { throw AppError.noMCP }
        guard let endpoint = MCPEndpoint(string: raw), endpoint.psn == id.localID else { throw AppError.mcpMismatch }
        let client = MCPClient(endpoint: endpoint, clientVersion: Self.appVersion)
        clients[account] = client
        return client
    }

    /// 裸 PSN 和 `candysign:<PSN>` 都落到存盘用的键。找不到设备时原样返回，和以前的失败路径一样。
    private func canonical(_ key: String) -> String {
        device(key)?.psn ?? key
    }

    func capabilities(for key: String) -> ChargerCapabilities {
        let id = device(key)?.chargerID ?? ChargerID(storedKey: key)
        return ChargerDrivers.driver(for: id)?.capabilities ?? []
    }

    /// 驱动没有这项能力时不发命令。小电拼的能力是满的，这里不会拦住。
    private func refuse(_ psn: String, _ capability: ChargerCapabilities) -> String? {
        guard capabilities(for: psn).contains(capability) else {
            let text = ChargerDriverError.unsupported.localizedDescription
            showMessage(psn, text, isError: true)
            return text
        }
        return nil
    }

    /// 经小电拼驱动的短会话发一条命令：打开、调用、关掉。HTTP 没有要断开的连接。
    /// `psn` 是存盘键（裸 PSN 或带前缀的编号），不碰界面状态，所以不用主线程。
    private nonisolated static func send(_ command: ChargerCommand, psn: String, client: MCPClient) async throws -> String {
        let id = ChargerID(storedKey: psn)
        guard let driver = ChargerDrivers.driver(for: id) as? CandySignDriver else {
            throw ChargerDriverError.unavailable
        }
        let session = driver.openSession(for: id, mcp: client, lanIP: nil)
        do {
            let text = try await session.perform(command)
            await session.close()
            return text
        } catch {
            await session.close()
            throw error
        }
    }

    private func showMessage(_ psn: String, _ text: String, isError: Bool) {
        messageCounter += 1
        let serial = messageCounter
        currentMessage[psn] = serial
        mutate(psn) {
            $0.message = text
            $0.messageIsError = isError
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 10 : 5))
            guard let self, self.currentMessage[psn] == serial, self.runtime[psn]?.message != nil else { return }
            self.currentMessage[psn] = nil
            self.mutate(psn) { $0.message = nil }
        }
    }

    private func mutate(_ psn: String, _ change: (inout DeviceRuntime) -> Void) {
        var state = runtime[psn] ?? DeviceRuntime()
        change(&state)
        runtime[psn] = state
        widgets?.setNeedsUpdate()
    }

    // MARK: - 设备与钥匙串

    func device(_ psn: String) -> DeviceConfig? {
        devices.first { $0.chargerID.matches(storedKey: psn) }
    }

    /// 保存一条 MCP 地址到钥匙串；`expectedPSN` 不为空时要求 PSN 一致。
    /// `raw` 可以只是地址，也可以是小程序「龙虾服务」复制出来的整段文字。
    func saveMCP(_ raw: String, expectedPSN: String? = nil) throws -> MCPEndpoint {
        let found = MCPEndpoint(string: raw).map { [$0] } ?? MCPEndpoint.extractAll(from: raw)
        guard let endpoint = found.first(where: { $0.psn == expectedPSN }) ?? found.first else { throw AppError.invalidMCP }
        if let expectedPSN, endpoint.psn != expectedPSN { throw AppError.mcpMismatch }
        try keychain.save(endpoint.url.absoluteString, account: endpoint.psn, label: "小电拼 MCP \(endpoint.psn)")
        clients[endpoint.psn] = nil
        mcpConfigured.insert(endpoint.psn)
        if device(endpoint.psn) == nil { addDevice(psn: endpoint.psn, name: nil) }
        return endpoint
    }

    func deleteMCP(psn: String) throws {
        let id = device(psn)?.chargerID ?? ChargerID(storedKey: psn)
        try keychain.delete(charger: id)
        for key in id.lookupKeys {
            clients[key] = nil
            mcpConfigured.remove(key)
        }
    }

    /// 从文本里导入所有 MCP 地址。
    @discardableResult
    func importMCP(from text: String) -> (saved: Int, failed: Int) {
        var saved = 0
        var failed = 0
        for endpoint in MCPEndpoint.extractAll(from: text) {
            do {
                _ = try saveMCP(endpoint.url.absoluteString)
                saved += 1
            } catch {
                failed += 1
                appLog.error("导入 MCP 地址失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        return (saved, failed)
    }

    func addDevice(psn: String, name: String?) {
        guard device(psn) == nil else { return }
        devices.append(DeviceConfig(psn: psn, name: name ?? "小电拼 \(psn.suffix(4))"))
        persistDevices()
        Task { await refresh(psn) }
    }

    /// 先删钥匙串里的 MCP 地址，删不掉就保留设备并报错，免得 token 留在钥匙串里却看不到。
    func removeDevice(_ requested: String) throws {
        let psn = canonical(requested)
        try deleteMCP(psn: psn)
        devices.removeAll { $0.chargerID.matches(storedKey: psn) }
        runtime[psn] = nil
        history[psn] = nil
        historyDirty = true
        historyLoading[psn] = nil
        historyError[psn] = nil
        recorders[psn] = nil
        appliedRefresh[psn] = refreshCounter
        persistDevices()
        updateSummary()
    }

    func rename(_ requested: String, to name: String) {
        let psn = canonical(requested)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateDevice(psn) { $0.name = trimmed }
    }

    func setHost(_ requested: String, _ host: String) {
        let psn = canonical(requested)
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = trimmed.isEmpty ? nil : trimmed
        guard let current = device(psn), current.hostOverride != override else { return }
        updateDevice(psn) { $0.hostOverride = override }
        // 作废改主机之前发出、还没返回的读取，再按新主机立即读一次
        appliedRefresh[psn] = refreshCounter
        mutate(psn) {
            $0.resolvedIP = nil
            $0.resolvedAt = nil
            $0.failures = 0
        }
        Task { await refresh(psn) }
    }

    func scanLAN() async -> [DiscoveredDevice] {
        let known = Set(devices.map(\.psn))
        return await BonjourScanner.scan(duration: 3).filter { !known.contains($0.psn) }
    }

    private func updateDevice(_ psn: String, _ change: (inout DeviceConfig) -> Void) {
        guard let index = devices.firstIndex(where: { $0.chargerID.matches(storedKey: psn) }) else { return }
        change(&devices[index])
        persistDevices()
    }

    private func persistDevices() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Keys.devices)
        }
        widgets?.setNeedsUpdate()
    }

    private func refreshMCPStatus() {
        mcpConfigured = Set(devices.compactMap { device in
            keychain.exists(charger: device.chargerID) ? device.psn : nil
        })
    }

    // MARK: - 登录时启动

    var launchAtLoginStatus: SMAppService.Status { SMAppService.mainApp.status }

    /// 已注册但还没在系统设置里批准（`.requiresApproval`）也算已注册：关闭时同样要注销。
    func setLaunchAtLogin(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        let registered = service.status == .enabled || service.status == .requiresApproval
        if enabled, !registered {
            try service.register()
        } else if !enabled, registered {
            try service.unregister()
        }
    }

    // MARK: - 启动参数

    /// `--import <文件>`：从文件里提取 MCP 地址存进钥匙串（按 PSN 建设备）；
    /// `--rename <PSN>=<名称>`：设置设备名称；`--cloud-only`：不读局域网，只用云端读数。日志里不输出地址。
    private func handleLaunchArguments() {
        let arguments = CommandLine.arguments
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch (flag, value) {
            case ("--import", let path?):
                let expanded = (path as NSString).expandingTildeInPath
                if let text = try? String(contentsOfFile: expanded, encoding: .utf8) {
                    let result = importMCP(from: text)
                    appLog.notice("导入 MCP 地址：成功 \(result.saved, privacy: .public) 条，失败 \(result.failed, privacy: .public) 条")
                } else {
                    appLog.error("导入失败：读不到文件")
                }
                index += 2
            case ("--rename", let pair?):
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { rename(parts[0], to: parts[1]) }
                index += 2
            case ("--cloud-only", _):
                cloudOnly = true
                appLog.notice("启动参数 --cloud-only：不读局域网，只用云端读数")
                index += 1
            default:
                index += 1
            }
        }
    }
}
