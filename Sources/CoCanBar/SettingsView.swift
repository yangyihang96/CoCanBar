import SwiftUI
import ServiceManagement
import CoCanKit
import CoCanStyle

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ControlsSettings()
                .tabItem { Label("调节", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.controls)
            DevicesSettings()
                .tabItem { Label("设备", systemImage: "bolt.horizontal") }
                .tag(SettingsTab.devices)
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        // 三页一样大，切换时窗口不跳；「调节」页是两栏卡片，另外两页的表单放在中间
        .frame(width: 1080, height: 720)
        // 换配色时整棵子树重建：`Palette` 是静态取值的，不重建会留着旧颜色
        .id(model.theme)
    }
}

/// 「设备」「通用」页：奶油底上居中一栏白卡片，输入框和按钮照 KangCharge 的连接表单（见 `SettingsStyle`）。
private struct FormPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CoCanBar")
                        .font(.system(size: 13, weight: .heavy).italic())
                        .foregroundStyle(SettingsStyle.orange)
                    Text(title)
                        .font(.system(size: 30, weight: .heavy))
                }
                .padding(.horizontal, 4)
                content
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsStyle.cream)
        .foregroundStyle(SettingsStyle.ink)
        .tint(SettingsStyle.orange)
    }
}

/// 设备列表：名称、主机、MCP 地址（存钥匙串）、添加和删除。
struct DevicesSettings: View {
    @Environment(AppModel.self) private var model

