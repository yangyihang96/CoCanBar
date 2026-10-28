import AppKit
import WidgetKit
import CoCanKit

/// 把面板的数据写给桌面小组件，并执行在小组件上点的端口开关。
///
/// 只在正式打包（签名里带 App Group）时工作；SwiftPM 的调试构建没有共享容器，`init` 返回 nil。
/// 小组件拿不到 MCP 令牌：它只能请 app 开关某台已添加设备的某个口，由 app 检查后用自己钥匙串里的令牌发送。
/// app 没在运行时小组件自己读局域网（不要令牌），所以快照里带上主机名、IP 和会话号，退出时也写一笔。
@MainActor
final class WidgetBridge {
    private let store: SharedStore
    private weak var model: AppModel?
    private var observer: DarwinNotificationObserver?
    private var refreshObserver: DarwinNotificationObserver?
    private var terminationObserver: NSObjectProtocol?
    private var watcher: DispatchSourceFileSystemObject?
    private var refreshing = false

    private var updateScheduled = false
    private var lastWritten: WidgetSnapshot?
    private var lastWrittenAt = Date.distantPast
    private var lastReloaded: WidgetSnapshot?
    private var lastReloadAt = Date.distantPast
    private var pendingReload: Task<Void, Never>?
    /// 已经收下、还没开始执行的命令所属的设备：同一批里给同一台设备的第二条命令要拒掉，不能等它被静默丢弃。
    private var accepted: Set<String> = []

    /// 读数每 10 秒写一次就够：小组件刷新时读最新的一份。开关、插拔、在线、提示这类变化马上写。
    private static let writeInterval: TimeInterval = 10
    /// 系统每天给小组件的刷新次数有限：状态变化最快 30 秒刷一次，只是功率变了 5 分钟最多一次。
    /// 在小组件上点了开关之后不受这个限制，执行完马上刷。
    private static let stateReloadInterval: TimeInterval = 30
    private static let readingsReloadInterval: TimeInterval = 300
    /// 一直没有明显变化也隔 14 分钟刷一次：小组件上的读数超过 15 分钟会标成过时。
    private static let keepFreshInterval: TimeInterval = 14 * 60

