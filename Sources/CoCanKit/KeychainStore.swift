import Foundation
import Security

public enum KeychainError: Error, LocalizedError, Sendable {
    case status(OSStatus)
    case encoding

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
            return "钥匙串错误 \(status)\(message.isEmpty ? "" : "：\(message)")"
        case .encoding:
            return "钥匙串数据编码失败"
        }
    }
}

/// 把每台设备的 MCP 地址（含 token）存在登录钥匙串的通用密码项里。
/// 小电拼的 account 仍是裸 PSN。读取时按 `ChargerID.lookupKeys` 先试旧键，再试 `candysign:<PSN>`。
public struct KeychainStore: Sendable {
    public static let defaultService = "com.local.CoCanBar.mcp"
    public let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ secret: String, account: String, label: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.encoding }
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    /// 只查是否存在，不读密码内容（不会触发钥匙串授权弹窗）。
    public func exists(account: String) -> Bool {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    /// 先读存盘用的旧键（小电拼是裸 PSN），没有再读带驱动前缀的键。
    public func read(charger id: ChargerID) throws -> String? {
        for key in id.lookupKeys {
            if let value = try read(account: key) { return value }
        }
        return nil
    }

    public func exists(charger id: ChargerID) -> Bool {
        for key in id.lookupKeys where exists(account: key) { return true }
        return false
    }

    /// 旧键和新键都删。不存在的项不算失败。
    public func delete(charger id: ChargerID) throws {
        for key in id.lookupKeys {
            try delete(account: key)
        }
    }
}
