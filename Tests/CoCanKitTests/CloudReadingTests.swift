import XCTest
@testable import CoCanKit

final class CloudReadingTests: XCTestCase {
    /// 结构和数值照 2026-10-16 一台 CP02 Pro（固件 2.2.0）的 `get_port_details`：C1 接着、5V 有输出但几乎不取电，C4 走 USB 普通充电。
    private let sample = """
    {"ports":[
     {"connected":false,"die_temperature":"moderate","fc_protocol":"Not Charging","iout_ma":0,"manufacturer_pid":0,
      "manufacturer_vid":0,"port":1,"session_charge_mwh":0,"session_id":0,"vin_mv":30270,"vout_mv":0},
     {"connected":true,"die_temperature":"moderate","fc_protocol":"PD Fixed 5V","iout_ma":3,"manufacturer_pid":0,
      "manufacturer_vid":0,"port":2,"session_charge_mwh":78,"session_id":10,"vin_mv":30250,"vout_mv":5216},
     {"connected":false,"die_temperature":"moderate","fc_protocol":"Not Charging","iout_ma":0,"manufacturer_pid":0,
      "manufacturer_vid":0,"port":3,"session_charge_mwh":0,"session_id":0,"vin_mv":30250,"vout_mv":0},
     {"connected":false,"die_temperature":"moderate","fc_protocol":"Not Charging","iout_ma":0,"manufacturer_pid":0,
      "manufacturer_vid":0,"port":4,"session_charge_mwh":0,"session_id":0,"vin_mv":30210,"vout_mv":0},
     {"connected":true,"die_temperature":"moderate","fc_protocol":"USB Legacy Charging","iout_ma":18,"manufacturer_pid":0,
      "manufacturer_vid":0,"port":5,"session_charge_mwh":2286,"session_id":10,"vin_mv":30190,"vout_mv":5008}
    ]}
    """

    private func ports(_ entries: String) -> [PortMetrics]? {
        CloudReading.metrics(from: JSONValue.parse("{\"ports\":[\(entries)]}"))?.ports
    }

