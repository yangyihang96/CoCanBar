import OSLog
import SwiftUI
import WidgetKit
import CoCanKit
import CoCanStyle

private let widgetLog = Logger(subsystem: "com.local.CoCanBar", category: "widget")

/// 小组件某一时刻要显示的内容。
struct ChargerEntry: TimelineEntry {
    var date: Date
    /// nil：菜单栏 app 还没写过数据（没打开过，或者不是带 App Group 签名的正式版本）。
    let snapshot: WidgetSnapshot?
    /// 小组件设置里选的设备；nil 或者已经删掉时显示第一台。
    let psn: String?
    var pending: PendingConfirmation?
    var notice: WidgetNotice?
    /// 生成时间线时菜单栏 app 是否在运行。之后的时刻沿用这个判断：app 退出时会请系统马上刷新小组件。
    var appRunning = true
    /// app 没在运行时小组件自己读到的局域网数据（这台设备的）。
    var direct: WidgetSnapshot.Device?
    /// app 没在运行，小组件这次也没读到局域网。
    var directFailed = false

    /// 读数超过 15 分钟没更新：菜单栏 app 可能没在运行，或者 Mac 离开了小电拼所在的网络。
    static let staleAfter: TimeInterval = 15 * 60
    /// app 的提示（「已关闭 C1」）在小组件上显示多久。
    static let messageLifetime: TimeInterval = 8

    /// app 快照里的这台设备。
    var appDevice: WidgetSnapshot.Device? { snapshot?.device(psn) ?? snapshot?.devices.first }

    /// 显示的设备：app 在运行时用它的快照；没在运行、小组件自己读到的数据更新时用那份，
    /// 名字、策略、能否控制仍以 app 最后写的为准。
    var device: WidgetSnapshot.Device? {
        guard let app = appDevice else { return nil }
        guard !appRunning, let direct, ChargerID(storedKey: direct.psn).matches(storedKey: app.psn),
              (direct.readAt ?? .distantPast) > (app.readAt ?? .distantPast) else { return app }
        var device = direct
        device.name = app.name
        device.strategy = app.strategy
        device.controllable = app.controllable
        return device
    }

    /// 显示的是小组件自己读的局域网数据。
    var isDirect: Bool {
        guard !appRunning, let direct, let shown = device else { return false }
        return shown.readAt == direct.readAt
    }

    var isStale: Bool {
        guard let readAt = device?.readAt else { return true }
        return date.timeIntervalSince(readAt) > Self.staleAfter
    }

    /// 能不能在小组件上开关：菜单栏 app 在运行（命令要它发）、配好了 MCP、在线、读数没过时、没有操作在进行。
    /// 读数来自云端时不行：云端读不到开关状态，关掉的口在小组件上就开不回来了。
    var canSwitch: Bool {
        guard appRunning, let device else { return false }
        return device.controllable && device.online && device.viaCloud != true && !isStale && device.busy == nil
    }

    /// 等第二次点击确认关闭的口。
    var pendingPort: Int? {
        guard let device, let pending, ChargerID(storedKey: pending.psn).matches(storedKey: device.psn),
              date < pending.expiresAt else { return nil }
        return pending.port
    }

    /// 底部的一行提示。小组件自己的提示比快照新时优先，否则用 app 的。
    var message: (text: String, isError: Bool)? {
        guard let device else { return nil }
        let updatedAt = snapshot?.updatedAt ?? .distantPast
        if let notice, notice.applies(to: device.psn, now: date), notice.postedAt > updatedAt {
            return (notice.text, notice.isError)
        }
        if let busy = device.busy { return (busy, false) }
        if let text = device.message, date.timeIntervalSince(updatedAt) < Self.messageLifetime {
            return (text, device.messageIsError)
        }
        return nil
    }

    /// 内容会自己变的时刻：读数变旧、确认过期、提示消失。
    var changeDates: [Date] {
        var dates: [Date] = []
        if let readAt = device?.readAt { dates.append(readAt.addingTimeInterval(Self.staleAfter + 1)) }
        if let pending { dates.append(pending.expiresAt) }
        if let notice { dates.append(notice.expiresAt) }
        if device?.message != nil, let updatedAt = snapshot?.updatedAt {
            dates.append(updatedAt.addingTimeInterval(Self.messageLifetime))
        }
        return dates
    }

    func at(_ date: Date) -> ChargerEntry {
        var entry = self
        entry.date = date
        return entry
    }
}

