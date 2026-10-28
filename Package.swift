// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoCanBar",
    platforms: [.macOS(.v14)],
    targets: [
        // 网络、协议、钥匙串等与界面无关的部分
        .target(name: "CoCanKit"),
        // 面板和桌面小组件共用的配色、格式和小部件（SwiftUI）
        .target(name: "CoCanStyle", dependencies: ["CoCanKit"]),
        // 菜单栏 app。日常开发和离屏截图用这里的调试构建；正式的 .app 由 Xcode 工程打包（scripts/build-app.sh）
        .executableTarget(name: "CoCanBar", dependencies: ["CoCanKit", "CoCanStyle"]),
        // 桌面小组件。SwiftPM 构建出来的是离屏截图工具（swift run CoCanBarWidget <目录>）；真正的扩展由 Xcode 工程打包
        .executableTarget(name: "CoCanBarWidget", dependencies: ["CoCanKit", "CoCanStyle"]),
        // 命令行自检工具：不开界面验证局域网读数和 MCP 只读调用
        .executableTarget(name: "cocan-probe", dependencies: ["CoCanKit"]),
        .testTarget(name: "CoCanKitTests", dependencies: ["CoCanKit", "CoCanStyle"]),
    ]
)
