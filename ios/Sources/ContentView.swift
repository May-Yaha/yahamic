import SwiftUI

/// 版式全部用系统控件与 Dynamic Type 文字样式（HIG 默认 8 pt 网格），不自定义字号与间距，跟随系统字号缩放。
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("设备", systemImage: "mic.circle") { NavigationStack { HomeView() } }
            Tab("录音", systemImage: "waveform") { NavigationStack { RecordingsView() } }
        }
    }

    nonisolated static func dmsLabel(_ dms: String?) -> String {
        switch dms ?? "" {
        case "": "未绑定"
        case "online": "在线"
        case "connecting": "连接中"
        default: "未在线"
        }
    }
}

/// 首页：先看状态，再做三件常用事（切 Wi-Fi、静音、发卡片）；一次性配置与账号放下面。
struct HomeView: View {
    @EnvironmentObject private var cloud: CloudStore
    @EnvironmentObject private var recordings: RecordingStore
    @State private var composing = false

    var body: some View {
        List {
            Section { statusCard } footer: { statusFooter }
            Section {
                NavigationLink { WiFiView() } label: {
                    LabeledContent { Text(cloud.status?.ssid ?? "") } label: { Label("切换 Wi-Fi", systemImage: "wifi") }
                }
                Group {
                    Button { Task { await cloud.mute(panToken: recordings.token) } } label: { Label("静音", systemImage: "mic.slash") }
                        .disabled(remoteBlocked != nil || cloud.busy || cloud.status?.muted == true)
                    Button { composing = true } label: { Label("发送卡片", systemImage: "rectangle.on.rectangle") }
                        .disabled(remoteBlocked != nil)
                }
                .foregroundStyle(remoteBlocked == nil ? Color.primary : Color.secondary)  // 列表里禁用的按钮文字不会自动变灰
            } header: { Text("常用") } footer: {
                Text(remoteBlocked ?? "静音与卡片经网盘设备服务下发，不用靠近设备；远程只能静音，不能开麦。")
            }
            Section("设备与账号") {
                NavigationLink { DeviceManageView() } label: { Label("设备管理", systemImage: "gearshape") }
                account("Zhi.AI", systemImage: "person.crop.circle", loggedIn: cloud.loggedIn, busy: cloud.busy,
                        login: { await cloud.login() }, logout: cloud.logout)
                account("百度网盘", systemImage: "externaldrive", loggedIn: recordings.token != nil, busy: recordings.busy,
                        login: { await recordings.login() }, logout: recordings.logout)
            }
        }
        .navigationTitle("Yaha Desk")
        .refreshable { await cloud.refresh() }
        .task { await cloud.refresh() }
        .sheet(isPresented: $composing) { CardSheet() }
        .safeAreaInset(edge: .bottom) { Banner(text: cloud.message.isEmpty ? recordings.message : cloud.message) }
    }

    @ViewBuilder private var statusCard: some View {
        if !cloud.loggedIn {
            VStack(alignment: .leading, spacing: 12) {
                Text("登录后查看设备状态").font(.headline)
                Text("设备每分钟经 Zhi.AI 上报一次；iPhone 只读状态，不能开麦。").font(.subheadline).foregroundStyle(.secondary)
                Button("登录 Zhi.AI") { Task { await cloud.login() } }
                    .buttonStyle(.borderedProminent).disabled(cloud.busy)
            }
            .padding(.vertical, 8)
        } else if let status = cloud.status, status.reported {
            HStack(spacing: 16) {
                Image(systemName: status.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(status.online ? (status.muted ? Color.gray : Color.green) : Color.secondary.opacity(0.4)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.online ? (status.muted ? "在线 · 已静音" : "在线 · 麦克风使用中") : "离线").font(.headline)
                    Text(detail(status)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        } else if cloud.status != nil {
            Text("设备还没有上报。先在“切换 Wi-Fi”里给设备连网。").foregroundStyle(.secondary)
        } else if cloud.busy {
            HStack { ProgressView(); Text("正在读取设备状态").foregroundStyle(.secondary) }
        } else {
            Text("没有读到设备状态，下拉重试。").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusFooter: some View {
        if let status = cloud.status, status.reported, !status.online {
            Text("超过 3 分钟没有上报。开麦讲话期间设备暂停联网，停报不一定是断网。")
        }
    }

    private func detail(_ status: DeskStatus) -> String {
        var parts: [String] = []
        if let ssid = status.ssid, !ssid.isEmpty { parts.append(ssid) }
        parts.append(status.mac ? "Mac 已连接" : "Mac 未连接")
        if let at = status.reportedAt {
            parts.append(Date(timeIntervalSince1970: TimeInterval(at)).formatted(date: .omitted, time: .shortened) + " 上报")
        }
        return parts.joined(separator: " · ")
    }

    /// 远程控制不可用的原因；nil 表示可用。
    private var remoteBlocked: String? {
        if !cloud.loggedIn { return "先登录 Zhi.AI 查看设备。" }
        if cloud.status?.panDevice?.isEmpty ?? true { return "设备还没有绑定网盘，在“设备管理”里绑定后可远程静音和发卡片。" }
        if recordings.token == nil { return "登录百度网盘后可远程静音和发卡片。" }
        return nil
    }

    private func account(_ title: String, systemImage: String, loggedIn: Bool, busy: Bool,
                         login: @escaping () async -> Void, logout: @escaping () -> Void) -> some View {
        LabeledContent {
            if loggedIn {
                Button("退出", role: .destructive, action: logout).buttonStyle(.borderless)
            } else {
                Button("登录") { Task { await login() } }.buttonStyle(.borderless).disabled(busy)
            }
        } label: {
            Label { Text(title); Text(loggedIn ? "已登录" : "未登录") } icon: { Image(systemName: systemImage) }
        }
    }
}

/// 底部提示条：只显示最近一条操作结果，空串不占位。
struct Banner: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Text(text).font(.footnote).padding(12).frame(maxWidth: .infinity).background(.regularMaterial)
        }
    }
}
