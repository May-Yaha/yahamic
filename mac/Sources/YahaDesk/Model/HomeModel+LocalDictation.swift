import DeskCore
import Foundation

extension HomeModel {
    func localSTTSettingChanged() {
        guard localSTTEnabled else {
            stopLocalSTT()
            return
        }
        guard started else { return }
        prepareLocalSTT()
    }

    func prepareLocalSTT() {
        guard localSTTEnabled else { return }
        if case .preparing = localSTTState { return }
        if localSTTState == .ready { return }
        localSTTPrepareTask?.cancel()
        localSTTState = .preparing(0)
        log("本地转文字:准备 Qwen3-ASR 0.6B 6-bit 模型")
        localSTTPrepareTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await localSpeech.prepare { [weak self] progress in
                    guard let self, self.localSTTEnabled else { return }
                    self.localSTTState = .preparing(
                        Int((progress.fractionCompleted * 100).rounded())
                    )
                }
                guard !Task.isCancelled, localSTTEnabled else { return }
                localSTTState = .ready
                log("本地转文字:模型已就绪")
            } catch {
                guard !Task.isCancelled, localSTTEnabled else { return }
                localSTTState = .failed("模型准备失败，关开重试")
                log("⚠️ 本地转文字模型准备失败:\(error.localizedDescription)")
            }
        }
    }

    func handleTalkKey(_ down: Bool, name: String) {
        overlay.setKey(down, online: mic.isOnline, muted: mic.state.muted)
        if down {
            beginLocalDictation()
        } else {
            requestLocalDictationStop()
        }
        uplink?.sendControl(muted: !down)
        log(down ? "\(name) 按下 → 送声" : "\(name) 松开 → 静音")
    }

    private func beginLocalDictation() {
        guard localSTTEnabled, localSTTState == .ready, mic.isOnline, let uplink else { return }
        guard let target = FocusedTextTarget.capture() else {
            log("⚠️ 本地转文字:请先点进可编辑输入框")
            return
        }
        guard audioCaptureGate.acquire() else {
            log("⚠️ 本地转文字:已有音频采集任务在运行")
            return
        }
        guard let buffer = localDictationCapture.begin(target: target) else {
            audioCaptureGate.release()
            return
        }
        uplink.onAudioTap = { data in buffer.append(data) }
        localSTTOwnVoice = ownVoiceProfile.map { OwnVoiceFilter(profile: $0) }
        localSTTState = .listening
        startLocalDictationPreview(buffer)
    }

    /// 按住期间一轮接一轮转写尾段作为浮层实时字幕;尾段过长时在停顿处定稿,见 LiveTranscript。
    private func startLocalDictationPreview(_ buffer: PCMBuffer) {
        localSTTPreviewTask?.cancel()
        localSTTLive = LiveTranscript()
        localSTTPreviewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                var pcm = buffer.snapshot()
                if let filter = localSTTOwnVoice { pcm = await filter.filter(pcm) }
                guard !Task.isCancelled else { return }
                if let end = localSTTLive.cut(pcm) {
                    let segment = Data(pcm[localSTTLive.offset..<end])
                    guard let text = try? await localSpeech.transcribe(segment), !Task.isCancelled else { continue }
                    localSTTLive.commit(text, upTo: end)
                    continue
                }
                let tail = localSTTLive.tail(of: pcm)
                guard tail.count >= LiveTranscript.bytesPerSecond / 2 else { continue }
                guard let text = try? await localSpeech.transcribe(tail), !Task.isCancelled else { continue }
                overlay.showPartial(localSTTLive.text(withTail: text))
            }
        }
    }

    private func requestLocalDictationStop() {
        guard localDictationCapture.held >= TalkOverlay.holdDelay else {
            if abortLocalDictation() { log("本地转文字:按住不到 1 秒,当误触忽略") }
            return
        }
        guard localDictationCapture.requestStop() else { return }
        localSTTPreviewTask?.cancel()
        localSTTPreviewTask = nil
        localSTTStopTask?.cancel()
        localSTTState = .transcribing
        overlay.setTranscribing()
        // 设备状态通常会先确认静音；断链或状态丢失时用短超时封口，不能永久占住音频抽头。
        localSTTStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.finishLocalDictationIfSafe(connected: true, muted: false, force: true)
        }
    }

    func finishLocalDictationIfSafe(connected: Bool, muted: Bool, force: Bool = false) {
        guard
            let utterance = localDictationCapture.finishIfSafe(
                connected: connected, muted: muted, force: force
            )
        else { return }
        localSTTStopTask?.cancel()
        localSTTStopTask = nil
        uplink?.onAudioTap = nil
        audioCaptureGate.release()
        transcribe(utterance, take: recordings.currentTake)  // still in its tail window: the take just spoken
    }

    private func transcribe(_ utterance: LocalDictationCapture.Utterance, take: Date?) {
        localSTTWorkTask?.cancel()
        let ownVoice = localSTTOwnVoice
        localSTTOwnVoice = nil
        localSTTWorkTask = Task { [weak self] in
            guard let self else { return }
            do {
                var pcm = utterance.pcm
                if let ownVoice {
                    pcm = await ownVoice.filter(pcm, final: true)
                    if ownVoice.dropped > 0 { log("只留本人声音:去掉 \(ownVoice.dropped) 段非本人语音(每段 0.5 秒)") }
                }
                guard !Task.isCancelled else { return }
                // 已定稿的前段沿用,只转剩下的尾段:松开后的等待与讲话时长无关,结果也与字幕一致。
                let live = localSTTLive
                let tail = live.tail(of: pcm)
                let draft = tail.count < 6_400 && !live.committed.isEmpty
                    ? live.committed
                    : live.text(withTail: try await localSpeech.transcribe(tail))
                guard !Task.isCancelled, localSTTEnabled else { return }
                if draft.isEmpty {
                    log("⚠️ 本地转文字:没有识别出文字")
                    overlay.finishTranscribing()
                } else if !dictationConfirm {
                    overlay.showPartial(draft)  // 定稿替换最后一轮字幕,浮层随即收起
                    let text = await polished(draft)
                    guard !Task.isCancelled, localSTTEnabled else { return }
                    commitDictation(text, to: utterance.target, take: take, label: draft)
                    overlay.finishTranscribing()
                } else {
                    overlay.showPartial(draft)
                    let text = await polished(draft)
                    guard !Task.isCancelled, localSTTEnabled else { return }
                    localSTTState = .reviewing
                    // 停在浮层等人改,回车才插入;改过的文字随录音存档作微调标注。
                    guard let final = await overlay.review(text) else {
                        log("本地转文字:已取消,未写入")
                        if localSTTEnabled { localSTTState = .ready }
                        localSTTWorkTask = nil
                        return
                    }
                    guard !Task.isCancelled, localSTTEnabled else { return }
                    if final != text { log("本地转文字:已人工修改") }
                    try? await Task.sleep(for: .milliseconds(150))  // 浮层交还键盘后,原窗口重新成为 key
                    commitDictation(final, to: utterance.target, take: take, label: final == text ? draft : final)
                }
            } catch {
                guard !Task.isCancelled, localSTTEnabled else { return }
                log("⚠️ 本地转文字失败:\(error.localizedDescription)")
                overlay.finishTranscribing()
            }
            if localSTTEnabled { localSTTState = .ready }
            localSTTWorkTask = nil
        }
    }

    /// 打开 AI 润色且有 Key 时交给智谱改写;失败或超时退回原文。
    private func polished(_ draft: String) async -> String {
        guard aiPolishEnabled, aiPolish.hasKey else { return draft }
        do {
            let text = try await aiPolish.polish(draft)
            log("AI 润色:\(draft.count) → \(text.count) 个字符")
            return text
        } catch {
            log("⚠️ \(error.localizedDescription),插入原文")
            return draft
        }
    }

    /// 写入按键时的输入框;label(默认同 text)作为这段录音的 .txt 随录音备份(微调时的标注)。
    /// AI 润色改掉了口头语,不是逐字转写,所以标注用润色前的原文。
    func commitDictation(_ text: String, to target: any DictationTextTarget, take: Date?, label: String? = nil) {
        guard LocalDictationText.commit(text, to: target) else {
            log("⚠️ 本地转文字:结果为空或焦点输入框不接受文字")
            return
        }
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        log("本地转文字:已写入 \(final.count) 个字符")
        if let take { recordings.saveTranscript((label ?? text).trimmingCharacters(in: .whitespacesAndNewlines), for: take) }
    }

    func stopLocalSTT() {
        localSTTPreviewTask?.cancel()
        localSTTPreviewTask = nil
        localSTTPrepareTask?.cancel()
        localSTTPrepareTask = nil
        localSTTWorkTask?.cancel()
        localSTTWorkTask = nil
        localSTTStopTask?.cancel()
        localSTTStopTask = nil
        if localDictationCapture.cancel() {
            uplink?.onAudioTap = nil
            audioCaptureGate.release()
        }
        overlay.finishTranscribing()
        localSTTState = .disabled
    }

    func cancelLocalDictationForListenerChange() {
        guard abortLocalDictation() else { return }
        overlay.finishTranscribing()
        log("本地转文字:讲话键监听变化，已取消本次采集")
    }

    /// 丢掉进行中的采集,不转写。
    @discardableResult
    private func abortLocalDictation() -> Bool {
        guard localDictationCapture.cancel() else { return false }
        localSTTPreviewTask?.cancel()
        localSTTPreviewTask = nil
        localSTTStopTask?.cancel()
        localSTTStopTask = nil
        uplink?.onAudioTap = nil
        audioCaptureGate.release()
        localSTTState = localSTTEnabled ? .ready : .disabled
        return true
    }
}
