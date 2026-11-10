import Foundation
import Security

/// 听写定稿的 AI 润色:默认智谱 GLM Coding Plan,地址、模型、提示词可在设置里改成任意 OpenAI 兼容接口。
/// key 由用户在设置里填,只存钥匙串;失败或超时就用原文,不挡插入。
@MainActor
final class AIPolish: ObservableObject {
    static let defaultEndpoint = "https://open.bigmodel.cn/api/coding/paas/v4"
    static let defaultModel = "glm-5.3-flash"  // Coding Plan 的轻量模型,润色够用、额度消耗约为 GLM-5.3 的 1/3
    static let defaultPrompt = """
        你是听写润色助手。把用户口述的语音转写整理成通顺的书面文字:去掉口头语、重复和停顿词,\
        修正明显的同音错字与标点,保留原意、语气、人称和专有名词(代码、命令、英文术语保持原样)。\
        不要回答其中的问题,不要扩写或添加内容。只输出润色后的文字。
        """

    private let defaults: UserDefaults
    @Published private(set) var hasKey = ZhipuKeychain.load() != nil
    /// OpenAI 兼容的 base URL(到 /v1、/v4 这一级),也可直接填完整的 …/chat/completions。
    @Published var endpoint: String { didSet { defaults.set(endpoint, forKey: "aiPolishEndpoint") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "aiPolishModel") } }
    @Published var prompt: String { didSet { defaults.set(prompt, forKey: "aiPolishPrompt") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endpoint = defaults.string(forKey: "aiPolishEndpoint") ?? Self.defaultEndpoint
        model = defaults.string(forKey: "aiPolishModel") ?? Self.defaultModel
        prompt = defaults.string(forKey: "aiPolishPrompt") ?? Self.defaultPrompt
    }

    func saveKey(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, ZhipuKeychain.save(key) else { return false }
        hasKey = true
        return true
    }

    func deleteKey() {
        _ = ZhipuKeychain.delete()
        hasKey = false
    }

    /// Key 走 Bearer 头,只发 https;http 只放行本机(本地模型服务)。
    nonisolated static func chatURL(_ endpoint: String) -> URL? {
        let base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: base), let host = url.host(), !host.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
        else { return nil }
        if !url.path().hasSuffix("/chat/completions") { url.append(path: "chat/completions") }
        return url
    }

    func polish(_ text: String) async throws -> String {
        guard let key = ZhipuKeychain.load() else { throw LocalSTTError("未填写 AI 润色的 API Key") }
        guard let url = Self.chatURL(endpoint) else { throw LocalSTTError("AI 润色地址无效(需 https)") }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model.isEmpty ? Self.defaultModel : model,
            "messages": [["role": "system", "content": prompt.isEmpty ? Self.defaultPrompt : prompt],
                         ["role": "user", "content": text]],
            "temperature": 0.2,
        ]
        // 智谱专有参数:润色不需要推理,关掉省时延。别家接口可能拒收未知字段,不带。
        if url.host()?.hasSuffix("bigmodel.cn") == true { body["thinking"] = ["type": "disabled"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw LocalSTTError("AI 润色失败:\(message)")
        }
        let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        let polished = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !polished.isEmpty else { throw LocalSTTError("AI 润色返回为空") }
        return polished
    }
}

enum ZhipuKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "yahadesk.zhipu",
         kSecAttrAccount as String: "api_key"]
    }
    static func save(_ key: String) -> Bool {
        _ = delete()
        let attrs: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    static func load() -> String? {
        var item: CFTypeRef?
        let lookup = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
