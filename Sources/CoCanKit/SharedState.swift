import Foundation
import Security
import notify

// 菜单栏 app 和桌面小组件之间共享的数据。
//
// 两边在同一个 App Group 容器里交换几个小文件：
// - snapshot.json：app 读到数据后写的快照。小组件拿不到 MCP 令牌（令牌只在 app 的钥匙串里）；
// - lan/<PSN>.json：app 没在运行时，小组件自己读局域网 `/metrics.json` 的结果（局域网接口不要令牌）。
//   文件名仍是裸 PSN。用 `candysign:<PSN>` 来查时会落到同一个文件。只有 HTTP 驱动可以直读；
// - commands/<id>.json：在小组件上点开关时写的命令，写完发一个 Darwin 通知叫醒 app；
// - replies/<id>.json：app 收下命令后的回复。小组件最多等 3 秒，等不到就撤回命令，提示 app 没在运行；
// - pending.json、notice.json：小组件自己用的「再点一次确认关闭」和提示文字。
// App Group 是 `<Team ID>.com.local.CoCanBar`，从自己的签名权限里读（见 `AppGroup`），代码里不写 Team ID。

public enum AppGroup {
    public static let entitlement = "com.apple.security.application-groups"

    /// 自己签名里的第一个 App Group。SwiftPM 的调试构建和临时签名（ad-hoc）没有这项权限，返回 nil。
    public static let identifier: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) else { return nil }
        return (value as? [String])?.first
    }()

    public static var containerURL: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// 小组件写完命令后发的通知。沙盒里的 Darwin 通知名以 App Group 开头。
    public static func commandNotification(group: String) -> String { "\(group).command" }

    /// 小组件上点了刷新：请 app 马上读一次局域网，写出新快照。
    public static func refreshNotification(group: String) -> String { "\(group).refresh" }
}

// MARK: - 快照

