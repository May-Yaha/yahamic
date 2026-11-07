import Foundation
import Testing
import DeskCore
@testable import YahaDesk

@Test func audioCaptureGateRejectsOverlapAndReleases() {
    var gate = AudioCaptureGate()
    let first = gate.acquire()
    let overlapping = gate.acquire()
    #expect(first)
    #expect(!overlapping)
    gate.release()
    let afterRelease = gate.acquire()
    #expect(afterRelease)
}

@Test func metricDistributionReportsTailWatermarks() {
    let values = (0..<101).map(Double.init)
    let summary = AudioDiagnostics.distribution(values)
    #expect(summary.minimum == 0)
    #expect(summary.p05 == 5)
    #expect(summary.median == 50)
    #expect(summary.p95 == 95)
    #expect(summary.maximum == 100)
    #expect(summary.average == 50)
}

@Test func audioDiagnosticsReadsCurrentJitterDepthInsteadOfCachedState() {
    let jitter = JitterBuffer(ms: 1_000)
    let samples = [Int16](repeating: 1, count: 1_600)
    samples.withUnsafeBufferPointer { jitter.push($0) }
    #expect(AudioDiagnostics.bufferMilliseconds(jitter) == 100)
}

@Test func metricDistributionHandlesEmptyInput() {
    let summary = AudioDiagnostics.distribution([])
    #expect(summary.minimum == 0)
    #expect(summary.maximum == 0)
}

@Test func enhancementInputIsConfinedToYahaDeskTemporaryCapture() {
    let temp = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    #expect(AudioDiagnostics.allowedEnhancementInput(
        URL(fileURLWithPath: "/private/tmp/yahadesk_stress_123.wav"), temporaryDirectory: temp))
    #expect(!AudioDiagnostics.allowedEnhancementInput(
        URL(fileURLWithPath: "/private/tmp/other.wav"), temporaryDirectory: temp))
    #expect(!AudioDiagnostics.allowedEnhancementInput(
        URL(fileURLWithPath: "/private/other/yahadesk_stress_123.wav"), temporaryDirectory: temp))
}