struct ChargerProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ChargerEntry {
        .preview(date: Date())
    }

    func snapshot(for configuration: SelectChargerIntent, in context: Context) async -> ChargerEntry {
        // 配色是 app 改的，小组件在另一个进程里：每次生成内容前重新读一次
        Palette.reload()
        let entry = current(configuration)
        // 小组件库里预览时还没有数据，就用演示数据
        return context.isPreview && entry.device == nil ? .preview(date: Date()) : entry
    }

    func timeline(for configuration: SelectChargerIntent, in context: Context) async -> Timeline<ChargerEntry> {
        Palette.reload()
        let now = Date()
        var entry = current(configuration, now: now)
        if !entry.appRunning, let device = entry.device, let host = device.host {
            await readDirectly(&entry, from: device, host: host)
        }
        let entries = [entry] + entry.changeDates.filter { $0 > now }.sorted().map(entry.at)
        // 5 分钟后再要一次（系统会按每日次数限制往后推）；小组件自己也读不到时隔 15 分钟再试。
        // 还没有数据时等 app 写出第一份快照后通知刷新。
        let policy: TimelineReloadPolicy = entry.device == nil ? .never
            : .after(now.addingTimeInterval(entry.directFailed ? 900 : 300))
        let devices = entry.snapshot.map { "\($0.devices.count) 台设备" } ?? "没有数据"
        let source = entry.appRunning ? "app 在运行" : entry.isDirect ? "小组件直读局域网" : "app 没在运行"
        widgetLog.notice("小组件时间线：\(devices, privacy: .public)，\(source, privacy: .public)，\(entry.isStale ? "读数过时" : "读数新", privacy: .public)，\(entries.count, privacy: .public) 个时刻")
        return Timeline(entries: entries, policy: policy)
    }

    private func current(_ configuration: SelectChargerIntent, now: Date = Date()) -> ChargerEntry {
        let store = SharedStore.appGroup
        let snapshot = store?.readSnapshot()
        var entry = ChargerEntry(date: now, snapshot: snapshot, psn: configuration.charger?.id,
                                 pending: store?.readPending(), notice: store?.readNotice())
        entry.appRunning = snapshot?.appIsRunning(at: now) ?? false
        if !entry.appRunning, let psn = entry.appDevice?.psn { entry.direct = store?.readDirectReading(psn) }
        return entry
    }

    /// 菜单栏 app 没在运行：自己读一次局域网（最多等 10 秒，不要令牌），读到了存起来，下次接着用。
    /// 小组件和 app 共用本地网络权限，app 允许过就能读。
    private func readDirectly(_ entry: inout ChargerEntry, from device: WidgetSnapshot.Device, host: String) async {
        let id = ChargerID(storedKey: device.psn)
        // 只有 HTTP 驱动能在小组件里自己读。蓝牙驱动要连上再断开，不能在这里占着。
        guard ChargerDrivers.driver(for: id)?.allowsDirectWidgetRead == true else {
            entry.directFailed = true
            return
        }
        let psn = id.localID
        let knownIP = device.lanIP
        do {
            let metrics = try await withDeadline(seconds: 10) {
                try await LANClient().verifiedMetrics(psn: psn, host: host, knownIP: knownIP)
            }
            let updated = device.updated(with: metrics, at: Date())
            try? SharedStore.appGroup?.writeDirectReading(updated)
            entry.direct = updated
        } catch {
            entry.directFailed = true
            widgetLog.notice("菜单栏 app 没在运行，小组件直接读局域网失败：\(Self.reason(error), privacy: .public)")
        }
    }

    /// 日志里的失败原因，不带主机名（里面有 PSN）和地址。
    private static func reason(_ error: Error) -> String {
        switch error {
        case LANError.unresolved: return "解析不到主机名"
        case LANError.wrongDevice: return "地址上是另一台设备"
        case LANError.network(let message) where message.hasPrefix("地址无效"): return "地址无效"
        case let error as LANError: return error.localizedDescription
        default: return "网络错误"
        }
    }
}

/// 给异步操作加总时限：先完成的那个算数，另一个取消。
private func withDeadline<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw LANError.network("请求超时")
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw LANError.network("请求超时") }
        return result
    }
}

struct ChargerWidget: Widget {
    static let kind = "CoCanBarCharger"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectChargerIntent.self, provider: ChargerProvider()) { entry in
            ChargerWidgetView(entry: entry)
                .containerBackground(Palette.card, for: .widget)
        }
        .configurationDisplayName("小电拼")
        .description("总功率、各口状态和最近 30 分钟的走势。菜单栏 app 没开时直接读局域网；大尺寸可以开关端口。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

/// 系统渲染时从环境里取尺寸；离屏截图时直接传 `family`。
struct ChargerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ChargerEntry

    var body: some View {
        ChargerWidgetContent(entry: entry, family: family)
    }
}
