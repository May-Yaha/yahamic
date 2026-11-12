import AVFoundation
import DeskCore
import DeskShared
import Foundation
import NaturalLanguage
import Translation

// 视频字幕:本机正在播放的声音(SystemAudioTap)→ 本地 Qwen3-ASR → 可选 Apple 系统翻译 → 字幕浮层。
// 与本地听写共用 localSpeech(actor 串行,听写那一轮会让字幕晚一拍),不占麦克风采集闸门、不碰 uplink。
extension HomeModel {
    static let captionTargets: [(id: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
    ]

    func liveCaptionSettingChanged() {
        guard started else { return }
        liveCaptionEnabled ? startLiveCaption() : stopLiveCaption()
    }

    func captionTranslationChanged() {
        captionSessions = [:]
        captionPairStatus = [:]
        captionPendingText = nil
        captionTranslateTask?.cancel()
        captionTranslateTask = nil
        if !captionTranslate { subtitles.show(original: subtitles.original, translation: "") }
    }

    func startLiveCaption() {
        guard captionTask == nil else { return }
        let buffer = PCMBuffer()
        captionTask = Task { [weak self] in
            // 首次启动 AudioDeviceStart 会一直等用户在系统授权框里点允许:放后台线程,别卡住主线程。
            let tap = await Task.detached { SystemAudioTap(onPCM: { buffer.append($0) }) }.value
            guard let self, !Task.isCancelled else { tap?.stop(); return }
            guard let tap else {
                log("⚠️ 视频字幕:系统声音采集启动失败(系统设置 → 隐私与安全性 → 屏幕与系统录音 里允许 Yaha Desk)")
                captionTask = nil
                liveCaptionEnabled = false
                return
            }
            captionTap = tap
            log("视频字幕:已开启(识别本机播放的声音)")
            do {
                try await localSpeech.prepare()
            } catch {
                log("⚠️ 视频字幕:Qwen3 模型准备失败:\(error.localizedDescription)")
                captionTask = nil
                liveCaptionEnabled = false
                return
            }
            var pending = Data()
            var live = LiveTranscript()
            var lastLine = ""
            var shown = ""
            var quietSince: Date?
            // 网盘备份:一段话的声音编成 Opus,转写全文(定稿段 + 末段)随它存成同名 txt。
            let encoder = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
                .flatMap(MicEncoder.init(input:))
            var spoken = ""
            var tailText = ""
            defer { endCaptionTake(LiveTranscript.join(spoken, tailText)) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let chunk = buffer.take()
                pending.append(chunk)
                // 连着放不停顿也每 10 分钟切一段,别让一个文件在内存里越攒越大;关了备份就收掉当前这段。
                if let take = captionRecordings.currentTake, !captionBackup || Date().timeIntervalSince(take) > 600 {
                    endCaptionTake(LiveTranscript.join(spoken, tailText))
                    spoken = ""
                    tailText = ""
                }
                if captionBackup, captionRecordings.currentTake == nil, !Self.isQuiet(chunk) { captionRecordings.talking(true) }
                for packet in encoder?.push(pcm16k: chunk) ?? [] {
                    captionRecordings.append(packet, samples: MicEncoder.frameSamples)
                }
                // 太久不转会越积越长:只留最近 30 秒。
                if pending.count > 30 * LiveTranscript.bytesPerSecond {
                    pending.removeFirst(pending.count - 30 * LiveTranscript.bytesPerSecond)
                }
                if Self.isQuiet(pending.suffix(3 * LiveTranscript.bytesPerSecond / 2)) {
                    quietSince = quietSince ?? Date()
                    if Date().timeIntervalSince(quietSince!) >= 2, !shown.isEmpty || !pending.isEmpty {
                        endCaptionTake(LiveTranscript.join(spoken, tailText))
                        spoken = ""
                        tailText = ""
                        pending = Data()
                        live = LiveTranscript()
                        lastLine = ""
                        shown = ""
                        subtitles.hide()
                    }
                    continue
                }
                quietSince = nil
                var current = ""
                if let end = live.cut(pending) {
                    guard let text = try? await localSpeech.transcribe(Data(pending.prefix(end))) else { continue }
                    // 切点在停顿处,多半是半句话:ASR 补的句号去掉,和下一段接成一句再翻。
                    lastLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    spoken = LiveTranscript.join(spoken, lastLine)
                    tailText = ""
                    if lastLine.hasSuffix(".") || lastLine.hasSuffix("。") { lastLine.removeLast() }
                    pending.removeFirst(end)
                    live = LiveTranscript()
                } else if pending.count >= LiveTranscript.bytesPerSecond / 2 {
                    guard let text = try? await localSpeech.transcribe(pending) else { continue }
                    current = text
                    tailText = text
                } else {
                    continue
                }
                guard !Task.isCancelled, liveCaptionEnabled else { return }
                let text = Self.captionWindow(LiveTranscript.join(lastLine, current))
                guard !text.isEmpty, text != shown else { continue }
                shown = text
                subtitles.show(original: text, translation: captionTranslate ? subtitles.translation : "")
                if captionTranslate { translateCaption(text) }
            }
        }
    }

    func stopLiveCaption() {
        captionTask?.cancel()
        captionTask = nil
        captionTranslateTask?.cancel()
        captionTranslateTask = nil
        captionPendingText = nil
        captionTap?.stop()
        captionTap = nil
        subtitles.hide()
    }

    /// 一段话结束:有转写就存成同名 txt,再收尾录音(不到 1 秒的不留)。
    private func endCaptionTake(_ text: String) {
        guard let take = captionRecordings.currentTake else { return }
        if !text.isEmpty { captionRecordings.saveTranscript(text, for: take) }
        captionRecordings.talking(false)
    }

    /// 平均绝对幅度低于 300(约 -40 dBFS)当没声音。
    nonisolated static func isQuiet(_ pcm: Data) -> Bool {
        guard pcm.count >= 2 else { return true }
        let total = pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).reduce(0) { $0 + abs(Int($1)) } }
        return total / (pcm.count / 2) < 300
    }

    /// 字幕显示与翻译的那段:去掉 um/uh 等语气词,按句取最后两句(总长不超过 limit),不从半个词开始。
    /// 整句送去翻译才通顺;按字符截尾会把 "this lecture" 截成 "s lecture"。
    nonisolated static func captionWindow(_ text: String, limit: Int = 160) -> String {
        var text = text.replacingOccurrences(of: #"(?i)\b(u+m+|u+h+|e+r+m+|h+m+)\b[,.]?\s*"#, with: "",
                                             options: .regularExpression)
        text = text.replacingOccurrences(of: #"([.?!])(?=[A-Za-z])"#, with: "$1 ", options: .regularExpression)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let starts = tokenizer.tokens(for: text.startIndex..<text.endIndex).map(\.lowerBound)
        guard let last = starts.last else { return "" }
        let trimmed = { (s: Substring) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if text.distance(from: last, to: text.endIndex) > limit {  // 一句太长:从词边界截尾
            let tail = text.suffix(limit)
            return trimmed(tail.firstIndex(of: " ").map { tail[$0...] } ?? tail)
        }
        if starts.count > 1, text.distance(from: starts[starts.count - 2], to: text.endIndex) <= limit {
            return trimmed(text[starts[starts.count - 2]...])
        }
        return trimmed(text[last...])
    }

    /// 原文语言只在这些里判:几个字的短句不加约束常被认成西班牙语、匈牙利语。
    static let captionSources: [NLLanguage] = [
        .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean, .french, .german, .spanish, .russian,
    ]

    /// 同一时刻只有一个翻译在跑:跑完接着翻最新那句,中间的字幕不排队。ASR 每轮都出新字,
    /// 若新字一来就取消旧翻译,翻译永远跑不完。
    private func translateCaption(_ text: String) {
        captionPendingText = text
        guard captionTranslateTask == nil else { return }
        captionTranslateTask = Task { [weak self] in
            while let self, let text = self.captionPendingText, !Task.isCancelled {
                self.captionPendingText = nil
                let translation = await self.translated(text)
                guard !Task.isCancelled, self.captionTranslate, !self.subtitles.original.isEmpty else { break }
                if let translation { self.subtitles.show(original: self.subtitles.original, translation: translation) }
            }
            if !Task.isCancelled { self?.captionTranslateTask = nil }
        }
    }

    /// 系统翻译装了该语言对就离线翻;没装且填了 AI Key 就走 AI 润色同一个接口;都不行返回 nil。
    /// 原文已是目标语言返回空串(不显示译文)。
    private func translated(_ text: String) async -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Self.captionSources
        recognizer.processString(text)
        guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
        let source = Locale.Language(identifier: code)
        let target = Locale.Language(identifier: captionTarget)
        guard source.languageCode != target.languageCode else { return "" }
        let pair = "\(code)→\(captionTarget)"
        if captionPairStatus[pair] != .installed {  // 没装的每次再查:用户在设置里装好立刻生效
            captionPairStatus[pair] = await LanguageAvailability().status(from: source, to: target)
        }
        if captionPairStatus[pair] == .installed {
            let session = captionSessions[code] ?? TranslationSession(installedSource: source, target: target)
            captionSessions[code] = session
            if let response = try? await session.translate(text) { return response.targetText }
        }
        let name = Self.captionTargets.first { $0.id == captionTarget }?.name ?? captionTarget
        if aiPolish.hasKey {
            if captionMissingPairs.insert(pair).inserted { log("视频字幕:\(pair) 未装系统翻译语言,改用 AI 翻译") }
            do {
                return try await aiPolish.translate(text, to: name)
            } catch {
                if captionMissingPairs.insert("ai:" + error.localizedDescription).inserted {
                    log("⚠️ 视频字幕:\(error.localizedDescription)")
                }
                return nil
            }
        }
        if captionMissingPairs.insert(pair).inserted {
            log("⚠️ 视频字幕:未安装 \(pair) 翻译语言,到 系统设置 → 通用 → 语言与地区 → 翻译语言 下载,或在设置里填 AI Key")
        }
        return nil
    }
}