/// app 写给小组件的状态：每台设备的读数、各口状态和最近 30 分钟的功率。
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var updatedAt: Date
    /// 按 app 里的设备顺序。
    public var devices: [Device]
    /// 菜单栏 app 正常退出时写的时间。异常退出时不会写，靠 `updatedAt` 超过 1 分钟判断。
    public var appStoppedAt: Date?

    /// app 运行时最慢 10–20 秒写一次快照（轮询间隔最长 10 秒），1 分钟没写就当它没在运行。
    public static let appAliveWindow: TimeInterval = 60

    public init(updatedAt: Date, devices: [Device], appStoppedAt: Date? = nil) {
        self.updatedAt = updatedAt
        self.devices = devices
        self.appStoppedAt = appStoppedAt
    }

    public func device(_ psn: String?) -> Device? {
        guard let psn else { return devices.first }
        return devices.first { ChargerID(storedKey: $0.psn).matches(storedKey: psn) }
    }

    /// 菜单栏 app 这时还在运行：没有正常退出，并且 1 分钟内写过快照。
    public func appIsRunning(at date: Date) -> Bool {
        appStoppedAt == nil && date.timeIntervalSince(updatedAt) < Self.appAliveWindow
    }

    public struct Device: Codable, Sendable, Equatable, Identifiable {
        public var psn: String
        public var name: String
        /// 写快照时 app 是否还能读到它。
        public var online: Bool
        /// 最近一次读到读数的时间（局域网或云端）。
        public var readAt: Date?
        /// 配好了 MCP，能开关端口。
        public var controllable: Bool
        /// 本 app 上次设置的充电策略（`ChargingStrategy.rawValue`）。MCP 读不到设备当前的策略。
        public var strategy: Int?
        public var ports: [Port]
        /// 最近 30 分钟每分钟的合计功率（W），最后一个是 `recentWattsAt` 所在的那一分钟；没有记录的分钟为 nil。
        public var recentWatts: [Double?]
        public var recentWattsAt: Date?
        /// app 正在执行的操作（「正在关闭 C1…」）和最近一条提示。
        public var busy: String?
        public var message: String?
        public var messageIsError: Bool
        /// 局域网主机名（默认 `cp02-<PSN>.local`）和 app 上次核对过身份的 IP。app 没在运行时小组件用它们自己读数。
        public var host: String?
        public var lanIP: String?
        /// 局域网 `session_charge` 每 mWh 的计数（app 用 MCP 读数校准过），小组件用它接着算本次电量。
        public var lanUnitsPerMWh: Double?
        /// 读数来自云端 MCP（Mac 连不上设备的局域网）：没有开关状态，小组件上不能开关。
        public var viaCloud: Bool?

        public init(psn: String, name: String, online: Bool, readAt: Date?, controllable: Bool, strategy: Int?,
                    ports: [Port], recentWatts: [Double?] = [], recentWattsAt: Date? = nil, busy: String? = nil,
                    message: String? = nil, messageIsError: Bool = false, host: String? = nil, lanIP: String? = nil,
                    lanUnitsPerMWh: Double? = nil, viaCloud: Bool? = nil) {
            self.psn = psn
            self.name = name
            self.online = online
            self.readAt = readAt
            self.controllable = controllable
            self.strategy = strategy
            self.ports = ports
            self.recentWatts = recentWatts
            self.recentWattsAt = recentWattsAt
            self.busy = busy
            self.message = message
            self.messageIsError = messageIsError
            self.host = host
            self.lanIP = lanIP
            self.lanUnitsPerMWh = lanUnitsPerMWh
            self.viaCloud = viaCloud
        }

        public var id: String { psn }
        public var totalWatts: Double { ports.reduce(0) { $0 + $1.watts } }
        public var chargingCount: Int { ports.filter(\.isCharging).count }

        /// 用小组件自己读到的局域网数据更新这台设备（菜单栏 app 没在运行时）：
        /// - 同一次充电（会话号没变）沿用 app 认出的设备名，本次电量按局域网计数接着算；
        /// - 电池电量和芯片温度只有 MCP 有，不再显示旧值；
        /// - 走势往后挪到这一分钟，中间没有记录的分钟留空。
        public func updated(with metrics: DeviceMetrics, at date: Date) -> Device {
            var previous: [Int: Port] = [:]
            for port in ports { previous[port.id] = port }
            var device = self
            device.ports = metrics.ports.map { port in
                let old = previous[port.id]
                let sameSession = port.attached && old?.attached == true && port.sessionID != nil
                    && old?.sessionID == port.sessionID
                var energy: Double?
                if sameSession, let base = old?.sessionEnergyMWh, let before = old?.sessionCharge,
                   let count = port.sessionCharge, count >= before, let units = lanUnitsPerMWh, units > 0 {
                    energy = base + Double(count - before) / units
                }
                return Port(id: port.id, poweredOn: port.isPoweredOn, attached: port.attached, watts: port.watts,
                            volts: port.volts, amps: port.amps, fcProtocol: port.fcProtocol, protocolText: port.protocolText,
                            deviceName: sameSession ? old?.deviceName : nil, sessionEnergyMWh: energy,
                            chargingSeconds: port.chargingDurationSeconds, sessionID: port.sessionID,
                            sessionCharge: port.sessionCharge)
            }
            device.online = true
            device.readAt = date
            device.viaCloud = nil
            device.recentWatts = WidgetSnapshot.shiftedSeries(recentWatts, from: recentWattsAt ?? readAt ?? date,
                                                              to: date, latest: metrics.totalWatts)
            device.recentWattsAt = date
            device.busy = nil
            device.message = nil
            device.messageIsError = false
            return device
        }
    }

    public struct Port: Codable, Sendable, Equatable, Identifiable {
        /// `PortMetrics.id`，从 0 开始。
        public var id: Int
        /// 开着为 true、关着为 false；云端读数里不知道时为 nil（见 `PortMetrics.isPoweredOn`）。
        public var poweredOn: Bool?
        public var attached: Bool
        public var watts: Double
        public var volts: Double
        public var amps: Double
        public var fcProtocol: Int
        /// 云端读数里认不出编号的协议原文（见 `PortMetrics.protocolText`）。
        public var protocolText: String?
        /// 认出的设备（品牌型号），认不出为 nil。
        public var deviceName: String?
        public var batteryPercent: Int?
        /// `die_temperature` 的原文，见 `PortTemperature`。
        public var temperature: String?
        public var sessionEnergyMWh: Double?
        public var chargingSeconds: Int
        /// 局域网读数里的充电会话号和电量计数（见 `PortMetrics`），小组件靠它们判断还是不是同一次充电。
        public var sessionID: Int?
        public var sessionCharge: Int?

        public init(id: Int, poweredOn: Bool?, attached: Bool, watts: Double, volts: Double, amps: Double,
                    fcProtocol: Int, protocolText: String? = nil, deviceName: String? = nil, batteryPercent: Int? = nil,
                    temperature: String? = nil, sessionEnergyMWh: Double? = nil, chargingSeconds: Int = 0,
                    sessionID: Int? = nil, sessionCharge: Int? = nil) {
            self.id = id
            self.poweredOn = poweredOn
            self.attached = attached
            self.watts = watts
            self.volts = volts
            self.amps = amps
            self.fcProtocol = fcProtocol
            self.protocolText = protocolText
            self.deviceName = deviceName
            self.batteryPercent = batteryPercent
            self.temperature = temperature
            self.sessionEnergyMWh = sessionEnergyMWh
            self.chargingSeconds = chargingSeconds
            self.sessionID = sessionID
            self.sessionCharge = sessionCharge
        }

        public var name: String { PortNaming.name(index: id) }
        public var isCharging: Bool { attached && amps > 0 }
        /// 和 `PortMetrics.isInUse` 一样：确定开着并且插着设备，关掉之前要确认。
        public var inUse: Bool { poweredOn == true && attached }
        public var temperatureLevel: PortTemperature? { PortTemperature(temperature) }
    }

    /// 合计功率按分钟取平均，给小组件画走势。`samples` 是充电曲线用的 10 秒点（可以带末尾的实时读数）。
    public static func minuteSeries(_ samples: [PowerSample], now: Date, minutes: Int = 30) -> [Double?] {
        guard minutes > 0 else { return [] }
        let end = (now.timeIntervalSince1970 / 60).rounded(.down) * 60 + 60
        let start = end - Double(minutes) * 60
        var sums = [Double](repeating: 0, count: minutes)
        var counts = [Int](repeating: 0, count: minutes)
        for sample in samples {
            let t = sample.time.timeIntervalSince1970
            guard t >= start, t < end else { continue }
            let index = Int((t - start) / 60)
            sums[index] += sample.watts
            counts[index] += 1
        }
        return zip(sums, counts).map { $1 == 0 ? nil : $0 / Double($1) }
    }

    /// 把每分钟的走势从 `start` 所在的分钟挪到 `date` 所在的分钟：挪出窗口的丢掉，中间没有记录的分钟留空，
    /// 最后一分钟填 `latest`。
    public static func shiftedSeries(_ values: [Double?], from start: Date, to date: Date, latest: Double,
                                     minutes: Int = 30) -> [Double?] {
        guard minutes > 0 else { return [] }
        var series = Array(values.suffix(minutes))
        series = Array(repeating: nil, count: minutes - series.count) + series
        let shift = Int((date.timeIntervalSince1970 / 60).rounded(.down) - (start.timeIntervalSince1970 / 60).rounded(.down))
        if shift >= minutes {
            series = Array(repeating: nil, count: minutes)
        } else if shift > 0 {
            series = Array(series.dropFirst(shift)) + Array(repeating: nil, count: shift)
        }
        series[minutes - 1] = latest
        return series
    }

    /// 和上一次让小组件刷新时的快照相比变了多少。
    public enum Change: Int, Comparable, Sendable {
        /// 没变或只是小幅波动。
        case none
        /// 功率变化明显。
        case readings
        /// 开关、插拔、在线、提示这类要马上显示的变化。
        case state

        public static func < (lhs: Change, rhs: Change) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public func change(since old: WidgetSnapshot?) -> Change {
        guard let old, old.devices.map(\.psn) == devices.map(\.psn) else { return .state }
        var result = Change.none
        for (new, before) in zip(devices, old.devices) {
            if new.name != before.name || new.online != before.online || new.viaCloud != before.viaCloud
                || new.controllable != before.controllable
                || new.strategy != before.strategy || new.busy != before.busy || new.message != before.message
                || new.ports.map(\.id) != before.ports.map(\.id) {
                return .state
            }
            for (port, previous) in zip(new.ports, before.ports)
            where port.poweredOn != previous.poweredOn || port.attached != previous.attached
                || port.deviceName != previous.deviceName {
                return .state
            }
            let delta = abs(new.totalWatts - before.totalWatts)
            if delta >= max(3, before.totalWatts * 0.15) { result = .readings }
        }
        return result
    }
}

