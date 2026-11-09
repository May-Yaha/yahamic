import Foundation
import Testing
@testable import YahaDesk

private func pcm(_ samples: [Int16]) -> Data {
    samples.withUnsafeBytes { Data($0) }
}

@Test func voiceSampleQualityAcceptsClearThreeSecondSpeech() {
    let samples = [Int16](repeating: 0, count: 8_000)
        + [Int16](repeating: 8_000, count: 32_000)
        + [Int16](repeating: 0, count: 8_000)
    let quality = VoiceSampleQuality.evaluate(pcm(samples))
    #expect(quality.accepted)
    #expect(quality.durationSeconds == 3)
    #expect(quality.activeRatio > 0.6)
}

@Test func voiceSampleQualityRejectsSilenceAndClipping() {
    #expect(!VoiceSampleQuality.evaluate(pcm([Int16](repeating: 0, count: 48_000))).accepted)
    #expect(!VoiceSampleQuality.evaluate(pcm([Int16](repeating: .max, count: 48_000))).accepted)
}

@Test func voiceIdentityPolicyNormalizesAverageAndGatesByDistance() throws {
    let profile = try #require(VoiceIdentityPolicy.average([[1, 0], [0.8, 0.2]]))
    let norm = sqrt(profile.reduce(0) { $0 + $1 * $1 })
    #expect(abs(norm - 1) < 0.0001)
    #expect(VoiceIdentityPolicy.accepts(profile, candidate: profile))
    #expect(!VoiceIdentityPolicy.accepts(profile, candidate: [-profile[0], -profile[1]]))
}

@MainActor
@Test func voiceProfilePersistsFiveSamplesWithoutImplicitPanAccess() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let profile = VoiceProfile(folder: folder) { recordings in
        #expect(recordings.count == 5)
        return [Float](repeating: 0, count: 255) + [1]
    }
    let speech = pcm([Int16](repeating: 0, count: 8_000)
        + [Int16](repeating: 8_000, count: 48_000)
        + [Int16](repeating: 0, count: 8_000))
    profile.capture = { _ in speech }
    var tokenReads = 0
    profile.token = { tokenReads += 1; return nil }

    for index in VoiceProfile.phrases.indices { await profile.record(index) }

    #expect(profile.ready)
    #expect(profile.manifest.embedding?.count == 256)
    #expect(tokenReads == 0)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("profile.json").path))
    let restored = VoiceProfile(folder: folder) { _ in [] }
    #expect(restored.ready)
    await profile.backup()
    #expect(tokenReads == 1)
    #expect(profile.message == "请先登录百度网盘")
}

@MainActor
@Test func voiceProfileDistinguishesPartialFromCompleteBackup() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let quality = VoiceSampleQuality(durationSeconds: 4, rmsDbfs: -20, activeRatio: 0.8,
                                     clippedRatio: 0, accepted: true, message: "录音质量合格")
    let samples = VoiceProfile.phrases.indices.map { index in
        let fileName = "phrase-\(index + 1).wav"
        _ = FileManager.default.createFile(atPath: folder.appendingPathComponent(fileName).path, contents: Data())
        return VoiceProfileSample(index: index, fileName: fileName, quality: quality)
    }
    var manifest = VoiceProfileManifest(profileID: "profile", samples: samples,
                                        embedding: [Float](repeating: 1, count: 256),
                                        remotePaths: ["phrase-1.wav": "/apps/拾见/录音/声纹/profile/phrase-1.wav"],
                                        modelVersion: VoiceProfile.modelVersion)
    try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("profile.json"))

    let partial = VoiceProfile(folder: folder) { _ in [] }
    #expect(partial.hasRemoteFiles)
    #expect(!partial.backedUp)

    for sample in samples {
        manifest.remotePaths[sample.fileName] = "/apps/拾见/录音/声纹/profile/\(sample.fileName)"
    }
    manifest.remotePaths["profile.json"] = "/apps/拾见/录音/声纹/profile/profile.json"
    try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("profile.json"))
    let complete = VoiceProfile(folder: folder) { _ in [] }
    #expect(complete.backedUp)
}

