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

    @Test func reviewReturnsTheEditedDraftOnConfirmAndNothingOnCancel() async {
        let overlay = TalkOverlay()
        async let first = overlay.review("swift test")
        await Task.yield()
        #expect(overlay.phase == .review)
        overlay.text = "swift test 通过"
        overlay.confirm()
        #expect(await first == "swift test 通过")
        #expect(overlay.phase == .hidden)

        async let second = overlay.review("不要")
        await Task.yield()
        overlay.cancel()
        #expect(await second == nil)

        async let third = overlay.review("关掉本地转文字")
        await Task.yield()
        overlay.finishTranscribing()  // stopLocalSTT 走这里,不能把等待中的确认挂住
        #expect(await third == nil)
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
