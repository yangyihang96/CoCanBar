import Foundation

/// 驱动怎么连上充电器。
public enum ChargerTransport: String, Sendable, Equatable {
    /// 无状态 HTTP（局域网 `metrics.json` 这一类）。桌面小组件可以在 app 没开时自己读。
    case http
    /// 短连接：`openSession` 连上，读完或发完命令就 `close`，不占着手机 app 的连接。
    /// 小组件不能自己连。这一版没有蓝牙驱动，只把接口留好。
    case bleSession
}

/// 一台设备做得到的调节。界面按这个决定显示哪些卡片；小电拼全部都有，所以现在看到的和以前一样。
public struct ChargerCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// 端口开关。
    public static let portPower = ChargerCapabilities(rawValue: 1 << 0)
    /// 充电策略（自由流、睡眠充、魔拟充、性能模式、极速单充）。
    public static let chargingStrategy = ChargerCapabilities(rawValue: 1 << 1)
    /// 温控。
    public static let temperatureMode = ChargerCapabilities(rawValue: 1 << 2)
    /// 屏幕亮度，以及设备自己报告支持时的屏显模式、待机显示、整点报时。
    public static let displaySettings = ChargerCapabilities(rawValue: 1 << 3)
    /// 临时端口功率分配。
    public static let powerAllocation = ChargerCapabilities(rawValue: 1 << 4)
    /// 识别口上接的设备（型号、电量、线材）。
    public static let portIdentity = ChargerCapabilities(rawValue: 1 << 5)
    /// 局域网不通时还能读云端。
    public static let cloudReading = ChargerCapabilities(rawValue: 1 << 6)

    public static let candySign: ChargerCapabilities = [
        .portPower, .chargingStrategy, .temperatureMode, .displaySettings,
        .powerAllocation, .portIdentity, .cloudReading,
    ]

    public func supports(_ command: ChargerCommand) -> Bool {
        switch command {
        case .setPort: return contains(.portPower)
        case .setStrategy: return contains(.chargingStrategy)
        case .setTemperature: return contains(.temperatureMode)
        case .setDisplay, .setStatusDisplayMode, .setIdleDisplay, .setHourlyChime:
            return contains(.displaySettings)
        case .setPowerAllocation: return contains(.powerAllocation)
        }
    }
}

/// 发给驱动的控制命令。端口号是 `PortMetrics.id`，从 0 开始。
public enum ChargerCommand: Sendable, Equatable {
    case setPort(index: Int, on: Bool)
    case setStrategy(ChargingStrategy)
    case setTemperature(TemperatureMode)
    case setDisplay(DisplayLevel)
    case setPowerAllocation([Int])
    case setStatusDisplayMode(StatusDisplayMode)
    case setIdleDisplay(IdleDisplay)
    case setHourlyChime(Bool)
}

public enum ChargerDriverError: Error, LocalizedError, Sendable, Equatable {
    case unsupported
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "这台设备不支持这项操作"
        case .unavailable: return "没有这台设备的驱动"
        }
    }
}

/// 一次短会话。HTTP 驱动不占设备；蓝牙驱动在 `close()` 里断开，把连接还给手机 app。
public protocol ChargerSession: Sendable {
    func readMetrics() async throws -> DeviceMetrics
    func perform(_ command: ChargerCommand) async throws -> String
    func close() async
}

/// 一种充电器品牌的读数和控制。具体怎么连（MCP、局域网、以后的蓝牙）由实现自己保存。
public protocol ChargerDriver: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var transport: ChargerTransport { get }
    var capabilities: ChargerCapabilities { get }
    /// 小组件自己读局域网只留给 HTTP 驱动。蓝牙不能在小组件里占着连接。
    var allowsDirectWidgetRead: Bool { get }

    /// 打开一次短会话。HTTP 驱动这里不建立长期连接；蓝牙驱动在这里连上，用完调用 `close()`。
    func openSession(for id: ChargerID) async throws -> any ChargerSession
}

public extension ChargerDriver {
    var allowsDirectWidgetRead: Bool { transport == .http }
}

public enum ChargerDrivers {
    public static func driver(for id: ChargerID) -> (any ChargerDriver)? {
        switch id.driver {
        case ChargerID.candySign: return CandySignDriver.shared
        default: return nil
        }
    }

    public static func driver(forStoredKey key: String) -> (any ChargerDriver)? {
        driver(for: ChargerID(storedKey: key))
    }
}
