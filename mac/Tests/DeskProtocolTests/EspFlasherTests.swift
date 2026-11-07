import CryptoKit
import Foundation
import Testing
@testable import DeskCore

/// 最小 ESP32-S3 ROM:按 SLIP 收命令,改一块 16 MB 假 flash,记录擦写过的区间。
private final class FakeRom: FlashPort {
    var flash = [UInt8](repeating: 0xFF, count: 0x420000)
    var erased: [Range<Int>] = []
    var out: [UInt8] = []
    var inDownloadMode = false
    var deaf = false  // 串口被别的程序抢走:ROM 收不到命令
    var rtsSinceDTR = 0  // 最后一次动 DTR 之后的 RTS 次数:复位回程序是 RTS 拉下再放开
    private var reader = SlipReader()
    private var writing: (offset: Int, blockSize: Int)?

    func setDTR(_ on: Bool) throws { rtsSinceDTR = 0; if on { inDownloadMode = true } }
    func setRTS(_ on: Bool) throws { rtsSinceDTR += 1 }
    func reopen() throws {}
    func read(timeout: TimeInterval) throws -> [UInt8] { defer { out = [] }; return out }

    func write(_ data: Data) throws {
        for b in data { if let f = reader.push(b) { handle(f) } }
    }

    private func u32(_ f: [UInt8], _ i: Int) -> Int { Int(f[i]) | Int(f[i + 1]) << 8 | Int(f[i + 2]) << 16 | Int(f[i + 3]) << 24 }

    private func handle(_ f: [UInt8]) {
        guard inDownloadMode, !deaf else { return }
        let op = f[1], body = Array(f[8...])
        var value: UInt32 = 0, data: [UInt8] = []
        switch op {
        case EspRom.sync: value = 0x2000_0000
        case EspRom.readReg: value = u32(body, 0) == 0x4000_1000 ? 9 : 0
        case EspRom.flashBegin:
            let size = u32(body, 0), offset = u32(body, 12)
            let end = offset + (size + 0xFFF) / 0x1000 * 0x1000
            erased.append(offset..<end)
            for i in offset..<end { flash[i] = 0xFF }
            writing = (offset, u32(body, 8))
        case EspRom.flashData:
            let block = Array(body[16...]), seq = u32(body, 4)
            let start = writing!.offset + seq * writing!.blockSize
            flash.replaceSubrange(start..<start + block.count, with: block)
        case EspRom.md5:
            let offset = u32(body, 0), size = u32(body, 4)
            data = Array(Insecure.MD5.hash(data: flash[offset..<offset + size])
                .map { String(format: "%02x", $0) }.joined().utf8)
        case EspRom.readFlashSlow:
            let offset = u32(body, 0), size = u32(body, 4)
            data = Array(flash[offset..<offset + size]) + [UInt8](repeating: 0, count: 64 - size)
        default: break
        }
        var r: [UInt8] = [1, op, 0, 0]
        withUnsafeBytes(of: value.littleEndian) { r += $0 }
        r += data + [0, 0]
        out += [UInt8](EspRom.slip(Data(r)))
    }
}

/// 形如 idf.py 产物的三段固件;app 带 esp_app_desc 版本。
private func files(version: String = "0.3.0", project: String = "yahadesk", appSize: Int = 5000) -> [String: Data] {
    var header = [UInt8](repeating: 0, count: 16)
    header[0] = 0xE9; header[12] = 9
    var app = header + [UInt8](repeating: 0, count: appSize - 16)
    app.replaceSubrange(32..<36, with: [0x32, 0x54, 0xCD, 0xAB])
    app.replaceSubrange(48..<48 + version.utf8.count, with: Array(version.utf8))
    app.replaceSubrange(80..<80 + project.utf8.count, with: Array(project.utf8))
    for i in 112..<appSize { app[i] = UInt8(i % 251) }
    return ["bootloader.bin": Data(header + [1, 2, 3]),
            "partition-table.bin": Data([0xAA, 0x50] + [UInt8](repeating: 7, count: 30)),
            "yahadesk.bin": Data(app)]
}

@Test func firmwareBundleReadsVersionAndRejectsBadImages() throws {
    #expect(try FirmwareBundle(files: files(version: "0.3.1")).version == "0.3.1")
    var big = files()
    big["yahadesk.bin"] = files(appSize: 0x400001)["yahadesk.bin"]  // 会压进 fac 分区
    #expect(throws: (any Error).self) { try FirmwareBundle(files: big) }
    var wrongChip = files()
    var app = [UInt8](wrongChip["yahadesk.bin"]!); app[12] = 5
    wrongChip["yahadesk.bin"] = Data(app)
    #expect(throws: (any Error).self) { try FirmwareBundle(files: wrongChip) }
    var missing = files(); missing["partition-table.bin"] = nil
    #expect(throws: (any Error).self) { try FirmwareBundle(files: missing) }
}

@Test func installWritesOnlyChangedImagesAndNeverTouchesNvsOrFactory() throws {
    let rom = FakeRom()
    let nvs = 0x9000..<0x10000, fac = 0x410000..<0x416000
    for i in nvs { rom.flash[i] = 0x5A }
    for i in fac { rom.flash[i] = 0xA5 }
    let bundle = try FirmwareBundle(files: files())
    var last = 0.0
    let written = try EspFlasher(port: rom).install(bundle) { last = $0 }
    #expect(written == ["bootloader.bin", "partition-table.bin", "yahadesk.bin"])
    #expect(last == 1)
    for image in bundle.images {
        #expect(Data(rom.flash[Int(image.offset)..<Int(image.offset) + image.data.count]) == image.data)
    }
    #expect(rom.erased.allSatisfy { !$0.overlaps(nvs) && !$0.overlaps(fac) })
    #expect(rom.flash[nvs].allSatisfy { $0 == 0x5A } && rom.flash[fac].allSatisfy { $0 == 0xA5 })

    // 只升级程序:bootloader 与分区表已一致,不再擦写。
    rom.erased = []
    let next = try FirmwareBundle(files: files(version: "0.3.1"))
    #expect(try EspFlasher(port: rom).install(next) == ["yahadesk.bin"])
    #expect(rom.erased == [0x10000..<0x12000])
    #expect(try EspFlasher(port: rom).install(next).isEmpty)
}

@Test func installRefusesOtherProjectsFirmwareUnlessConfirmed() throws {
    let rom = FakeRom()
    let other = try FirmwareBundle(files: files(project: "yahamic"))
    try EspFlasher(port: rom).install(other)  // 空板(全 0xFF)不算别的项目
    let bundle = try FirmwareBundle(files: files())
    #expect(throws: ForeignFirmwareError.self) { try EspFlasher(port: rom).install(bundle) }
    #expect(try EspFlasher(port: rom).install(bundle, allowForeign: true) == ["yahadesk.bin"])
}

@Test func installResetsDeviceBackToItsAppWhenSyncFails() throws {
    let rom = FakeRom()
    rom.deaf = true
    #expect(throws: (any Error).self) { try EspFlasher(port: rom).install(FirmwareBundle(files: files())) }
    // 进下载模式的时序以 RTS 放开收尾(1 次);之后还要有复位回程序的拉下 + 放开。
    #expect(rom.rtsSinceDTR == 3)
}
