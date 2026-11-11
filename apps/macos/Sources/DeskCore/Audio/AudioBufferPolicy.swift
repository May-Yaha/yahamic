public enum AudioBufferPolicy {
    public static let defaultTargetMs = 180

    public static func normalizedTargetMs(_ stored: Int?) -> Int {
        max(stored ?? defaultTargetMs, defaultTargetMs)
    }

    public static func prebufferSamples(targetMs: Int) -> Int {
        normalizedTargetMs(targetMs) * 16
    }
}
