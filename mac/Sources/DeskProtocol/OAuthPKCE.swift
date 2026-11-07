import CryptoKit
import Foundation

/// RFC 7636 §4.2 的 S256 与 RFC 8252 §7.3 loopback、§7.1 App 私有回调校验。
public enum OAuthPKCE {
    public static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func random() -> String {
        var rng = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }))
    }

    /// RFC 4648 §5 without padding (also the factory cert encoding DMS iotcoreprovision expects).
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}

public enum OAuthCallback {
    public static func code(from url: URL, redirect: URL, state: String, issuer: URL? = nil) throws -> String {
        // loopback 只认 127.0.0.1；私有 scheme（com.yaha.desk.ios:/oauth）不带 host。
        guard url.scheme == redirect.scheme, url.host == (url.scheme == "http" ? "127.0.0.1" : nil), url.host == redirect.host,
              url.port == redirect.port, url.path == redirect.path, url.user == nil, url.password == nil,
              url.fragment == nil, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw DeskProtocolError("授权回调地址不匹配") }
        let items = parts.queryItems ?? []
        for key in ["code", "state", "error", "iss"] where items.filter({ $0.name == key }).count > 1 {
            throw DeskProtocolError("授权回调包含重复参数")
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw DeskProtocolError("授权状态不匹配")
        }
        if let issuer {
            guard let returned = items.first(where: { $0.name == "iss" })?.value,
                  returned.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                    issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            else { throw DeskProtocolError("授权服务来源不匹配") }
        }
        if items.contains(where: { $0.name == "error" }) { throw OAuthCallbackError.denied }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw DeskProtocolError("授权未完成或已拒绝") }
        return code
    }
}

public enum OAuthCallbackError: LocalizedError {
    case denied
    public var errorDescription: String? { "授权已拒绝或取消" }
}
