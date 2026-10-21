import AppIntents
import CoCanKit

// 小组件里的三个动作：选显示哪台设备、端口开关按钮、刷新按钮。
// 都在小组件扩展里执行。扩展没有 MCP 令牌，开关是写一条命令请菜单栏 app 去发。

/// 小组件能选的设备：菜单栏 app 写在快照里的那几台。
struct WidgetChargerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "小电拼"
    static let defaultQuery = WidgetChargerQuery()

    /// PSN。
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ device: WidgetSnapshot.Device) {
        id = device.psn
        name = device.name
    }
}

struct WidgetChargerQuery: EntityQuery {
    private var devices: [WidgetSnapshot.Device] { SharedStore.appGroup?.readSnapshot()?.devices ?? [] }

    func entities(for identifiers: [String]) async throws -> [WidgetChargerEntity] {
        let devices = devices
        return identifiers.compactMap { id in
            devices.first { ChargerID(storedKey: $0.psn).matches(storedKey: id) }.map(WidgetChargerEntity.init)
        }
    }

    func suggestedEntities() async throws -> [WidgetChargerEntity] {
        devices.map(WidgetChargerEntity.init)
    }

    func defaultResult() async -> WidgetChargerEntity? {
        devices.first.map(WidgetChargerEntity.init)
    }
}

struct SelectChargerIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择小电拼"
    static let description: IntentDescription? = IntentDescription("选择这个小组件显示哪一台小电拼。")

    @Parameter(title: "设备", description: "不选时显示第一台")
    var charger: WidgetChargerEntity?

    init() {}
}

/// 小组件上的端口开关。关闭正在用的口要点两次：第一次只变成「关闭？」，10 秒内再点才发。
struct WidgetPortSwitchIntent: AppIntent {
    static let title: LocalizedStringResource = "小组件端口开关"
    static let isDiscoverable = false

    @Parameter(title: "设备")
    var psn: String

    @Parameter(title: "端口")
    var port: Int

    @Parameter(title: "打开")
    var turnOn: Bool

    @Parameter(title: "正在用")
    var inUse: Bool

    init() {}

    init(psn: String, port: Int, turnOn: Bool, inUse: Bool) {
        self.psn = psn
        self.port = port
        self.turnOn = turnOn
        self.inUse = inUse
    }

    /// 等菜单栏 app 回复的时间。它在运行时一般几十毫秒就回。
    static let replyTimeout: Duration = .seconds(3)

    func perform() async throws -> some IntentResult {
        guard let store = SharedStore.appGroup, let group = AppGroup.identifier else { return .result() }
        let now = Date()
        let name = PortNaming.name(index: port)
        if !turnOn, inUse, store.readPending()?.matches(psn: psn, port: port, now: now) != true {
            store.writePending(PendingConfirmation(psn: psn, port: port,
                                                   expiresAt: now.addingTimeInterval(PendingConfirmation.lifetime)))
            return .result()
        }
        store.writePending(nil)

        let command = WidgetCommand(psn: psn, port: port, turnOn: turnOn, issuedAt: now)
        do {
            try store.send(command)
        } catch {
            notice(store, "写不了共享数据，没有发送", isError: true)
            return .result()
        }
        DarwinNotification.post(AppGroup.commandNotification(group: group))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.replyTimeout)
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(80))
            if let reply = store.takeReply(command.id) {
                if reply.accepted {
                    notice(store, turnOn ? "正在打开 \(name)…" : "正在关闭 \(name)…", isError: false, lifetime: 15)
                } else {
                    notice(store, reply.message, isError: true)
                }
                return .result()
            }
        }
        if store.withdraw(command.id) {
            notice(store, "菜单栏 app 没在运行，打开「小电拼」后再试", isError: true)
        } else {
            // app 已经取走了命令，只是回复慢
            notice(store, turnOn ? "正在打开 \(name)…" : "正在关闭 \(name)…", isError: false, lifetime: 15)
        }
        return .result()
    }

    private func notice(_ store: SharedStore, _ text: String, isError: Bool, lifetime: TimeInterval = 10) {
        let now = Date()
        store.writeNotice(WidgetNotice(psn: psn, text: text, isError: isError, postedAt: now,
                                       expiresAt: now.addingTimeInterval(lifetime)))
    }
}

/// 小组件右上角的刷新。菜单栏 app 在运行时请它马上读一次局域网，等它写出新快照（最多 3 秒）；
/// 没在运行时直接返回，系统接着刷新小组件，由小组件自己读局域网。
struct WidgetRefreshIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新小电拼小组件"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        guard let store = SharedStore.appGroup, let group = AppGroup.identifier,
              let before = store.readSnapshot(), before.appIsRunning(at: Date()) else { return .result() }
        DarwinNotification.post(AppGroup.refreshNotification(group: group))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if let latest = store.readSnapshot(), latest.updatedAt > before.updatedAt { break }
        }
        return .result()
    }
}
