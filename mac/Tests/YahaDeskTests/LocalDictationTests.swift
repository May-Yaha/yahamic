import Foundation
import MLXAudioSTT
import Testing

@testable import YahaDesk

@MainActor
@Suite(.serialized)
struct LocalDictationTests {
    private final class TestBundleToken {}

    private final class Target: DictationTextTarget {
        var inserted: [String] = []

        func insert(_ text: String) -> Bool {
            inserted.append(text)
            return true
        }
    }

    @Test func doubaoInputMethodIsDetected() {
        #expect(ActiveInputMethod.isDoubao("com.bytedance.inputmethod.doubaoime"))
        #expect(ActiveInputMethod.isDoubao("com.bytedance.inputmethod.doubaoime.pinyin"))
        #expect(!ActiveInputMethod.isDoubao("com.apple.inputmethod.SCIM"))
        #expect(!ActiveInputMethod.isDoubao(nil))
    }

    @Test func duplicateKeyEventsProduceOneCompleteUtterance() throws {
        var capture = LocalDictationCapture()
        let target = Target()
        let started = capture.begin(target: target)
        let buffer = try #require(started)
        let duplicateStart = capture.begin(target: target)
        #expect(duplicateStart == nil)
        buffer.append(Data([1, 2, 3, 4]))

        let requested = capture.requestStop()
        let duplicateStop = capture.requestStop()
        let beforeMute = capture.finishIfSafe(connected: true, muted: false)
        let finished = capture.finishIfSafe(connected: true, muted: true)
        #expect(requested)
        #expect(!duplicateStop)
        #expect(beforeMute == nil)
        let utterance = try #require(finished)
        #expect(utterance.pcm == Data([1, 2, 3, 4]))
        #expect(utterance.target === target)
        #expect(capture.finishIfSafe(connected: true, muted: true) == nil)
    }

    @Test func disconnectOrTimeoutCanCloseTheTailExactlyOnce() throws {
        var disconnected = LocalDictationCapture()
        let first = Target()
        let firstBuffer = disconnected.begin(target: first)
        _ = try #require(firstBuffer)
        let firstStop = disconnected.requestStop()
        let disconnectedUtterance = disconnected.finishIfSafe(connected: false, muted: false)
        #expect(firstStop)
        #expect(disconnectedUtterance != nil)
        #expect(disconnected.finishIfSafe(connected: false, muted: false) == nil)

        var timedOut = LocalDictationCapture()
        let second = Target()
        let secondBuffer = timedOut.begin(target: second)
        _ = try #require(secondBuffer)
        let secondStop = timedOut.requestStop()
        let timeoutUtterance = timedOut.finishIfSafe(connected: true, muted: false, force: true)
        #expect(secondStop)
        #expect(timeoutUtterance != nil)
        #expect(timedOut.finishIfSafe(connected: true, muted: false, force: true) == nil)
    }

    @Test func cancelDropsCapturedAudioWithoutCreatingAnUtterance() throws {
        var capture = LocalDictationCapture()
        let buffer = capture.begin(target: Target())
        _ = try #require(buffer)
        let cancelled = capture.cancel()
        let duplicateCancel = capture.cancel()
        #expect(cancelled)
        #expect(!duplicateCancel)
        #expect(capture.finishIfSafe(connected: false, muted: true, force: true) == nil)
    }

    @Test func finalTextPolicyRejectsBlankAndCommitsOneFinalResult() {
        let target = Target()
        #expect(!LocalDictationText.commit("  \n", to: target))
        #expect(target.inserted.isEmpty)
        #expect(LocalDictationText.commit(" 今天下午三点开会。 \n", to: target))
        #expect(target.inserted == ["今天下午三点开会。"])
    }

    @Test func captureReportsHowLongTheKeyHasBeenHeld() throws {
        var capture = LocalDictationCapture()
        #expect(capture.held == .infinity)  // nothing to abort
        let buffer = capture.begin(target: Target())
        _ = try #require(buffer)
        #expect(capture.held < TalkOverlay.holdDelay)  // released now = mis-press
        _ = capture.cancel()
        #expect(capture.held == .infinity)
    }

    @Test func liveTranscriptCutsLongTailsAtThePauseAndJoinsSegments() {
        var live = LiveTranscript()
        let second = LiveTranscript.bytesPerSecond
        // 6.5 s of loud audio with a silent 100 ms frame at 4.2 s.
        var samples = [Int16](repeating: 8_000, count: 6 * 16_000 + 8_000)
        for i in 67_200..<68_800 { samples[i] = 0 }
        let pcm = samples.withUnsafeBytes { Data($0) }
        #expect(live.cut(Data(pcm.prefix(5 * second))) == nil)  // short tail: keep re-transcribing it
        let end = live.cut(pcm)
        #expect(end == 68_000 * 2)  // middle of the silent frame
        live.commit("帮我跑一下 swift", upTo: end!)
        #expect(live.tail(of: pcm).count == pcm.count - end!)
        #expect(live.text(withTail: "test") == "帮我跑一下 swift test")
        #expect(LiveTranscript.join("今天", "下午") == "今天下午")
    }

    @Test func reviewWaitsForConfirmAndReturnsTheEditedText() async {
        let overlay = TalkOverlay()
        async let edited = overlay.review("swift test")
        await waitForReview(overlay)
        overlay.text = "swift test 通过"
        try? await Task.sleep(for: .milliseconds(100))  // no auto-insert: still waiting
        #expect(overlay.phase == .review)
        overlay.confirm()
        #expect(await edited == "swift test 通过")

        async let cancelled = overlay.review("不要")
        await waitForReview(overlay)
        overlay.cancel()
        #expect(await cancelled == nil)

        async let stopped = overlay.review("关掉本地转文字")
        await waitForReview(overlay)
        overlay.finishTranscribing()  // stopLocalSTT 走这里,不能把等待中的确认挂住
        #expect(await stopped == nil)
    }

