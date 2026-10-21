import XCTest
@testable import CoCanKit

/// 设备身份从裸 PSN 迁到 `<驱动>:<编号>`，以及小电拼驱动的能力。
/// 已经存下来的配置、小组件快照、直读文件都还用裸 PSN，查找时要能对上。
final class ChargerDriverTests: XCTestCase {
    private let psn = "1350000000000001"

    func testBarePSNIsCandySign() {
        let id = ChargerID(storedKey: psn)
        XCTAssertEqual(id.driver, ChargerID.candySign)
        XCTAssertEqual(id.localID, psn)
        XCTAssertEqual(id.namespaced, "candysign:\(psn)")
        XCTAssertEqual(id.legacyStorageKey, psn)
        XCTAssertEqual(id, ChargerID(storedKey: "candysign:\(psn)"))
        XCTAssertTrue(id.matches(storedKey: psn))
        XCTAssertTrue(id.matches(storedKey: "candysign:\(psn)"))
        // 旧键在前：钥匙串里现成的是裸 PSN，先查到就不用再问带前缀的那条。
        XCTAssertEqual(id.lookupKeys, [psn, "candysign:\(psn)"])
        XCTAssertEqual(id.directReadingToken, psn)
    }

    func testExplicitDriverAndLocalIDRoundTrip() {
        let id = ChargerID(driver: "cuktech", localID: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(ChargerID(storedKey: id.namespaced), id)
        XCTAssertEqual(id.legacyStorageKey, "cuktech:AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(id.lookupKeys, ["cuktech:AA:BB:CC:DD:EE:FF"])
        XCTAssertNil(id.directReadingToken, "带冒号的编号不进直读文件名")
    }

    func testUppercaseOrShortPrefixStaysLegacy() {
        let mac = ChargerID(storedKey: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(mac.driver, ChargerID.candySign)
        XCTAssertEqual(mac.localID, "AA:BB:CC:DD:EE:FF")

        let short = ChargerID(storedKey: "a:b")
        XCTAssertEqual(short.driver, ChargerID.candySign)
        XCTAssertEqual(short.localID, "a:b")

        let empty = ChargerID(storedKey: "candysign:")
        XCTAssertEqual(empty.driver, ChargerID.candySign)
        XCTAssertEqual(empty.localID, "candysign:")
    }

    func testFutureDriverIDParsesWithoutADriverImplementation() {
        let id = ChargerID(storedKey: "anker:prime-160")
        XCTAssertEqual(id.driver, "anker")
        XCTAssertEqual(id.localID, "prime-160")
        XCTAssertNil(ChargerDrivers.driver(for: id), "这一版不注册 Anker 驱动")
        XCTAssertNotNil(ChargerDrivers.driver(forStoredKey: psn))
        XCTAssertEqual(ChargerDrivers.driver(forStoredKey: psn)?.identifier, ChargerID.candySign)
    }

    func testChargerIDCodableAcceptsBareAndNamespaced() throws {
        let bare = try JSONDecoder().decode(ChargerID.self, from: Data("\"\(psn)\"".utf8))
        let prefixed = try JSONDecoder().decode(ChargerID.self, from: Data("\"candysign:\(psn)\"".utf8))
        XCTAssertEqual(bare, prefixed)
        let encoded = try JSONEncoder().encode(bare)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"candysign:\(psn)\"")
    }

    func testLegacyDeviceConfigDecodesAndRewritesWithoutADriverField() throws {
        let json = """
        {"psn":"\(psn)","name":"书桌","hostOverride":"cp02.local","lastStrategy":1}
        """
        let device = try JSONDecoder().decode(SavedDevice.self, from: Data(json.utf8))
        XCTAssertEqual(device.chargerID, ChargerID(storedKey: psn))
        XCTAssertEqual(device.psn, psn)
        XCTAssertEqual(device.id, psn)
        XCTAssertEqual(device.name, "书桌")
        XCTAssertEqual(device.hostOverride, "cp02.local")
        XCTAssertEqual(device.lastStrategy, 1)
        XCTAssertEqual(device.capabilities, ChargerCapabilities.candySign)

        let encoded = try JSONEncoder().encode(device)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["psn"] as? String, psn)
        XCTAssertEqual(object["name"] as? String, "书桌")
        XCTAssertEqual(object["hostOverride"] as? String, "cp02.local")
        XCTAssertEqual((object["lastStrategy"] as? NSNumber)?.intValue, 1)
        XCTAssertNil(object["driver"], "小电拼重新存盘不加 driver，旧版还能读")
        XCTAssertNil(object["id"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("candysign:"))

        let again = try JSONDecoder().decode(SavedDevice.self, from: encoded)
        XCTAssertEqual(again, device)
    }

    func testDeviceConfigAcceptsNamespacedForms() throws {
        let byPSN = try JSONDecoder().decode(SavedDevice.self, from: Data("""
        {"psn":"candysign:\(psn)","name":"书桌"}
        """.utf8))
        let byDriver = try JSONDecoder().decode(SavedDevice.self, from: Data("""
        {"driver":"candysign","psn":"\(psn)","name":"书桌"}
        """.utf8))
        let byID = try JSONDecoder().decode(SavedDevice.self, from: Data("""
        {"id":"candysign:\(psn)","name":"书桌"}
        """.utf8))
        XCTAssertEqual(byPSN.chargerID, ChargerID(storedKey: psn))
        XCTAssertEqual(byDriver.chargerID, byPSN.chargerID)
        XCTAssertEqual(byID.chargerID, byPSN.chargerID)
        XCTAssertEqual(byPSN.id, psn, "存盘键仍是裸 PSN")

        let other = try JSONDecoder().decode(SavedDevice.self, from: Data("""
        {"id":"esphome:plug-1","driver":"esphome","psn":"plug-1","name":"入户计量"}
        """.utf8))
        XCTAssertEqual(other.chargerID, ChargerID(driver: "esphome", localID: "plug-1"))
        XCTAssertEqual(other.id, "esphome:plug-1")
        XCTAssertTrue(other.capabilities.isEmpty)
        let stored = try JSONEncoder().encode(other)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "esphome:plug-1")
        XCTAssertEqual(object["driver"] as? String, "esphome")
        XCTAssertEqual(object["psn"] as? String, "plug-1")
    }

    func testSnapshotAndWidgetStateMatchLegacyKeys() {
        let device = WidgetSnapshot.Device(
            psn: psn, name: "书桌", online: true, readAt: nil, controllable: true, strategy: nil, ports: [])
        let snapshot = WidgetSnapshot(updatedAt: Date(timeIntervalSince1970: 0), devices: [device])
        XCTAssertEqual(snapshot.device(psn)?.name, "书桌")
        XCTAssertEqual(snapshot.device("candysign:\(psn)")?.psn, psn)
        XCTAssertNil(snapshot.device("other"))

        let now = Date(timeIntervalSince1970: 1_000)
        let pending = PendingConfirmation(psn: psn, port: 3, expiresAt: now.addingTimeInterval(10))
        XCTAssertTrue(pending.matches(psn: "candysign:\(psn)", port: 3, now: now))
        XCTAssertFalse(pending.matches(psn: "candysign:\(psn)", port: 2, now: now))

        let notice = WidgetNotice(psn: psn, text: "x", isError: false, expiresAt: now.addingTimeInterval(5))
        XCTAssertTrue(notice.applies(to: "candysign:\(psn)", now: now))
        XCTAssertFalse(notice.applies(to: "candysign:other", now: now))
        XCTAssertTrue(WidgetNotice(psn: nil, text: "x", isError: false, expiresAt: now.addingTimeInterval(5))
            .applies(to: "anything", now: now))
    }

    func testDirectReadingFileFallsBackToBarePSN() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoCanID-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(directory: directory)
        let device = WidgetSnapshot.Device(
            psn: psn, name: "书桌", online: true, readAt: nil, controllable: false, strategy: nil, ports: [])
        try store.writeDirectReading(device)
        XCTAssertEqual(store.readDirectReading(psn)?.name, "书桌")
        XCTAssertEqual(store.readDirectReading("candysign:\(psn)")?.psn, psn)
        let file = directory.appendingPathComponent("lan/\(psn).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "文件名仍是裸 PSN")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("lan/candysign:\(psn).json").path))

        var namespaced = device
        namespaced.psn = "candysign:\(psn)"
        namespaced.name = "同一台"
        try store.writeDirectReading(namespaced)
        XCTAssertEqual(store.readDirectReading(psn)?.name, "同一台")
    }

    func testCandySignCapabilitiesAndHTTPWidgetRead() {
        let driver = CandySignDriver.shared
        XCTAssertEqual(driver.identifier, "candysign")
        XCTAssertEqual(driver.transport, .http)
        XCTAssertTrue(driver.allowsDirectWidgetRead)
        let caps = driver.capabilities
        XCTAssertTrue(caps.contains(.portPower))
        XCTAssertTrue(caps.contains(.chargingStrategy))
        XCTAssertTrue(caps.contains(.temperatureMode))
        XCTAssertTrue(caps.contains(.displaySettings))
        XCTAssertTrue(caps.contains(.powerAllocation))
        XCTAssertTrue(caps.contains(.portIdentity))
        XCTAssertTrue(caps.contains(.cloudReading))
        XCTAssertTrue(caps.supports(.setStrategy(.fast)))
        XCTAssertTrue(caps.supports(.setPort(index: 0, on: false)))
        XCTAssertTrue(caps.supports(.setHourlyChime(true)))
    }

    func testMetricsJSONStaysInsideTheCandySignDriver() throws {
        let metrics = try CandySignDriver.decodeMetrics(Data(#"{"ports":[{"id":1}]}"#.utf8))
        XCTAssertEqual(metrics.ports.first?.id, 1)
        XCTAssertEqual(metrics.ports.first?.powerKnown, true)
        XCTAssertNil(metrics.ports.first?.protocolText)
        XCTAssertThrowsError(try CandySignDriver.decodeMetrics(Data("[]".utf8)))
    }
}
