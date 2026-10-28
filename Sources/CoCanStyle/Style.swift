import SwiftUI
import Foundation
import CoCanKit

// 面板和桌面小组件共用的配色、格式和小部件。设置窗口照 KangCharge 的配色另见 `SettingsStyle`。

/// 两套配色。暖色是原来照小程序 wxss 和场景模式配色表（scene-mode.js）做的那套：
/// 奶油底 #F8F5EC、白卡片、品牌橙红 #FF4719。冷色把奶油底换成冷灰、橙红换成蓝色。
/// 菜单栏面板、设置窗口和桌面小组件读的是同一套，改一处三处一起变。
public enum ThemeMode: String, CaseIterable, Sendable, Identifiable {
    case warm
    case cool

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .warm: return "暖色"
        case .cool: return "冷色"
        }
    }

    /// 设置里那句说明。
    public var detail: String {
        switch self {
        case .warm: return "奶油底、橙红强调，和原来的样子一样"
        case .cool: return "冷灰底、蓝色强调，不刺眼"
        }
    }
}

/// 一套配色的全部颜色。`Palette` 按当前 `ThemeMode` 取其中一套。
public struct Theme: Sendable {
    // 强调色和状态色
    public let brand: Color
    public let brandLight: Color
    public let online: Color
    public let danger: Color
    /// 芯片温度中间两档。故意不跟强调色走：温度从凉到热必须是绿-黄-红，
    /// 冷色主题里不能变成蓝色（那看着像凉快）。
    public let heatModerate: Color
    public let heatHigh: Color

    // 中性色
    public let canvas: Adaptive
    public let card: Adaptive
    public let cardStroke: Adaptive
    public let inset: Adaptive
    public let ink: Adaptive
    public let heading: Adaptive
    public let unit: Adaptive
    public let track: Adaptive
    public let hatch: Adaptive
    public let pillStroke: Adaptive
    public let pill: Adaptive
    public let columnSelected: Adaptive
    public let columnHover: Adaptive
    /// 设置窗口的三个灰：次要文字、更浅的灰、细分隔线。
    public let gray: Adaptive
    public let lightGray: Adaptive
    public let line: Adaptive
    public let toggleOff: Adaptive
    public let tagOff: Adaptive

    /// 「调节」页画的那台小电拼机身：上浅下深的机身、描边、投影。
    /// 暖色是产品本身的奶油白，冷色换成冷白，免得一页冷色里蹦出一块暖白。
    public let deviceTop: Color
    public let deviceBottom: Color
    public let deviceEdge: Color
    public let deviceShadow: Color

    /// 场景模式的主题色和五个口的配色（A、C1…C4）。
    public let standard: ModeColors
    public let sleep: ModeColors
    public let performance: ModeColors
    public let singlePort: ModeColors

    /// 强调色的浅底：选中的端口标签、选中的温控项。
    public var accentSoft: Adaptive {
        Adaptive(light: brand.opacity(0.1), dark: brand.opacity(0.2))
    }

