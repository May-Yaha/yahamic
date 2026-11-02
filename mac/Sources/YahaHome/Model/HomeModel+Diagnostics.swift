import Foundation
import YahamicCore

// 诊断命令:录制(capture)、指标采样(metrics)、压测(stress)。
extension HomeModel {
    /// 录制设备音频 N 秒(16 kHz 单声道 S16LE,解码后 PCM)并落盘 WAV,返回路径与包络分析。
    func captureStream(seconds: Int) async -> [String: Any] {
        guard mic.isOnline else { return ["error": "设备不在线"] }
        guard let uplink else { return ["error": "链路未启动"] }
        // 抽头回调在 Uplink 内部串行队列上触发,与这里的读取并发,用加锁盒子收。
        let box = PCMBox()
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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yahamic_stream_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).wav")
        do {
            try wavFile(pcm: captured, samples: samples).write(to: url, options: .withoutOverwriting)
        } catch {
            return ["error": "写入失败:\(error.localizedDescription)"]
        }
        return ["path": url.path, "seconds": seconds, "samples": samples,
                "bursts": bursts, "peakDb": peakDb]
    }

    private func wavFile(pcm: Data, samples: Int) -> Data {
        var wav = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        let bytes = UInt32(samples * 2)
        wav.append(contentsOf: Array("RIFF".utf8)); le32(36 + bytes)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16)
        le16(1); le16(1); le32(16000); le32(32000); le16(2); le16(16)
        wav.append(contentsOf: Array("data".utf8)); le32(bytes)
        wav.append(pcm.prefix(Int(bytes)))
        return wav
    }

    /// 采样 N 秒流指标,返回汇总(不动任何状态)。
    func collectMetrics(seconds: Int) async -> [String: Any] {
        guard mic.isOnline else { return ["error": "设备不在线"] }
        var fps: [Int] = [], levels: [Double] = [], buffers: [Double] = []
        let start = mic.state
        for _ in 0..<seconds {
            try? await Task.sleep(for: .seconds(1))
            guard mic.isOnline else { return ["error": "设备中途掉线"] }
            fps.append(mic.state.framesPerSecond)
            levels.append(mic.state.levelDb)
            buffers.append(mic.state.bufferMs)
        }
        let now = Self.diagFields(mic.state.diag), before = Self.diagFields(start.diag)
        return [
            "seconds": seconds,
            "fpsAvg": fps.reduce(0, +) / max(fps.count, 1),
            "fpsMin": fps.min() ?? 0,
            "levelDbMax": levels.max() ?? -120.0,
            "bufferMsAvg": buffers.reduce(0.0, +) / Double(max(buffers.count, 1)),
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
        log("压测开始:\(seconds)s,音源=\(source)(结束自动恢复原状态)")
        if pttEnabled { pttEnabled = false }       // 常开,保证全程送声
        uplink?.sendControl(muted: false)
        try? await Task.sleep(for: .milliseconds(800))  // 等静音解除生效

        // TTS 音源:一段足够长的文本,结束时主动终止。
        var speaker: Process?
        if source == "tts" {
            // 编号句子:转写输出里"每句应出现一次",重复立即可数。
            let lines = ["压力测试第一句,验证链路。", "第二句,验证渲染。",
                         "第三句,验证采集。", "第四句,验证缓冲。", "第五句,验证稳定性。"]
            let rounds = seconds / 4 + 1
            let text = (0..<rounds).map { lines[$0 % lines.count] }.joined(separator: " ")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", "Tingting", text]
            try? process.run()
            speaker = process
        }

        var report = await collectMetrics(seconds: seconds)

        // 不在 MainActor 同步等待长文本 TTS 退出,避免压测结束时阻塞 UI 与控制接口。
        speaker?.terminate()
        // 恢复原状态(重新开启 push-to-talk 会自动回到静音待命)。
        pttEnabled = savedPtt
        if !savedPtt { uplink?.sendControl(muted: savedMuted) }
        report["source"] = source
        log("压测完成:\(report)")
        return report
    }
}

// capture 抽头的线程安全容器:锁操作收在同步方法里(async 上下文可直接调用)。
private final class PCMBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
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
