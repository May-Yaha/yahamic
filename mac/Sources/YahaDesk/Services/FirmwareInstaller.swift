import Combine
import DeskCore
import Foundation

/// 一键安装固件:App 自带的固件经 USB 线写进设备,只写有变化的段,Wi-Fi、配对和出厂身份不动。
final class FirmwareInstaller: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var progress: Double?
    @Published private(set) var message: String?
    /// 设备上是别的项目的固件:界面确认后带 allowForeign 重来。
    @Published var foreignProject: String?

    let bundle = Bundle.main.resourceURL.flatMap { try? FirmwareBundle(directory: $0.appendingPathComponent("Firmware")) }
    var log: (String) -> Void = { _ in }

    func install(allowForeign: Bool = false) {
        guard let bundle, !busy else { return }
        // ponytail: 只取第一个 usbmodem 口;同时插多块板再加选择器。
        guard let path = SerialFlashPort.candidates().first else {
            message = "没找到设备:用 USB 数据线把设备连到这台 Mac"
            return
        }
        busy = true; progress = nil; message = "正在连接设备…"
        log("开始安装固件 \(bundle.version) → \(path)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try EspFlasher(port: SerialFlashPort(path: path)).install(bundle, allowForeign: allowForeign) { p in
                    DispatchQueue.main.async { self?.progress = p; self?.message = "正在写入固件…" }
                }
            }
            DispatchQueue.main.async { self?.finish(result, version: bundle.version) }
        }
    }

    private func finish(_ result: Result<[String], Error>, version: String) {
        busy = false; progress = nil
        switch result {
        case .success(let written):
            message = written.isEmpty ? "设备上已是 \(version)，无需安装" : "已安装 \(version)，设备重启后自动重连"
            log("固件安装完成:写入 \(written)")
        case .failure(let error as ForeignFirmwareError):
            message = nil
            foreignProject = error.project
        case .failure(let error):
            message = error.localizedDescription
            log("固件安装失败:\(error.localizedDescription)")
        }
    }
}
