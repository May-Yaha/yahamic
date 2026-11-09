import DeskCore
import Foundation

/// 只留本人说话:每 0.5 s 一段,取这段及之前的有声帧(最多 1.5 s)算声纹与档案比对,不像本人的段置零
/// (时长与字节偏移不变)。安静段、有声不足 1 s 的段、紧跟本人语段的下一段一律保留:宁可漏进他人半秒,
/// 也不吞本人的字。只能丢掉“只有他人在说”的段,本人与他人同时说话分不开。
/// 实测(2026-11-09,1.5 s 窗):本人 0.57–0.86,他人与 TTS ≤ 0.24;门限沿用 VoiceIdentityPolicy(相似度 ≥ 0.35)。
@MainActor
final class OwnVoiceFilter {
    static let hop = 8_000
    static let frame = 320
    static let window = 24_000
    static let minVoiced = 16_000
    static let silenceDbfs: Float = -50

    private let profile: [Float]
    private let embed: ([Float]) async throws -> [Float]
    private(set) var kept: [Bool] = []
    private var ownerBefore = false

    init(profile: [Float], embed: @escaping ([Float]) async throws -> [Float] = {
        try await VoiceEmbeddingModel.shared.embedding(of: $0)
    }) {
        self.profile = profile
        self.embed = embed
    }

    var dropped: Int { kept.filter { !$0 }.count }
    /// 已判定到的样本数;final 判过末尾半段后可能超过实际长度。
    var decided: Int { kept.count * Self.hop }

    func keeps(_ sample: Int) -> Bool { sample / Self.hop >= kept.count || kept[sample / Self.hop] }

    /// 判定新凑满的段;final 时连同末尾不足 0.5 s 的半段。samples[0] 是第 base 个样本(base 按段对齐)。
    func decide(_ samples: [Int16], base: Int = 0, final: Bool = false) async {
        while true {
            let index = kept.count
            let start = index * Self.hop - base
            let end = min(start + Self.hop, samples.count)
            guard end > start, end - start == Self.hop || final else { return }
            let keep = await judge(samples, hop: start..<end)
            guard kept.count == index else { continue }  // 另一路调用在等待期间已判过这一段
            kept.append(keep)
        }
    }

    /// 判定后把不像本人的段置零。
    func filter(_ pcm: Data, final: Bool = false) async -> Data {
        var samples = Self.samples(pcm)
        await decide(samples, final: final)
        mask(&samples)
        return samples.withUnsafeBytes { Data($0) }
    }

    func mask(_ samples: inout [Int16]) {
        for i in samples.indices where !keeps(i) { samples[i] = 0 }
    }

    private func judge(_ samples: [Int16], hop: Range<Int>) async -> Bool {
        let voicedInHop = stride(from: hop.lowerBound, to: hop.upperBound - Self.frame + 1, by: Self.frame)
            .filter { Self.voiced(samples, at: $0) }.count
        guard voicedInHop * 4 >= hop.count / Self.frame else { return true }  // 安静段
        // 从段尾往回收有声帧,最多回看两个窗长:句首前的静音不稀释声纹。
        var voiced: [Float] = []
        var at = hop.upperBound - Self.frame
        while at >= max(0, hop.upperBound - 2 * Self.window), voiced.count < Self.window {
            if Self.voiced(samples, at: at) {
                voiced.insert(contentsOf: samples[at..<at + Self.frame].map { Float($0) / 32_768 }, at: 0)
            }
            at -= Self.frame
        }
        guard voiced.count >= Self.minVoiced else { return true }  // 证据不足
        guard let candidate = try? await embed(voiced) else { return true }  // 模型出错不丢音
        let owner = VoiceIdentityPolicy.accepts(profile, candidate: candidate)
        defer { ownerBefore = owner }
        return owner || ownerBefore
    }

