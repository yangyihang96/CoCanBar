import XCTest
@testable import CoCanKit

final class CoCanKitTests: XCTestCase {
    // 结构取自 2026-10-15 实测的 /metrics.json（Wi‑Fi 字段已换成假值）
    func testDecodeMetrics() throws {
        let json = """
        {"ports":[
          {"id":0,"active":true,"state":"ACTIVE","port_type":"A","attached":false,"charging_duration_seconds":0,
           "fc_protocol":255,"current":0,"voltage":0,"vin_value":30010,"session_id":0,"session_charge":0,"power_budget":0,"pd_status":null},
          {"id":4,"active":true,"state":"ATTACHED","port_type":"A","attached":true,"charging_duration_seconds":1784,
           "fc_protocol":0,"current":1311,"voltage":5088,"vin_value":29820,"session_id":9,"session_charge":508213073,"power_budget":60,"pd_status":null}],
         "system":{"chip":"esp32c3","app_version":"2.2.0","boot_time_seconds":293,"reset_reason":3,"free_heap":43044},
         "tasks":[{"name":"httpd","stack_watermark_bytes":3076,"cpu_percent":0.0006}],
         "wifi":{"ssid":"test","bssid":"00:00:00:00:00:00","channel":6,"rssi":-42}}
        """
        let metrics = try CandySignDriver.decodeMetrics(Data(json.utf8))
        XCTAssertEqual(metrics.ports.count, 2)
        XCTAssertEqual(metrics.ports[1].watts, 6.670368, accuracy: 0.000001)
        XCTAssertEqual(metrics.totalWatts, 6.670368, accuracy: 0.000001)
        XCTAssertTrue(metrics.ports[1].isCharging)
        XCTAssertFalse(metrics.ports[0].isCharging)
        XCTAssertEqual(metrics.ports[0].isPoweredOn, true)
        XCTAssertEqual(metrics.system?.appVersion, "2.2.0")
        // id 4 报 port_type "A"，但它是 C4
        XCTAssertEqual(PortNaming.name(index: metrics.ports[1].id), "C4")
        XCTAssertEqual(metrics.ports[1].sessionID, 9)
        XCTAssertEqual(metrics.ports[1].sessionCharge, 508_213_073)
        XCTAssertEqual(metrics.ports[0].sessionCharge, 0)
    }

    // 结构取自 2026-10-15 对 CP02 Pro 实测的 get_port_pd_status / get_port_details（只留用到的字段）：
    // C1 接的设备走 PD 5V 但没报厂商号，C4 走 USB 普通充电。
    func testIdentityFromLiveShapes() throws {
        let pd = try XCTUnwrap(JSONValue.parse("""
        {"ports":[
          {"port":2,"battery_design_capacity":0,"battery_last_full_charge_capacity":0,"battery_present":false,
           "battery_present_capacity":0,"battery_vid":0,"cable_max_vbus_current":"3A","cable_max_vbus_voltage":"20V",
           "cable_usb_highest_speed":"USB 2.0","has_emarker":false,"manufacturer_pid":0,"manufacturer_vid":0,
           "operating_current":300,"operating_voltage":500,"pd_revision":"PD 3.0","pps_charging_supported":false,
           "request_epr_mode_capable":false,"sink_maximum_pdp":0},
          {"port":5,"has_emarker":false,"manufacturer_vid":0,"operating_current":0,"operating_voltage":0,"pd_revision":"PD 1.0"}]}
        """))
        let details = try XCTUnwrap(JSONValue.parse("""
        {"ports":[
          {"port":1,"connected":false,"fc_protocol":"Not Charging","manufacturer_vid":0,"session_id":0},
          {"port":2,"connected":true,"fc_protocol":"PD Fixed 5V","manufacturer_vid":0,"session_id":13},
          {"port":5,"connected":true,"fc_protocol":"USB Legacy Charging","manufacturer_vid":0,"session_id":9}]}
        """))
        let identities = PortIdentity.parse(pdStatus: pd, details: details)
        XCTAssertEqual(Set(identities.keys), [1, 4], "没接设备的 A 口不该有结果")

        let c1 = try XCTUnwrap(identities[1])
        XCTAssertTrue(c1.usesPD)
        XCTAssertEqual(c1.sessionID, 13)
        XCTAssertNil(c1.vendorID)
        XCTAssertNil(c1.displayName)
        XCTAssertNil(c1.battery)
        XCTAssertNil(c1.cable, "没有 E-Marker")
        XCTAssertEqual(c1.pdSummary, "PD 3.0 · 请求 5V 3A")

        let c4 = try XCTUnwrap(identities[4])
        XCTAssertFalse(c4.usesPD)
        XCTAssertNil(c4.pdSummary, "USB 普通充电时 PD 字段没有意义")
        XCTAssertEqual(c4.sessionID, 9)
    }

