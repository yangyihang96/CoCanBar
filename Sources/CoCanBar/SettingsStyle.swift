import SwiftUI
import CoCanKit
import CoCanStyle

/// 设置窗口的配色，照 KangCharge（github.com/LeiZiKang/KangCharge，MIT）的主窗口：
/// 奶油底、白卡片、一个强调色、近黑的正文；选中的胶囊、开关和充电中的功率是强调色，在线是绿色。
/// 颜色全部取自 `Palette`，所以和菜单栏面板、桌面小组件一起跟着「暖色 / 冷色」切换。
enum SettingsStyle {
    static var orange: Color { Palette.brand }
    static var green: Color { Palette.online }
    static var amber: Color { Palette.heatModerate }
    static var red: Color { Palette.danger }

    static var cream: Adaptive { Palette.canvas }
    static var card: Adaptive { Palette.card }
    static var ink: Adaptive { Palette.ink }
    static var gray: Adaptive { Palette.current.gray }
    static var lightGray: Adaptive { Palette.current.lightGray }
    static var line: Adaptive { Palette.current.line }
    /// 强调色的浅底：端口标签、选中的温控项。
    static var orangeSoft: Adaptive { Palette.current.accentSoft }
    /// 没选中的胶囊按钮的细边。
    static var pillStroke: Adaptive { Palette.pillStroke }
    /// 关着的开关。
    static var toggleOff: Adaptive { Palette.current.toggleOff }
    /// 关着的端口标签。
    static var tagOff: Adaptive { Palette.current.tagOff }

    /// 芯片温度：凉爽绿、温和琥珀、偏热和过热红，不认识的档位灰。
    static func temperature(_ temperature: PortTemperature) -> AnyShapeStyle {
        switch temperature {
        case .cool: return AnyShapeStyle(green)
        case .moderate: return AnyShapeStyle(amber)
        case .warm, .hot: return AnyShapeStyle(red)
        case .other: return AnyShapeStyle(gray)
        }
    }
}

// MARK: - 卡片

extension View {
    /// 白色大圆角卡片（KangCharge 的卡片没有阴影）。
    func settingsCard(padding: CGFloat = 18, radius: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(SettingsStyle.card))
    }
}

/// 卡片标题：粗黑字，右边可以带一句灰色说明。
struct CardTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 16, weight: .heavy))
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsStyle.gray)
                    .lineLimit(1)
            }
        }
    }
}

/// 卡片里的一行：左边灰色名称，右边加粗的值，值可以选中复制。
struct InfoRow: View {
    let title: String
    let value: String?

    init(_ title: String, _ value: String?) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(SettingsStyle.gray)
            Spacer(minLength: 12)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}

/// 一项设置：左边灰色名称，右边是选项；一行放不下时选项换到下一行。
struct OptionLine<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // 间距只算一次（名称和选项之间至少 12），CP02S 的「待机显示」四个选项才放得下一行
            HStack(spacing: 0) {
                label
                Spacer(minLength: 12)
                content
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                content
            }
        }
    }

    private var label: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SettingsStyle.gray)
            .fixedSize()
    }
}

// MARK: - 按钮和开关

/// 胶囊按钮：`filled` 时橙底白字（选中的选项、主要操作），否则白底细边。
struct Pill: View {
    let title: String
    var symbol: String?
    var filled = false
    var large = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: large ? 11 : 10, weight: .bold))
                }
                Text(title)
                    .font(.system(size: large ? 13 : 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(SettingsStyle.ink))
            .padding(.horizontal, large ? 13 : 11)
            .padding(.vertical, large ? 7 : 6)
            .background(Capsule().fill(filled ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.card)))
            .overlay(Capsule().strokeBorder(filled ? AnyShapeStyle(Color.clear) : AnyShapeStyle(SettingsStyle.pillStroke),
                                            lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// 一排单选的胶囊（亮度、待机显示、曲线的端口和时间范围）。
struct PillSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let selection: Value?
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                Pill(title: option.title, filled: option.value == selection) { onSelect(option.value) }
            }
        }
    }
}

