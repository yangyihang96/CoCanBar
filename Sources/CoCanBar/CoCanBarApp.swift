import SwiftUI
import CoCanKit
import CoCanStyle

@main
struct CoCanBarApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        // 调试用：`--theme warm|cool` 指定这次用哪套配色（不写盘）
        PanelSnapshots.applyThemeArgument()
        // 调试用：`CoCanBar --snapshot <目录>` 离屏渲染面板截图后退出；
        // `CoCanBar --demo <场景号> [--demo-window]` 用演示数据跑真实的面板（可另开一个普通窗口显示）；
        // `CoCanBar --live-window` 用真实设备的数据把面板放进普通窗口
        if PanelSnapshots.runIfRequested() { exit(0) }
        let demo = PanelSnapshots.demoModelIfRequested()
        if demo != nil || PanelSnapshots.liveWindowRequested {
            let model = demo ?? AppModel()
            _model = State(initialValue: model)
            PanelSnapshots.showDemoWindowIfRequested(model: model)
            PanelSnapshots.showDemoSettingsIfRequested(model: model)
            PanelSnapshots.captureDemoWindowsIfRequested()
            return
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// 菜单栏上的那颗糖和总功率，画成固定宽度的模板图（见 `MenuBarIcon`）。
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(nsImage: MenuBarIcon.image(title: model.menuBarTitle, online: model.anyOnline))
            .renderingMode(.template)
    }
}
