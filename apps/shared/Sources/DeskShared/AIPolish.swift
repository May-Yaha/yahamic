import DeskProtocol
import Foundation
import Security

/// 听写定稿的 AI 润色:默认智谱 GLM Coding Plan,地址、模型、提示词可在设置里改成任意 OpenAI 兼容接口。
/// key 由用户在设置里填,只存钥匙串;失败或超时就用原文,不挡插入。
@MainActor
public final class AIPolish: ObservableObject {
    public static let defaultEndpoint = "https://open.bigmodel.cn/api/coding/paas/v4"
    public static let defaultModel = "glm-5.3-flash"  // Coding Plan 的轻量模型,润色够用、额度消耗约为 GLM-5.3 的 1/3
    public static let defaultPrompt = """
        你是听写润色助手。把用户口述的语音转写整理成通顺的书面文字:去掉口头语、重复和停顿词,\
        修正明显的同音错字与标点,保留原意、语气、人称和专有名词(代码、命令、英文术语保持原样)。\
        不要回答其中的问题,不要扩写或添加内容。只输出润色后的文字。
        """

    private let defaults: UserDefaults
    @Published public private(set) var hasKey = ZhipuKeychain.load() != nil
    /// OpenAI 兼容的 base URL(到 /v1、/v4 这一级),也可直接填完整的 …/chat/completions。
    @Published public var endpoint: String {
        didSet {
            defaults.set(endpoint, forKey: "aiPolishEndpoint")
            if endpoint != oldValue { models = []; modelsMessage = nil }  // 换了接口,旧列表作废
        }
    }
    /// 接口 /models 返回的模型 id;空表示还没取到,设置里退回手填。
    @Published public private(set) var models: [String] = []
    @Published public private(set) var modelsBusy = false
    @Published public private(set) var modelsMessage: String?
    @Published public var model: String { didSet { defaults.set(model, forKey: "aiPolishModel") } }
    @Published public var prompt: String { didSet { defaults.set(prompt, forKey: "aiPolishPrompt") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endpoint = defaults.string(forKey: "aiPolishEndpoint") ?? Self.defaultEndpoint
        model = defaults.string(forKey: "aiPolishModel") ?? Self.defaultModel
        prompt = defaults.string(forKey: "aiPolishPrompt") ?? Self.defaultPrompt
    }

    public func saveKey(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, ZhipuKeychain.save(key) else { return false }
        hasKey = true
        return true
    }

    public func deleteKey() {
        _ = ZhipuKeychain.delete()
        hasKey = false
        models = []
    }

    /// GET {base}/models 列出可用模型,用户从中选一个;选中即存进 model,下次润色直接用。
    public func fetchModels() async {
        guard let key = ZhipuKeychain.load() else { modelsMessage = "先保存 API Key"; return }
        guard let url = Self.modelsURL(endpoint) else { modelsMessage = "接口地址无效(需 https)"; return }
        let asked = endpoint
        modelsBusy = true
        defer { modelsBusy = false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard endpoint == asked else { return }  // 请求途中改了地址,结果不属于当前接口
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ids = Self.modelIDs(data)
            if status == 200, !ids.isEmpty {
                models = ids
                modelsMessage = nil
            } else {
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let reason = (json?["error"] as? [String: Any])?["message"] as? String
                    ?? (status == 200 ? "列表为空" : "HTTP \(status)")
                modelsMessage = "取不到模型列表:\(reason)。可直接手填模型名"
            }
        } catch {
            guard endpoint == asked else { return }
            modelsMessage = "取不到模型列表:\(error.localizedDescription)"
        }
    }

    /// chat/completions 同级的 models(OpenAI 兼容约定)。
    public nonisolated static func modelsURL(_ endpoint: String) -> URL? {
        guard var url = chatURL(endpoint) else { return nil }
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url.appending(path: "models")
    }

    /// OpenAI 兼容的 {"data": [{"id": …}]},去重排序。
    public nonisolated static func modelIDs(_ data: Data) -> [String] {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ids = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        return Set(ids).sorted()
    }

    /// Key 走 Bearer 头,只发 https;http 只放行本机(本地模型服务)。
    public nonisolated static func chatURL(_ endpoint: String) -> URL? {
        let base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: base), let host = url.host(), !host.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
        else { return nil }
        if !url.path().hasSuffix("/chat/completions") { url.append(path: "chat/completions") }
        return url
    }

    public func polish(_ text: String) async throws -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await chat(system: prompt.isEmpty ? Self.defaultPrompt : prompt, user: text, timeout: 10, what: "AI 润色")
    }

    public static let summaryPrompt = """
        你是工作总结助手。下面是用户一天里按时间顺序的语音听写记录,每行开头是时间。\
        整理成一份简洁的中文工作总结,分三段,段名单独一行:【今天做了什么】按主题归并而不是按时间流水;\
        【待办】没有就写「无」;【关键结论】。条目用「• 」开头。只依据记录内容,不编造,\
        代码、命令和专有名词保持原样。不要用 Markdown 标题或加粗。
        """

    /// iPhone「AI 总结」:一天的听写文字(已带时间)交给同一个接口和模型整理成工作总结。
    public func summarize(_ lines: [String]) async throws -> String {
        try await chat(system: Self.summaryPrompt, user: lines.joined(separator: "\n"), timeout: 90, what: "AI 总结")
    }

    public static let correctPrompt = """
        你是语音转写校对助手。用户给出同一段中文口述录音的两份机器转写:A 是讲话时实时转的,B 是事后整段重转的,\
        可能有同音错字、英文术语拼写或大小写错误。输出最可能是说话人原话的一份转写:只修正同音错字、术语和标点,\
        保留口头语、重复和原有措辞,不润色、不增删内容,两份不同时取更合理的写法。代码、命令和英文术语保持原样。\
        只输出转写文字。
        """

    /// 训练数据标注:两份机器转写交给同一个接口和模型,只纠错不润色。模型听不到音频,结果仍需人工裁定。
    public func correct(live: String, offline: String) async throws -> String {
        try await chat(system: Self.correctPrompt, user: "A:\(live)\nB:\(offline)", timeout: 30, what: "AI 校对")
    }

    /// 视频字幕翻译:系统翻译没装对应语言包时的后备。字幕常是半句话,照译不补全。
    public func translate(_ text: String, to language: String) async throws -> String {
        let system = "你是视频字幕翻译。把用户给出的字幕翻译成\(language),只输出译文,不解释、不加引号。字幕可能是半句话,照译即可,不要补全。"
        return try await chat(system: system, user: text, timeout: 8, what: "AI 翻译")
    }

    private func chat(system: String, user: String, timeout: TimeInterval, what: String) async throws -> String {
        guard let key = ZhipuKeychain.load() else { throw DeskProtocolError("未填写\(what)的 API Key") }
        guard let url = Self.chatURL(endpoint) else { throw DeskProtocolError("\(what)地址无效(需 https)") }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model.isEmpty ? Self.defaultModel : model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0.2,
        ]
        // 智谱专有参数:润色、总结都不需要推理,关掉省时延。别家接口可能拒收未知字段,不带。
        if url.host()?.hasSuffix("bigmodel.cn") == true { body["thinking"] = ["type": "disabled"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw DeskProtocolError("\(what)失败:\(message)")
        }
        let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        let text = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw DeskProtocolError("\(what)返回为空") }
        return text
    }
}

public enum ZhipuKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "yahadesk.zhipu",
         kSecAttrAccount as String: "api_key"]
    }
    public static func save(_ key: String) -> Bool {
        _ = delete()
        let attrs: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    public static func load() -> String? {
        var item: CFTypeRef?
        let lookup = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