@MainActor
@Test func privateVoiceCaptureNeverEntersAutomaticRecordingBackup() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let backup = RecordingBackup(folder: folder)
    backup.token = { PanToken(token: "pan-test", expires: Date().timeIntervalSince1970 + 3_600) }
    backup.tail = .milliseconds(1)

    backup.setPrivateCapture(true)
    backup.talking(true)
    for _ in 0..<60 { backup.append(Data(repeating: 0x58, count: 120), samples: 960) }
    backup.talking(false)
    backup.setPrivateCapture(false)
    try await Task.sleep(for: .milliseconds(10))

    #expect(backup.pending == 0)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}

@Test func privateCaptureGateWaitsForMuteConfirmationBeforeRelease() throws {
    var gate = AudioCaptureGate()
    let acquired = gate.acquire()
    #expect(acquired)

    gate.awaitMuteBeforeRelease(savedPtt: false, savedMuted: false)
    #expect(gate.completeRestoreIfSafe(connected: true, muted: false) == nil)
    #expect(gate.busy)

    let completed = gate.completeRestoreIfSafe(connected: true, muted: true)
    let restore = try #require(completed)
    #expect(!restore.savedPtt)
    #expect(!restore.savedMuted)
    #expect(!gate.busy)
}

@MainActor
@Test func remoteDeleteFailureStillRemovesLocalBiometricDataAndKeepsRetryReceipt() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fileName = "phrase-1.wav"
    try Data("voice".utf8).write(to: folder.appendingPathComponent(fileName))
    let quality = VoiceSampleQuality(durationSeconds: 4, rmsDbfs: -20, activeRatio: 0.8,
                                     clippedRatio: 0, accepted: true, message: "录音质量合格")
    let remotePath = PanFiles.voiceProfileRoot + "/profile/" + fileName
    let saved = VoiceProfileManifest(
        profileID: "profile", samples: [VoiceProfileSample(index: 0, fileName: fileName, quality: quality)],
        embedding: [Float](repeating: 1, count: 256), remotePaths: [fileName: remotePath],
        modelVersion: VoiceProfile.modelVersion)
    try JSONEncoder().encode(saved).write(to: folder.appendingPathComponent("profile.json"))
    let profile = VoiceProfile(folder: folder) { _ in [] }
    profile.token = { nil }

    await profile.delete(includeRemote: true)

    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName).path))
    #expect(profile.manifest.samples.isEmpty)
    #expect(profile.manifest.embedding == nil)
    #expect(profile.manifest.remotePaths == [fileName: remotePath])
    #expect(profile.message?.hasPrefix("本机已删除，网盘删除失败") == true)
    let restored = VoiceProfile(folder: folder) { _ in [] }
    #expect(restored.manifest.remotePaths == [fileName: remotePath])
}

@MainActor
@Test func dictationTextIsSavedBesideItsRecordingWhetherItArrivesBeforeOrAfterTheFile() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let backup = RecordingBackup(folder: folder)
    // Expired: recording still runs, upload stays local, so no network is touched.
    backup.token = { PanToken(token: "pan-test", expires: Date().timeIntervalSince1970) }
    backup.tail = .milliseconds(20)
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    backup.now = { clock }

    func take() -> Date? {
        backup.talking(true)
        for _ in 0..<20 { backup.append(Data(repeating: 0x58, count: 120), samples: 960) }
        backup.talking(false)
        return backup.currentTake
    }
    let early = try #require(take())
    backup.saveTranscript("今天下午三点开会", for: early)  // text inside the tail window
    try await Task.sleep(for: .milliseconds(60))
    clock += 5
    let late = try #require(take())
    try await Task.sleep(for: .milliseconds(60))
    backup.saveTranscript("git commit 一下", for: late)  // text after the audio file was written
    backup.saveTranscript("不属于任何录音", for: Date(timeIntervalSince1970: 1))

    func text(_ date: Date) throws -> String {
        let audio = folder.appendingPathComponent(RecordingBackup.relativePath(date))
        #expect(FileManager.default.fileExists(atPath: audio.path))
        return try String(contentsOf: audio.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
    }
    #expect(try text(early) == "今天下午三点开会")
    #expect(try text(late) == "git commit 一下")
    let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)!.allObjects as! [URL]
    #expect(all.filter { $0.pathExtension == "txt" }.count == 2)
    #expect(backup.pending == 2)  // pending counts takes, not their text files
}