// MARK: - 命令和回复

/// 小组件发给 app 的开关命令。
public struct WidgetCommand: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var psn: String
    /// `PortMetrics.id`，从 0 开始。
    public var port: Int
    public var turnOn: Bool
    public var issuedAt: Date

    /// 超过 15 秒的命令不执行，免得 app 晚打开时端口突然被开关。
    public static let lifetime: TimeInterval = 15

    public init(id: UUID = UUID(), psn: String, port: Int, turnOn: Bool, issuedAt: Date = Date()) {
        self.id = id
        self.psn = psn
        self.port = port
        self.turnOn = turnOn
        self.issuedAt = issuedAt
    }

    /// 太旧，或者时间在未来（时钟被改过）。
    public func isExpired(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        return age > Self.lifetime || age < -5
    }
}

/// app 对命令的回复。收下命令就回，不等 MCP 执行完；执行结果在下一份快照的提示里。
public struct WidgetReply: Codable, Sendable, Equatable {
    public var id: UUID
    public var accepted: Bool
    public var message: String
    public var repliedAt: Date

    public init(id: UUID, accepted: Bool, message: String, repliedAt: Date = Date()) {
        self.id = id
        self.accepted = accepted
        self.message = message
        self.repliedAt = repliedAt
    }
}

/// 在小组件上关闭正在用的口要点两次：第一次记在这里，10 秒内再点同一个口才发命令。
public struct PendingConfirmation: Codable, Sendable, Equatable {
    public var psn: String
    public var port: Int
    public var expiresAt: Date

