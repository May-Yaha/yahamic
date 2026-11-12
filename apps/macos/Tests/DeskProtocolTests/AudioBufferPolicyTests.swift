import Testing
@testable import DeskCore

@Test func audioBufferPolicyMigratesUnsafeLegacyTargets() {
    #expect(AudioBufferPolicy.normalizedTargetMs(nil) == 180)
    #expect(AudioBufferPolicy.normalizedTargetMs(60) == 180)
    #expect(AudioBufferPolicy.normalizedTargetMs(120) == 180)
    #expect(AudioBufferPolicy.normalizedTargetMs(180) == 180)
    #expect(AudioBufferPolicy.normalizedTargetMs(240) == 240)
}

@Test func audioBufferPolicyDerivesPrebufferFromTarget() {
    #expect(AudioBufferPolicy.prebufferSamples(targetMs: 180) == 2_880)
    #expect(AudioBufferPolicy.prebufferSamples(targetMs: 240) == 3_840)
}

@Test func systemAudioDownsamplesToSixteenKilohertz() {
    var down = Downsampler(rate: 48_000)
    let out = down.push(mono: [Float](repeating: 0.5, count: 4_800))
    #expect(out.count == 1_600)
    #expect(out.allSatisfy { abs(Int($0) - 16_383) <= 1 })
    var odd = Downsampler(rate: 44_100)  // 非整数比:跨多次喂入总数仍对得上
    let total = (0..<10).reduce(0) { n, _ in n + odd.push(mono: [Float](repeating: 0, count: 441)).count }
    #expect(abs(total - 1_600) <= 1)
}
