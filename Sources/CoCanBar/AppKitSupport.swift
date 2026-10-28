import SwiftUI
import AppKit

/// 报告所在窗口是否在屏幕上。MenuBarExtra 的面板关上后窗口只是隐藏，
/// SwiftUI 不一定发 onDisappear，所以直接看窗口的可见状态和遮挡状态。
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityProbeView {
        let view = VisibilityProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityProbeView, context: Context) {
        view.onChange = onChange
    }
}

final class VisibilityProbeView: NSView {
    var onChange: ((Bool) -> Void)?
    private var reported: Bool?

    private static let notifications: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
    ]

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard let window else { return }
        for name in Self.notifications {
            NotificationCenter.default.removeObserver(self, name: name, object: window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            for name in Self.notifications {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
            }
        }
        update()
    }

    @objc private func windowChanged(_ notification: Notification) {
        update()
        // 面板失去焦点后才被收起，过一会儿再看一次，不只靠遮挡通知
        if notification.name == NSWindow.didResignKeyNotification {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.update()
            }
        }
    }

    private func update() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        guard visible != reported else { return }
        reported = visible
        appLog.debug("面板可见：\(visible, privacy: .public)")
        // 推迟到下一轮再改 SwiftUI 状态，避免在视图更新过程中修改
        Task { @MainActor [weak self] in
            self?.onChange?(visible)
        }
    }
}

/// 菜单栏标签画成一张固定宽度的模板图：制糖工厂那颗糖加等宽数字的总功率。
/// 宽度只按几种最宽的写法算，和当前读数无关，读数变化时菜单栏图标不会左右挪；模板图由系统按深浅色着色。
enum MenuBarIcon {
    /// `AppModel.format(watts:)` 可能给出的最宽写法（等宽数字下 8 和其他数字一样宽）。
    static let widthSamples = ["88.8", "999", "1.2k", "—"]

    static func image(title: String, online: Bool) -> NSImage {
        let fontSize = NSFont.menuBarFont(ofSize: 0).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let textWidth = ceil(widthSamples.map { Self.textWidth($0, font: font) }.max() ?? 0)
        let candy = candySize(fontSize: fontSize)
        let lineHeight = ceil(font.ascender - font.descender)
        let size = NSSize(width: candy.width + 3 + textWidth, height: max(lineHeight, candy.height))
        // 没有数字（离线时的“—”）就居中，有数字就右对齐
        let centered = !title.contains(where: \.isNumber)
        let image = NSImage(size: size, flipped: false) { rect in
            if let context = NSGraphicsContext.current?.cgContext {
                CandyMark.draw(in: context,
                               rect: NSRect(x: 0, y: ((rect.height - candy.height) / 2).rounded(),
                                            width: candy.width, height: candy.height),
                               filled: online)
            }
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let width = (title as NSString).size(withAttributes: attributes).width
            let x = centered ? rect.width - textWidth + (textWidth - width) / 2 : rect.width - width
            let y = ((rect.height - (font.ascender - font.descender)) / 2).rounded()
            (title as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        // 界面上省掉单位，读屏时补回来
        image.accessibilityDescription = online ? "小电拼 \(title) 瓦" : "小电拼 未连接"
        return image
    }

    /// 菜单栏里那颗糖占的尺寸：高跟字高差不多，宽按标志的固定比例，在线离线一样大。
    private static func candySize(fontSize: CGFloat) -> NSSize {
        let height = (fontSize * 0.85).rounded()
        return NSSize(width: (height * CandyMark.aspectRatio).rounded(), height: height)
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// 在 SwiftUI 按钮下面弹出 AppKit 菜单用的锚点：记住按钮所在的 NSView。
/// 系统 Menu 控件会盖住、裁掉自绘胶囊的两头，所以按钮整个用 SwiftUI 画，菜单另外弹。
@MainActor
final class MenuAnchorHolder {
    weak var view: NSView?
    /// 最近弹出的菜单。菜单项的 target 是弱引用，留住它，选中后的动作才一定发得出去。
    var menu: ClosureMenu?
}

struct MenuAnchor: NSViewRepresentable {
    let holder: MenuAnchorHolder

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        holder.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        holder.view = view
    }

    /// 只当坐标参照，不接收点击。
    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 用闭包当动作的 NSMenu。菜单是同步弹出的，弹出期间这个对象由调用方持有。
@MainActor
final class ClosureMenu: NSObject {
    let menu = NSMenu()
    private var actions: [() -> Void] = []
    private var children: [ClosureMenu] = []

    override init() {
        super.init()
        menu.autoenablesItems = false
    }

    func section(_ title: String) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(.sectionHeader(title: title))
    }

    func separator() {
        menu.addItem(.separator())
    }

    /// `detail` 在 macOS 14.4 起显示成标题下面的灰色副标题，更早的系统接在标题后面的括号里。
    /// `symbol` 是 SF Symbols 名称，画在标题左边。
    func item(_ title: String, detail: String? = nil, symbol: String? = nil, checked: Bool = false,
              enabled: Bool = true, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        decorate(item, detail: detail, symbol: symbol)
        item.target = self
        item.tag = actions.count
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        actions.append(action)
        menu.addItem(item)
    }

    /// 带子菜单的一项，子菜单里的选项在 `build` 里照常添加。
    func submenu(_ title: String, detail: String? = nil, symbol: String? = nil, build: (ClosureMenu) -> Void) {
        let child = ClosureMenu()
        build(child)
        children.append(child)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        decorate(item, detail: detail, symbol: symbol)
        item.submenu = child.menu
        menu.addItem(item)
    }

    private func decorate(_ item: NSMenuItem, detail: String?, symbol: String?) {
        if let detail {
            if #available(macOS 14.4, *) {
                item.subtitle = detail
            } else {
                item.title = "\(item.title)（\(detail)）"
            }
        }
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    /// 灰色的说明行。
    func note(_ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    /// 在锚点视图正下方弹出，左边对齐。
    func popUp(below view: NSView) {
        let y = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
