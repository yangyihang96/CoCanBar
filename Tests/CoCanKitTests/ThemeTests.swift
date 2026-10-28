import AppKit
import SwiftUI
import XCTest
@testable import CoCanStyle

/// 两套配色（暖色 / 冷色）的约定：该跟着换的换，不该跟着换的不许换。
final class ThemeTests: XCTestCase {
    override func tearDown() {
        // 存档测试会写偏好设置，跑完还原成默认的暖色，免得影响别的测试
        ThemeStorage.save(.warm)
    }

    /// 把 `Color` 摊成 sRGB 分量，好逐位比较。SwiftUI 的 `Color` 本身不相等可比。
    private func rgb(_ color: Color) throws -> [CGFloat] {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            throw XCTSkip("这个颜色没法转成 sRGB")
        }
        return [converted.redComponent, converted.greenComponent, converted.blueComponent, converted.alphaComponent]
    }

    private func hsb(_ color: Color) throws -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            throw XCTSkip("这个颜色没法转成 sRGB")
        }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        converted.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness)
    }

    /// 色相环上的最短距离，0…0.5。
    private func hueGap(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let distance = abs(a - b)
        return min(distance, 1 - distance)
    }

    func testAccentColorFollowsTheme() throws {
        XCTAssertNotEqual(try rgb(Theme.warm.brand), try rgb(Theme.cool.brand), "换配色后强调色应该跟着换")
        XCTAssertNotEqual(try rgb(Theme.warm.canvas.light), try rgb(Theme.cool.canvas.light), "底色也要换")
        XCTAssertNotEqual(try rgb(Theme.warm.canvas.dark), try rgb(Theme.cool.canvas.dark), "深色外观同样要换")
    }

    func testModeColorsFollowTheme() throws {
        for (warm, cool) in [(Theme.warm.standard, Theme.cool.standard),
                             (Theme.warm.sleep, Theme.cool.sleep),
                             (Theme.warm.performance, Theme.cool.performance),
                             (Theme.warm.singlePort, Theme.cool.singlePort)] {
            XCTAssertNotEqual(try rgb(warm.theme), try rgb(cool.theme))
            XCTAssertEqual(warm.ports.count, 5, "A、C1…C4 五个口")
            XCTAssertEqual(cool.ports.count, 5)
        }
    }

    /// 温度、在线、危险是状态色：允许跟着底色微调明度饱和，但色相必须留着。
    /// 温度从凉到热是绿-黄-红，跟着强调色挪成蓝色会看着像「凉快」。
    func testStatusColorsKeepTheirHue() throws {
        let pairs: [(String, Color, Color)] = [
            ("在线", Theme.warm.online, Theme.cool.online),
            ("危险", Theme.warm.danger, Theme.cool.danger),
            ("偏热", Theme.warm.heatModerate, Theme.cool.heatModerate),
            ("过热", Theme.warm.heatHigh, Theme.cool.heatHigh),
        ]
        for (name, warm, cool) in pairs {
            let gap = hueGap(try hsb(warm).hue, try hsb(cool).hue)
            XCTAssertLessThan(gap, 0.12, "\(name) 换配色后色相跑偏了，状态色不能跟着强调色走")
        }
    }

    /// 冷色的强调色是蓝的，状态色得离它远一点，别读成同一种色。
    func testCoolStatusColorsStayAwayFromAccent() throws {
        let accent = try hsb(Theme.cool.brand).hue
        let statuses: [(String, Color)] = [
            ("在线", Theme.cool.online),
            ("危险", Theme.cool.danger),
            ("偏热", Theme.cool.heatModerate),
            ("过热", Theme.cool.heatHigh),
        ]
        for (name, color) in statuses {
            let gap = hueGap(accent, try hsb(color).hue)
            XCTAssertGreaterThan(gap, 0.10, "\(name) 的色相太接近冷色的强调蓝了")
        }
    }

    func testThemeStorageRoundTrip() {
        XCTAssertEqual(ThemeMode.allCases.map(\.rawValue), ["warm", "cool"], "存档格式变了会让老用户的选择丢失")

        ThemeStorage.save(.cool)
        XCTAssertEqual(ThemeStorage.load(forceRefresh: true), .cool)

        ThemeStorage.save(.warm)
        XCTAssertEqual(ThemeStorage.load(forceRefresh: true), .warm)
    }

    func testUnknownStoredValueFallsBackToWarm() {
        // 没存过、或者是别的版本写进去的值，都应该回到暖色，不能崩
        UserDefaults.standard.set("没有这个配色", forKey: "themeMode")
        XCTAssertEqual(ThemeStorage.load(forceRefresh: true), .warm)
    }
}