/// 整行的胶囊按钮：默认黑色（KangCharge 的「调整分配」）；`orange` 是表单的主要操作（它的「连接」），不能点时变浅灰。
struct WideButton: View {
    let title: String
    var orange = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(orange ? AnyShapeStyle(Color.white) : AnyShapeStyle(SettingsStyle.card))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
                .opacity(isEnabled || orange ? 1 : 0.35)
        }
        .buttonStyle(.plain)
    }

    private var fill: AnyShapeStyle {
        guard orange else { return AnyShapeStyle(SettingsStyle.ink) }
        return isEnabled ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.lightGray)
    }
}

/// 白色圆形图标按钮（页首的刷新、设置）。
struct CircleIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SettingsStyle.ink)
                .frame(width: 34, height: 34)
                .background(Circle().fill(SettingsStyle.card))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 橙色的胶囊开关。系统开关改不了颜色，窗口不在前台时还会变灰，所以自己画。
struct OrangeToggle: View {
    @Binding var isOn: Bool
    let label: String
    var scale: CGFloat = 1

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.toggleOff))
                .frame(width: 34 * scale, height: 20 * scale)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    // 圆点定死尺寸，左右对齐才有位移
                    Circle()
                        .fill(.white)
                        .frame(width: 16 * scale, height: 16 * scale)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .padding(2 * scale)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "开" : "关")
    }
}

// MARK: - 表单

/// 表单里的一项：上面一行灰色小标题，下面是输入框（照 KangCharge 的连接表单）。
struct FormField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsStyle.gray)
            content
        }
    }
}

extension View {
    /// 奶油底、细边、圆角 10 的输入框。
    func settingsField() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SettingsStyle.cream))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SettingsStyle.line))
    }
}

// MARK: - 小标签

/// 连接状态的小方标，白字：在线绿、连接中琥珀、离线红。
struct ConnectionBadge: View {
    enum Status {
        case online, connecting, offline
    }

    let status: Status
    var text: String?

    var body: some View {
        Text(text ?? defaultText)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color))
            .fixedSize()
    }

    private var color: Color {
        switch status {
        case .online: return SettingsStyle.green
        case .connecting: return SettingsStyle.amber
        case .offline: return SettingsStyle.red
        }
    }

    private var defaultText: String {
        switch status {
        case .online: return "在线"
        case .connecting: return "连接中"
        case .offline: return "离线"
        }
    }
}

extension ConnectionBadge.Status {
    /// 读得到数据是在线；还没读到过也没出过错是连接中；其余是离线。
    @MainActor init(_ model: AppModel, psn: String) {
        if model.isOnline(psn) {
            self = .online
            return
        }
        let state = model.runtime[psn]
        self = state?.lastError == nil && state?.metrics == nil ? .connecting : .offline
    }
}

/// 端口标签：圆角方块里写端口名，开着是橙色，关着是灰色。
struct PortTag: View {
    let name: String
    let enabled: Bool
    var size: CGFloat = 36

    var body: some View {
        Text(name)
            .font(.system(size: size * 0.36, weight: .heavy))
            .foregroundStyle(enabled ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.gray))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(enabled ? AnyShapeStyle(SettingsStyle.orangeSoft) : AnyShapeStyle(SettingsStyle.tagOff)))
    }
}

/// 芯片温度：前面一个按档位着色的圆点。
struct TemperatureDot: View {
    let temperature: PortTemperature

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(SettingsStyle.temperature(temperature))
                .frame(width: 6, height: 6)
            Text(temperature.label)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(SettingsStyle.gray)
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("芯片温度\(temperature.label)")
    }
}

/// 底部弹出的提示：执行中转圈，成功橙色勾，出错红色感叹号。
struct SettingsToast: View {
    enum Kind {
        case busy, success, error
    }

    let text: String
    let kind: Kind

    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .busy:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SettingsStyle.orange)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(SettingsStyle.red)
            }
            Text(text)
                .foregroundStyle(SettingsStyle.ink)
                .lineLimit(2)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(SettingsStyle.card))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
    }
}
