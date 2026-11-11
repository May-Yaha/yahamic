import AppKit
import CryptoKit

// 虚拟麦克风 BlackHole 的安装引导:没装 Homebrew 的用户也能在 App 里一键装好。
// 一键安装 = 下载官方 pkg(钉死版本与 sha256)→ 管理员授权跑 installer → 重启
// coreaudiod 让驱动立即生效(pkg 自身要求重启电脑,重启音频服务即可免重启)。
// 装好与否不靠安装结果判断:HomeModel 在缺设备期间轮询设备列表,任何途径装好都会自动接上。
enum BlackHoleSetup {
    // ponytail: 版本钉死,升级 BlackHole 时同步改 URL 与 sha256(brew info --cask blackhole-2ch)
    static let pkgURL = URL(string: "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg")!
    static let pkgSHA256 = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"

    static var hasHomebrew: Bool {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 给「复制命令」用:有 brew 走 brew,没有就 curl 官方 pkg + 系统 installer。
    static var terminalCommand: String {
        if hasHomebrew {
            return "brew install blackhole-2ch && sudo killall coreaudiod"
        }
        return "curl -fLo /tmp/BlackHole2ch.pkg \(pkgURL.absoluteString)"
            + " && sudo installer -pkg /tmp/BlackHole2ch.pkg -target / && sudo killall coreaudiod"
    }

    enum SetupError: LocalizedError {
        case download(String), checksum, cancelled, install(String)

        var errorDescription: String? {
            switch self {
            case .download(let why): return "下载失败:\(why)"
            case .checksum: return "安装包校验不通过,已放弃安装"
            case .cancelled: return "已取消授权"
            case .install(let why): return "安装失败:\(why)"
            }
        }
    }

    /// 下载 → 校验 → 授权安装。全程不经 shell 拼接用户输入:路径是本进程生成的临时路径。
    /// `onVerified` 在校验通过、即将弹管理员授权框时回调(界面切到「安装中」)。
    @MainActor
    static func install(onVerified: () -> Void) async throws {
        let data: Data
        do {
            let (fetched, response) = try await URLSession.shared.data(from: pkgURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw SetupError.download("服务器返回异常")
            }
            data = fetched
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError.download(error.localizedDescription)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == pkgSHA256 else { throw SetupError.checksum }

        // 写进用户私有临时目录($TMPDIR 权限 0700),别的用户无法在校验后掉包。
        let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("BlackHole2ch.pkg")
        try data.write(to: pkg, options: .atomic)
        defer { try? FileManager.default.removeItem(at: pkg) }
        onVerified()

        let quoted = pkg.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            do shell script "/usr/sbin/installer -pkg " & quoted form of "\(quoted)" & \
            " -target / && (/usr/bin/killall coreaudiod || true)" \
            with prompt "Yaha Desk 要安装虚拟麦克风 BlackHole。" with administrator privileges
            """
        let (status, stderr) = try await runOsascript(script)
        if status == 0 { return }
        if stderr.contains("-128") { throw SetupError.cancelled }
        throw SetupError.install(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func runOsascript(_ script: String) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
        let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, stderr)
    }
}

/// 安装进度:idle → downloading → installing → waiting(装好,等 CoreAudio 出现设备)。
enum BlackHoleInstallState: Equatable {
    case idle, downloading, installing, waiting
    case failed(String)

    var busy: Bool { self == .downloading || self == .installing || self == .waiting }
}