    func testPortDetailsBecomeLANLikeReadings() throws {
        let value = JSONValue.parse(sample)
        let metrics = try XCTUnwrap(CloudReading.metrics(from: value))
        XCTAssertEqual(metrics.ports.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertNil(metrics.system)
        XCTAssertEqual(metrics.chargingCount, 2)

        let empty = metrics.ports[0]
        XCTAssertFalse(empty.attached)
        XCTAssertNil(empty.isPoweredOn, "没在供电的口分不出开着空着还是关着")
        XCTAssertFalse(empty.isInUse)
        XCTAssertEqual(empty.fcProtocol, 255)
        XCTAssertEqual(empty.protocolName, "未充电")
        XCTAssertEqual(empty.inputMillivolts, 30_270)

        let c1 = metrics.ports[1]
        XCTAssertTrue(c1.attached)
        XCTAssertEqual(c1.isPoweredOn, true)
        XCTAssertTrue(c1.isInUse)
        XCTAssertEqual(c1.voltageMillivolts, 5_216)
        XCTAssertEqual(c1.currentMilliamps, 3)
        XCTAssertEqual(c1.fcProtocol, 15)
        XCTAssertNil(c1.protocolText)
        XCTAssertEqual(c1.protocolName, "PD 5V")
        XCTAssertTrue(c1.usesPD)
        XCTAssertEqual(c1.sessionID, 10)
        XCTAssertNil(c1.sessionCharge, "云端的 mWh 不是局域网的电量计数，不能混用")
        XCTAssertEqual(c1.chargingDurationSeconds, 0)
        XCTAssertEqual(c1.powerBudgetWatts, 0)

        let c4 = metrics.ports[4]
        XCTAssertEqual(c4.fcProtocol, 0)
        XCTAssertEqual(c4.protocolName, "USB 普通")
        XCTAssertFalse(c4.usesPD)
        XCTAssertEqual(c4.watts, 18 * 5.008 / 1000, accuracy: 0.0001)

        // 同一次结果里的芯片温度和本次电量：局域网计数为空时就是服务端给的 mWh
        let details = PortDetail.parse(value)
        let detail = try XCTUnwrap(details[4])
        XCTAssertEqual(detail.temperature, .moderate)
        XCTAssertEqual(SessionEnergy.estimate(detail, port: c4, unitsPerMWh: nil), 2_286)
    }

    func testAttachedWithoutOutputIsUnknown() throws {
        let port = try XCTUnwrap(ports("""
        {"port":3,"connected":true,"fc_protocol":"Not Charging","vout_mv":0,"iout_ma":0}
        """)?.first)
        XCTAssertEqual(port.id, 2)
        XCTAssertTrue(port.attached)
        XCTAssertNil(port.isPoweredOn, "接着设备但没有输出：可能是关着，也可能是设备没取电")
        XCTAssertFalse(port.isInUse)
        XCTAssertFalse(port.isCharging)
    }

    func testUnrecognizedProtocolKeepsText() throws {
        let result = try XCTUnwrap(ports("""
        {"port":2,"connected":true,"fc_protocol":"  Apple 2.4A ","vout_mv":5100,"iout_ma":900},
        {"port":3,"connected":true,"fc_protocol":"PD Fixed 20V","vout_mv":20000,"iout_ma":2000},
        {"port":4,"connected":true,"fc_protocol":"PD Custom","vout_mv":12000,"iout_ma":1000},
        {"port":5,"connected":true,"vout_mv":5000,"iout_ma":100}
        """))
        XCTAssertEqual(result[0].fcProtocol, FastChargeProtocol.unrecognized)
        XCTAssertEqual(result[0].protocolText, "Apple 2.4A")
        XCTAssertEqual(result[0].protocolName, "Apple 2.4A")
        XCTAssertFalse(result[0].usesPD)
        XCTAssertEqual(result[1].fcProtocol, 16)
        XCTAssertNil(result[1].protocolText)
        XCTAssertEqual(result[1].protocolName, "PD 固定高压")
        XCTAssertTrue(result[2].usesPD, "认不出的 PD 档位按原文判断")
        XCTAssertEqual(result[2].protocolName, "PD Custom")
        XCTAssertEqual(result[3].fcProtocol, 255, "没给协议时当作未充电")
        XCTAssertNil(result[3].protocolText)
    }

    func testBadEntriesAreSkipped() {
        XCTAssertNil(CloudReading.metrics(from: nil))
        XCTAssertNil(CloudReading.metrics(from: JSONValue.parse("{\"ports\":[]}")))
        XCTAssertNil(ports("{\"connected\":true}"), "没有端口号的不要")
        XCTAssertNil(ports("{\"port\":0,\"connected\":true}"), "端口号从 1 开始")
        let result = ports("""
        {"port":"2","connected":true,"vout_mv":"9000","iout_ma":-5},
        {"port":2,"connected":false},
        {"port":1,"connected":false}
        """)
        XCTAssertEqual(result?.map(\.id), [0, 1], "重复的口只取第一个，结果按口排序")
        XCTAssertEqual(result?[1].voltageMillivolts, 9_000)
        XCTAssertEqual(result?[1].currentMilliamps, 0, "负的电流按 0 算")
    }

    func testCloudProtocolNames() {
        XCTAssertEqual(FastChargeProtocol.code(cloudName: "Not Charging"), 255)
        XCTAssertEqual(FastChargeProtocol.code(cloudName: "USB Legacy Charging"), 0)
        XCTAssertEqual(FastChargeProtocol.code(cloudName: "PD Fixed 5V"), 15)
        XCTAssertEqual(FastChargeProtocol.code(cloudName: "pd fixed 9v"), 16)
        XCTAssertEqual(FastChargeProtocol.code(cloudName: "PD PPS"), 18)
        XCTAssertEqual(FastChargeProtocol.code(cloudName: "QC 3.0"), 2)
        XCTAssertEqual(FastChargeProtocol.code(cloudName: "QC3+"), 3)
        XCTAssertEqual(FastChargeProtocol.code(cloudName: "SuperVOOC 2.0"), 10)
        XCTAssertNil(FastChargeProtocol.code(cloudName: "Apple 2.4A"))
        XCTAssertEqual(FastChargeProtocol.name(FastChargeProtocol.unrecognized), "其他协议")
    }

    func testRetryIntervalBacksOff() {
        XCTAssertEqual(CloudReading.interval(afterFailures: 0), 15)
        XCTAssertEqual(CloudReading.interval(afterFailures: 1), 30)
        XCTAssertEqual(CloudReading.interval(afterFailures: 2), 60)
        XCTAssertEqual(CloudReading.interval(afterFailures: 9), 60)
        XCTAssertEqual(CloudReading.interval(afterFailures: -1), 15)
        // 曲线两点隔 30 秒以上会断开，正常读数要比这密
        XCTAssertLessThan(CloudReading.interval, 30)
    }

    func testLANReadingsAlwaysKnowPowerState() throws {
        let json = #"{"ports":[{"id":0,"active":true,"state":"INACTIVE","attached":false},{"id":1,"state":"ATTACHED","attached":true}]}"#
        let metrics = try CandySignDriver.decodeMetrics(Data(json.utf8))
        XCTAssertEqual(metrics.ports[0].isPoweredOn, false)
        XCTAssertEqual(metrics.ports[1].isPoweredOn, true)
        XCTAssertNil(metrics.ports[1].protocolText)
    }
}