    init?(model: AppModel) {
        guard let group = AppGroup.identifier, let store = SharedStore.appGroup else { return nil }
        self.store = store
        self.model = model
        observer = DarwinNotificationObserver(name: AppGroup.commandNotification(group: group)) { [weak self] in
            Task { @MainActor in self?.handleCommands() }
        }
        refreshObserver = DarwinNotificationObserver(name: AppGroup.refreshNotification(group: group)) { [weak self] in
            Task { @MainActor in await self?.refreshNow() }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillTerminate() }
        }
        watchCommands()
        appLog.notice("桌面小组件共享已启用")
        // app 没开时点的命令早就过期了，这里只是回复并清掉
        handleCommands()
    }

    /// 数据变了。合并到下一轮再处理：一次读取改好几处时只算一次。
    func setNeedsUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.update(force: false)
        }
    }

    private func update(force: Bool, now: Date = Date()) {
        guard let model else { return }
        let snapshot = model.widgetSnapshot(now: now)
        let change = snapshot.change(since: lastWritten)
        guard force || change == .state || now.timeIntervalSince(lastWrittenAt) >= Self.writeInterval else { return }
        // 上一份快照已经超过 1 分钟（Mac 睡过一觉、或者一轮读取卡了很久）：小组件可能已经当 app 没在运行，
        // 改成自己读局域网、把开关变灰。这份写完要马上刷新，不按平时的节流等 5–14 分钟
        let resumed = lastWritten != nil && now.timeIntervalSince(lastWrittenAt) >= WidgetSnapshot.appAliveWindow
        do {
            try store.writeSnapshot(snapshot)
        } catch {
            appLog.error("写小组件数据失败：\(error.localizedDescription, privacy: .public)")
            return
        }
        if lastWritten == nil {
            let online = snapshot.devices.filter(\.online).count
            appLog.notice("小组件数据已写入：\(snapshot.devices.count, privacy: .public) 台设备，\(online, privacy: .public) 台在线")
        }
        lastWritten = snapshot
        lastWrittenAt = now
        if force || resumed {
            reload(snapshot, now: now)
        } else {
            scheduleReload(for: snapshot, now: now)
        }
    }

    private func scheduleReload(for snapshot: WidgetSnapshot, now: Date) {
        let change = snapshot.change(since: lastReloaded)
        let interval: TimeInterval
        switch change {
        case .none:
            if now.timeIntervalSince(lastReloadAt) >= Self.keepFreshInterval { reload(snapshot, now: now) }
            return
        case .readings: interval = Self.readingsReloadInterval
        case .state: interval = Self.stateReloadInterval
        }
        let due = lastReloadAt.addingTimeInterval(interval)
        if due <= now {
            reload(snapshot, now: now)
        } else if change == .state, pendingReload == nil {
            // 到点再刷，刷的时候用那时最新写好的快照
            pendingReload = Task { [weak self] in
                try? await Task.sleep(for: .seconds(due.timeIntervalSince(now)))
                guard let self, !Task.isCancelled else { return }
                self.pendingReload = nil
                if let latest = self.lastWritten { self.reload(latest, now: Date()) }
            }
        }
    }

    private func reload(_ snapshot: WidgetSnapshot, now: Date) {
        pendingReload?.cancel()
        pendingReload = nil
        lastReloaded = snapshot
        lastReloadAt = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 配色改了：配色文件已经由 `Palette.apply` 写进容器，这里只请系统按新配色重画。
    /// 不受上面那几个节流限制——用户刚点完开关，应该马上看到颜色变。
    func themeChanged() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 小组件上点了刷新：马上读一次（局域网读不到的设备改读云端），写出新快照并刷新小组件。连点时只读一次。
    private func refreshNow() async {
        guard let model, !refreshing else { return }
        refreshing = true
        await model.refreshAll(cloudNow: true)
        refreshing = false
        update(force: true)
    }

    /// 正常退出：在快照里记下退出时间，小组件马上改成自己读局域网，开关变灰。
    private func appWillTerminate() {
        guard let model else { return }
        var snapshot = model.widgetSnapshot(now: Date())
        snapshot.appStoppedAt = Date()
        try? store.writeSnapshot(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        appLog.notice("退出前已告诉小组件：app 不再运行")
    }

    // MARK: - 小组件上点的开关

    /// 命令目录里一有文件变化就处理。和 Darwin 通知互为备份，哪个先到都行（重复处理时目录已经空了）。
    private func watchCommands() {
        let url = store.commandsURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            appLog.error("监视小组件命令目录失败")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleCommands() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func handleCommands(now: Date = Date()) {
        for command in store.takeCommands() {
            let problem = check(command, now: now)
            do {
                try store.reply(WidgetReply(id: command.id, accepted: problem == nil, message: problem ?? "已收到"))
            } catch {
                appLog.error("回复小组件失败：\(error.localizedDescription, privacy: .public)")
            }
            if let problem {
                appLog.notice("小组件的开关命令没有执行：\(problem, privacy: .public)")
                continue
            }
            guard let model, let device = model.device(command.psn) else { continue }
            let psn = device.psn
            accepted.insert(psn)
            Task { [weak self] in
                let error = await model.setPort(psn: psn, index: command.port, on: command.turnOn)
                self?.accepted.remove(psn)
                if let error {
                    appLog.notice("小组件的开关命令失败：\(error, privacy: .public)")
                }
                self?.update(force: true)
            }
        }
    }

    /// 命令没过期、设备是 app 里添加过的、配好了 MCP、读数来自局域网、口存在、设备没有别的操作在进行。
    private func check(_ command: WidgetCommand, now: Date) -> String? {
        guard let model else { return "菜单栏 app 正在退出" }
        if command.isExpired(now: now) { return "命令已过期，没有执行" }
        guard let device = model.device(command.psn) else { return "菜单栏 app 里没有这台设备" }
        guard model.mcpConfigured.contains(device.psn) else { return "「\(device.name)」还没配好 MCP，不能开关端口" }
        guard model.isOnline(device.psn) else { return "「\(device.name)」不在线" }
        // 云端读数没有开关状态，小组件上的开关是按旧状态画的，点下去未必是想要的方向
        if model.isCloud(device.psn) { return "Mac 连不上「\(device.name)」的局域网，请在菜单栏面板里开关" }
        guard model.runtime[device.psn]?.metrics?.ports.contains(where: { $0.id == command.port }) == true else {
            return "读不到这个口"
        }
        if let busy = model.runtime[device.psn]?.busy { return AppModel.busyText(busy) }
        if accepted.contains(device.psn) { return "上一个操作还没完成，请稍后再试" }
        return nil
    }
}

extension AppModel {
    /// 给小组件的快照：和面板显示的是同一份数据。
    func widgetSnapshot(now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(updatedAt: now, devices: devices.map { device in
            let state = runtime[device.psn]
            let ports = (state?.metrics?.ports ?? []).map { port in
                let identity = identity(device.psn, port: port)
                return WidgetSnapshot.Port(id: port.id, poweredOn: port.isPoweredOn, attached: port.attached,
                                           watts: port.watts, volts: port.volts, amps: port.amps,
                                           fcProtocol: port.fcProtocol, protocolText: port.protocolText,
                                           deviceName: identity?.displayName,
                                           batteryPercent: identity?.battery?.percent,
                                           temperature: temperature(device.psn, port: port)?.rawValue,
                                           sessionEnergyMWh: sessionEnergy(device.psn, port: port),
                                           chargingSeconds: port.chargingDurationSeconds, sessionID: port.sessionID,
                                           sessionCharge: port.sessionCharge)
            }
            let samples = historySamples(psn: device.psn, port: nil, since: now.addingTimeInterval(-31 * 60), now: now)
            return WidgetSnapshot.Device(psn: device.psn, name: device.name, online: isOnline(device.psn),
                                         readAt: state?.lastSuccess, controllable: mcpConfigured.contains(device.psn),
                                         strategy: device.lastStrategy, ports: ports,
                                         recentWatts: WidgetSnapshot.minuteSeries(samples, now: now), recentWattsAt: now,
                                         busy: state?.busy, message: state?.message,
                                         messageIsError: state?.messageIsError ?? false,
                                         host: device.effectiveHost, lanIP: state?.verifiedIP ?? state?.resolvedIP,
                                         lanUnitsPerMWh: state?.identity.lanUnitsPerMWh,
                                         viaCloud: isCloud(device.psn) ? true : nil)
        })
    }
}