    public static let lifetime: TimeInterval = 10

    public init(psn: String, port: Int, expiresAt: Date) {
        self.psn = psn
        self.port = port
        self.expiresAt = expiresAt
    }

    public func matches(psn: String, port: Int, now: Date = Date()) -> Bool {
        ChargerID(storedKey: self.psn).matches(storedKey: psn) && self.port == port && now < expiresAt
    }
}

/// 小组件上临时显示的一行提示（例如菜单栏 app 没在运行）。
public struct WidgetNotice: Codable, Sendable, Equatable {
    /// 只在这台设备的小组件上显示；nil 表示都显示。
    public var psn: String?
    public var text: String
    public var isError: Bool
    /// 比这更新的快照（app 执行完命令后写的）里的提示优先。
    public var postedAt: Date
    public var expiresAt: Date

    public init(psn: String?, text: String, isError: Bool, postedAt: Date = Date(), expiresAt: Date) {
        self.psn = psn
        self.text = text
        self.isError = isError
        self.postedAt = postedAt
        self.expiresAt = expiresAt
    }

    public func applies(to psn: String, now: Date = Date()) -> Bool {
        guard now < expiresAt else { return false }
        guard let stored = self.psn else { return true }
        return ChargerID(storedKey: stored).matches(storedKey: psn)
    }
}

// MARK: - 文件