    /// 暖色：照小程序的奶油底和场景配色，数值和以前一样。
    public static let warm = Theme(
        brand: Color(hex: 0xFF4719),
        brandLight: Color(hex: 0xFF7A4D),
        online: Color(hex: 0x00C539),
        danger: Color(hex: 0xFF3B30),
        heatModerate: Color(hex: 0xFFA51E),
        heatHigh: Color(hex: 0xFF4719),
        canvas: Adaptive(light: Color(hex: 0xF8F5EC), dark: Color(hex: 0x1C1B19)),
        card: Adaptive(light: .white, dark: Color(hex: 0x292724)),
        cardStroke: Adaptive(light: .black.opacity(0.03), dark: .white.opacity(0.06)),
        inset: Adaptive(light: Color(hex: 0xF8F5EC), dark: Color(hex: 0x211F1C)),
        ink: Adaptive(light: Color(hex: 0x121212), dark: Color(hex: 0xF3F0EA)),
        heading: Adaptive(light: Color(hex: 0x6E6A62), dark: Color(hex: 0xA9A49A)),
        unit: Adaptive(light: Color(hex: 0xB8B8B8), dark: Color(hex: 0x7A766E)),
        track: Adaptive(light: Color(hex: 0xEFEBE1), dark: Color(hex: 0x3A3733)),
        hatch: Adaptive(light: .black.opacity(0.08), dark: .white.opacity(0.08)),
        pillStroke: Adaptive(light: Color(hex: 0xDCD7CB), dark: .white.opacity(0.16)),
        pill: Adaptive(light: Color(hex: 0xF1EDE4), dark: .white.opacity(0.1)),
        columnSelected: Adaptive(light: Color(hex: 0xFFF2EC), dark: Color(hex: 0x3B2B24)),
        columnHover: Adaptive(light: Color(hex: 0xFAF8F3), dark: Color(hex: 0x302E2A)),
        gray: Adaptive(light: Color(hex: 0x808080), dark: Color(hex: 0x9C978E)),
        lightGray: Adaptive(light: Color(hex: 0xCCCCCC), dark: Color(hex: 0x5C5852)),
        line: Adaptive(light: Color(hex: 0xE8E8E8), dark: .white.opacity(0.08)),
        toggleOff: Adaptive(light: Color(hex: 0xDEDBD4), dark: Color(hex: 0x4A4640)),
        tagOff: Adaptive(light: Color(hex: 0xF0F0F0), dark: .white.opacity(0.08)),
        deviceTop: Color(hex: 0xFFFDF7),
        deviceBottom: Color(hex: 0xEEE7D8),
        deviceEdge: Color(hex: 0xDCD3C1),
        deviceShadow: Color(hex: 0x7A5A2A),
        standard: ModeColors(theme: Color(hex: 0xFFA51E),
                             ports: [0x2C89FB, 0xFFC444, 0xFFA51E, 0xFF921E, 0xFF7315].map(Color.init(hex:))),
        sleep: ModeColors(theme: Color(hex: 0x9965C7),
                          ports: [0x4460DD, 0xB787E0, 0x9965C7, 0x7B3FB0, 0x56297E].map(Color.init(hex:))),
        performance: ModeColors(theme: Color(hex: 0xFF7F17),
                                ports: [0x2C89FB, 0xFFC444, 0xFFA51E, 0xFF921E, 0xFF7315].map(Color.init(hex:))),
        singlePort: ModeColors(theme: Color(hex: 0x1DC6FA),
                               ports: [0x46BC2C, 0x71CBE7, 0x22ADEE, 0x0381E1, 0x0058C4].map(Color.init(hex:)))
    )

