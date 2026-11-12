import Foundation
import MLXAudioSTT
import Testing

@testable import YahaDesk

struct CaptionPacingTests {
    private final class TestBundleToken {}

    @Test func sentencesFinalizeOnceAndPartialKeepsGrowing() {
        var s = CaptionSentences()
        #expect(s.update(tail: "Um, hi, I'm Marco").isEmpty)
        #expect(s.partial == "hi, I'm Marco")
        // 整句出现就定稿;重转改了前面的字也不再改已出的句子。
        #expect(s.update(tail: "Hi, I'm Marco. I've been an") == ["Hi, I'm Marco."])
        #expect(s.update(tail: "Hi I'm Marco. I've been an engineer").isEmpty)
        #expect(s.partial == "I've been an engineer")
        // 切段:ASR 补的句号去掉,半句接到下一段。
        #expect(s.cut("Hi, I'm Marco. I've been an engineer for").isEmpty)
        #expect(s.update(tail: "15 years. A manager") == ["I've been an engineer for 15 years."])
        #expect(s.flush() == ["A manager"])
        #expect(s.partial.isEmpty)
    }

    @Test func longSentenceBreaksAtCommaWithinTwoLines() {
        var s = CaptionSentences()
        let long = "When I started my career as an engineer, there was no ladder at all, and nobody could tell me what the next step was supposed to look like."
        let lines = s.update(tail: long) + s.flush()
        #expect(lines.count >= 2)
        #expect(lines.allSatisfy { CaptionSentences.weight($0) <= CaptionSentences.maxWeight })
        #expect(lines.joined(separator: " ") == long)
        var zh = CaptionSentences()
        let chinese = String(repeating: "我们今天讨论职业发展阶梯", count: 8) + "。"
        #expect((zh.update(tail: chinese) + zh.flush()).allSatisfy { CaptionSentences.weight($0) <= CaptionSentences.maxWeight })
    }

    @Test func queueHoldsEachSentenceAndMergesBacklog() {
        var q = CaptionQueue()
        #expect(q.tick(now: 0, partial: "Hi, I'm")?.final == false)
        q.push(.init(original: "Hi, I'm Marco."))
        let first = q.tick(now: 0.1, partial: "I've")
        #expect(first?.original == "Hi, I'm Marco." && first?.final == true)
        // 半句没在停留期间顶掉整句。
        #expect(q.tick(now: 1.0, partial: "I've been an engineer")?.original == "Hi, I'm Marco.")
        #expect(q.tick(now: 1.5, partial: "I've been an engineer")?.final == false)
        // 半句长成整句:同一屏,不换 id。
        q.push(.init(original: "I've been an engineer for 15 years."))
        let grown = q.tick(now: 1.6, partial: nil)
        #expect(grown?.id == q.tick(now: 1.7, partial: nil)?.id)
        // 排队的几句放得下就并成一屏。
        q.push(.init(original: "One."))
        q.push(.init(original: "Two."))
        #expect(q.tick(now: 10, partial: nil)?.original == "One. Two.")
        #expect(q.tick(now: 20, partial: nil) == nil)
    }

    /// 用真实视频回放:按实时节奏喂音频(识别多慢,下一轮就多攒多少),记录屏幕上每一屏停了多久。
    /// YAHA_CAPTION_PCM 是 16 kHz 单声道 s16le(ffmpeg -ac 1 -ar 16000 -f s16le),YAHA_CAPTION_SECONDS 限定时长。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAHA_CAPTION_PCM"] != nil))
    func replayVideoAtRealTimePace() async throws {
        let env = ProcessInfo.processInfo.environment
        let modelDirectory = try #require(env["YAHA_QWEN_MODEL_DIR"])
        let seconds = Double(env["YAHA_CAPTION_SECONDS"] ?? "120") ?? 120
        let pcm = try Data(contentsOf: URL(fileURLWithPath: try #require(env["YAHA_CAPTION_PCM"])))
            .prefix(Int((Double(env["YAHA_CAPTION_FROM"] ?? "0") ?? 0) + seconds) * LiveTranscript.bytesPerSecond)
        let metallib = try #require(Bundle(for: TestBundleToken.self).resourceURL?
            .appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources"))
        _ = FileManager.default.changeCurrentDirectoryPath(metallib.path)
        let speech = LocalSpeechRecognizer { _ in try await Qwen3ASRModel.fromModelDirectory(URL(fileURLWithPath: modelDirectory)) }
        try await speech.prepare()

        var stream = CaptionStream()
        var queue = CaptionQueue()
        var shown: CaptionQueue.Caption?
        var screens: [(at: Double, caption: CaptionQueue.Caption)] = []
        var updates = 0
        var at = Int(Double(env["YAHA_CAPTION_FROM"] ?? "0") ?? 0) * LiveTranscript.bytesPerSecond  // 已喂的字节
        var clock = 0.0  // 模拟时钟 = 音频播放到的秒数
        var step = 0.25
        var partial = ""  // App 里半句和定稿句同一拍更新:识别期间显示的还是上一轮的半句
        let display = { (now: Double, queue: inout CaptionQueue) in
            let caption = queue.tick(now: now, partial: partial)
            if caption != shown {
                updates += 1
                if let caption, caption.id != shown?.id { screens.append((now, caption)) }
                shown = caption
            }
        }
        while at < pcm.count {
            let n = min(pcm.count - at, Int(step * Double(LiveTranscript.bytesPerSecond)) & ~1)
            let chunk = Data(pcm[pcm.startIndex + at..<pcm.startIndex + at + n])
            at += n
            let started = Date()
            var trace = ""
            let lines = await stream.feed(chunk) {
                let text = try await speech.transcribe($0)
                trace += String(format: "  asr %.1fs: %@\n", Double($0.count) / 32_000, text)
                return text
            }
            if env["YAHA_CAPTION_TRACE"] != nil {
                print(String(format: "@%.1f", clock) + "\n" + trace + lines.map { "  => " + $0 }.joined(separator: "\n") + "\n  partial: " + stream.partial)
            }
            let spent = Date().timeIntervalSince(started)
            // 识别期间显示循环照常每 100 ms 跑。
            var t = clock
            while t < clock + 0.25 + spent { display(t, &queue); t += 0.1 }
            clock += 0.25 + spent
            step = 0.25 + spent
            for line in lines { queue.push(.init(original: line)) }
            partial = stream.partial
            display(clock, &queue)
        }
        var report = ""
        for (i, s) in screens.enumerated() {
            let hold = (i + 1 < screens.count ? screens[i + 1].at : clock) - s.at
            report += String(format: "%7.1fs  停 %4.1fs  %@ %@\n", s.at, hold, s.caption.final ? "■" : "…", s.caption.original)
        }
        let holds = zip(screens, screens.dropFirst()).map { $1.at - $0.at }
        report += "屏数 \(screens.count),刷新 \(updates) 次,<1 秒就被换掉的 \(holds.filter { $0 < 1 }.count) 屏,"
            + String(format: "实时倍率 %.2f\n", clock / seconds)
        try report.write(toFile: env["YAHA_CAPTION_REPORT"] ?? "/tmp/caption-report.txt", atomically: true, encoding: .utf8)
        #expect(!screens.isEmpty)
        #expect(screens.allSatisfy { CaptionSentences.weight($0.caption.original) <= CaptionSentences.maxWeight + 20 })
    }
}