    private static func voiced(_ samples: [Int16], at start: Int) -> Bool {
        guard start >= 0, start + frame <= samples.count else { return false }
        var sum: Float = 0
        for s in samples[start..<start + frame] { sum += Float(s) * Float(s) }
        return 20 * log10(max((sum / Float(frame)).squareRoot() / 32_768, 1e-9)) > silenceDbfs
    }

    static func samples(_ pcm: Data) -> [Int16] {
        let count = pcm.count / 2
        var samples = [Int16](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { pcm.prefix(count * 2).copyBytes(to: $0) }
        return samples
    }
}

/// 送往 BlackHole 的音频过一遍 OwnVoiceFilter:比原链路晚 lead 出声,让每段在播放前判完。
/// 按到帧节奏放行(不是判完整段一次塞进缓冲),播放仍是连续的;停帧 idleFlush 后判掉尾段、清空,下句重来。
@MainActor
final class OwnVoiceStream {
    static let lead = 12_000  // 0.75 s:凑满 0.5 s 一段 + 一次推理(实测约 40 ms)+ 主线程排队的余量
    static let idleFlush: Duration = .milliseconds(250)

    let profile: [Float]
    private let jitter: JitterBuffer
    private var filter: OwnVoiceFilter
    private var samples: [Int16] = []  // 从第 base 个样本起;常开麦不停帧,只留判定还要回看的部分
    private var base = 0
    private var released = 0
    private var deciding = false
    private var idle: Task<Void, Never>?
    private var generation = 0

    private let embed: ([Float]) async throws -> [Float]

    init(jitter: JitterBuffer, profile: [Float], embed: @escaping ([Float]) async throws -> [Float] = {
        try await VoiceEmbeddingModel.shared.embedding(of: $0)
    }) {
        self.jitter = jitter
        self.profile = profile
        self.embed = embed
        filter = OwnVoiceFilter(profile: profile, embed: embed)
    }

    func push(_ pcm: Data) {
        samples += OwnVoiceFilter.samples(pcm)
        release(upTo: received - Self.lead)
        decideNext()
        idle?.cancel()
        let generation = generation
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.idleFlush)
            guard !Task.isCancelled else { return }
            await self?.flush(generation)
        }
    }

    /// 断链:丢掉没放出去的音频,与 Uplink 清空抖动缓冲一致。
    func reset() {
        idle?.cancel()
        generation += 1
        filter = OwnVoiceFilter(profile: profile, embed: embed)
        samples = []
        base = 0
        released = 0
        deciding = false
    }

    private var received: Int { base + samples.count }

    private func decideNext() {
        guard !deciding, received - filter.decided >= OwnVoiceFilter.hop else { return }
        deciding = true
        let generation = generation
        let (snapshot, snapshotBase) = (samples, base)
        Task { [weak self] in
            guard let self else { return }
            await filter.decide(snapshot, base: snapshotBase)
            guard generation == self.generation else { return }
            deciding = false
            release(upTo: received - Self.lead)
            decideNext()
        }
    }

    private func flush(_ generation: Int) async {
        let (filter, before) = (filter, received)
        await filter.decide(samples, base: base, final: true)
        // 判定期间又来了帧:话没说完,留给下一次停顿再收尾。
        guard generation == self.generation, received == before else { return }
        release(upTo: received)
        reset()
    }

    private func release(upTo target: Int) {
        let end = min(target, filter.decided, received)
        guard end > released else { return }
        var chunk = Array(samples[(released - base)..<(end - base)])
        for i in chunk.indices where !filter.keeps(released + i) { chunk[i] = 0 }
        chunk.withUnsafeBufferPointer { jitter.push($0) }
        released = end
        // 判定回看两个窗长;再早的已放行样本可以丢。攒满 10 s 才挪一次,省得每帧搬数组。
        let needed = min(released, filter.decided - 2 * OwnVoiceFilter.window)
        let drop = (needed - base) / OwnVoiceFilter.hop * OwnVoiceFilter.hop
        if drop >= 20 * OwnVoiceFilter.hop {
            samples.removeFirst(drop)
            base += drop
        }
    }
}