    /// 冷色：同一个明暗层次，色相挪到蓝灰；端口色也从橙系换成从浅青到深蓝的渐变。
    public static let cool = Theme(
        brand: Color(hex: 0x2F7BF6),
        brandLight: Color(hex: 0x6FA5FF),
        online: Color(hex: 0x10B981),
        danger: Color(hex: 0xE5484D),
        heatModerate: Color(hex: 0xF5A524),
        heatHigh: Color(hex: 0xE8562B),
        canvas: Adaptive(light: Color(hex: 0xF0F4F9), dark: Color(hex: 0x141920)),
        card: Adaptive(light: .white, dark: Color(hex: 0x1E242C)),
        cardStroke: Adaptive(light: .black.opacity(0.03), dark: .white.opacity(0.07)),
        inset: Adaptive(light: Color(hex: 0xF0F4F9), dark: Color(hex: 0x1A2028)),
        ink: Adaptive(light: Color(hex: 0x0F1826), dark: Color(hex: 0xE9EFF7)),
        heading: Adaptive(light: Color(hex: 0x5C6B7D), dark: Color(hex: 0x97A5B6)),
        unit: Adaptive(light: Color(hex: 0xAEBAC9), dark: Color(hex: 0x6B7889)),
        track: Adaptive(light: Color(hex: 0xE4EBF3), dark: Color(hex: 0x2E3742)),
        hatch: Adaptive(light: .black.opacity(0.08), dark: .white.opacity(0.08)),
        pillStroke: Adaptive(light: Color(hex: 0xD2DCE8), dark: .white.opacity(0.16)),
        pill: Adaptive(light: Color(hex: 0xEAF1F9), dark: .white.opacity(0.1)),
        columnSelected: Adaptive(light: Color(hex: 0xE6F1FF), dark: Color(hex: 0x1C2B3F)),
        columnHover: Adaptive(light: Color(hex: 0xF6F9FD), dark: Color(hex: 0x232B34)),
        gray: Adaptive(light: Color(hex: 0x6B7A8C), dark: Color(hex: 0x93A1B2)),
        lightGray: Adaptive(light: Color(hex: 0xC2CCD9), dark: Color(hex: 0x54606D)),
        line: Adaptive(light: Color(hex: 0xE2E8F0), dark: .white.opacity(0.08)),
        toggleOff: Adaptive(light: Color(hex: 0xD7DFE9), dark: Color(hex: 0x3B444F)),
        tagOff: Adaptive(light: Color(hex: 0xEDF1F7), dark: .white.opacity(0.08)),
        deviceTop: Color(hex: 0xF9FBFF),
        deviceBottom: Color(hex: 0xE1E9F4),
        deviceEdge: Color(hex: 0xD2DCE9),
        deviceShadow: Color(hex: 0x2B3B55),
        standard: ModeColors(theme: Color(hex: 0x2F7BF6),
                             ports: [0x5AC8F5, 0x3BA4F0, 0x2F7BF6, 0x255FCC, 0x1B3F94].map(Color.init(hex:))),
        sleep: ModeColors(theme: Color(hex: 0x8B5CF6),
                          ports: [0x4F46E5, 0xA78BFA, 0x8B5CF6, 0x6D28D9, 0x4C1D95].map(Color.init(hex:))),
        performance: ModeColors(theme: Color(hex: 0x1F63E8),
                                ports: [0x5AC8F5, 0x3BA4F0, 0x2F7BF6, 0x255FCC, 0x1B3F94].map(Color.init(hex:))),
        singlePort: ModeColors(theme: Color(hex: 0x16B6E8),
                               ports: [0x22C08A, 0x67D5F0, 0x22B0E0, 0x0D84C9, 0x075A96].map(Color.init(hex:)))
    )
}

/// 把选中的配色存到 app 和小组件都能读到的地方。
/// 正式包有 App Group，写容器里的 `theme.txt`；SwiftPM 调试构建没有，退回标准偏好设置。
public enum ThemeStorage {
    private static let key = "themeMode"
    private static let fileName = "theme.txt"

    nonisolated(unsafe) private static var cached: ThemeMode?

    /// 上次选的配色，没选过是暖色。`forceRefresh` 丢掉缓存重新读盘（小组件用）。
    public static func load(forceRefresh: Bool = false) -> ThemeMode {
        if !forceRefresh, let cached { return cached }
        let mode = read() ?? .warm
        cached = mode
        return mode
    }

    public static func save(_ mode: ThemeMode) {
        cached = mode
        if let url = AppGroup.containerURL?.appendingPathComponent(fileName) {
            try? Data(mode.rawValue.utf8).write(to: url, options: .atomic)
        }
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }

    private static func read() -> ThemeMode? {
        if let url = AppGroup.containerURL?.appendingPathComponent(fileName),
           let text = try? String(contentsOf: url, encoding: .utf8),
           let mode = ThemeMode(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return mode
        }
        return UserDefaults.standard.string(forKey: key).flatMap(ThemeMode.init(rawValue:))
    }
}

/// 当前配色下的颜色。用法和以前一样（`Palette.brand`、`Palette.canvas`…），只是会跟着 `mode` 变。
public enum Palette {
    /// 当前选的是哪套。菜单栏 app 通过 `AppModel.theme` 改它；小组件生成时间线前调 `reload()`。
    nonisolated(unsafe) public private(set) static var mode: ThemeMode = ThemeStorage.load()

    public static var current: Theme { mode == .cool ? .cool : .warm }

    public static var brand: Color { current.brand }
    public static var brandLight: Color { current.brandLight }
    public static var online: Color { current.online }
    public static var danger: Color { current.danger }
    public static var heatModerate: Color { current.heatModerate }
    public static var heatHigh: Color { current.heatHigh }

