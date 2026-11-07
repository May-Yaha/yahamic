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
    }

    private func requestLocalDictationStop() {
        guard localDictationCapture.requestStop() else { return }
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
        transcribe(utterance)
    }

    private func transcribe(_ utterance: LocalDictationCapture.Utterance) {
        localSTTWorkTask?.cancel()
        localSTTWorkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await localSpeech.transcribe(utterance.pcm)
                guard !Task.isCancelled, localSTTEnabled else { return }
                if LocalDictationText.commit(text, to: utterance.target) {
                    log("本地转文字:已写入 \(text.count) 个字符")
                } else {
                    log("⚠️ 本地转文字:结果为空或焦点输入框不接受文字")
                }
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

    func stopLocalSTT() {
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
        guard localDictationCapture.cancel() else { return }
        localSTTStopTask?.cancel()
        localSTTStopTask = nil
        uplink?.onAudioTap = nil
        audioCaptureGate.release()
        overlay.finishTranscribing()
        localSTTState = localSTTEnabled ? .ready : .disabled
        log("本地转文字:讲话键监听变化，已取消本次采集")
    }
}
