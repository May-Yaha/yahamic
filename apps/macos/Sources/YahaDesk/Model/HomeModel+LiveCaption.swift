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
        captionPendingLines = []
        captionTranslateTask?.cancel()
        captionTranslateTask = nil
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
            startCaptionDisplay()
            var stream = CaptionStream()
            // 网盘备份:一段话的声音编成 Opus,转写全文(定稿句 + 半句)随它存成同名 txt。
            let encoder = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
                .flatMap(MicEncoder.init(input:))
            var spoken = ""
            defer { endCaptionTake(LiveTranscript.join(spoken, captionPartial)) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let chunk = buffer.take()
                // 连着放不停顿也每 10 分钟切一段,别让一个文件在内存里越攒越大;关了备份或静音 2 秒就收掉当前这段。
                if let take = captionRecordings.currentTake,
                   !captionBackup || stream.silence >= 2 || Date().timeIntervalSince(take) > 600 {
                    endCaptionTake(LiveTranscript.join(spoken, captionPartial))
                    spoken = ""
                }
                if captionBackup, captionRecordings.currentTake == nil, !CaptionStream.isQuiet(chunk) {
                    captionRecordings.talking(true)
                }
                for packet in encoder?.push(pcm16k: chunk) ?? [] {
                    captionRecordings.append(packet, samples: MicEncoder.frameSamples)
                }
                let speech = localSpeech
                let lines = await stream.feed(chunk) { try await speech.transcribe($0) }
                guard !Task.isCancelled, liveCaptionEnabled else { return }
                captionPartial = stream.partial
                for line in lines {
                    spoken = CaptionSentences.join(spoken, line)
                    if captionTranslate {
                        translateCaption(line)
                    } else {
                        captionQueue.push(.init(original: line))
                    }
                }
            }
        }
    }

    /// 每 100 ms 问一次队列该显示什么,变了才动浮层:识别那一轮再慢,换屏节奏也不受影响。
    private func startCaptionDisplay() {
        captionQueue = CaptionQueue()
        captionPartial = ""
        captionDisplayTask = Task { [weak self] in
            var shown: CaptionQueue.Caption?
            while let self, !Task.isCancelled {
                // 翻译时主字幕是译文:半句没有译文,只上整句。
                let caption = captionQueue.tick(now: ProcessInfo.processInfo.systemUptime,
                                                partial: captionTranslate ? nil : captionPartial)
                if caption != shown {
                    shown = caption
                    if let caption { subtitles.show(caption) } else { subtitles.hide() }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stopLiveCaption() {
        captionTask?.cancel()
        captionTask = nil
        captionDisplayTask?.cancel()
        captionDisplayTask = nil
        captionTranslateTask?.cancel()
        captionTranslateTask = nil
        captionPendingLines = []
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

    /// 原文语言只在这些里判:几个字的短句不加约束常被认成西班牙语、匈牙利语。
    static let captionSources: [NLLanguage] = [
        .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean, .french, .german, .spanish, .russian,
    ]

    /// 定稿句按先后翻,翻完连原文一起进上屏队列。翻得比讲得慢时,排着的几句并成一次翻,别越拖越晚。
    private func translateCaption(_ line: String) {
        captionPendingLines.append(line)
        guard captionTranslateTask == nil else { return }
        captionTranslateTask = Task { [weak self] in
            while let self, !captionPendingLines.isEmpty, !Task.isCancelled {
                let text = captionPendingLines.reduce("", CaptionSentences.join)
                captionPendingLines = []
                let translation = await translated(text)
                guard !Task.isCancelled, captionTranslate else { break }
                captionQueue.push(.init(original: text, translation: translation ?? ""))
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