/// 共享目录里的文件。写入都是先写临时文件再改名，读的一方不会读到半份。
public struct SharedStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// App Group 容器；没有 App Group 权限时为 nil。
    public static var appGroup: SharedStore? {
        AppGroup.containerURL.map { SharedStore(directory: $0) }
    }

    private var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }
    /// app 监视这个目录：Darwin 通知万一没送到，新命令文件也能叫醒它。
    public var commandsURL: URL { directory.appendingPathComponent("commands", isDirectory: true) }
    private var repliesURL: URL { directory.appendingPathComponent("replies", isDirectory: true) }
    private var pendingURL: URL { directory.appendingPathComponent("pending.json") }
    private var noticeURL: URL { directory.appendingPathComponent("notice.json") }
    private var directURL: URL { directory.appendingPathComponent("lan", isDirectory: true) }

    public func writeSnapshot(_ snapshot: WidgetSnapshot) throws {
        try write(snapshot, to: snapshotURL)
    }

    public func readSnapshot() -> WidgetSnapshot? {
        read(WidgetSnapshot.self, at: snapshotURL)
    }

    /// 小组件：app 没在运行时自己读到的局域网数据，每台设备一个文件（几个小组件各读各的设备，互不覆盖）。
    /// 小电拼的文件名仍是裸 PSN。`candysign:<PSN>` 写成、读成同一个文件。
    public func writeDirectReading(_ device: WidgetSnapshot.Device) throws {
        guard let url = directFile(ChargerID(storedKey: device.psn)) else { return }
        try write(device, to: url)
    }

    public func readDirectReading(_ psn: String) -> WidgetSnapshot.Device? {
        directFile(ChargerID(storedKey: psn)).flatMap { read(WidgetSnapshot.Device.self, at: $0) }
    }

    /// 文件名只用数字和字母。小电拼是裸 PSN；带冒号的前缀不进路径。
    private func directFile(_ id: ChargerID) -> URL? {
        guard let token = id.directReadingToken else { return nil }
        return directURL.appendingPathComponent("\(token).json")
    }

    /// 小组件：写一条命令（之后发通知叫醒 app）。
    public func send(_ command: WidgetCommand) throws {
        try write(command, to: commandsURL.appendingPathComponent("\(command.id.uuidString).json"))
    }

    /// app：取走所有命令，按发出时间排序。读完就删；删不掉说明小组件已经撤回，跳过。
    public func takeCommands() -> [WidgetCommand] {
        let files = (try? FileManager.default.contentsOfDirectory(at: commandsURL, includingPropertiesForKeys: nil)) ?? []
        var commands: [WidgetCommand] = []
        for file in files where file.pathExtension == "json" {
            let data = try? Data(contentsOf: file)
            guard (try? FileManager.default.removeItem(at: file)) != nil,
                  let data, let command = try? Self.decoder.decode(WidgetCommand.self, from: data) else { continue }
            commands.append(command)
        }
        return commands.sorted { $0.issuedAt < $1.issuedAt }
    }

    /// 小组件：等不到回复时撤回命令。返回 true 表示 app 还没取走，之后也不会再执行。
    public func withdraw(_ id: UUID) -> Bool {
        (try? FileManager.default.removeItem(at: commandsURL.appendingPathComponent("\(id.uuidString).json"))) != nil
    }

    /// app：回复一条命令，顺手删掉一分钟前没人取的回复。
    public func reply(_ reply: WidgetReply) throws {
        pruneReplies(before: reply.repliedAt.addingTimeInterval(-60))
        try write(reply, to: repliesURL.appendingPathComponent("\(reply.id.uuidString).json"))
    }

    /// 小组件：取走这条命令的回复。
    public func takeReply(_ id: UUID) -> WidgetReply? {
        let file = repliesURL.appendingPathComponent("\(id.uuidString).json")
        guard let reply = read(WidgetReply.self, at: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return reply
    }

    func pruneReplies(before date: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: repliesURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where read(WidgetReply.self, at: file).map({ $0.repliedAt < date }) ?? true {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func readPending() -> PendingConfirmation? {
        read(PendingConfirmation.self, at: pendingURL)
    }

    /// nil 表示清掉。
    public func writePending(_ pending: PendingConfirmation?) {
        if let pending { try? write(pending, to: pendingURL) } else { try? FileManager.default.removeItem(at: pendingURL) }
    }

    public func readNotice() -> WidgetNotice? {
        read(WidgetNotice.self, at: noticeURL)
    }

    public func writeNotice(_ notice: WidgetNotice?) {
        if let notice { try? write(notice, to: noticeURL) } else { try? FileManager.default.removeItem(at: noticeURL) }
    }

    private static let decoder = JSONDecoder()

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func read<Value: Decodable>(_ type: Value.Type, at url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }
}

// MARK: - Darwin 通知

/// 跨进程只传「有新命令了」，内容在共享文件里。
public enum DarwinNotification {
    @discardableResult
    public static func post(_ name: String) -> Bool {
        notify_post(name) == NOTIFY_STATUS_OK
    }
}

/// 收 Darwin 通知，释放时注销。
public final class DarwinNotificationObserver: Sendable {
    private let token: Int32

    public init?(name: String, queue: DispatchQueue = .main, handler: @escaping @Sendable () -> Void) {
        var token: Int32 = 0
        guard notify_register_dispatch(name, &token, queue, { _ in handler() }) == NOTIFY_STATUS_OK else { return nil }
        self.token = token
    }

    deinit {
        notify_cancel(token)
    }
}
