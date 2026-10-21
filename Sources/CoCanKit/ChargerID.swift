import Foundation

/// 一台充电器在本 app 里的身份：`<驱动>:<本地编号>`，例如 `candysign:1350…`。
///
/// 2026-10 之前只有小电拼，存盘、小组件、快捷指令和钥匙串都用裸 PSN。
/// 裸字符串（没有合法的驱动前缀）一律当成 `candysign`。查找时先试存盘用的旧键，再试带前缀的新键。
public struct ChargerID: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let candySign = "candysign"

    /// 驱动名，小写，例如 `candysign`。还没实现的品牌也可以先写在身份里。
    public var driver: String
    /// 驱动自己的编号。小电拼是 PSN；以后的蓝牙设备可以带冒号（MAC）。
    public var localID: String

    public init(driver: String = ChargerID.candySign, localID: String) {
        self.driver = driver
        self.localID = localID
    }

    /// 解析存下来的键。没有驱动前缀、或者前缀不像驱动名时，整段都是小电拼的本地编号。
    public init(storedKey: String) {
        if let colon = storedKey.firstIndex(of: ":") {
            let prefix = String(storedKey[..<colon])
            let local = String(storedKey[storedKey.index(after: colon)...])
            if !local.isEmpty, Self.isDriverToken(prefix) {
                driver = prefix
                localID = local
                return
            }
        }
        driver = Self.candySign
        localID = storedKey
    }

    /// `candysign:1350…`。本地编号里还可以再有冒号。
    public var namespaced: String { "\(driver):\(localID)" }

    /// 写进现有存储时用的键。小电拼继续用裸 PSN，这样旧配置、小组件和钥匙串不用搬。
    public var legacyStorageKey: String {
        driver == Self.candySign ? localID : namespaced
    }

    /// 查找顺序：先旧键（小电拼的裸 PSN，钥匙串里现成的那条），再带前缀的键。
    /// 先查得到的那条就停，避免为了不存在的新键再问一次钥匙串。
    public var lookupKeys: [String] {
        var keys: [String] = []
        func add(_ key: String) {
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        add(legacyStorageKey)
        add(namespaced)
        return keys
    }

    /// 小组件直读文件名。只允许数字和字母，所以小电拼仍是 `lan/<PSN>.json`。
    public var directReadingToken: String? {
        for candidate in [legacyStorageKey, localID] where Self.isFileToken(candidate) {
            return candidate
        }
        return nil
    }

    public func matches(storedKey other: String) -> Bool {
        self == ChargerID(storedKey: other)
    }

    public var description: String { namespaced }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(storedKey: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(namespaced)
    }

    /// 驱动名：2–32 个字符，小写字母开头，后面是小写字母、数字、`-` 或 `_`。
    /// 大写开头的（例如裸 MAC `AA:BB:…`）不当成驱动前缀。
    public static func isDriverToken(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard (2...32).contains(scalars.count), let first = scalars.first, isASCIILowercase(first) else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            isASCIILowercase(scalar) || isASCIIDigit(scalar) || scalar.value == 45 || scalar.value == 95
        }
    }

    private static func isASCIILowercase(_ scalar: Unicode.Scalar) -> Bool {
        (97...122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    public static func isFileToken(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
