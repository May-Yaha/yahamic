import AppKit
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
    case reviewing
    case failed(String)

    var detail: String {
        switch self {
        case .disabled: return "关闭"
        case .preparing(let percent):
            return percent > 0 ? "准备 Qwen3 模型 \(percent)%" : "准备 Qwen3 模型"
        case .ready: return "按住讲话，松开输入"
        case .listening: return "正在收音"
        case .transcribing: return "正在转文字"
        case .reviewing: return "可修改,回车插入"
        case .failed(let message): return message
        }
    }
}

@MainActor
protocol DictationTextTarget: AnyObject {
    func insert(_ text: String) -> Bool
}

/// Fn 按下时锁定焦点对象；模型返回后只经辅助功能替换该对象的选区。
/// 微信 4.x 这类不开放辅助功能树的 App 拿不到焦点对象:记下前台 App,插入时还是它才粘贴进去。
@MainActor
final class FocusedTextTarget: DictationTextTarget {
    private let element: AXUIElement?
    private let app: pid_t

    private init(element: AXUIElement?, app: pid_t) {
        self.element = element
        self.app = app
    }

    static func capture() -> FocusedTextTarget? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        // 如流(Flutter)系统级查询报 -25204,按 App 查才拿得到焦点输入框。
        let element = focused(in: AXUIElementCreateSystemWide())
            ?? focused(in: AXUIElementCreateApplication(front.processIdentifier))
        return FocusedTextTarget(element: element, app: front.processIdentifier)
    }

    private static func focused(in root: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Flutter 只认带 HID 事件源的键盘事件,source 为 nil 的合成事件会被静默丢掉。
    private static func key(_ code: CGKeyCode, down: Bool) -> CGEvent? {
        CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down)
    }

    func insert(_ text: String) -> Bool {
        guard let element else {
            // 讲完切走了就不贴:文字不能落进别的窗口。
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app else { return false }
            return Self.paste(text)
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue,
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFString
            ) == .success
        {
            return true
        }
        // 终端、Electron 等不开放 AX 选区写入:像输入法一样把文字当键盘事件打给当前焦点。
        return Self.type(text)
    }

    /// 剪贴板 + ⌘V,半秒后还原剪贴板(期间用户自己复制了就不动)。
    private static func paste(_ text: String) -> Bool {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))  // 剪贴板管理器别记
        board.writeObjects([item])
        let mine = board.changeCount
        for down in [true, false] {
            guard let event = key(9, down: down) else { return false }  // V
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard board.changeCount == mine else { return }
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
        return true
    }

    private static func type(_ text: String) -> Bool {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return false }
        // 单个事件的 Unicode 串系统只收约 20 个 UTF-16 单元,按 16 切,不切开代理对。
        var start = 0
        while start < units.count {
            var end = min(start + 16, units.count)
            if end < units.count, UTF16.isTrailSurrogate(units[end]) { end -= 1 }
            let chunk = Array(units[start..<end])
            for down in [true, false] {
                guard let event = key(0, down: down) else { return false }
                event.flags = []  // 讲话键是修饰键时别把它带进去变成快捷键
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cghidEventTap)
            }
            start = end
        }
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

/// 实时字幕:前段在停顿处定稿,每轮只重转定稿之后的尾段,刷新耗时不随讲话时长增长。
/// 16 kHz Int16 单声道,1 秒 = 32 000 字节。
struct LiveTranscript {
    static let bytesPerSecond = 32_000
    static let maxTail = 6 * bytesPerSecond  // 尾段超过 6 秒就找停顿切一刀

    private(set) var committed = ""
    private(set) var offset = 0  // pcm 中已并入 committed 的字节数

    func tail(of pcm: Data) -> Data { Data(pcm.dropFirst(offset)) }

    /// 尾段过长时返回切点:尾段 3–6 秒里最安静的 100 ms 帧中间。
    func cut(_ pcm: Data) -> Int? {
        guard pcm.count - offset >= Self.maxTail else { return nil }
        let frame = Self.bytesPerSecond / 10
        var best = (energy: Int.max, at: offset + Self.maxTail)
        var start = offset + Self.maxTail / 2
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            while start + frame <= offset + Self.maxTail {
                var energy = 0
                for i in (start / 2)..<((start + frame) / 2) { energy += abs(Int(samples[i])) }
                if energy < best.energy { best = (energy, start + frame / 2) }
                start += frame
            }
        }
        return best.at
    }

    mutating func commit(_ text: String, upTo end: Int) {
        committed = Self.join(committed, text)
        offset = end
    }

    func text(withTail tail: String) -> String { Self.join(committed, tail) }

    /// 中文直接相连;两边都是拉丁字母或数字时补一个空格(swift + test)。
    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = a.unicodeScalars.last, let first = b.unicodeScalars.first else { return a + b }
        let latin = { (c: Unicode.Scalar) in c.isASCII && CharacterSet.alphanumerics.contains(c) }
        return latin(last) && latin(first) ? a + " " + b : a + b
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
    private var startedAt = Date()

    /// 本次按住了多久;没有进行中的采集时为无穷大。
    var held: TimeInterval { active == nil ? .infinity : Date().timeIntervalSince(startedAt) }

    mutating func begin(target: any DictationTextTarget) -> PCMBuffer? {
        guard active == nil else { return nil }
        let buffer = PCMBuffer()
        active = (buffer, target)
        startedAt = Date()
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
    // Qwen3-ASR reads the system context as biasing text; the terms keep English coding words in Latin script.
    private static let context = "Transcribe only words that are spoken in the audio. Do not append acknowledgements, continuations, or filler words after speech ends. Terms: Claude Code, Codex, swift test, Swift, Xcode, Git, commit, push, PR, merge, branch, API, JSON, README, bug, debug, build, test, ESP32, BLE, Opus, Mac, iOS."

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