    func testRecognizedDeviceWithBatteryAndCable() throws {
        let pd = try XCTUnwrap(JSONValue.parse("""
        {"ports":[{"port":2,"manufacturer_vid":1452,"manufacturer_pid":4660,"operating_voltage":2000,"operating_current":325,
          "pd_revision":"PD 3.0","sink_maximum_pdp":70,"pps_charging_supported":true,
          "has_battery":true,"battery_present":true,"battery_design_capacity":520,
          "battery_last_full_charge_capacity":470,"battery_present_capacity":300,
          "has_emarker":true,"cable_max_vbus_current":"5A","cable_max_vbus_voltage":"20V",
          "cable_usb_highest_speed":"USB 3.2 Gen1","cable_is_active":false,"cable_epr_mode_capable":false}]}
        """))
        let details = try XCTUnwrap(JSONValue.parse("""
        {"ports":[{"port":2,"connected":true,"fc_protocol":"PD Fixed High Voltage","session_id":3,
          "device_brand_zh":"苹果","device_brand_en":"Apple","device_name_zh":"MacBook Air"}]}
        """))
        let c1 = try XCTUnwrap(PortIdentity.parse(pdStatus: pd, details: details)[1])
        XCTAssertEqual(c1.displayName, "苹果 MacBook Air")
        XCTAssertEqual(c1.idText, "厂商号 0x05AC · 产品号 0x1234")
        XCTAssertEqual(c1.pdSummary, "PD 3.0 · 请求 20V 3.25A · 设备最高 70W · 支持 PPS")
        XCTAssertEqual(c1.battery, BatteryInfo(percent: 64, health: 90, designWh: 52))
        XCTAssertEqual(c1.cable?.summary, "E-Marker · 最高 5A / 20V · USB 3.2 Gen1")

        // 只有厂商号、服务端没给型号时，按内置厂商表显示
        let bare = try XCTUnwrap(PortIdentity.parse(pdStatus: pd, details: nil)[1])
        XCTAssertEqual(bare.displayName, "Apple 设备")
        XCTAssertTrue(bare.usesPD, "没有 get_port_details 时按请求的档位判断")
    }

