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
