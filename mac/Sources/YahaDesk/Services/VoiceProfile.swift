import Combine
import Foundation
import FluidAudio

struct VoiceSampleQuality: Codable, Equatable {
    let durationSeconds: Double
    let rmsDbfs: Double
    let activeRatio: Double
    let clippedRatio: Double
    let accepted: Bool
    let message: String

    static func evaluate(_ pcm: Data) -> VoiceSampleQuality {
        let count = pcm.count / 2
        var samples = [Int16](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { pcm.prefix(count * 2).copyBytes(to: $0) }
        let duration = Double(count) / 16_000
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (energy / Double(max(count, 1))).squareRoot()
        let rmsDbfs = 20 * log10(max(rms / 32_768, 1e-9))
        let clipped = samples.reduce(0) { $0 + (abs(Int($1)) >= 32_767 ? 1 : 0) }
        let clippedRatio = Double(clipped) / Double(max(count, 1))
        let window = 320
        var active = 0
        var windows = 0
        for start in stride(from: 0, through: max(count - window, 0), by: window) where start + window <= count {
            let sum = samples[start..<start + window].reduce(0.0) { $0 + Double($1) * Double($1) }
            let level = 20 * log10(max((sum / Double(window)).squareRoot() / 32_768, 1e-9))
            active += level > -50 ? 1 : 0
            windows += 1
        }
        let activeRatio = Double(active) / Double(max(windows, 1))
        let message: String
        if !(2...6).contains(duration) { message = "请连续说 2–6 秒" }
        else if clippedRatio > 0.001 { message = "声音过大，请离麦克风稍远后重录" }
        else if rmsDbfs < -45 { message = "声音太小，请靠近麦克风后重录" }
        else if activeRatio < 0.4 { message = "有效语音不足，请读完整句子" }
        else { message = "录音质量合格" }
        return VoiceSampleQuality(durationSeconds: duration, rmsDbfs: rmsDbfs, activeRatio: activeRatio,
                                  clippedRatio: clippedRatio, accepted: message == "录音质量合格", message: message)
    }
}

enum VoiceIdentityPolicy {
    static let threshold: Float = 0.65

    static func average(_ embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first, !first.isEmpty,
              embeddings.allSatisfy({ $0.count == first.count }) else { return nil }
        var result = [Float](repeating: 0, count: first.count)
        for embedding in embeddings {
            for index in result.indices { result[index] += embedding[index] }
        }
        return normalized(result)
    }

    static func accepts(_ profile: [Float], candidate: [Float], threshold: Float = threshold) -> Bool {
        guard let left = normalized(profile), let right = normalized(candidate), left.count == right.count else {
            return false
        }
        let similarity = zip(left, right).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return 1 - similarity <= threshold
    }

    private static func normalized(_ values: [Float]) -> [Float]? {
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return nil }
        return values.map { $0 / norm }
    }
}

enum PCM16Wave {
    static func data(_ pcm: Data) -> Data {
        var wav = Data()
        func le32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        func le16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        let bytes = UInt32(pcm.count - pcm.count % 2)
        wav.append(contentsOf: Array("RIFF".utf8)); le32(36 + bytes)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16)
        le16(1); le16(1); le32(16_000); le32(32_000); le16(2); le16(16)
        wav.append(contentsOf: Array("data".utf8)); le32(bytes)
        wav.append(pcm.prefix(Int(bytes)))
        return wav
    }

    static func data(_ samples: [Float]) -> Data {
        let pcm = samples.map { value -> Int16 in
            let scaled = (min(max(value, -1), 1) * 32_767).rounded()
            return Int16(scaled)
        }
        return pcm.withUnsafeBytes { data(Data($0)) }
    }
}