    func testBatteryRulesFollowMiniProgram() throws {
        func battery(_ fields: String) throws -> BatteryInfo? {
            let json = try XCTUnwrap(JSONValue.parse(#"{"ports":[{"port":2,"operating_voltage":900,"operating_current":200,"# + fields + "}]}"))
            return PortIdentity.parse(pdStatus: json, details: nil)[1]?.battery
        }
        // 健康度 70% 低于 75%：当作报得不准，整块不显示
        XCTAssertNil(try battery(#""battery_design_capacity":150,"battery_last_full_charge_capacity":105,"battery_present_capacity":80"#))
        // 设计容量 2 Wh 不在 5–200 Wh 之间
        XCTAssertNil(try battery(#""battery_design_capacity":20,"battery_last_full_charge_capacity":20,"battery_present_capacity":10"#))
        // 0xFFFF 表示不知道
        XCTAssertNil(try battery(#""battery_design_capacity":150,"battery_last_full_charge_capacity":145,"battery_present_capacity":65535"#))
        XCTAssertNil(try battery(#""battery_invalid":true,"battery_design_capacity":150,"battery_last_full_charge_capacity":145,"battery_present_capacity":80"#))
        // 满电容量比设计容量大时健康度按 100% 算，电量不超过 100%
        XCTAssertEqual(try battery(#""battery_design_capacity":150,"battery_last_full_charge_capacity":152,"battery_present_capacity":160"#),
                       BatteryInfo(percent: 100, health: 100, designWh: 15))
    }

    func testVendorFallbacks() throws {
        // 苹果设备只在电池信息里报厂商号
        let apple = try XCTUnwrap(JSONValue.parse(#"{"ports":[{"port":3,"manufacturer_vid":0,"battery_vid":1452,"battery_pid":5,"operating_voltage":900,"operating_current":222}]}"#))
        let c2 = try XCTUnwrap(PortIdentity.parse(pdStatus: apple, details: nil)[2])
        XCTAssertEqual(c2.vendorID, 0x05AC)
        XCTAssertEqual(c2.productID, 5)
        XCTAssertEqual(c2.displayName, "Apple 设备")
        XCTAssertEqual(c2.pdSummary, "请求 9V 2.22A")

        // PD 芯片厂（TI 0x0451）的号不当品牌
        let chip = try XCTUnwrap(JSONValue.parse(#"{"ports":[{"port":2,"manufacturer_vid":"0x0451","operating_voltage":500,"operating_current":300}]}"#))
        let c1 = try XCTUnwrap(PortIdentity.parse(pdStatus: chip, details: nil)[1])
        XCTAssertNil(c1.displayName)
        XCTAssertEqual(c1.idText, "厂商号 0x0451")
    }

    // 2026-10-15 实测：服务端认出苹果 240W 线时给了品牌和型号、去掉了 cable_vid，
    // 不认识的编号写成 unknown(N)
    func testServerRecognizedCable() throws {
        let pd = try XCTUnwrap(JSONValue.parse("""
        {"ports":[{"port":2,"manufacturer_vid":0,"operating_voltage":500,"operating_current":300,"pd_revision":"PD 3.0",
          "request_epr_mode_capable":true,"has_emarker":true,"cable_brand_en":"Apple","cable_brand_zh":"Apple",
          "cable_name_en":"Apple","cable_name_zh":"Apple","cable_epr_mode_capable":true,"cable_is_active":false,
          "cable_max_vbus_current":"unknown(2)","cable_max_vbus_voltage":"unknown(3)","cable_usb_highest_speed":"USB 2.0"}]}
        """))
        let details = try XCTUnwrap(JSONValue.parse(#"{"ports":[{"port":2,"fc_protocol":"PD Fixed 5V","session_id":10}]}"#))
        let c1 = try XCTUnwrap(PortIdentity.parse(pdStatus: pd, details: details)[1])
        XCTAssertEqual(c1.cable?.summary, "Apple · 最高 5A / 50V · USB 2.0 · 支持 EPR")
        XCTAssertEqual(c1.pdSummary, "PD 3.0 · 请求 5V 3A · 支持 EPR")
        XCTAssertNil(c1.displayName, "认出的是线，不是设备")
        XCTAssertFalse(c1.recognizedByServer)
    }

    func testCableCodesAndSignature() throws {
        // 开源固件里线材字段是编号
        let pd = try XCTUnwrap(JSONValue.parse(#"{"ports":[{"port":2,"operating_voltage":2000,"operating_current":500,"has_emarker":true,"cable_max_vbus_current":2,"cable_max_vbus_voltage":3,"cable_usb_highest_speed":3,"cable_epr_mode_capable":true}]}"#))
        XCTAssertEqual(PortIdentity.parse(pdStatus: pd, details: nil)[1]?.cable?.summary, "E-Marker · 最高 5A / 50V · USB4 Gen3 · 支持 EPR")

        func port(_ attached: Bool, fc: Int, session: Int?) -> PortMetrics {
            PortMetrics(id: 1, active: true, state: "ATTACHED", portType: "C", attached: attached, chargingDurationSeconds: 0,
                        fcProtocol: fc, currentMilliamps: 0, voltageMillivolts: 0, inputMillivolts: 0, powerBudgetWatts: 0,
                        sessionID: session)
        }
        let before = PortIdentity.signature(of: [port(true, fc: 15, session: 3)])
        XCTAssertEqual(before, PortIdentity.signature(of: [port(true, fc: 15, session: 3)]))
        XCTAssertNotEqual(before, PortIdentity.signature(of: [port(true, fc: 16, session: 3)]), "重新握手")
        XCTAssertNotEqual(before, PortIdentity.signature(of: [port(true, fc: 15, session: 4)]), "换了设备")
        XCTAssertNotEqual(before, PortIdentity.signature(of: [port(false, fc: 255, session: 3)]), "拔掉")
    }

    func testMissingFieldsUseDefaults() throws {
        let metrics = try CandySignDriver.decodeMetrics(Data(#"{"ports":[{"id":2,"state":"INACTIVE"}]}"#.utf8))
        let port = try XCTUnwrap(metrics.ports.first)
        XCTAssertEqual(port.fcProtocol, 255)
        XCTAssertEqual(port.isPoweredOn, false)
        XCTAssertNil(metrics.system)
    }

    func testEndpointParsing() throws {
        let endpoint = try XCTUnwrap(MCPEndpoint(string: "  https://mcp.thecandysign.com/1234567890123456/abcd1234/mcp \n"))
        XCTAssertEqual(endpoint.psn, "1234567890123456")
        XCTAssertEqual(endpoint.url.absoluteString, "https://mcp.thecandysign.com/1234567890123456/abcd1234/mcp")
        XCTAssertFalse(endpoint.redacted.contains("abcd1234"))

        // 小程序按接入模型给 /sse 或 /mcp，token 相同，统一走 /mcp
        let sse = try XCTUnwrap(MCPEndpoint(string: "https://mcp.thecandysign.com/1234567890123456/abcd1234/sse"))
        XCTAssertEqual(sse.url.absoluteString, "https://mcp.thecandysign.com/1234567890123456/abcd1234/mcp")

        let rejected = [
            "http://mcp.thecandysign.com/1234567890123456/abcd1234/mcp",
            "https://evil.example.com/1234567890123456/abcd1234/mcp",
            "https://mcp.thecandysign.com.evil.example/1234567890123456/abcd1234/mcp",
            "https://mcp.thecandysign.com/1234567890123456/abcd1234/mcp?next=x",
            "https://user@mcp.thecandysign.com/1234567890123456/abcd1234/mcp",
            "https://mcp.thecandysign.com:8443/1234567890123456/abcd1234/mcp",
            "https://mcp.thecandysign.com/12ab/abcd1234/mcp",
            "https://mcp.thecandysign.com/1234567890123456/abcd1234/http",
            "https://mcp.thecandysign.com/1234567890123456/SKILL.md",
        ]
        for raw in rejected { XCTAssertNil(MCPEndpoint(string: raw), raw) }
    }

    func testExtractFromMiniProgramCopy() {
        // 小程序「龙虾服务」点复制得到的整段文字（PSN 和 token 是假的）
        let text = "现在安装控制「AI 小电拼 CP02」的技能：阅读 `https://mcp.thecandysign.com/1234567890123456/SKILL.md`。"
            + "这台小电拼的名字是「桌子」。MCP 服务器的地址是 `https://mcp.thecandysign.com/1234567890123456/abcd1234/sse`。"
        XCTAssertNil(MCPEndpoint(string: text))
        XCTAssertEqual(MCPEndpoint.extractAll(from: text).map(\.url.absoluteString),
                       ["https://mcp.thecandysign.com/1234567890123456/abcd1234/mcp"])
        XCTAssertTrue(MCPEndpoint.extractAll(from: "https://mcp.thecandysign.com/1234567890123456/abcd1234/ssex").isEmpty)
    }

    func testExtractAllDeduplicatesByPSN() {
        let text = """
        沙发 https://mcp.thecandysign.com/1111111111111111/aaaa1111/mcp
        桌子 `https://mcp.thecandysign.com/2222222222222222/bbbb2222/mcp`
        重复 https://mcp.thecandysign.com/1111111111111111/aaaa1111/mcp
        """
        XCTAssertEqual(MCPEndpoint.extractAll(from: text).map(\.psn), ["1111111111111111", "2222222222222222"])
    }

    func testSSEParsing() {
        let text = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":1}}\r\n\r\n: ping\n\ndata: {\"a\":\ndata: 1}\n\n"
        let messages = MCPClient.parseSSE(text)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["id"]?.intValue, 3)
        XCTAssertEqual(messages[1]["a"]?.intValue, 1)
    }

    func testInfoParsing() throws {
        let html = #"<script>window.__INFOZ = {"psn":"1350000000000001","device_name":"CP02-1A2B3C","note":"a}b","product_family":"CP02"};window.__CONFIG={"broker":"mqtts://example"}</script>"#
        let info = try XCTUnwrap(DeviceInfo.parse(html: html))
        XCTAssertEqual(info.psn, "1350000000000001")
        XCTAssertEqual(info.deviceName, "CP02-1A2B3C")
        XCTAssertEqual(info.productFamily, "CP02")
    }

    func testJSONValueEncodesIntegersAsIntegers() throws {
        let data = try JSONEncoder().encode(JSONValue.object(["ports": .array([.number(5)])]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ports":[5]}"#)
    }

    func testBonjourNameParsing() {
        XCTAssertEqual(BonjourScanner.parse(serviceName: "cp02-1320000000000002")?.psn, "1320000000000002")
        XCTAssertEqual(BonjourScanner.parse(serviceName: "CP02-1320000000000002")?.hostname, "cp02-1320000000000002.local")
        XCTAssertNil(BonjourScanner.parse(serviceName: "printer-1234567890"))
        XCTAssertNil(BonjourScanner.parse(serviceName: "cp02-abc"))
    }

    func testNames() {
        XCTAssertEqual(FastChargeProtocol.name(16), "PD 固定高压")
        XCTAssertEqual(FastChargeProtocol.name(255), "未充电")
        XCTAssertEqual(FastChargeProtocol.name(99), "协议 99")
        XCTAssertEqual(PortNaming.name(index: 0), "A")
        XCTAssertEqual(PortNaming.name(index: 0, family: "PA768S"), "C1")
        XCTAssertEqual(PortNaming.name(index: 7), "P8")
    }

    func testHostResolverAcceptsIPv4Literal() async {
        XCTAssertTrue(HostResolver.isIPv4Literal("192.0.2.22"))
        XCTAssertFalse(HostResolver.isIPv4Literal("cp02-1.local"))
        let resolved = await HostResolver.resolveIPv4("10.0.0.7")
        XCTAssertEqual(resolved, "10.0.0.7")
    }

    func testResponseMatchingIsStrict() throws {
        // 别的 id 的成功响应不能顶替本次请求
        let other = try XCTUnwrap(JSONValue.parse(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#))
        XCTAssertNil(MCPClient.match(other, id: 3))
        let batch = try XCTUnwrap(JSONValue.parse(#"[{"id":7,"result":{}},{"id":"3","result":{"x":1}}]"#))
        XCTAssertEqual(MCPClient.match(batch, id: 3)?["result"]?["x"]?.intValue, 1)
        // id 为 null 只接受错误响应
        let nullError = try XCTUnwrap(JSONValue.parse(#"{"id":null,"error":{"code":-32700,"message":"parse"}}"#))
        XCTAssertNotNil(MCPClient.match(nullError, id: 3)?["error"])
        let nullResult = try XCTUnwrap(JSONValue.parse(#"{"id":null,"result":{}}"#))
        XCTAssertNil(MCPClient.match(nullResult, id: 3))
    }

    func testParseBody() throws {
        let sse = Data("event: message\ndata: {\"id\":1,\"result\":{}}\n\ndata: {\"id\":2,\"result\":{\"v\":5}}\n\n".utf8)
        XCTAssertEqual(try MCPClient.parseBody(sse, id: 2)?["result"]?["v"]?.intValue, 5)
        let json = Data(#"{"jsonrpc":"2.0","id":4,"result":{"v":6}}"#.utf8)
        XCTAssertEqual(try MCPClient.parseBody(json, id: 4)?["result"]?["v"]?.intValue, 6)
        XCTAssertThrowsError(try MCPClient.parseBody(Data("not json".utf8), id: 4))
    }

    func testRedactsTokenInServerText() throws {
        let endpoint = try XCTUnwrap(MCPEndpoint(string: "https://mcp.thecandysign.com/1234567890123456/abcd1234/mcp"))
        let text = endpoint.redact("token abcd1234 rejected for https://mcp.thecandysign.com/1234567890123456/abcd1234/mcp")
        XCTAssertFalse(text.contains("abcd1234"))
        XCTAssertTrue(text.contains("1234567890123456/••••/mcp"))
    }

    // 取自 2026-10-15 实测的 get_machine_facts（只留用到的字段）
    func testMachineFactsAndAllocationLimits() throws {
        let json = try XCTUnwrap(JSONValue.parse("""
        {"max_power_budget":160,"ports":[
          {"index":2,"name":"C1","power":140},{"index":1,"name":"A","power":60},
          {"index":3,"name":"C2","power":140},{"index":4,"name":"C3","power":140},{"index":5,"name":"C4","power":140}]}
        """))
        let facts = try XCTUnwrap(MachineFacts(json: json))
        XCTAssertEqual(facts, .cp02Pro)
        XCTAssertNil(facts.problem(with: [0, 100, 60, 0, 0]))
        XCTAssertNil(facts.problem(with: [15, 65, 40, 20, 20]))
        XCTAssertNotNil(facts.problem(with: [0, 100, 70, 0, 0]), "合计超过 160 W")
        XCTAssertNotNil(facts.problem(with: [61, 0, 0, 0, 0]), "A 口上限 60 W")
        XCTAssertNotNil(facts.problem(with: [0, 10, 0, 0, 0]), "1–14 W 不合法")
        XCTAssertNotNil(facts.problem(with: [0, 100, 60, 0]), "端口数不对")
        // 固件用 uint8 累加合计，140 + 140 会溢出成 24；这里必须在本地拦住
        XCTAssertNotNil(facts.problem(with: [0, 140, 140, 0, 0]))
    }

    func testDisplayConfigParsing() throws {
        let cp02 = DisplayConfig(json: try XCTUnwrap(JSONValue.parse(#"{"level":"中"}"#)))
        XCTAssertEqual(cp02.level, .medium)
        XCTAssertFalse(cp02.supportsExtendedOptions)
        // CP02S 的字段名没有文档，按取值识别
        let cp02s = DisplayConfig(json: try XCTUnwrap(JSONValue.parse(
            #"{"level":"高","display_mode":"功率显示优先","idle_display":"落花","hourly_chime":true}"#)))
        XCTAssertEqual(cp02s.level, .high)
        XCTAssertEqual(cp02s.statusMode, .power)
        XCTAssertEqual(cp02s.idleDisplay, .petals)
        XCTAssertEqual(cp02s.hourlyChime, true)
        XCTAssertTrue(cp02s.supportsExtendedOptions)
    }

    // MARK: 芯片温度、本次电量、充电曲线

    func testPortTemperature() {
        XCTAssertEqual(PortTemperature("moderate"), .moderate)
        XCTAssertEqual(PortTemperature(" Warm\n"), .warm)
        XCTAssertNil(PortTemperature(""))
        XCTAssertNil(PortTemperature(nil))
        XCTAssertEqual([PortTemperature.cool, .moderate, .warm, .hot].map(\.label), ["凉爽", "温和", "偏热", "过热"])
        XCTAssertEqual([PortTemperature.cool, .moderate, .warm, .hot].map(\.level), [0, 1, 2, 3])
        // 不认识的档位原样显示，不配色
        XCTAssertEqual(PortTemperature("scorching")?.label, "scorching")
        XCTAssertNil(PortTemperature("scorching")?.level)
    }

    // 结构照 2026-10-15 实测的 get_port_details（只留用到的字段，数值改过）
    func testPortDetailsFromLiveShape() throws {
        let details = PortDetail.parse(try XCTUnwrap(JSONValue.parse("""
        {"ports":[
          {"port":1,"connected":false,"session_id":0,"session_charge_mwh":0,"die_temperature":"cool"},
          {"port":2,"connected":true,"session_id":13,"session_charge_mwh":834,"die_temperature":"moderate"},
          {"port":5,"connected":true,"session_id":9,"session_charge_mwh":42200,"die_temperature":"warm"},
          {"port":0,"die_temperature":"hot"}]}
        """)))
        XCTAssertEqual(Set(details.keys), [0, 1, 4], "端口号从 1 开始，0 号不认")
        XCTAssertEqual(details[1], PortDetail(portID: 1, sessionID: 13, sessionEnergyMWh: 834, temperature: .moderate))
        XCTAssertEqual(details[4]?.temperature, .warm)
        XCTAssertEqual(details[4]?.sessionEnergyMWh, 42_200)
        XCTAssertNil(details[4]?.lanChargeAtLoad, "局域网计数由 app 读到时补上")
        XCTAssertTrue(PortDetail.parse(nil).isEmpty)
    }

    private func chargingPort(session: Int?, charge: Int?) -> PortMetrics {
        PortMetrics(id: 4, active: true, state: "ATTACHED", portType: "A", attached: true,
                    chargingDurationSeconds: 600, fcProtocol: 0, currentMilliamps: 1000,
                    voltageMillivolts: 5000, inputMillivolts: 30_000, powerBudgetWatts: 60,
                    sessionID: session, sessionCharge: charge)
    }

    func testSessionEnergyCalibrationAndEstimate() throws {
        let small = PortDetail(portID: 1, sessionID: 13, sessionEnergyMWh: 28, lanChargeAtLoad: 4_160_000)
        let big = PortDetail(portID: 4, sessionID: 9, sessionEnergyMWh: 1000, lanChargeAtLoad: 146_600_000)
        // 用电量最大的会话校准；电量太小、比值离谱时不校准
        XCTAssertEqual(try XCTUnwrap(SessionEnergy.calibrate([small, big])), 146_600, accuracy: 0.001)
        XCTAssertNil(SessionEnergy.calibrate([small]))
        XCTAssertNil(SessionEnergy.calibrate([PortDetail(portID: 0, sessionEnergyMWh: 1000, lanChargeAtLoad: 1000)]))
        XCTAssertNil(SessionEnergy.calibrate([PortDetail(portID: 0, sessionEnergyMWh: 1000)]))

        // MCP 读数加上之后局域网计数的增量：又涨了 73,300,000 = 500 mWh
        let later = chargingPort(session: 9, charge: 146_600_000 + 73_300_000)
        XCTAssertEqual(try XCTUnwrap(SessionEnergy.estimate(big, port: later, unitsPerMWh: 146_600)), 1500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SessionEnergy.estimate(big, port: later, unitsPerMWh: nil)), 1500, accuracy: 0.001,
                       "没校准时用实测的默认比值")
        // 计数没涨或变小（固件重置）时只用 MCP 读数
        XCTAssertEqual(SessionEnergy.estimate(big, port: chargingPort(session: 9, charge: 1), unitsPerMWh: nil), 1000)
        XCTAssertEqual(SessionEnergy.estimate(big, port: chargingPort(session: 9, charge: nil), unitsPerMWh: nil), 1000)
        // 已经换了一次插入
        XCTAssertNil(SessionEnergy.estimate(big, port: chargingPort(session: 10, charge: 5), unitsPerMWh: nil))
        XCTAssertNil(SessionEnergy.estimate(PortDetail(portID: 4), port: later, unitsPerMWh: nil))
    }

    func testSessionEnergyFormat() {
        XCTAssertEqual(SessionEnergy.format(mWh: 28), "28 mWh")
        XCTAssertEqual(SessionEnergy.format(mWh: -3), "0 mWh")
        XCTAssertEqual(SessionEnergy.format(mWh: 999.4), "999 mWh")
        XCTAssertEqual(SessionEnergy.format(mWh: 999.6), "1.00 Wh")
        XCTAssertEqual(SessionEnergy.format(mWh: 3_456), "3.46 Wh")
        XCTAssertEqual(SessionEnergy.format(mWh: 42_200), "42.2 Wh")
        XCTAssertEqual(SessionEnergy.format(mWh: 512_000), "512 Wh")
        XCTAssertEqual(SessionEnergy.format(mWh: 1_250_000), "1.25 kWh")
    }

    func testHistoryRecorderAveragesTenSeconds() throws {
        var recorder = HistoryRecorder()
        let base = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(recorder.add(watts: 10, volts: 5, amps: 2, at: base))
        XCTAssertNil(recorder.add(watts: 20, volts: 5, amps: 4, at: base.addingTimeInterval(9.9)))
        let first = try XCTUnwrap(recorder.add(watts: 30, volts: 9, amps: 3.3, at: base.addingTimeInterval(11)))
        XCTAssertEqual(first.time, base)
        XCTAssertEqual(first.watts, 15, accuracy: 1e-9)
        XCTAssertEqual(first.amps, 3, accuracy: 1e-9)
        // 时间倒退（改了系统时间）时丢掉攒的，不出点
        XCTAssertNil(recorder.add(watts: 1, volts: 1, amps: 1, at: base.addingTimeInterval(2)))
        let next = try XCTUnwrap(recorder.add(watts: 1, volts: 1, amps: 1, at: base.addingTimeInterval(25)))
        XCTAssertEqual(next.time, base)
        XCTAssertEqual(next.watts, 1)
    }

    func testPortHistoryMergesDeviceMemory() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func sample(_ offset: TimeInterval, _ watts: Double) -> PowerSample {
            PowerSample(time: base.addingTimeInterval(offset), watts: watts, volts: 5, amps: watts / 5)
        }
        var history = PortHistory()
        for index in 0..<10 { history.record(sample(Double(index) * 10, 1)) }
        history.record(sample(50, 99))
        XCTAssertEqual(history.recorded.count, 10, "不比最后一个点新的忽略")

        // 设备内存覆盖的时段用设备的（顺序乱了也能排好），前后用本 app 记的
        history.setDeviceSamples([sample(40, 5), sample(30, 5)], loadedAt: base.addingTimeInterval(95))
        XCTAssertEqual(history.samples(since: base).map(\.watts), [1, 1, 1, 5, 5, 1, 1, 1, 1, 1])
        XCTAssertEqual(history.samples(since: base.addingTimeInterval(25)).first?.time, base.addingTimeInterval(30))
        XCTAssertEqual(history.deviceLoadedAt, base.addingTimeInterval(95))

        // 只留 2 小时
        history.record(sample(PortHistory.retention + 15, 2))
        XCTAssertEqual(history.recorded.first?.time, base.addingTimeInterval(20))
    }

    // get_port_stats 的点没有时间：最后一个算作刚结束的 10 秒，往前每个早 10 秒
    func testDeviceSamplesFromPortStats() throws {
        let value = try XCTUnwrap(JSONValue.parse("""
        {"count":3,"port":2,"samples":[
          {"current_ma":1000,"power_mw":5000,"voltage_mv":5000},
          {"current_ma":2000,"voltage_mv":9000},
          {"current_ma":0,"power_mw":0,"voltage_mv":0}]}
        """))
        let samples = PortHistory.deviceSamples(from: value, now: Date(timeIntervalSince1970: 1_000_007))
        XCTAssertEqual(samples.map(\.time.timeIntervalSince1970), [999_970, 999_980, 999_990])
        XCTAssertEqual(samples[0].watts, 5)
        XCTAssertEqual(samples[0].volts, 5)
        XCTAssertEqual(samples[1].watts, 18, accuracy: 1e-9, "没有 power_mw 时用电压乘电流")
        XCTAssertEqual(samples[1].amps, 2)
        XCTAssertTrue(PortHistory.deviceSamples(from: nil, now: Date()).isEmpty)
    }

    func testHistoryTotalAndSegments() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func sample(_ offset: TimeInterval, _ watts: Double) -> PowerSample {
            PowerSample(time: base.addingTimeInterval(offset), watts: watts, volts: 5, amps: watts / 5)
        }
        let total = PortHistory.total([[sample(0, 1), sample(10, 2)], [sample(10, 3), sample(20, 4)]])
        XCTAssertEqual(total.map(\.watts), [1, 5, 4])
        XCTAssertEqual(total.map(\.volts), [0, 0, 0], "合计不给电压")
        // 隔了 40 秒（超过 30 秒）就断开
        let gap = [sample(0, 1), sample(10, 1), sample(50, 1), sample(80, 1)]
        XCTAssertEqual(PortHistory.segments(gap), [0, 0, 1, 1])
        XCTAssertEqual(PortHistory.segments([]), [])
        XCTAssertEqual(PortHistory.slot(Date(timeIntervalSince1970: 1_000_009.9)), base)
    }
}
