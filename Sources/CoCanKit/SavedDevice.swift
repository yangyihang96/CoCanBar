import Foundation

/// 存进 UserDefaults 的一台设备，不含任何密钥。
///
/// 旧文件只有 `psn` / `name` / `hostOverride` / `lastStrategy`。没有 `driver` 就是小电拼。
/// 小电拼重新存盘时仍写成这个形状，不把 PSN 改成 `candysign:…`。
public struct SavedDevice: Codable, Identifiable, Hashable, Sendable {
    public let chargerID: ChargerID
    public var name: String
    public var hostOverride: String?
    /// 上次由本 app 设置的充电策略（`ChargingStrategy.rawValue`）。MCP 读不到设备当前的策略。
    public var lastStrategy: Int?

    /// 小组件、运行时字典和旧接口用的键。小电拼等于裸 PSN。
    public var id: String { chargerID.legacyStorageKey }
    /// 驱动自己的编号。小电拼是 PSN，这时和 `id` 相同。
    public var psn: String { chargerID.localID }

    public init(psn: String, name: String, hostOverride: String? = nil, lastStrategy: Int? = nil, driver: String? = nil) {
        if let driver, !driver.isEmpty {
            let parsed = ChargerID(storedKey: psn)
            chargerID = ChargerID(driver: driver, localID: parsed.localID)
        } else {
            chargerID = ChargerID(storedKey: psn)
        }
        self.name = name
        self.hostOverride = hostOverride
        self.lastStrategy = lastStrategy
    }

    private enum CodingKeys: String, CodingKey {
        case id, driver, psn, name, hostOverride, lastStrategy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        hostOverride = try container.decodeIfPresent(String.self, forKey: .hostOverride)
        lastStrategy = try container.decodeIfPresent(Int.self, forKey: .lastStrategy)
        if let rawID = try container.decodeIfPresent(String.self, forKey: .id), !rawID.isEmpty {
            chargerID = ChargerID(storedKey: rawID)
        } else if let psn = try container.decodeIfPresent(String.self, forKey: .psn) {
            let parsed = ChargerID(storedKey: psn)
            if let driver = try container.decodeIfPresent(String.self, forKey: .driver), !driver.isEmpty {
                chargerID = ChargerID(driver: driver, localID: parsed.localID)
            } else {
                chargerID = parsed
            }
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .psn, in: container, debugDescription: "设备配置缺少 psn 或 id")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if chargerID.driver == ChargerID.candySign {
            try container.encode(chargerID.localID, forKey: .psn)
        } else {
            try container.encode(chargerID.namespaced, forKey: .id)
            try container.encode(chargerID.driver, forKey: .driver)
            try container.encode(chargerID.localID, forKey: .psn)
        }
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(hostOverride, forKey: .hostOverride)
        try container.encodeIfPresent(lastStrategy, forKey: .lastStrategy)
    }
}

public extension SavedDevice {
    /// 这台设备的驱动能做的事。还没有对应驱动时是空的，界面上就不显示那些卡片。
    var capabilities: ChargerCapabilities {
        ChargerDrivers.driver(for: chargerID)?.capabilities ?? []
    }
}
