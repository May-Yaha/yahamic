import ApplicationServices
import Foundation
import HuggingFace
import MLX
import MLXAudioSTT

enum LocalSTTState: Equatable {
    case disabled
    case preparing(Int)
    case ready
    case listening
    case transcribing
    case failed(String)

    var detail: String {
        switch self {
        case .disabled: return "关闭"
        case .preparing(let percent):
            return percent > 0 ? "准备 Qwen3 模型 \(percent)%" : "准备 Qwen3 模型"
        case .ready: return "按住讲话，松开输入"
        case .listening: return "正在收音"
        case .transcribing: return "正在转文字"
        case .failed(let message): return message
        }
    }
}

@MainActor
protocol DictationTextTarget: AnyObject {
    func insert(_ text: String) -> Bool
}

/// Fn 按下时锁定焦点对象；模型返回后只经辅助功能替换该对象的选区。
@MainActor
final class FocusedTextTarget: DictationTextTarget {
    private let element: AXUIElement

    private init(element: AXUIElement) {
        self.element = element
    }

    static func capture() -> FocusedTextTarget? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value
            ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return FocusedTextTarget(element: unsafeBitCast(value, to: AXUIElement.self))
    }

    func insert(_ text: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                element, kAXSelectedTextAttribute as CFString, &settable
            ) == .success, settable.boolValue,
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFString
            ) == .success
        else { return false }
        return true
    }
}

@MainActor
enum LocalDictationText {
    static func commit(_ text: String, to target: any DictationTextTarget) -> Bool {
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !final.isEmpty && target.insert(final)
    }
}

final class PCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    init(capacityBytes: Int = 30 * 16_000 * 2) {
        storage.reserveCapacity(capacityBytes)
    }

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
struct LocalDictationCapture {
    struct Utterance {
        let pcm: Data
        let target: any DictationTextTarget
    }

    private var active: (buffer: PCMBuffer, target: any DictationTextTarget)?
    private var stopRequested = false

    mutating func begin(target: any DictationTextTarget) -> PCMBuffer? {
        guard active == nil else { return nil }
        let buffer = PCMBuffer()
        active = (buffer, target)
        stopRequested = false
        return buffer
    }

    mutating func requestStop() -> Bool {
        guard active != nil, !stopRequested else { return false }
        stopRequested = true
        return true
    }

    mutating func finishIfSafe(connected: Bool, muted: Bool, force: Bool = false) -> Utterance? {
        guard stopRequested, force || !connected || muted, let active else { return nil }
        self.active = nil
        stopRequested = false
        return Utterance(pcm: active.buffer.snapshot(), target: active.target)
    }

    mutating func cancel() -> Bool {
        guard active != nil else { return false }
        active = nil
        stopRequested = false
        return true
    }
}

actor LocalSpeechRecognizer {
    typealias ProgressHandler = @MainActor @Sendable (Progress) -> Void
    typealias Loader = @Sendable (ProgressHandler?) async throws -> Qwen3ASRModel

    static let modelRepository = "mlx-community/Qwen3-ASR-0.6B-6bit"
    static let modelSourceRevision = "468b9b6d692d3397d5d17b84a1166876a00c9bfa"
    private static let context = "Transcribe only words that are spoken in the audio. Do not append acknowledgements, continuations, or filler words after speech ends."

    private var model: Qwen3ASRModel?
    private let loader: Loader

    init(
        loader: @escaping Loader = { progress in
            let cache = HubCache(cacheDirectory: try LocalSpeechRecognizer.modelCacheDirectory())
            guard let repository = Repo.ID(rawValue: LocalSpeechRecognizer.modelRepository) else {
                throw LocalSTTError("Qwen3 模型地址无效")
            }
            let client = HubClient(cache: cache)
            let directory = try await client.downloadSnapshot(
                of: repository,
                revision: LocalSpeechRecognizer.modelSourceRevision,
                matching: ["*.safetensors", "*.json", "*.txt", "*.wav"],
                progressHandler: progress
            )
            try Task.checkCancellation()
            return try await Qwen3ASRModel.fromModelDirectory(directory)
        }
    ) {
        self.loader = loader
    }

    func prepare(progress: ProgressHandler? = nil) async throws {
        _ = try await load(progress: progress)
    }

    func transcribe(_ pcm: Data) async throws -> String {
        guard pcm.count >= 6_400 else { throw LocalSTTError("讲话太短，请说完后再松开") }
        let count = pcm.count / 2
        var samples = [Int16](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { pcm.prefix(count * 2).copyBytes(to: $0) }
        let audio = MLXArray(samples.map { Float($0) / 32_768 })
        let model = try await load()
        try Task.checkCancellation()
        let output = model.generate(
            audio: audio,
            maxTokens: 2_048,
            temperature: 0,
            context: Self.context,
            chunkDuration: 30,
            minChunkDuration: 1
        )
        Memory.clearCache()
        try Task.checkCancellation()
        return output.text
    }

    private func load(progress: ProgressHandler? = nil) async throws -> Qwen3ASRModel {
        if let model { return model }
        // shortcut:HomeModel 在准备完成前不进入转写，不需要额外的 in-flight 去重 Task。
        let loaded = try await loader(progress)
        model = loaded
        return loaded
    }

    private static func modelCacheDirectory() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent(
            "YahaDesk/Models",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

struct LocalSTTError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