    @State private var newURL = ""
    @State private var scanning = false
    @State private var found: [DiscoveredDevice] = []
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        FormPage(title: "设备") {
            ForEach(model.devices) { device in
                DeviceEditor(device: device)
            }
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(title: "添加设备")
                FormField(title: "MCP 地址") {
                    SecureField("MCP 地址", text: $newURL, prompt: Text("粘贴从小程序「龙虾服务」复制的内容"))
                        .settingsField()
                }
                HStack(spacing: 8) {
                    Pill(title: "用 MCP 地址添加", filled: !newURLIsEmpty) { addFromURL() }
                        .disabled(newURLIsEmpty)
                    Pill(title: scanning ? "正在扫描…" : "扫描局域网", symbol: "wifi") { scan() }
                        .disabled(scanning)
                    Spacer(minLength: 0)
                }
                ForEach(found, id: \.psn) { candidate in
                    HStack {
                        Text(candidate.serviceName)
                            .font(.system(size: 12).monospaced())
                        Spacer()
                        Pill(title: "添加", filled: true) {
                            model.addDevice(psn: candidate.psn, name: nil)
                            found.removeAll { $0.psn == candidate.psn }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SettingsStyle.cream))
                }
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(messageIsError ? AnyShapeStyle(SettingsStyle.red) : AnyShapeStyle(SettingsStyle.gray))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard(padding: 20)
        }
    }

    private var newURLIsEmpty: Bool { newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func addFromURL() {
        do {
            let endpoint = try model.saveMCP(newURL)
            newURL = ""
            message = "已保存 \(endpoint.redacted)"
            messageIsError = false
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }

    private func scan() {
        scanning = true
        message = nil
        Task {
            found = await model.scanLAN()
            scanning = false
            message = found.isEmpty ? "没有发现新的小电拼（已添加的不再列出）。如果系统询问“本地网络”权限，请允许。" : nil
            messageIsError = false
        }
    }
}

/// 一台设备的卡片：名称和连接状态，名称、主机两个输入框，PSN 和 MCP 状态，替换 MCP 地址、测试连接和删除。
struct DeviceEditor: View {
    @Environment(AppModel.self) private var model
    let device: DeviceConfig

    private enum Field { case name, host }

    // 名称和主机先编辑草稿，按回车或离开输入框时才写入，避免输到一半就生效
    @State private var nameDraft = ""
    @State private var hostDraft = ""
    @FocusState private var focus: Field?
    @State private var urlDraft = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var testing = false
    @State private var confirmDelete = false

    private var configured: Bool { model.mcpConfigured.contains(device.psn) }
    private var urlDraftIsEmpty: Bool { urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(device.name)
                    .font(.system(size: 16, weight: .heavy))
                    .lineLimit(1)
                let badge = ConnectionBadge.Status(model, psn: device.psn)
                ConnectionBadge(status: badge, text: badge == .online && model.isCloud(device.psn) ? "云端" : nil)
                Spacer(minLength: 8)
                Button("删除设备", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsStyle.red)
            }
            HStack(alignment: .top, spacing: 12) {
                FormField(title: "名称") {
                    TextField("名称", text: $nameDraft, prompt: Text("设备名称"))
                        .focused($focus, equals: .name)
                        .onSubmit(commitName)
                        .settingsField()
                }
                FormField(title: "主机") {
                    TextField("主机", text: $hostDraft, prompt: Text(device.defaultHost))
                        .focused($focus, equals: .host)
                        .onSubmit(commitHost)
                        .settingsField()
                }
            }
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("PSN")
                        .foregroundStyle(SettingsStyle.gray)
                    Spacer(minLength: 12)
                    Text(device.psn)
                        .fontWeight(.semibold)
                        .monospaced()
                        .textSelection(.enabled)
                }
                .font(.system(size: 12))
                InfoRow("MCP", configured ? "已保存在钥匙串" : "未配置")
            }
            FormField(title: configured ? "替换 MCP 地址" : "MCP 地址") {
                SecureField(configured ? "替换地址" : "MCP 地址", text: $urlDraft,
                            prompt: Text(configured ? "粘贴新的 MCP 地址" : "粘贴从小程序「龙虾服务」复制的内容"))
                    .settingsField()
            }
            HStack(spacing: 8) {
                Pill(title: "保存地址", filled: !urlDraftIsEmpty) { save() }
                    .disabled(urlDraftIsEmpty)
                Pill(title: testing ? "测试中…" : "测试连接") { test() }
                    .disabled(!configured || testing)
                Spacer(minLength: 0)
            }
            if let status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(statusIsError ? AnyShapeStyle(SettingsStyle.red) : AnyShapeStyle(SettingsStyle.gray))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard(padding: 20)
        .onAppear {
            nameDraft = device.name
            hostDraft = device.hostOverride ?? ""
        }
        .onChange(of: focus) { previous, _ in
            if previous == .name { commitName() }
            if previous == .host { commitHost() }
        }
        // 没按回车就关掉设置窗口时也保存
        .onDisappear {
            commitName()
            commitHost()
        }
        .confirmationDialog("删除「\(device.name)」？", isPresented: $confirmDelete) {
            Button("删除设备和钥匙串里的 MCP 地址", role: .destructive) { remove() }
        } message: {
            Text("之后要重新粘贴 MCP 地址才能控制这台设备。")
        }
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            nameDraft = device.name
        } else if trimmed != device.name {
            model.rename(device.psn, to: trimmed)
        }
    }

    private func commitHost() {
        model.setHost(device.psn, hostDraft)
    }

    private func remove() {
        do {
            try model.removeDevice(device.psn)
        } catch {
            status = "删除失败，设备已保留：\(error.localizedDescription)"
            statusIsError = true
        }
    }

    private func save() {
        do {
            _ = try model.saveMCP(urlDraft, expectedPSN: device.psn)
            urlDraft = ""
            status = "已保存到钥匙串"
            statusIsError = false
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    private func test() {
        testing = true
        Task {
            switch await model.testMCP(psn: device.psn) {
            case .success(let count):
                status = "连接正常：服务提供 \(count) 个工具"
                statusIsError = false
            case .failure(let error):
                status = error.localizedDescription
                statusIsError = true
            }
            testing = false
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?

    var body: some View {
        FormPage(title: "通用") {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(title: "外观", detail: model.theme.title)
                OptionLine(title: "冷色调") {
                    OrangeToggle(isOn: Binding(get: { model.theme == .cool },
                                               set: { model.theme = $0 ? .cool : .warm }),
                                 label: "冷色调")
                }
                Text("打开：冷灰底 + 蓝色强调。关掉：奶油底 + 橙红强调（原来的样子）。菜单栏面板、设置页和桌面小组件一起换，选择会记住；面板右上角的齿轮菜单里也能一键切。")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsStyle.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard(padding: 20)
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(title: "运行")
                OptionLine(title: "刷新间隔") {
                    PillSegments(options: [(value: 2.0, title: "2 秒"), (value: 3.0, title: "3 秒"),
                                           (value: 5.0, title: "5 秒"), (value: 10.0, title: "10 秒")],
                                 selection: model.pollInterval) { model.pollInterval = $0 }
                }
                Divider()
                    .overlay(SettingsStyle.line)
                OptionLine(title: "登录时启动") {
                    OrangeToggle(isOn: Binding(
                        get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                        set: { enabled in
                            do {
                                try model.setLaunchAtLogin(enabled)
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                            }
                            loginStatus = model.launchAtLoginStatus
                        }), label: "登录时启动")
                }
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("还需要在「系统设置 › 通用 › 登录项」里允许。")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsStyle.gray)
                        Spacer()
                        Pill(title: "打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsStyle.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard(padding: 20)
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "说明")
                Group {
                    Text("读数：局域网 http://<设备>/metrics.json，每隔几秒读一次，不需要登录。")
                    Text("控制：官方 MCP（\(MCPEndpoint.host)）。MCP 地址含 token，只保存在登录钥匙串，服务名 \(KeychainStore.defaultService)。")
                    Text("MCP 不提供读取当前充电策略，面板上显示的是上次由本 app 设置的值。")
                }
                .font(.system(size: 12))
                .foregroundStyle(SettingsStyle.gray)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard(padding: 20)
        }
        .onAppear { loginStatus = model.launchAtLoginStatus }
    }
}