    /// 面板的底色。
    public static var canvas: Adaptive { current.canvas }
    public static var card: Adaptive { current.card }
    public static var cardStroke: Adaptive { current.cardStroke }
    /// 卡片里的浅底（详情条、表头），和面板底色一个色调。
    public static var inset: Adaptive { current.inset }
    /// 大数字和端口名。
    public static var ink: Adaptive { current.ink }
    /// 卡片外的分组标题（小程序「实时调度」那种灰）。
    public static var heading: Adaptive { current.heading }
    /// 数字后面的单位。
    public static var unit: Adaptive { current.unit }
    /// 功率柱的底槽、关闭的开关。
    public static var track: Adaptive { current.track }
    public static var hatch: Adaptive { current.hatch }
    public static var pillStroke: Adaptive { current.pillStroke }
    public static var pill: Adaptive { current.pill }
    public static var columnSelected: Adaptive { current.columnSelected }
    public static var columnHover: Adaptive { current.columnHover }

    /// 「调节」页画的小电拼机身。
    public static var deviceTop: Color { current.deviceTop }
    public static var deviceBottom: Color { current.deviceBottom }
    public static var deviceEdge: Color { current.deviceEdge }
    public static var deviceShadow: Color { current.deviceShadow }

    /// 只在离屏截图时垫在面板下面。
    public static var snapshotBackdrop: Adaptive { current.canvas }

    /// 换一套配色。`persist` 为真时写盘，小组件下次生成时间线时读到。
    public static func apply(_ newMode: ThemeMode, persist: Bool = true) {
        guard mode != newMode || !persist else { return }
        mode = newMode
        if persist { ThemeStorage.save(newMode) }
    }

    /// 重新读盘（小组件在生成时间线前调用，别的进程可能刚刚改过）。
    public static func reload() {
        mode = ThemeStorage.load(forceRefresh: true)
    }
}

/// 每个场景模式的主题色和五个口的配色（A、C1…C4）。
/// 魔拟充和临时分配在小程序里用的是默认（自由流）的配色。
public struct ModeColors: Sendable {
    public let theme: Color
    public let ports: [Color]

    public init(theme: Color, ports: [Color]) {
        self.theme = theme
        self.ports = ports
    }

    // 跟着当前配色走：暖色是原来那套橙/紫/青，冷色换成本文件 `Theme.cool` 里的冷色系。
    public static var standard: ModeColors { Palette.current.standard }
    public static var sleep: ModeColors { Palette.current.sleep }
    public static var performance: ModeColors { Palette.current.performance }
    public static var singlePort: ModeColors { Palette.current.singlePort }

    public static func of(_ strategy: ChargingStrategy?) -> ModeColors {
        switch strategy {
        case .slow: return .sleep
        case .highPerformance: return .performance
        case .ultraFastSinglePort: return .singlePort
        case .fast, .usbA, nil: return .standard
        }
    }

    public func port(_ index: Int) -> Color {
        ports.isEmpty ? theme : ports[min(max(index, 0), ports.count - 1)]
    }
}

public extension ChargingStrategy {
    /// 小程序「模式」页的图标，换成意思相近的 SF Symbols。
    var symbol: String {
        switch self {
        case .fast: return "fanblades"
        case .slow: return "moon.zzz"
        case .usbA: return "arrow.triangle.2.circlepath"
        case .highPerformance: return "gauge.with.dots.needle.67percent"
        case .ultraFastSinglePort: return "arrow.right.circle"
        }
    }
}

public extension TemperatureMode {
    /// 小程序里的叫法：功率优先 = 性能温控（更高效能），温度优先 = 安心温控（更少发热）。
    var displayName: String {
        switch self {
        case .powerFirst: return "性能温控"
        case .temperatureFirst: return "安心温控"
        }
    }

    var detail: String {
        switch self {
        case .powerFirst: return "更高效能"
        case .temperatureFirst: return "更少发热"
        }
    }

