import DeskCore
import Foundation
import Testing
@testable import YahaDesk

/// 2 s 本人(正电平)+ 3 s 他人(负电平):假模型按回看样本的均值正负认人。
private let speech = [Int16](repeating: 8_000, count: 32_000) + [Int16](repeating: -8_000, count: 48_000)
private func fakeEmbed(_ samples: [Float]) -> [Float] {
    samples.reduce(0, +) > 0 ? [1, 0] : [0, 1]
}

@MainActor
@Test func ownVoiceFilterKeepsOwnerAndOneHopAfterThenSilencesOthers() async {
    let filter = OwnVoiceFilter(profile: [1, 0], embed: fakeEmbed)
    let pcm = speech.withUnsafeBytes { Data($0) }
    let out = OwnVoiceFilter.samples(await filter.filter(pcm, final: true))
    #expect(out.count == speech.count)
    // 第 5 段回看里本人占多数;第 6 段紧跟本人语段照留;之后他人段置零。
    #expect(filter.kept == [true, true, true, true, true, true, false, false, false, false])
    #expect(out[..<48_000].elementsEqual(speech[..<48_000]))
    #expect(out[48_000...].allSatisfy { $0 == 0 })
}

@MainActor
@Test func ownVoiceFilterKeepsQuietAudioAndModelFailures() async {
    let quiet = [Int16](repeating: 20, count: 40_000)
    let filter = OwnVoiceFilter(profile: [1, 0]) { _ in [0, 1] }
    #expect(await filter.filter(quiet.withUnsafeBytes { Data($0) }, final: true) == quiet.withUnsafeBytes { Data($0) })
    let failing = OwnVoiceFilter(profile: [1, 0]) { _ in throw VoiceProfileError("model") }
    _ = await failing.filter(speech.withUnsafeBytes { Data($0) }, final: true)
    #expect(failing.dropped == 0)
}

@MainActor
@Test func ownVoiceStreamDelaysThenReleasesEverySampleFiltered() async throws {
    let jitter = JitterBuffer(ms: 8_000)
    let stream = OwnVoiceStream(jitter: jitter, profile: [1, 0], embed: fakeEmbed)
    for start in stride(from: 0, to: speech.count, by: 960) {
        stream.push(speech[start..<min(start + 960, speech.count)].withUnsafeBytes { Data($0) })
        await Task.yield()
    }
    #expect(jitter.count <= speech.count - OwnVoiceStream.lead)
    try await Task.sleep(for: .milliseconds(600))  // 停帧后收尾
    var out = [Int16](repeating: 1, count: speech.count + 10)
    let n = out.withUnsafeMutableBufferPointer { jitter.pop(into: $0) }
    #expect(n == speech.count)
    #expect(out[..<48_000].elementsEqual(speech[..<48_000]))
    #expect(out[48_000..<n].allSatisfy { $0 == 0 })
}
