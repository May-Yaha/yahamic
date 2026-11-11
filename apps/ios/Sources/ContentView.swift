import SwiftUI

/// 版式全部用系统控件与 Dynamic Type 文字样式（HIG 默认 8 pt 网格），不自定义字号与间距，跟随系统字号缩放。
/// 窄屏(iPhone、Duo 折叠)底部两个标签;宽屏(Duo 展开、横放)左右分栏,左边设备状态与常用操作,右边录音时间线。
struct ContentView: View {
    @State private var width: CGFloat = 0

    var body: some View {
        Group {
            if width >= 600 {
                HStack(spacing: 0) {
                    NavigationStack { HomeView() }
                        .frame(width: min(max(width * 0.45, 320), 420))
                    Divider().ignoresSafeArea()
                    NavigationStack { RecordingsView() }
                }
            } else {
                TabView {
                    Tab("首页", systemImage: "mic.circle") { NavigationStack { HomeView() } }
                    Tab("录音", systemImage: "waveform") { NavigationStack { RecordingsView() } }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(.snappy, value: width >= 600)
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

/// 首页：顶部选声源（设备 / 手机），下面整页只讲选中的那个；设备页再做三件常用事（切 Wi-Fi、静音、发卡片）。
struct HomeView: View {
    @EnvironmentObject private var cloud: CloudStore
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var phoneMic: PhoneMic
    @State private var composing = false
    @AppStorage("homePhoneSource") private var phoneSource = false

    var body: some View {
        List {
            Section { sourcePicker }.listSectionSpacing(.compact)
            if phoneSource { phoneSections } else { deviceSections }
            Section("账号") {
                if !phoneSource {
                    account("Zhi.AI", systemImage: "person.fill", color: .indigo, loggedIn: cloud.loggedIn, busy: cloud.busy,
                            login: { await cloud.login() }, logout: cloud.logout)
                }
                account("百度网盘", systemImage: "externaldrive.fill", color: .cyan, loggedIn: recordings.token != nil, busy: recordings.busy,
                        login: { await recordings.login() }, logout: recordings.logout)
            }
        }
        .navigationTitle("Yaha Desk")
        .refreshable { if !phoneSource { await cloud.refresh() } }
        .task { await recordings.renew(); await cloud.refresh() }
        .sheet(isPresented: $composing) { CardSheet() }
        .safeAreaInset(edge: .bottom) { Banner(text: cloud.message.isEmpty ? recordings.message : cloud.message) }
        .animation(.snappy, value: phoneSource)
        .onChange(of: phoneMic.joined) { _, joined in if joined { phoneSource = true } }  // 系统恢复了频道
    }

    /// 手机当麦克风:只讲手机自己,不出现设备状态、远程控制和 Zhi.AI(没有设备的用户也能用)。
    @ViewBuilder private var phoneSections: some View {
        Section {
            if phoneMic.joined {
                // 讲话绿、Mac 已连接蓝、等待 Mac 灰。
                hero(symbol: phoneMic.talking ? "mic.fill" : "iphone.gen3",
                     tint: phoneMic.talking ? .green : phoneMic.macLinked ? .blue : .gray, lit: phoneMic.macLinked,
                     title: phoneMic.talking ? "讲话中" : phoneMic.macLinked ? "Mac 已连接" : "等待 Mac",
                     detail: phoneMic.macLinked ? "按住 Mac 的讲话键讲话，锁屏也能用" : "在 Mac 菜单把声源切到“手机”，首次连接两边确认配对")
            } else {
                VStack(spacing: 12) {
                    hero(symbol: "iphone.gen3", tint: .gray, lit: false, title: "手机麦克风未开启",
                         detail: "开启后 Mac 把手机当麦克风用，锁屏也能讲话")
                    Button("开启") { phoneMic.toggle() }.buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }
        } footer: {
            if !phoneMic.message.isEmpty { Text(phoneMic.message) }
        }
        Section("设置") { aiSummaryLink }
    }

    @ViewBuilder private var deviceSections: some View {
        Section { statusCard } footer: { statusFooter }
        Section {
            NavigationLink { WiFiView() } label: {
                LabeledContent { Text(cloud.status?.ssid ?? "") } label: {
                    Label("切换 Wi-Fi", systemImage: "wifi").labelStyle(.badge(.blue))
                }
            }
            Group {
                Button { Task { await cloud.mute(panToken: recordings.token) } } label: {
                    Label("静音", systemImage: "mic.slash.fill").labelStyle(.badge(.red))
                }
                .disabled(remoteBlocked != nil || cloud.busy || cloud.status?.muted == true)
                Button { composing = true } label: {
                    Label("发送卡片", systemImage: "rectangle.on.rectangle").labelStyle(.badge(.orange))
                }
                .disabled(remoteBlocked != nil)
            }
            .foregroundStyle(remoteBlocked == nil ? Color.primary : Color.secondary)  // 列表里禁用的按钮文字不会自动变灰
        } header: { Text("常用") } footer: {
            Text(remoteBlocked ?? "静音与卡片经网盘设备服务下发，不用靠近设备；远程只能静音，不能开麦。")
        }
        Section("设置") {
            NavigationLink { DeviceManageView() } label: { Label("设备管理", systemImage: "gearshape.fill").labelStyle(.badge(.gray)) }
            aiSummaryLink
        }
    }

    private var aiSummaryLink: some View {
        NavigationLink { AISettingsView() } label: { Label("AI 总结", systemImage: "sparkles").labelStyle(.badge(.purple)) }
    }

    @ViewBuilder private var statusCard: some View {
        if !cloud.loggedIn {
            VStack(alignment: .leading, spacing: 12) {
                Text("登录后查看设备状态").font(.headline)
                Text("设备每分钟经 Zhi.AI 上报一次。没有设备的话，在上面切到“手机”。").font(.subheadline).foregroundStyle(.secondary)
                Button("登录 Zhi.AI") { Task { await cloud.login() } }
                    .buttonStyle(.borderedProminent).disabled(cloud.busy)
            }
            .padding(.vertical, 8)
        } else if let status = cloud.status, status.reported {
            // 单一主角:大圆状态 + 状态词 + 一行说明;色与 Mac 菜单一致(开麦绿、静音红、离线灰)。
            hero(symbol: status.online ? (status.muted ? "mic.slash.fill" : "mic.fill") : "mic.slash",
                 tint: status.online ? (status.muted ? .red : .green) : .gray, lit: status.online,
                 title: status.online ? (status.muted ? "在线 · 已静音" : "在线 · 麦克风使用中") : "离线",
                 detail: detail(status))
                .animation(.snappy, value: status)
        } else if cloud.status != nil {
            Text("设备还没有上报。先在“切换 Wi-Fi”里给设备连网。").foregroundStyle(.secondary)
        } else if cloud.busy {
            HStack { ProgressView(); Text("正在读取设备状态").foregroundStyle(.secondary) }
        } else {
            Text("没有读到设备状态，下拉重试。").foregroundStyle(.secondary)
        }
    }

    /// 大圆只表达状态;切声源用顶部的分段控件,和 Mac 菜单同构。
    private func hero(symbol: String, tint: Color, lit: Bool, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 104, height: 104)
                .background(Circle().fill(tint.gradient))
                .padding(8)
                .overlay(Circle().strokeBorder(tint.opacity(0.25), lineWidth: 6))
                .shadow(color: tint.opacity(lit ? 0.35 : 0), radius: 16, y: 6)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(title).font(.title3.bold()).foregroundStyle(tint)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .animation(.snappy, value: phoneMic.joined)
        .animation(.snappy, value: phoneMic.talking)
    }

    /// 声源:设备 / 手机,决定下面整页讲哪个。选“手机”即加入频道,选“设备”即离开;选择跨启动保留。
    private var sourcePicker: some View {
        Picker("声源", selection: Binding(get: { phoneSource }, set: { on in
            phoneSource = on
            if on != phoneMic.joined { phoneMic.toggle() }
        })) {
            Label("设备", systemImage: "mic.fill").tag(false)
            Label("手机", systemImage: "iphone.gen3").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
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

    private func account(_ title: String, systemImage: String, color: Color, loggedIn: Bool, busy: Bool,
                         login: @escaping () async -> Void, logout: @escaping () -> Void) -> some View {
        LabeledContent {
            if loggedIn {
                Button("退出", role: .destructive, action: logout).buttonStyle(.borderless)
            } else {
                Button("登录") { Task { await login() } }.buttonStyle(.borderless).disabled(busy)
            }
        } label: {
            Label { Text(title); Text(loggedIn ? "已登录" : "未登录") } icon: { Image(systemName: systemImage) }
                .labelStyle(.badge(color))
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
