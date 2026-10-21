import Foundation

/// Mac 连不上设备的局域网时改用的云端读数：官方 MCP 的 `get_port_details`（只读，走云端，不在同一个网络也能读）。
///
/// 2026-10-16 在两台 CP02 Pro（固件 2.2.0）上和局域网读数对照过：每个口有 connected、vout_mv、iout_ma、vin_mv、
/// fc_protocol（英文名）、die_temperature、session_id、session_charge_mwh，电压电流和局域网读数一致；
/// 没有开关状态、充电时长和分配功率。`get_charging_status` 的位掩码表示接着设备（不取电也置位），也不是开关状态。
/// 所以只有接着设备、并且有输出电压的口能确定开着，其余的口开关状态未知（`PortMetrics.isPoweredOn` 为 nil）。
public enum CloudReading {
    /// 每 15 秒读一次：充电曲线两点隔 30 秒以上就断开，这样曲线还能连着画。
    public static let interval = CandySignDriver.cloudInterval
    /// 最近一次云端读数在这段时间内算在线。
    public static let freshness = CandySignDriver.cloudFreshness

    /// 连续失败时拉长间隔：15、30、60 秒，设备断电或云端出问题时不一直问。
    public static func interval(afterFailures failures: Int) -> TimeInterval {
        CandySignDriver.cloudInterval(afterFailures: failures)
    }

    /// `get_port_details` 的结果换成和局域网一样的读数；一个口都没有时返回 nil。
    /// 解码在 `CandySignDriver`，这里留着是原来的调用点。
    public static func metrics(from details: JSONValue?) -> DeviceMetrics? {
        CandySignDriver.metrics(fromCloud: details)
    }
}

public extension MCPClient {
    /// 云端读数，和同一次结果里各口的芯片温度、本次电量（`get_port_details`，只读）。
    func cloudReading() async throws -> (metrics: DeviceMetrics, details: [Int: PortDetail]) {
        let value = try await callToolJSON("get_port_details")
        guard let metrics = CloudReading.metrics(from: value) else {
            throw MCPError.badResponse("get_port_details 里没有端口")
        }
        return (metrics, PortDetail.parse(value))
    }
}
