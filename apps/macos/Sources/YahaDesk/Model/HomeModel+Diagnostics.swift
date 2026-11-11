import Foundation
import DeskCore
import FluidAudio

struct MetricDistribution {
    let minimum: Double
    let p05: Double
    let median: Double
    let p95: Double
    let maximum: Double
    let average: Double
}

struct AudioCaptureGate {
    private(set) var busy = false
    private var pendingRestore: PrivateAudioCaptureRestore?

    mutating func acquire() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }

    mutating func release() { busy = false }

    mutating func awaitMuteBeforeRelease(savedPtt: Bool, savedMuted: Bool) {
        pendingRestore = PrivateAudioCaptureRestore(savedPtt: savedPtt, savedMuted: savedMuted)
    }

    mutating func completeRestoreIfSafe(connected: Bool, muted: Bool) -> PrivateAudioCaptureRestore? {
        guard let pendingRestore, !connected || muted else { return nil }
        self.pendingRestore = nil
        busy = false
        return pendingRestore
    }
}

struct PrivateAudioCaptureRestore: Equatable {
    let savedPtt: Bool
    let savedMuted: Bool
}

enum AudioDiagnostics {
    static func bufferMilliseconds(_ jitter: JitterBuffer) -> Double {
        Double(jitter.count) / 16
    }

    static func distribution(_ values: [Double]) -> MetricDistribution {
        guard !values.isEmpty else {
            return MetricDistribution(minimum: 0, p05: 0, median: 0, p95: 0, maximum: 0, average: 0)
        }
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            let position = fraction * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = Int(position.rounded(.up))
            guard lower != upper else { return sorted[lower] }
            return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
        }
        return MetricDistribution(
            minimum: sorted[0], p05: percentile(0.05), median: percentile(0.5),
            p95: percentile(0.95), maximum: sorted[sorted.count - 1],
            average: values.reduce(0, +) / Double(values.count)
        )
    }

    static func allowedEnhancementInput(_ url: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> Bool {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let temporary = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard parent.path == temporary.path, standardized.lastPathComponent.hasPrefix("yahadesk_"),
              standardized.pathExtension.lowercased() == "wav" else { return false }
        if FileManager.default.fileExists(atPath: standardized.path) {
            let resolved = standardized.resolvingSymlinksInPath()
            guard resolved.deletingLastPathComponent().path == temporary.path,
                  (try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                return false
            }
        }
        return true
    }
}

// 诊断命令:录制(capture)、指标采样(metrics)、压测(stress)。
extension HomeModel {
    /// 录制设备音频 N 秒(16 kHz 单声道 S16LE,解码后 PCM)并落盘 WAV,返回路径与包络分析。
    func captureStream(seconds: Int) async -> [String: Any] {
        guard mic.isOnline else { return ["error": "设备不在线"] }
        guard let uplink else { return ["error": "链路未启动"] }
        guard audioCaptureGate.acquire() else { return ["error": "已有音频采集任务在运行"] }
        defer {
            uplink.onAudioTap = nil
            audioCaptureGate.release()
        }
        // 抽头回调在 Uplink 内部串行队列上触发,与这里的读取并发,用加锁盒子收。
        let box = PCMBox(capacityBytes: seconds * 16_000 * 2)
        uplink.onAudioTap = { data in box.append(data) }
        try? await Task.sleep(for: .seconds(seconds))
        uplink.onAudioTap = nil
        let captured = box.snapshot()
        let samples = captured.count / 2
        var pcm = [Int16](repeating: 0, count: samples)  // 本机小端,按字节拷避免未对齐读
        _ = pcm.withUnsafeMutableBytes { captured.copyBytes(to: $0) }
        // 包络:20ms 一窗,数语音段
        let win = 320
        var bursts = 0, inBurst = false
        var peakDb = -120.0
        var i = 0
        while i + win <= samples {
            let sum = pcm[i..<i + win].reduce(0.0) { $0 + Double($1) * Double($1) }
            let db = 20 * log10(max((sum / Double(win)).squareRoot() / 32768, 1e-9))
            peakDb = max(peakDb, db)
            if db > -55 {
                if !inBurst { inBurst = true; bursts += 1 }
            } else {
                inBurst = false
            }
            i += win
        }
        // 写进用户私有临时目录,随机文件名 + withoutOverwriting:不跟随别人预放的链接/文件。
        let result = writeCapture(captured, prefix: "yahadesk_stream")
        guard let url = result.url else { return ["error": result.error ?? "写入失败"] }
        return ["path": url.path, "seconds": seconds, "samples": samples,
                "bursts": bursts, "peakDb": peakDb]
    }

