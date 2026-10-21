import Foundation

/// 制糖工厂小电拼（CP02）驱动：局域网 `metrics.json`、官方 MCP，局域网不通时用云端读数。
///
/// 读数编成品牌无关的 `DeviceMetrics`。`metrics.json` 和云端 `get_port_details` 的解码只在这里。
/// 轮询、退避和 IP 缓存仍在 `AppModel`：这一版只把「怎么读、能调什么、命令怎么发」收进驱动。
public struct CandySignDriver: ChargerDriver {
    public static let shared = CandySignDriver()

    public let identifier = ChargerID.candySign
    public let displayName = "CANDYSIGN"
    public let transport = ChargerTransport.http
    public let capabilities = ChargerCapabilities.candySign

    /// 云端读数间隔。充电曲线两点隔 30 秒以上就断开，所以正常要比这密。
    public static let cloudInterval: TimeInterval = 15
    /// 最近一次云端读数在这段时间内算在线。
    public static let cloudFreshness: TimeInterval = 45

    public init() {}

    public func openSession(for id: ChargerID) async throws -> any ChargerSession {
        openSession(for: id, mcp: nil, lanIP: nil)
    }

    /// 带上已经握过手的 MCP 客户端。命令走它；`lanIP` 有的话 `readMetrics()` 读局域网。
    /// HTTP 没有要占的连接，这里不建连，`close()` 也是空的。
    public func openSession(for id: ChargerID, mcp: MCPClient?, lanIP: String?) -> any ChargerSession {
        CandySignSession(id: id, mcp: mcp, lanIP: lanIP)
    }

    public static func cloudInterval(afterFailures failures: Int) -> TimeInterval {
        cloudInterval * Double(1 << min(max(failures, 0), 2))
    }

    /// 解码 `GET /metrics.json`。字段缺失用默认值，固件加减字段不至于整份失败。
    public static func decodeMetrics(_ data: Data) throws -> DeviceMetrics {
        let file = try JSONDecoder().decode(MetricsFile.self, from: data)
        return DeviceMetrics(ports: file.ports.map(\.metrics), system: file.system?.metrics)
    }

    /// `get_port_details` 换成和局域网一样的读数。一个口都没有时返回 nil。
    ///
    /// 2026-10-16 在两台 CP02 Pro（固件 2.2.0）上对照过：有 connected、vout_mv、iout_ma、vin_mv、
    /// fc_protocol（英文名）、die_temperature、session_id、session_charge_mwh；没有开关状态、充电时长和分配功率。
    /// 只有接着设备并且输出电压够高的口能确定开着，其余口的开关状态未知。
    public static func metrics(fromCloud details: JSONValue?) -> DeviceMetrics? {
        var ports: [PortMetrics] = []
        for entry in details?["ports"]?.arrayValue ?? [] {
            guard let number = entry["port"]?.looseInt, number >= 1,
                  !ports.contains(where: { $0.id == number - 1 }) else { continue }
            let attached = entry["connected"]?.boolValue ?? false
            let millivolts = max(entry["vout_mv"]?.looseInt ?? 0, 0)
            let powered = attached && millivolts >= poweredMillivolts
            let text = entry["fc_protocol"]?.trimmedText
            let code = text.flatMap { FastChargeProtocol.code(cloudName: $0) }
            ports.append(PortMetrics(
                id: number - 1, active: powered, state: "", portType: "", attached: attached,
                chargingDurationSeconds: 0,
                fcProtocol: code ?? (text == nil ? 255 : FastChargeProtocol.unrecognized),
                currentMilliamps: max(entry["iout_ma"]?.looseInt ?? 0, 0), voltageMillivolts: millivolts,
                inputMillivolts: max(entry["vin_mv"]?.looseInt ?? 0, 0), powerBudgetWatts: 0,
                sessionID: entry["session_id"]?.looseInt, sessionCharge: nil,
                powerKnown: powered, protocolText: code == nil ? text : nil))
        }
        guard !ports.isEmpty else { return nil }
        return DeviceMetrics(ports: ports.sorted { $0.id < $1.id }, system: nil)
    }

    /// 输出电压到这么高才算确实在供电（USB PD 的 PPS 最低档是 3.3 V）。
    static let poweredMillivolts = 3_000
}

/// 小电拼的一次短会话：命令走 MCP，读数走局域网 IP。没有蓝牙那种要断开的连接。
public struct CandySignSession: ChargerSession {
    public let id: ChargerID
    private let mcp: MCPClient?
    private let lanIP: String?