    var symbol: String {
        switch self {
        case .powerFirst: return "thermometer.high"
        case .temperatureFirst: return "thermometer.low"
        }
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// 按浅色 / 深色外观取颜色。用 SwiftUI 环境判断，离屏渲染时指定 colorScheme 也能生效。
public struct Adaptive: ShapeStyle, Sendable {
    public let light: Color
    public let dark: Color

    public init(light: Color, dark: Color) {
        self.light = light
        self.dark = dark
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? dark : light
    }
}

/// 面板里数字和文字的格式。
public enum PanelFormat {
    /// 功率数字（单位另外显示）：100 W 以下保留一位小数。
    public static func watts(_ value: Double) -> String {
        value >= 99.95 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// 电压：接近整数时不带小数（20V、5V），PPS 这类可调电压保留一位（9.1V）。
    public static func volts(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.15 ? String(format: "%.0fV", value) : String(format: "%.1fV", value)
    }

    public static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(minutes, 1)) 分钟" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(rest) 分"
    }

    /// 端口柱旁边放得下的快充协议简称（全称见 `FastChargeProtocol.name`）。
    public static func shortProtocol(_ code: Int) -> String {
        switch code {
        case 0: return "USB"
        case 1: return "QC2"
        case 2: return "QC3"
        case 3: return "QC3+"
        case 4: return "SFCP"
        case 5: return "AFC"
        case 6: return "FCP"
        case 7: return "SCP"
        case 8, 9: return "VOOC"
        case 10: return "SVOOC"
        case 11: return "TFCP"
        case 12: return "UFCS"
        case 13, 14: return "PE"
        case 15, 16: return "PD"
        case 17, 20: return "AVS"
        case 18, 21: return "PPS"
        case 19: return "EPR"
        default: return ""
        }
    }
}

public extension PortMetrics {
    /// 柱子旁边、快捷指令里用的协议简称；云端给的协议认不出编号时用原文。
    var shortProtocol: String { protocolText ?? PanelFormat.shortProtocol(fcProtocol) }
}

public extension WidgetSnapshot.Port {
    var shortProtocol: String { protocolText ?? PanelFormat.shortProtocol(fcProtocol) }
}

/// 在线状态的小胶囊：在线是绿底白字（小程序首页的「在线」），连接中和离线是灰的。
public struct StatusBadge: View {
    public enum Status: Sendable {
        case online, connecting, offline
    }

    public let status: Status
    public var text: String?

    public init(status: Status, text: String? = nil) {
        self.status = status
        self.text = text
    }

    public var body: some View {
        Text(text ?? defaultText)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(status == .online ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(Capsule().fill(status == .online ? AnyShapeStyle(Palette.online) : AnyShapeStyle(Palette.track)))
            .lineLimit(1)
            .fixedSize()
            .animation(.easeInOut(duration: 0.25), value: status)
    }

    private var defaultText: String {
        switch status {
        case .online: return "在线"
        case .connecting: return "连接中"
        case .offline: return "离线"
        }
    }
}

/// 芯片温度：前面一个按档位着色的圆点（凉爽绿、温和黄、偏热橙红、过热红，不认识的档位灰色）。
public struct TemperatureLabel: View {
    public let temperature: PortTemperature
    public var size: CGFloat = 12

    public init(temperature: PortTemperature, size: CGFloat = 12) {
        self.temperature = temperature
        self.size = size
    }

    public static func color(_ temperature: PortTemperature) -> Color {
        switch temperature.level {
        case 0: return Palette.online
        // 温和、偏热用固定的暖色：这两档说的是温度，不能跟着强调色变成蓝的
        case 1: return Palette.heatModerate
        case 2: return Palette.heatHigh
        case 3: return Palette.danger
        default: return .secondary
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Self.color(temperature))
                .frame(width: size * 0.45, height: size * 0.45)
            Text(temperature.label)
                .font(.system(size: size))
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("芯片温度\(temperature.label)")
    }
}

/// 品牌色的开关外形（小程序「实时调度」里的橙色开关）。面板的开关和小组件的开关按钮共用。
public struct SwitchCapsule: View {
    public let isOn: Bool
    public var size: CGFloat = 1

    public init(isOn: Bool, size: CGFloat = 1) {
        self.isOn = isOn
        self.size = size
    }

    public var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Palette.brand) : AnyShapeStyle(Palette.track))
            .frame(width: 30 * size, height: 17 * size)
            .overlay(alignment: isOn ? .trailing : .leading) {
                // 圆点定死尺寸，左右对齐才有位移
                Circle()
                    .fill(.white)
                    .frame(width: 13 * size, height: 13 * size)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(2 * size)
            }
    }
}

/// 斜线底纹（小程序里空闲端口的柱子）。
public struct Hatch: Shape {
    public var spacing: CGFloat = 3

    public init(spacing: CGFloat = 3) {
        self.spacing = spacing
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
