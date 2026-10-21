import Foundation

public enum LANError: Error, LocalizedError, Sendable, Equatable {
    case unresolved(String)
    case http(Int)
    case network(String)
    case decoding(String)
    case wrongDevice(String)

    public var errorDescription: String? {
        switch self {
        case .unresolved(let host): return "找不到 \(host)"
        case .http(let code): return "设备返回 HTTP \(code)"
        case .network(let message): return message
        case .decoding(let message): return "读数格式不对：\(message)"
        case .wrongDevice(let psn): return "这个地址上是另一台设备（PSN \(psn)）"
        }
    }
}

/// 读局域网接口：`GET /metrics.json`（实时读数）和 `GET /`（设备信息）。两个接口都不需要鉴权。
public struct LANClient: Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 4) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func metrics(ip: String) async throws -> DeviceMetrics {
        let data = try await get(ip: ip, path: "/metrics.json")
        do {
            return try CandySignDriver.decodeMetrics(data)
        } catch {
            throw LANError.decoding(String(describing: error).prefix(160).description)
        }
    }

    public func info(ip: String) async throws -> DeviceInfo {
        let data = try await get(ip: ip, path: "/")
        guard let html = String(data: data, encoding: .utf8), let info = DeviceInfo.parse(html: html) else {
            throw LANError.decoding("首页里没有 window.__INFOZ")
        }
        return info
    }

    /// 读一次指定设备：先解析主机名（失败时试上次核对过的 IP），每次都用首页里的 PSN 核对，再读实时数据。
    /// 小组件在菜单栏 app 没运行时用。app 自己的轮询会缓存 IP、每分钟核对一次，见 `AppModel.refresh`。
    public func verifiedMetrics(psn: String, host: String, knownIP: String? = nil) async throws -> DeviceMetrics {
        var addresses: [String] = []
        if let ip = await HostResolver.resolveIPv4(host) { addresses.append(ip) }
        if let knownIP, HostResolver.isIPv4Literal(knownIP), !addresses.contains(knownIP) { addresses.append(knownIP) }
        var failure: Error = LANError.unresolved(host)
        for ip in addresses {
            do {
                do {
                    let info = try await info(ip: ip)
                    if let found = info.psn, found != psn { throw LANError.wrongDevice(found) }
                } catch LANError.decoding {
                    // 首页格式变了、核对不了 PSN 时不拦读数（和 app 一样）
                }
                return try await metrics(ip: ip)
            } catch {
                failure = error
            }
        }
        throw failure
    }

    private func get(ip: String, path: String) async throws -> Data {
        guard HostResolver.isIPv4Literal(ip), let url = URL(string: "http://\(ip)\(path)") else {
            throw LANError.network("地址无效：\(ip)")
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw LANError.network("设备没有响应") }
            guard http.statusCode == 200 else { throw LANError.http(http.statusCode) }
            return data
        } catch let error as LANError {
            throw error
        } catch let error as URLError {
            throw LANError.network(NetworkErrorText.describe(error))
        } catch {
            throw LANError.network("网络错误")
        }
    }
}

/// URLError 转成不含地址的中文说明（MCP 地址里有 token，绝不能出现在错误信息里）。
public enum NetworkErrorText {
    public static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: return "请求超时"
        case .notConnectedToInternet: return "没有网络连接（如果系统弹出“本地网络”权限，请点允许）"
        case .cannotFindHost, .dnsLookupFailed: return "找不到服务器"
        case .cannotConnectToHost: return "连不上设备"
        case .networkConnectionLost: return "网络连接中断"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "TLS 连接失败"
        case .cancelled: return "请求已取消"
        case .appTransportSecurityRequiresSecureConnection: return "被 ATS 拦截（需要允许本地网络 HTTP）"
        default: return "网络错误（\(error.code.rawValue)）"
        }
    }
}
