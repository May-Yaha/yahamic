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
        localSTTState = .listening
        startLocalDictationPreview(buffer)
    }

    /// 按住期间约每 0.8 秒把已收到的音频整段重转一次,结果作为浮层实时字幕。
    private func startLocalDictationPreview(_ buffer: PCMBuffer) {
        localSTTPreviewTask?.cancel()
        localSTTPreviewTask = Task { [weak self] in
            // ponytail: 每轮重转整段缓冲,长按时总耗时 O(n²);要讲很久时改为停顿处分段提交或 generateStream。
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, !Task.isCancelled else { return }
                let pcm = buffer.snapshot()
                guard pcm.count >= 32_000 else { continue }  // 不到 1 秒没什么可看的
                guard let partial = try? await localSpeech.transcribe(pcm), !Task.isCancelled else { continue }
                overlay.showPartial(partial)
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
        localSTTWorkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await localSpeech.transcribe(utterance.pcm)
                guard !Task.isCancelled, localSTTEnabled else { return }
                overlay.showPartial(text)  // 定稿替换最后一轮字幕,浮层随即收起
                commitDictation(text, to: utterance.target, take: take)
                overlay.finishTranscribing()
            } catch {
                guard !Task.isCancelled, localSTTEnabled else { return }
                log("⚠️ 本地转文字失败:\(error.localizedDescription)")
                overlay.finishTranscribing()
            }
            if localSTTEnabled { localSTTState = .ready }
            localSTTWorkTask = nil
        }
    }

    /// 写入按键时的输入框,并作为这段录音的 .txt 随录音备份(微调时的标注)。
    func commitDictation(_ text: String, to target: any DictationTextTarget, take: Date?) {
        guard LocalDictationText.commit(text, to: target) else {
            log("⚠️ 本地转文字:结果为空或焦点输入框不接受文字")
            return
        }
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        log("本地转文字:已写入 \(final.count) 个字符")
        if let take { recordings.saveTranscript(final, for: take) }
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
