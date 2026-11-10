import SwiftUI

/// 生成过的总结按天存在本机,再打开直接显示;要更新点「重新生成」。
struct SavedSummary: Codable, Equatable {
    let text: String
    let takes: Int  // 生成时用了几条有文字的录音
    let at: Date

    // ponytail: 存 UserDefaults,一天一条几 KB;要跨设备同步再改存网盘。
    nonisolated static func key(_ day: Date) -> String {
        "summary." + day.formatted(.iso8601.year().month().day())
    }
    nonisolated static func load(_ day: Date, defaults: UserDefaults = .standard) -> SavedSummary? {
        defaults.data(forKey: key(day)).flatMap { try? JSONDecoder().decode(SavedSummary.self, from: $0) }
    }
    nonisolated func save(_ day: Date, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key(day))
    }
}

/// 一天的听写记录交给 AI(默认智谱 GLM)整理成工作总结:做了什么、待办、关键结论,可复制、分享。
struct DaySummarySheet: View {
    let day: Date
    let takes: [PanFiles.Take]
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var ai: AIPolish
    @Environment(\.dismiss) private var dismiss
    @State private var saved: SavedSummary?
    private var summary: String { saved?.text ?? "" }
    @State private var error: String?
    @State private var running = false

    /// 按时间先后排好、带时间的听写行;没文字的录音跳过。
    nonisolated static func lines(_ takes: [PanFiles.Take], texts: [UInt64: String]) -> [String] {
        takes.sorted { $0.mtime < $1.mtime }.compactMap { take in
            guard let text = texts[take.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return take.mtime.formatted(date: .omitted, time: .shortened) + " " + text
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !ai.hasKey && saved == nil {
                    ContentUnavailableView {
                        Label("先填写 API Key", systemImage: "key.fill")
                    } description: {
                        Text("总结用你自己的 GLM 或任意 OpenAI 兼容接口,Key 只存在这台 iPhone 的钥匙串。")
                    } actions: {
                        NavigationLink("去设置") { AISettingsView() }.buttonStyle(.borderedProminent)
                    }
                } else if running {
                    VStack(spacing: 16) {
                        Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, isActive: true)
                        Text("正在整理 \(takes.count) 条录音…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView {
                        Label("没有生成总结", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("重试") { Task { await run() } }.buttonStyle(.borderedProminent)
                    }
                } else if let saved {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(saved.text).textSelection(.enabled)
                            Text("\(saved.at.formatted(date: .abbreviated, time: .shortened)) 生成 · \(saved.takes) 条录音")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                }
            }
            .navigationTitle(day.formatted(.dateTime.month().day()) + " 工作总结")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                if !summary.isEmpty && !running {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { Task { await run() } } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                        Button { UIPasteboard.general.string = summary } label: { Label("复制", systemImage: "doc.on.doc") }
                        ShareLink(item: summary)
                    }
                }
            }
        }
        .task(id: ai.hasKey) {
            saved = saved ?? SavedSummary.load(day)
            if ai.hasKey && saved == nil { await run() }  // 只在没存过时自动生成
        }
    }

    private func run() async {
        running = true
        error = nil
        defer { running = false }
        for take in takes { await recordings.player.loadText(take) }
        let lines = Self.lines(takes, texts: recordings.player.texts)
        guard !lines.isEmpty else { error = "这一天的录音还没有确认过的文字。"; return }
        do {
            let fresh = SavedSummary(text: try await ai.summarize(lines), takes: lines.count, at: .now)
            fresh.save(day)
            saved = fresh
        } catch { self.error = error.localizedDescription }
    }
}

/// 总结用的接口、Key、模型,与 Mac「AI 润色」同一套配置格式;iPhone 单独保存。
struct AISettingsView: View {
    @EnvironmentObject private var ai: AIPolish
    @State private var key = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                TextField("接口地址", text: $ai.endpoint, prompt: Text(AIPolish.defaultEndpoint))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !ai.endpoint.isEmpty && AIPolish.chatURL(ai.endpoint) == nil {
                    Text("地址需以 https:// 开头").foregroundStyle(.orange)
                }
                LabeledContent("API Key", value: ai.hasKey ? "已保存在钥匙串" : "未填写")
                SecureField(ai.hasKey ? "填新的 Key 覆盖" : "粘贴 Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(save)
                if !key.isEmpty { Button("保存 Key", action: save) }
                if ai.hasKey { Button("删除 Key", role: .destructive) { ai.deleteKey() } }
                if let message { Text(message).foregroundStyle(.orange) }
            } header: { Text("接口") } footer: {
                Text("默认智谱 GLM Coding Plan,也可填任何 OpenAI 兼容接口(base URL 到 /v1 这一级)。Key 只存在本机钥匙串,不上传、不同步。")
            }
            Section("模型") {
                if ai.models.isEmpty {
                    TextField("模型", text: $ai.model, prompt: Text(AIPolish.defaultModel))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    Picker("模型", selection: $ai.model) {
                        ForEach(ai.models.contains(ai.model) ? ai.models : [ai.model] + ai.models, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button(ai.modelsBusy ? "正在获取…" : "获取模型列表") { Task { await ai.fetchModels() } }
                    .disabled(!ai.hasKey || ai.modelsBusy)
                if let note = ai.modelsMessage { Text(note).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("AI 总结")
    }

    private func save() {
        message = ai.saveKey(key) ? nil : "保存失败,请检查 Key"
        key = ""
        if message == nil { Task { await ai.fetchModels() } }
    }
}
