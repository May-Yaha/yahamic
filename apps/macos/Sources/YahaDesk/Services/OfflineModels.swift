import AppKit
import Foundation
import NaturalLanguage
import Translation

/// 设置「离线模型」:本机 Qwen3-ASR 权重的下载/删除,与视频字幕要用的系统翻译语言包状态。
/// 语言包归系统管:App 只能查状态、发起下载(系统弹确认框),删除要到系统设置里。
@MainActor
final class OfflineModels: ObservableObject {
    enum ASR: Equatable {
        case missing
        case downloading(Int)
        case ready(Int64)
        case failed(String)
    }

    struct Pair: Identifiable, Equatable {
        let source: Locale.Language
        let target: Locale.Language
        let status: LanguageAvailability.Status
        var id: String { source.minimalIdentifier + "→" + target.minimalIdentifier }
        var title: String { "\(Self.name(source)) → \(Self.name(target))" }
        static func name(_ language: Locale.Language) -> String {
            Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
        }
    }

    @Published private(set) var asr = ASR.missing
    @Published private(set) var pairs: [Pair] = []
    private var download: Task<Void, Never>?

    /// 本地转文字、视频字幕在用模型时不让删(删了正在转的那句会失败)。
    var inUse: () -> Bool = { false }
    var unload: () async -> Void = {}
    var captionTarget: () -> String = { "zh-Hans" }
    var log: (String) -> Void = { _ in }

    init() { refreshASR() }

    func refreshASR() {
        guard download == nil else { return }
        asr = LocalSpeechRecognizer.downloadedSize().map(ASR.ready) ?? .missing
    }

    func downloadASR() {
        guard download == nil else { return }
        asr = .downloading(0)
        log("离线模型:开始下载 Qwen3-ASR 0.6B")
        download = Task { [weak self] in
            do {
                _ = try await LocalSpeechRecognizer.download { progress in
                    self?.asr = .downloading(Int((progress.fractionCompleted * 100).rounded()))
                }
                self?.download = nil
                self?.refreshASR()
                self?.log("离线模型:Qwen3-ASR 下载完成")
            } catch {
                self?.download = nil
                self?.asr = Task.isCancelled ? .missing : .failed("下载失败:\(error.localizedDescription)")
                if !Task.isCancelled { self?.log("⚠️ 离线模型:Qwen3-ASR 下载失败:\(error.localizedDescription)") }
            }
        }
    }

    /// 已下好的文件留在缓存里,下次下载接着用。
    func cancelDownload() {
        download?.cancel()
    }

    func deleteASR() async {
        guard download == nil, !inUse(), let root = LocalSpeechRecognizer.repositoryDirectory else { return }
        await unload()
        do {
            try FileManager.default.removeItem(at: root)
            log("离线模型:已删除 Qwen3-ASR 本机权重")
        } catch {
            log("⚠️ 离线模型:删除失败:\(error.localizedDescription)")
        }
        refreshASR()
    }

    func revealASR() {
        guard let root = LocalSpeechRecognizer.repositoryDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    /// 视频字幕会认的原文语言 → 当前目标语言,逐对查系统是否已装。
    func refreshPairs() async {
        let target = Locale.Language(identifier: captionTarget())
        let availability = LanguageAvailability()
        var result: [Pair] = []
        for code in HomeModel.captionSources.map(\.rawValue) {
            let source = Locale.Language(identifier: code)
            guard source.languageCode != target.languageCode else { continue }  // 同语言不翻,见 translateCaption
            result.append(Pair(source: source, target: target, status: await availability.status(from: source, to: target)))
        }
        pairs = result
    }

    func openSystemTranslationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
