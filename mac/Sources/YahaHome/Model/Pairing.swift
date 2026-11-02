import Foundation
import Security
import YahamicProtocol

/// 配对码:App 与设备配网页共用的共享密钥(协议 v2 由它派生会话密钥)。
/// 存在登录钥匙串里,不进 UserDefaults(plist 明文、可被别的进程读)。
enum Pairing {
    private static let service = "com.yaha.home.pairing"
    private static let account = "yahamic"
    // 去掉易混字符 0/O、1/I/L,方便在手机配网页上照抄。
    private static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")

    static func isValid(_ code: String) -> Bool {
        (SessionCrypto.minCodeLength...SessionCrypto.maxCodeLength).contains(code.count)
            && code.allSatisfy { $0.isASCII && !$0.isWhitespace }
    }

    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<10).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// 读钥匙串;没有就迁移旧版 UserDefaults 里合格的 token,再不行生成新码。
    static func loadOrCreate(migrating defaults: UserDefaults) -> String {
        if let code = read(), isValid(code) { return code }
        let legacy = defaults.string(forKey: "token") ?? ""
        let code = isValid(legacy) ? legacy : generate()
        save(code)
        defaults.removeObject(forKey: "token")
        return code
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ code: String) -> Bool {
        let data = Data(code.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