    /// `async let` 子任务何时跑到 review() 不确定,等到它挂起在确认上再操作。
    private func waitForReview(_ overlay: TalkOverlay) async {
        for _ in 0..<200 where overlay.phase != .review { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func localDictationAndPushToTalkCannotDiverge() {
        let model = HomeModel.shared
        let savedPTT = model.pttEnabled
        let savedLocalSTT = model.localSTTEnabled
        defer {
            model.localSTTEnabled = false
            model.pttEnabled = savedPTT
            model.localSTTEnabled = savedLocalSTT
        }

        model.localSTTEnabled = false
        model.pttEnabled = false
        model.localSTTEnabled = true
        #expect(model.pttEnabled)

        model.pttEnabled = false
        #expect(!model.localSTTEnabled)
    }

    @Test func disablingPushToTalkCancelsAnActiveLocalCapture() throws {
        let model = HomeModel.shared
        let savedPTT = model.pttEnabled
        let savedLocalSTT = model.localSTTEnabled
        defer {
            model.localSTTEnabled = false
            model.pttEnabled = savedPTT
            model.localSTTEnabled = savedLocalSTT
        }

        model.localSTTEnabled = true
        let acquired = model.audioCaptureGate.acquire()
        let buffer = model.localDictationCapture.begin(target: Target())
        #expect(acquired)
        _ = try #require(buffer)
        model.localSTTState = .listening

        model.pttEnabled = false

        #expect(!model.audioCaptureGate.busy)
        #expect(!model.localSTTEnabled)
        #expect(model.localSTTState == .disabled)
        let duplicateCancel = model.localDictationCapture.cancel()
        #expect(!duplicateCancel)
    }

    @Test func qwenModelIsPinnedAndPreparationCancellationReachesTheLoader() async {
        #expect(LocalSpeechRecognizer.modelRepository == "mlx-community/Qwen3-ASR-0.6B-6bit")
        #expect(LocalSpeechRecognizer.modelSourceRevision == "468b9b6d692d3397d5d17b84a1166876a00c9bfa")
        let recognizer = LocalSpeechRecognizer { _ in
            try await Task.sleep(for: .milliseconds(500))
            throw LocalSTTError("loader was not cancelled")
        }

        let task = Task { try await recognizer.prepare() }
        try? await Task.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        do {
            try await task.value
            Issue.record("cancelled preparation unexpectedly completed")
        } catch is CancellationError {
            // Expected: the structured load receives caller cancellation immediately.
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
        #expect(cancelledAt.duration(to: clock.now) < .milliseconds(200))
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["YAHA_QWEN_MODEL_DIR"] != nil,
            "设置 YAHA_QWEN_MODEL_DIR 与 YAHA_QWEN_PCM 运行真实模型测试"
        )
    )
    func qwenRecognizesAReal16kPCMFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelDirectory = try #require(environment["YAHA_QWEN_MODEL_DIR"])
        let pcmPath = try #require(environment["YAHA_QWEN_PCM"])
        let testBundle = Bundle(for: TestBundleToken.self)
        let metallib = try #require(
            testBundle.resourceURL?
                .appendingPathComponent("mlx-swift_Cmlx.bundle")
                .appendingPathComponent("Contents/Resources/default.metallib")
        )
        #expect(FileManager.default.fileExists(atPath: metallib.path))
        let originalDirectory = FileManager.default.currentDirectoryPath
        #expect(FileManager.default.changeCurrentDirectoryPath(
            metallib.deletingLastPathComponent().path
        ))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
        let recognizer = LocalSpeechRecognizer { _ in
            try await Qwen3ASRModel.fromModelDirectory(URL(fileURLWithPath: modelDirectory))
        }

        try await recognizer.prepare()
        let text = try await recognizer.transcribe(
            Data(contentsOf: URL(fileURLWithPath: pcmPath))
        )

        #expect(text.contains("下午三点开会"), "真实 Qwen 输出：\(text)")
        #expect(text.count < 40, "短句输出异常膨胀：\(text)")
    }
}

@Test func aiPolishURLAppendsChatPathAndRejectsPlainHTTP() {
    #expect(AIPolish.chatURL(AIPolish.defaultEndpoint)?.absoluteString
        == "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions")
    #expect(AIPolish.chatURL("https://api.example.com/v1/chat/completions")?.absoluteString
        == "https://api.example.com/v1/chat/completions")
    #expect(AIPolish.chatURL(" http://localhost:11434/v1 ")?.absoluteString
        == "http://localhost:11434/v1/chat/completions")
    #expect(AIPolish.chatURL("http://api.example.com/v1") == nil)  // Key 不走明文
    #expect(AIPolish.chatURL("api.example.com/v1") == nil)
}

@Test func aiPolishModelsURLAndListParsing() {
    #expect(AIPolish.modelsURL(AIPolish.defaultEndpoint)?.absoluteString
        == "https://open.bigmodel.cn/api/coding/paas/v4/models")
    #expect(AIPolish.modelsURL("https://api.example.com/v1/chat/completions")?.absoluteString
        == "https://api.example.com/v1/models")
    #expect(AIPolish.modelsURL("http://api.example.com/v1") == nil)
    let body = Data(#"{"object":"list","data":[{"id":"glm-b"},{"id":"glm-a"},{"id":"glm-b"},{"x":1}]}"#.utf8)
    #expect(AIPolish.modelIDs(body) == ["glm-a", "glm-b"])
    #expect(AIPolish.modelIDs(Data("not json".utf8)).isEmpty)
}