    private func writeCapture(_ captured: Data, prefix: String) -> (url: URL?, error: String?) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).wav")
        do {
            try PCM16Wave.data(captured).write(to: url, options: .withoutOverwriting)
            return (url, nil)
        } catch {
            return (nil, "写入失败:\(error.localizedDescription)")
        }
    }

    /// Voice-profile enrollment capture: temporarily opens the mic, captures decoded 16 kHz PCM, then restores PTT.
    func captureVoicePCM(seconds: Int) async throws -> Data {
        guard mic.isOnline, let uplink else { throw VoiceProfileError("设备不在线") }
        guard audioCaptureGate.acquire() else { throw VoiceProfileError("已有音频采集任务正在运行，请稍后重试") }
        let savedPtt = pttEnabled
        let savedMuted = mic.state.muted
        recordings.setPrivateCapture(true)
        if pttEnabled { pttEnabled = false }
        uplink.sendControl(muted: false)
        defer {
            uplink.onAudioTap = nil
            finishPrivateAudioCapture(savedPtt: savedPtt, savedMuted: savedMuted, uplink: uplink)
        }
        try await Task.sleep(for: .milliseconds(800))
        guard mic.isOnline else { throw VoiceProfileError("设备在录音前断开") }
        let box = PCMBox(capacityBytes: seconds * 16_000 * 2)
        uplink.onAudioTap = { data in box.append(data) }
        try await Task.sleep(for: .seconds(seconds))
        uplink.onAudioTap = nil
        guard mic.isOnline else { throw VoiceProfileError("录音过程中设备断开") }
        return box.snapshot()
    }

    /// Offline A/B only: LocalVQE without far-end reference performs denoise/dereverb, not speaker filtering.
    func enhanceCapture(path: String) async -> [String: Any] {
        let input = URL(fileURLWithPath: path)
        guard AudioDiagnostics.allowedEnhancementInput(input), FileManager.default.fileExists(atPath: input.path) else {
            return ["error": "只允许处理 Yaha Desk 在临时目录生成的 WAV"]
        }
        do {
            let enhancer = try await LocalVqeManager()
            let samples = try await enhancer.process(micURL: input, referenceURL: nil)
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("yahadesk_enhanced_\(UUID().uuidString.prefix(8)).wav")
            try PCM16Wave.data(samples).write(to: output, options: .withoutOverwriting)
            return ["path": output.path, "samples": samples.count, "model": "LocalVQE-v1.3-no-reference"]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// 采样 N 秒流指标,返回汇总(不动任何状态)。
    func collectMetrics(seconds: Int) async -> [String: Any] {
        guard mic.isOnline else { return ["error": "设备不在线"] }
        var fps: [Int] = [], levels: [Double] = [], buffers: [Double] = []
        let start = mic.state
        let clock = ContinuousClock()
        let startedAt = clock.now
        for tick in 1...(seconds * 10) {
            let deadline = startedAt.advanced(by: .milliseconds(tick * 100))
            do { try await clock.sleep(until: deadline) } catch { return ["error": "采样已取消"] }
            guard mic.isOnline else { return ["error": "设备中途掉线"] }
            buffers.append(AudioDiagnostics.bufferMilliseconds(jitter))
            if tick % 10 == 0 {
                fps.append(mic.state.framesPerSecond)
                levels.append(mic.state.levelDb)
            }
        }
        let buffer = AudioDiagnostics.distribution(buffers)
        let now = Self.diagFields(mic.state.diag), before = Self.diagFields(start.diag)
        return [
            "seconds": seconds,
            "fpsAvg": fps.reduce(0, +) / max(fps.count, 1),
            "fpsMin": fps.min() ?? 0,
            "levelDbMax": levels.max() ?? -120.0,
            "bufferMsAvg": buffer.average,
            "bufferMsMin": buffer.minimum,
            "bufferMsP05": buffer.p05,
            "bufferMsP50": buffer.median,
            "bufferMsP95": buffer.p95,
            "bufferMsMax": buffer.maximum,
            "overflowsDelta": mic.state.overflows - start.overflows,
            "underrunsDelta": mic.state.underruns - start.underruns,
            "droppedFrames": mic.state.droppedFrames,                          // 链路全程累计丢帧/跳帧
            "droppedFramesDelta": mic.state.droppedFrames - start.droppedFrames,  // 采样窗口内新增
            // 采样窗口内的分阶段计数增量(零帧断点定位,口径见 Uplink.Diag)。
            "diagDelta": now.merging(before) { $0 - $1 },
        ]
    }

    /// 压测:保存当前状态 → 常开麦克风(+可选 TTS 播放作音源)→ 采样 → 恢复。
    func runStress(seconds: Int, source: String) async -> [String: Any] {
        guard mic.isOnline else { return ["error": "设备不在线"] }
        let savedPtt = pttEnabled
        let savedMuted = mic.state.muted
        guard let uplink else { return ["error": "链路未启动"] }
        guard audioCaptureGate.acquire() else { return ["error": "已有音频采集任务在运行"] }
        recordings.setPrivateCapture(true)
        let box = PCMBox(capacityBytes: seconds * 16_000 * 2)
        uplink.onAudioTap = { data in box.append(data) }
        var speaker: Process?
        defer {
            uplink.onAudioTap = nil
            speaker?.terminate()
            finishPrivateAudioCapture(savedPtt: savedPtt, savedMuted: savedMuted, uplink: uplink)
        }
        log("压测开始:\(seconds)s,音源=\(source)(结束自动恢复原状态)")
        if pttEnabled { pttEnabled = false }       // 常开,保证全程送声
        uplink.sendControl(muted: false)
        try? await Task.sleep(for: .milliseconds(800))  // 等静音解除生效

        // TTS 音源:一段足够长的文本,结束时主动终止。
        var referenceText = ""
        if source == "tts" {
            // 编号句子:转写输出里"每句应出现一次",重复立即可数。
            let lines = ["压力测试第一句,验证链路。", "第二句,验证渲染。",
                         "第三句,验证采集。", "第四句,验证缓冲。", "第五句,验证稳定性。"]
            let rounds = seconds / 4 + 1
            let text = (0..<rounds).map { lines[$0 % lines.count] }.joined(separator: " ")
            referenceText = text
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", "Tingting", text]
            try? process.run()
            speaker = process
        }

        var report = await collectMetrics(seconds: seconds)

        uplink.onAudioTap = nil
        let captured = box.snapshot()
        let capture = writeCapture(captured, prefix: "yahadesk_stress")
        if let url = capture.url {
            report["decodedPath"] = url.path
            report["decodedSamples"] = captured.count / 2
        } else if let error = capture.error {
            report["captureError"] = error
        }
        if !referenceText.isEmpty { report["referenceText"] = referenceText }
        report["source"] = source
        log("压测完成:\(report)")
        return report
    }

    /// Keep ordinary recording suppressed until the device confirms mute. Uplink callbacks preserve
    /// status/audio ordering, so a mute status also proves that private tail frames were dispatched.
    func finishPrivateAudioCapture(savedPtt: Bool, savedMuted: Bool, uplink: Uplink) {
        audioCaptureGate.awaitMuteBeforeRelease(savedPtt: savedPtt, savedMuted: savedMuted)
        if pttEnabled != savedPtt { pttEnabled = savedPtt }
        uplink.sendControl(muted: true)
        // Connected sessions wait for a subsequent Uplink state emitted from its audio/status queue.
        // That preserves ordering with all already-dispatched private tail frames.
        if !mic.state.connected { completePrivateAudioCaptureIfSafe(mic.state) }
    }

    func completePrivateAudioCaptureIfSafe(_ state: Uplink.State) {
        guard let restore = audioCaptureGate.completeRestoreIfSafe(
            connected: state.connected, muted: state.muted
        ) else { return }
        recordings.setPrivateCapture(false)
        if state.connected, !restore.savedPtt, !restore.savedMuted {
            uplink?.sendControl(muted: false)
        }
    }
}

// capture 抽头的线程安全容器与本地转文字共用同一实现。
private typealias PCMBox = PCMBuffer
