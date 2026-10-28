import SwiftUI
import CoCanKit
import CoCanStyle

/// 「调节」页的功率图：上面一排端口卡，每个口一根线连到右下角画的小电拼。
/// 线是橙色表示开着（充电时加一道白色虚线），灰色表示关着或开关状态未知。
/// 设备离线时显示的是上次的读数，整张图画成灰色（不用滤镜：离屏截图画不出 `saturation`）。
/// 样子照 KangCharge 的主窗口（那张图来自官方 App），不做动画。
struct PowerDiagram: View {
    let ports: [PortMetrics]
    /// 每口上限（W），按端口顺序；关着的口在卡片下半格显示。
    let limits: [Int]
    /// 读数是不是实时的。
    var live = true

    var body: some View {
        GeometryReader { proxy in
            // 还没读到端口时，机身照每口上限的个数画口
            let layout = DiagramLayout(size: proxy.size, count: ports.count, slotCount: max(ports.count, limits.count))
            ZStack(alignment: .topLeading) {
                ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                    let cable = layout.cable(index)
                    cable.stroke(cableColor(port), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    if live, port.isCharging {
                        cable.stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, dash: [2, 14]))
                    }
                }
                ChargerDrawing(slots: layout.slots, total: ports.isEmpty ? nil : ports.reduce(0) { $0 + $1.watts }, live: live)
                    .frame(width: layout.charger.width, height: layout.charger.height)
                    .offset(x: layout.charger.minX, y: layout.charger.minY)
                ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                    let frame = layout.chip(index)
                    PortChip(port: port, limit: limits.indices.contains(port.id) ? limits[port.id] : nil, live: live)
                        .frame(width: frame.width)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
    }

    private func cableColor(_ port: PortMetrics) -> AnyShapeStyle {
        guard port.isPoweredOn == true else { return AnyShapeStyle(SettingsStyle.pillStroke) }
        guard live else { return AnyShapeStyle(SettingsStyle.lightGray) }
        return AnyShapeStyle(SettingsStyle.orange.opacity(port.isCharging ? 1 : 0.75))
    }
}

/// 端口卡：上面是端口名，框里是功率，分隔线下面是协议（关着时是该口上限）。
private struct PortChip: View {
    let port: PortMetrics
    let limit: Int?
    let live: Bool

    private var on: Bool { port.isPoweredOn == true }
    private var accent: AnyShapeStyle { on && live ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(SettingsStyle.lightGray) }
    private var text: AnyShapeStyle { on && live ? AnyShapeStyle(SettingsStyle.ink) : AnyShapeStyle(SettingsStyle.gray) }

    var body: some View {
        let name = PortNaming.name(index: port.id)
        VStack(spacing: 3) {
            Text(port.id == 0 ? "USB-A" : name)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(text)
            VStack(spacing: 0) {
                Text(power)
                    .font(.system(size: 16, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.vertical, 5)
                Rectangle()
                    .fill(accent)
                    .opacity(0.6)
                    .frame(height: 1)
                Text(detail)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(text)
                    .lineLimit(1)
                    .padding(.vertical, 3)
            }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsStyle.card))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(accent, lineWidth: 1.5))
        }
        .help("\(name)：\(port.protocolName)")
    }

    private var power: String {
        switch port.isPoweredOn {
        case true?: return PanelFormat.watts(port.watts) + "W"
        case false?: return "OFF"
        case nil: return "—"
        }
    }

    private var detail: String {
        if on, port.attached {
            let name = port.shortProtocol
            if !name.isEmpty { return name }
            return port.isCharging ? "—" : "未取电"
        }
        if on { return "空闲" }
        return limit.map { "\($0)W" } ?? "—"
    }
}

/// 画的小电拼：机身和产品一样是浅色，左上一块小屏显示总功率，下面一排口（A 口宽一点）。
/// 机身颜色跟着配色走（暖色是奶油白，冷色是冷白）。
private struct ChargerDrawing: View {
    /// 各口在机身上的位置（相对机身左上角）。
    let slots: [CGRect]
    /// 还没读到端口时为 nil，屏上显示「—」。
    let total: Double?
    let live: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Palette.deviceTop, Palette.deviceBottom],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Palette.deviceEdge, lineWidth: 1))
                .shadow(color: Palette.deviceShadow.opacity(0.16), radius: 14, y: 9)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hex: 0x121212))
                .frame(width: 58, height: 25)
                .overlay {
                    Text(total.map { "\(Int($0.rounded()))W" } ?? "—")
                        .font(.system(size: 12.5, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(live ? AnyShapeStyle(SettingsStyle.orange) : AnyShapeStyle(Color(hex: 0x8A8A8A)))
                }
                .offset(x: 22, y: 22)
            ForEach(slots.indices, id: \.self) { index in
                let slot = slots[index]
                RoundedRectangle(cornerRadius: index == 0 ? 2 : 4.5, style: .continuous)
                    .fill(Color(hex: 0x121212).opacity(0.82))
                    .frame(width: slot.width, height: slot.height)
                    .offset(x: slot.minX, y: slot.minY)
            }
        }
    }
}

/// 端口卡排在顶上居中，机身在右下角，线从卡片底边弯到机身上对应的口。
private struct DiagramLayout {
    let size: CGSize
    let count: Int
    /// 机身上画几个口（不少于端口数）。
    let slotCount: Int

    static let gap: CGFloat = 10
    static let chipHeight: CGFloat = 66
    static let chargerSize = CGSize(width: 212, height: 110)

    var chipWidth: CGFloat {
        guard count > 0 else { return 0 }
        return min((size.width - Self.gap * CGFloat(count - 1)) / CGFloat(count), 100)
    }

    func chip(_ index: Int) -> CGRect {
        let row = chipWidth * CGFloat(count) + Self.gap * CGFloat(max(count - 1, 0))
        let x = (size.width - row) / 2 + CGFloat(index) * (chipWidth + Self.gap)
        return CGRect(x: x, y: 0, width: chipWidth, height: Self.chipHeight)
    }

    var charger: CGRect {
        CGRect(x: size.width - Self.chargerSize.width - 4, y: size.height - Self.chargerSize.height - 4,
               width: Self.chargerSize.width, height: Self.chargerSize.height)
    }

    var slots: [CGRect] {
        var x: CGFloat = 22
        return (0..<slotCount).map { index in
            let width: CGFloat = index == 0 ? 26 : 19
            defer { x += width + 11 }
            return CGRect(x: x, y: 70, width: width, height: 9)
        }
    }

    func cable(_ index: Int) -> Path {
        let chip = chip(index)
        let slot = slots[index]
        let start = CGPoint(x: chip.midX, y: chip.maxY - 4)
        let end = CGPoint(x: charger.minX + slot.midX, y: charger.minY + slot.midY)
        let rise = end.y - start.y
        return Path { path in
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x, y: start.y + rise * 0.6),
                          control2: CGPoint(x: end.x, y: end.y - rise * 0.55))
        }
    }
}
