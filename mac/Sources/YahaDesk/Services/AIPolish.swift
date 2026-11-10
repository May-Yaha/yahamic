import Foundation
import Security

/// 听写定稿的 AI 润色:智谱 GLM Coding Plan(OpenAI 兼容 Chat Completions)。
/// key 由用户在设置里填,只存钥匙串;失败或超时就用原文,不挡插入。
@MainActor
final class AIPolish: ObservableObject {
    static let endpoint = URL(string: "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions")!
    static let model = "glm-5.3-flash"  // Coding Plan 的轻量模型,润色够用、额度消耗约为 GLM-5.3 的 1/3
    private static let prompt = """
        你是听写润色助手。把用户口述的语音转写整理成通顺的书面文字:去掉口头语、重复和停顿词,\
        修正明显的同音错字与标点,保留原意、语气、人称和专有名词(代码、命令、英文术语保持原样)。\
        不要回答其中的问题,不要扩写或添加内容。只输出润色后的文字。
        """

    @Published private(set) var hasKey = ZhipuKeychain.load() != nil

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

    func polish(_ text: String) async throws -> String {
        guard let key = ZhipuKeychain.load() else { throw LocalSTTError("未填写智谱 API Key") }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.model,
            "messages": [["role": "system", "content": Self.prompt], ["role": "user", "content": text]],
            "temperature": 0.2,
            "thinking": ["type": "disabled"],  // 润色不需要推理,关掉省时延
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw LocalSTTError("智谱润色失败:\(message)")
        }
        let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        let polished = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !polished.isEmpty else { throw LocalSTTError("智谱润色返回为空") }
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