    init(id: ChargerID, mcp: MCPClient?, lanIP: String?) {
        self.id = id
        self.mcp = mcp
        self.lanIP = lanIP
    }

    public func readMetrics() async throws -> DeviceMetrics {
        guard let lanIP else { throw LANError.unresolved(id.localID) }
        return try await LANClient().metrics(ip: lanIP)
    }

    public func perform(_ command: ChargerCommand) async throws -> String {
        guard CandySignDriver.shared.capabilities.supports(command) else { throw ChargerDriverError.unsupported }
        guard let mcp else { throw ChargerDriverError.unavailable }
        switch command {
        case .setPort(let index, let on):
            return try await mcp.setPorts([index + 1], on: on)
        case .setStrategy(let strategy):
            return try await mcp.setStrategy(strategy)
        case .setTemperature(let mode):
            return try await mcp.setTemperatureMode(mode)
        case .setDisplay(let level):
            return try await mcp.setDisplayLevel(level)
        case .setPowerAllocation(let watts):
            return try await mcp.setPowerAllocation(watts)
        case .setStatusDisplayMode(let mode):
            return try await mcp.setStatusDisplayMode(mode)
        case .setIdleDisplay(let display):
            return try await mcp.setIdleDisplay(display)
        case .setHourlyChime(let enabled):
            return try await mcp.setHourlyChime(enabled)
        }
    }

    public func close() async {}
}

private struct MetricsFile: Decodable {
    var ports: [PortFile]
    var system: SystemFile?
}

private struct SystemFile: Decodable {
    var appVersion: String?
    var bootTimeSeconds: Int?
    var resetReason: Int?
    var freeHeap: Int?

    var metrics: SystemMetrics {
        SystemMetrics(appVersion: appVersion, bootTimeSeconds: bootTimeSeconds,
                      resetReason: resetReason, freeHeap: freeHeap)
    }

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case bootTimeSeconds = "boot_time_seconds"
        case resetReason = "reset_reason"
        case freeHeap = "free_heap"
    }
}

private struct PortFile: Decodable {
    var id: Int
    var active: Bool
    var state: String
    var portType: String
    var attached: Bool
    var chargingDurationSeconds: Int
    var fcProtocol: Int
    var currentMilliamps: Int
    var voltageMillivolts: Int
    var inputMillivolts: Int
    var powerBudgetWatts: Int
    var sessionID: Int?
    var sessionCharge: Int?

    var metrics: PortMetrics {
        PortMetrics(id: id, active: active, state: state, portType: portType, attached: attached,
                    chargingDurationSeconds: chargingDurationSeconds, fcProtocol: fcProtocol,
                    currentMilliamps: currentMilliamps, voltageMillivolts: voltageMillivolts,
                    inputMillivolts: inputMillivolts, powerBudgetWatts: powerBudgetWatts,
                    sessionID: sessionID, sessionCharge: sessionCharge, powerKnown: true, protocolText: nil)
    }

    enum CodingKeys: String, CodingKey {
        case id, active, state, attached, current, voltage
        case portType = "port_type"
        case chargingDurationSeconds = "charging_duration_seconds"
        case fcProtocol = "fc_protocol"
        case vinValue = "vin_value"
        case powerBudget = "power_budget"
        case sessionID = "session_id"
        case sessionCharge = "session_charge"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        portType = try container.decodeIfPresent(String.self, forKey: .portType) ?? ""
        attached = try container.decodeIfPresent(Bool.self, forKey: .attached) ?? false
        chargingDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .chargingDurationSeconds) ?? 0
        fcProtocol = try container.decodeIfPresent(Int.self, forKey: .fcProtocol) ?? 255
        currentMilliamps = try container.decodeIfPresent(Int.self, forKey: .current) ?? 0
        voltageMillivolts = try container.decodeIfPresent(Int.self, forKey: .voltage) ?? 0
        inputMillivolts = try container.decodeIfPresent(Int.self, forKey: .vinValue) ?? 0
        powerBudgetWatts = try container.decodeIfPresent(Int.self, forKey: .powerBudget) ?? 0
        sessionID = try container.decodeIfPresent(Int.self, forKey: .sessionID)
        sessionCharge = try container.decodeIfPresent(Int.self, forKey: .sessionCharge)
    }
}