actor VoiceEmbeddingModel {
    static let shared = VoiceEmbeddingModel()
    private var manager: DiarizerManager?

    private func diarizer() async throws -> DiarizerManager {
        if let manager { return manager }
        let models = try await DiarizerModels.downloadIfNeeded()
        let loaded = DiarizerManager()
        loaded.initialize(models: models)
        manager = loaded
        return loaded
    }

    /// 16 kHz 单声道一段语音的声纹(未归一化,比对前由 VoiceIdentityPolicy 归一)。
    func embedding(of samples: [Float]) async throws -> [Float] {
        try await diarizer().extractSpeakerEmbedding(from: samples)
    }

    func embedding(for recordings: [Data]) async throws -> [Float] {
        let diarizer = try await diarizer()
        let embeddings = try recordings.map { pcm -> [Float] in
            let count = pcm.count / 2
            var samples = [Int16](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBytes { pcm.prefix(count * 2).copyBytes(to: $0) }
            return try diarizer.extractSpeakerEmbedding(from: samples.map { Float($0) / 32_768 })
        }
        guard let profile = VoiceIdentityPolicy.average(embeddings), profile.count == 256 else {
            throw VoiceProfileError("声纹模型没有生成有效的 256 维特征")
        }
        return profile
    }
}

struct VoiceProfileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct VoiceProfileSample: Codable, Equatable, Identifiable {
    let index: Int
    let fileName: String
    let quality: VoiceSampleQuality
    var id: Int { index }
}

struct VoiceProfileManifest: Codable, Equatable {
    var profileID: String
    var samples: [VoiceProfileSample]
    var embedding: [Float]?
    var remotePaths: [String: String]
    var modelVersion: String
}

@MainActor
final class VoiceProfile: ObservableObject {
    static let phrases = [
        "今天的语音输入只保留我说的内容。",
        "请准确识别这句话，不要重复，也不要漏字。",
        "窗外有声音时，仍然优先听清我的语音。",
        "这是一段用于建立本人声纹的录音。",
        "完成之后，请用新的录音继续验证稳定性。",
    ]
    static let modelVersion = "FluidAudio-0.17.7-WeSpeaker-v2"

    @Published private(set) var manifest: VoiceProfileManifest
    @Published private(set) var busy = false
    @Published private(set) var recordingIndex: Int?
    @Published private(set) var message: String?

    var capture: ((Int) async throws -> Data)?
    var token: () -> PanToken? = PanKeychain.load
    var session = URLSession(configuration: .ephemeral)
    var log: (String) -> Void = { _ in }
    private let folder: URL
    private let embedRecordings: ([Data]) async throws -> [Float]

    var ready: Bool { manifest.samples.count == Self.phrases.count && manifest.embedding?.count == 256 }
    var hasLocalData: Bool { !manifest.samples.isEmpty || manifest.embedding != nil }
    var hasRemoteFiles: Bool { !manifest.remotePaths.isEmpty }
    var backedUp: Bool {
        let expected = Set(manifest.samples.map(\.fileName) + ["profile.json"])
        return manifest.remotePaths.count == expected.count && Set(manifest.remotePaths.keys) == expected
    }

    init(folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("YahaDesk/VoiceProfile"),
         embedRecordings: (([Data]) async throws -> [Float])? = nil) {
        self.folder = folder
        self.embedRecordings = embedRecordings ?? { try await VoiceEmbeddingModel.shared.embedding(for: $0) }
        let url = folder.appendingPathComponent("profile.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(VoiceProfileManifest.self, from: data) {
            manifest = saved
        } else {
            manifest = Self.emptyManifest()
        }
        manifest.samples.removeAll { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
        if manifest.samples.count != Self.phrases.count { manifest.embedding = nil }
    }

    func sample(at index: Int) -> VoiceProfileSample? {
        manifest.samples.first { $0.index == index }
    }

    func record(_ index: Int) async {
        guard Self.phrases.indices.contains(index), !busy else { return }
        guard manifest.remotePaths.isEmpty else {
            message = "已备份的档案不可直接重录；请先删除旧档案再重新建立"
            return
        }
        guard let capture else { message = "设备音频链路尚未就绪"; return }
        busy = true
        recordingIndex = index
        message = "正在录制第 \(index + 1) 句，请自然朗读"
        defer { busy = false; recordingIndex = nil }
        do {
            let pcm = try await capture(4)
            let quality = VoiceSampleQuality.evaluate(pcm)
            guard quality.accepted else { message = quality.message; return }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileName = "phrase-\(index + 1).wav"
            try PCM16Wave.data(pcm).write(to: folder.appendingPathComponent(fileName), options: .atomic)
            manifest.samples.removeAll { $0.index == index }
            manifest.samples.append(VoiceProfileSample(index: index, fileName: fileName, quality: quality))
            manifest.samples.sort { $0.index < $1.index }
            manifest.embedding = nil
            try save()
            if manifest.samples.count == Self.phrases.count {
                message = "五句录音合格，正在下载本地模型并建立声纹"
                try await buildEmbedding()
                message = "本人声纹已在本机建立"
            } else {
                message = "第 \(index + 1) 句录音合格"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func backup() async {
        guard ready, !busy else { return }
        guard let token = token(), token.valid() else { message = "请先登录百度网盘"; return }
        busy = true
        defer { busy = false }
        do {
            let pan = PanFiles(token: token.token, log: { [log] in log($0) }, session: session)
            let root = PanFiles.voiceProfileRoot + "/" + manifest.profileID
            for sample in manifest.samples where manifest.remotePaths[sample.fileName] == nil {
                let data = try Data(contentsOf: folder.appendingPathComponent(sample.fileName))
                manifest.remotePaths[sample.fileName] = try await pan.upload(
                    data, to: root + "/" + sample.fileName, modified: Date())
                try save()
            }
            if manifest.remotePaths["profile.json"] == nil {
                let data = try JSONEncoder().encode(manifest)
                manifest.remotePaths["profile.json"] = try await pan.upload(
                    data, to: root + "/profile.json", modified: Date())
                try save()
            }
            message = "本人声纹档案已备份到网盘"
        } catch {
            message = "网盘备份失败，原始语音仍保留在本机：\(error.localizedDescription)"
        }
    }

    func delete(includeRemote: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let remotePaths = manifest.remotePaths
        let profileID = manifest.profileID
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        } catch {
            message = "本机声纹档案删除失败：\(error.localizedDescription)"
            return
        }
        guard includeRemote, !remotePaths.isEmpty else {
            manifest = Self.emptyManifest()
            message = remotePaths.isEmpty ? "本机声纹档案已删除" : "本机声纹档案已删除，网盘备份已保留"
            return
        }

        // 原始语音和 embedding 先删；只留无生物特征的远端路径收据，供断网后重试。
        manifest = VoiceProfileManifest(profileID: profileID, samples: [], embedding: nil,
                                        remotePaths: remotePaths, modelVersion: Self.modelVersion)
        do {
            try save()
        } catch {
            message = "本机已删除，但网盘删除待办保存失败：\(error.localizedDescription)"
            return
        }
        do {
            guard let token = token(), token.valid() else { throw VoiceProfileError("网盘登录已失效") }
            let pan = PanFiles(token: token.token, log: { [log] in log($0) }, session: session)
            try await pan.deleteVoiceProfile(paths: Array(remotePaths.values))
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            manifest = Self.emptyManifest()
            message = "本机和网盘声纹档案已删除"
        } catch {
            message = "本机已删除，网盘删除失败：\(error.localizedDescription)"
        }
    }

    private func buildEmbedding() async throws {
        let recordings = try manifest.samples.map { sample -> Data in
            let wav = try Data(contentsOf: folder.appendingPathComponent(sample.fileName))
            guard wav.count >= 44 else { throw VoiceProfileError("声纹录音文件损坏") }
            return Data(wav.dropFirst(44))
        }
        manifest.embedding = try await embedRecordings(recordings)
        guard manifest.embedding?.count == 256 else { throw VoiceProfileError("声纹模型返回维度错误") }
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("profile.json"), options: .atomic)
    }

    private static func emptyManifest() -> VoiceProfileManifest {
        VoiceProfileManifest(profileID: UUID().uuidString.lowercased(), samples: [], embedding: nil,
                             remotePaths: [:], modelVersion: modelVersion)
    }
}
