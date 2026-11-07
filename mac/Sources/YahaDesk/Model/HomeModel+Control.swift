import Foundation
import DeskCore

// 控制接口命令分发(MCP/脚本/压测),请求来自 ControlServer 的 Unix socket。
extension HomeModel {
    func handleControl(_ request: [String: Any]) async -> [String: Any] {
        switch request["cmd"] as? String ?? "" {
        case "status":
            return statusReport()
        case "set_mute":
            guard let value = request["value"] as? Bool else { return ["error": "value(布尔)必填"] }
            guard mic.isOnline else { return ["error": "设备不在线"] }
            uplink?.sendControl(muted: value)
            return ["ok": true, "muted": value]
        case "set_ptt":
            guard let value = request["value"] as? Bool else { return ["error": "value(布尔)必填"] }
            pttEnabled = value
            return ["ok": true, "ptt": value]
        case "devices":
            refreshOutputs()
            return ["devices": outputs.map { $0.name }]
        case "logs":
            let tail = min(max(request["tail"] as? Int ?? 20, 1), 200)
            return ["logs": Array(logs.suffix(tail))]
        case "dump":
            guard mic.isOnline else { return ["error": "设备不在线"] }
            uplink?.sendDump()
            return ["ok": true, "note": "截图经串口日志回传(SCR 行),由串口侧重建"]
        case "capture":
            let seconds = min(max(request["seconds"] as? Int ?? 10, 1), 120)
            return await captureStream(seconds: seconds)
        case "metrics":
            let seconds = min(max(request["seconds"] as? Int ?? 10, 1), 300)
            return await collectMetrics(seconds: seconds)
        case "stress":
            let seconds = min(max(request["seconds"] as? Int ?? 30, 5), 600)
            let source = request["source"] as? String ?? "tts"
            return await runStress(seconds: seconds, source: source)
        case "enhance_capture":
            guard let path = request["path"] as? String, !path.isEmpty else { return ["error": "path 必填"] }
            return await enhanceCapture(path: path)
        case "cloud":
            return cloud.report()
        case "cloud_configure":
            return ["error": "应用使用预置连接自动同步；此接口不接收连接凭据，请在设备设置窗口查看状态"]
        default:
            return ["error": "未知命令;可用:status/set_mute/set_ptt/devices/logs/dump/capture/metrics/stress/enhance_capture/cloud/cloud_configure"]
        }
    }

    private func statusReport() -> [String: Any] {
        var out: [String: Any] = [
            "version": version,
            "ptt": pttEnabled,
            "fnAvailable": fnAvailable,
            "localSTT": localSTTEnabled,
            "localSTTState": localSTTState.detail,
            "needsAccessibility": needsAccessibility,
            "launchAtLogin": launchAtLogin,
            "outputDevice": sink?.deviceName ?? "-",
        ]
        if let audioError { out["audioError"] = audioError }
        // 「激活」阶段诊断:流是否被音频帧喂起来过(见 AudioSink.streamStats)。
        if let stats = sink?.streamStats() {
            out["streamActive"] = stats.active
            out["streamActivations"] = stats.activations
        }
        var device: [String: Any] = ["connected": mic.isOnline, "paused": mic.paused]
        if mic.isOnline {
            let s = mic.state
            device["name"] = s.deviceName
            device["rssi"] = s.rssi
            device["muted"] = s.muted
            device["levelDb"] = s.levelDb
            device["framesPerSecond"] = s.framesPerSecond
            device["bufferMs"] = s.bufferMs
            device["overflows"] = s.overflows
            device["underruns"] = s.underruns
            // 接收侧本地统计(seq 跳号缺口),非设备遥测透传。
            device["droppedFrames"] = s.droppedFrames
            // 分阶段诊断计数:定位零帧断点用,各字段口径见 Uplink.Diag。
            device["diag"] = Self.diagFields(s.diag)
        }
        out["device"] = device
        return out
    }

    /// Uplink.Diag 摊平成字典;metrics 的增量也按这份字段表算,两处不会漏字段。
    static func diagFields(_ d: Uplink.Diag) -> [String: Int] {
        [
            "rxPackets": d.rxPackets,
            "rxInvalid": d.rxInvalid,
            "audioPackets": d.audioPackets,
            "decodeErrors": d.decodeErrors,
            "decodedFrames": d.decodedFrames,
            "enqueuedFrames": d.enqueuedFrames,
            "outputFrames": d.outputFrames,
            "dropJump": d.dropJump,
        ]
    }
}
