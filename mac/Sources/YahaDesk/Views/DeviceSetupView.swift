import SwiftUI
import DeskProtocol

/// 设备设置窗口:系统设置风格的分组表单(设备 / Wi-Fi / 网盘 / 录音备份 / 工作台)。
struct DeviceSetupView: View {
    @ObservedObject var cloud: CloudSync
    @ObservedObject var recordings: RecordingBackup
    @ObservedObject var voiceProfile: VoiceProfile
    @ObservedObject var firmware: FirmwareInstaller
    @ObservedObject var aiPolish: AIPolish
    var deviceFirmware: String
    @State private var ssid = ""
    @State private var password = ""
    @State private var manualSSID = false
    @State private var confirmingVoiceDelete = false
    @State private var showAllRecordings = false
    @State private var zhipuKey = ""
    @State private var zhipuMessage: String?

    var body: some View {
        Form {
            deviceSection
            #if !APP_STORE
            firmwareSection
            #endif
            wifiSection
            panSection
            recordingSection
            voiceProfileSection
            aiPolishSection
            workbenchSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 480)
        .safeAreaInset(edge: .bottom) { MiniPlayerBar(player: recordings.player).frame(maxWidth: 520) }
        .onDisappear { recordings.player.stop() }  // 关窗即停,不在后台偷偷放
        .task(id: cloud.panLoggedIn) { if cloud.panLoggedIn { await recordings.upload(); await recordings.refresh() } }
        .confirmationDialog("删除本人声纹档案？", isPresented: $confirmingVoiceDelete, titleVisibility: .visible) {
            Button("只删除本机档案", role: .destructive) {
                Task { await voiceProfile.delete(includeRemote: false) }
            }
            if voiceProfile.hasRemoteFiles {
                Button("删除本机和网盘备份", role: .destructive) {
                    Task { await voiceProfile.delete(includeRemote: true) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(voiceProfile.hasRemoteFiles
                 ? "网盘备份与本机档案分开保存；选择第二项会把网盘副本移入回收站。"
                 : "删除后需要重新录制五句话。")
        }
    }

    // MARK: 设备

    private var deviceSection: some View {
        Section {
            LabeledContent("蓝牙") {
                status(cloud.deviceConnected ? "已连接" : "未连接", ok: cloud.deviceConnected)
            }
            if cloud.deviceConnected && cloud.deviceSupported {
                LabeledContent("Wi-Fi") {
                    status(cloud.deviceCloudState.wifiConnected ? "已连接" : "未连接",
                           ok: cloud.deviceCloudState.wifiConnected)
                }
                if let message = cloud.deviceCloudState.errorMessage { warning(message) }
            }
            if cloud.deviceConnected && !cloud.deviceSupported {
                warning("当前固件不支持联网配置。请升级固件后再配网和授权。")
            }
        } header: {
            Text("设备")
        } footer: {
            Text(cloud.deviceConnected
                 ? "在 iPhone 上配置时，先在菜单栏点「暂时断开」，把蓝牙连接让给 iPhone。"
                 : "打开设备并靠近 Mac；首次连接按设备屏幕上的 6 位数字配对。")
        }
    }

    // MARK: 固件

    #if !APP_STORE  // 商店版沙盒没有串口权限(Xcode 只认 device.usb),固件只在官网版安装
    private var firmwareSection: some View {
        Section {
            if let bundle = firmware.bundle {
                LabeledContent("设备上的版本", value: deviceFirmware.isEmpty ? "未知" : deviceFirmware)
                HStack {
                    if let value = firmware.progress {
                        ProgressView(value: value)
                    } else if let message = firmware.message {
                        progress(message, busy: firmware.busy)
                    }
                    Spacer()
                    Button(deviceFirmware == bundle.version ? "重新安装 \(bundle.version)" : "安装 \(bundle.version)") {
                        firmware.install()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(firmware.busy)
                }
            } else {
                warning("这个版本的 App 没有带固件。")
            }
        } header: {
            Text("固件")
        } footer: {
            Text("用 USB 数据线把设备连到这台 Mac 再安装，过程中不要拔线。只更新有变化的部分，Wi-Fi、蓝牙配对和网盘授权都保留。")
        }
        .confirmationDialog("覆盖设备上的「\(firmware.foreignProject ?? "")」？", isPresented: Binding(
            get: { firmware.foreignProject != nil }, set: { if !$0 { firmware.foreignProject = nil } }
        ), titleVisibility: .visible) {
            Button("安装 Yaha Desk", role: .destructive) { firmware.install(allowForeign: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台设备上是别的固件。安装后它会变成 Yaha Desk，原来的程序被替换。")
        }
    }
    #endif

    // MARK: Wi-Fi

    private var wifiSection: some View {
        Section {
            if cloud.deviceSupportsWiFiScan && !manualSSID { networkPicker }
            if !cloud.deviceSupportsWiFiScan || manualSSID {
                TextField("网络名称", text: $ssid, prompt: Text("2.4 GHz Wi-Fi"))
            }
            if selectedNetwork?.secure != false {
                SecureField("密码", text: $password)
            }
            HStack {
                if cloud.deviceSupportsWiFiScan {
                    Button(manualSSID ? "从扫描列表选择" : "手动输入隐藏网络") { manualSSID.toggle(); ssid = "" }
                        .buttonStyle(.link)
                }
                Spacer()
                Button("发送到设备") {
                    let value = selectedNetwork?.secure == false ? "" : password
                    password = ""
                    Task { await cloud.configureWiFi(ssid: ssid, password: value) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProvision || ssid.isEmpty)
            }
            if let message = cloud.deviceMessage {
                progress(message, busy: cloud.deviceBusy && !cloud.authorizationBusy && !cloud.panBusy)
            }
        } header: {
            Text("Wi-Fi")
        } footer: {
            Text("密码经加密蓝牙写入设备，只存在设备上；云端只记网络名。")
        }
        .disabled(!cloud.deviceConnected)
    }

    private var networkPicker: some View {
        HStack {
            Picker("网络", selection: $ssid) {
                Text(cloud.wifiNetworks.isEmpty ? "请先扫描" : "选择网络").tag("")
                ForEach(cloud.wifiNetworks, id: \.ssid) { network in
                    Text("\(network.ssid)\(network.secure ? "" : "（开放）") · \(signal(network.rssi))").tag(network.ssid)
                }
            }
            .disabled(cloud.wifiNetworks.isEmpty)
            if cloud.wifiScanning { ProgressView().controlSize(.small) }
            Button {
                Task { await cloud.scanWiFi() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(cloud.wifiNetworks.isEmpty ? "扫描附近 Wi-Fi" : "重新扫描")
            .accessibilityLabel("扫描 Wi-Fi")
            .disabled(!canProvision || cloud.wifiScanning)
        }
        .onChange(of: cloud.deviceSupportsWiFiScan, initial: true) {
            // Scan once per connection. Unstructured: a cancelled provisioning write drops the BLE link.
            if canProvision && cloud.wifiNetworks.isEmpty { Task { await cloud.scanWiFi() } }
        }
        .onChange(of: cloud.wifiNetworks) { _, networks in
            if !networks.contains(where: { $0.ssid == ssid }) { ssid = "" }
        }
    }
    // MARK: 网盘

    private var panSection: some View {
        Section {
            LabeledContent("百度网盘") {
                HStack {
                    status(cloud.panLoggedIn ? "已登录" : "未登录", ok: cloud.panLoggedIn)
                    if cloud.panLoggedIn {
                        Button("退出", action: cloud.logoutPan).disabled(cloud.panBusy)
                    } else {
                        Button("登录") { Task { await cloud.loginPan() } }.disabled(cloud.panBusy)
                    }
                }
            }
            LabeledContent("设备绑定") {
                HStack {
                    if cloud.panBusy { ProgressView().controlSize(.small) }
                    Text(cloud.deviceConnected ? cloud.panStatus : "蓝牙未连接").foregroundStyle(.secondary)
                    if cloud.canUnbindPan {
                        Button("解绑") { Task { await cloud.unbindPan() } }.disabled(cloud.panBusy || cloud.deviceBusy)
                    } else if cloud.canBindPan {
                        Button("绑定") { Task { await cloud.bindPan() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(cloud.panBusy || cloud.deviceBusy)
                    }
                }
            }
            if cloud.deviceConnected && cloud.deviceSupported && !cloud.deviceSupportsPan {
                warning("当前固件不支持网盘绑定。请升级固件后再绑定。")
            }
            if let message = cloud.panMessage { Text(message).foregroundStyle(.secondary) }
        } header: {
            Text("网盘")
        } footer: {
            Text("绑定后设备直接连百度网盘设备服务；网盘登录只保存在本机钥匙串，约 30 天需重新登录。")
        }
    }

    // MARK: 录音备份

    private var recordingSection: some View {
        Section {
            if recordings.items.isEmpty {
                ContentUnavailableView {
                    Label(cloud.panLoggedIn ? "还没有已备份的录音" : "未登录网盘", systemImage: "waveform")
                } description: {
                    Text(cloud.panLoggedIn ? "开麦讲话后静音，录音会自动上传" : "登录网盘后显示已备份的录音")
                }
            }
            ForEach(showAllRecordings ? recordings.items : Array(recordings.items.prefix(5))) { take in
                TakeRow(take: take, player: recordings.player, showsDate: true)
            }
            if recordings.items.count > 5 {
                Button(showAllRecordings ? "收起" : "显示全部 \(recordings.items.count) 条") { showAllRecordings.toggle() }
                    .buttonStyle(.link)
            }
            if let message = recordings.message { Text(message).foregroundStyle(.secondary) }
        } header: {
            HStack {
                Text("录音备份")
                if recordings.pending > 0 {
                    Text("\(recordings.pending) 段待上传").foregroundStyle(.orange)
                }
                Spacer()
                if recordings.busy { ProgressView().controlSize(.small) }
                Button {
                    Task { await recordings.upload(); await recordings.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("上传待传录音并刷新列表")
                .accessibilityLabel("刷新录音列表")
                .disabled(recordings.busy || !cloud.panLoggedIn)
            }
        } footer: {
            Text("每次讲话的录音存到网盘兼容目录 /apps/拾见/录音，本地转文字写入的文本以同名 .txt 一起保存并显示在录音下面；点录音播放，最多显示最近 100 条。")
        }
    }

    // MARK: 本人声纹

    private var voiceProfileSection: some View {
        Section {
            LabeledContent("状态") {
                HStack(spacing: 6) {
                    if voiceProfile.busy { ProgressView().controlSize(.small) }
                    status(voiceProfile.ready ? "本机模型已就绪"
                           : !voiceProfile.hasLocalData && voiceProfile.hasRemoteFiles ? "本机已删除，网盘待处理"
                           : "已录 \(voiceProfile.manifest.samples.count)/5 句",
                           ok: voiceProfile.ready)
                }
            }
            ForEach(VoiceProfile.phrases.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("第 \(index + 1) 句").font(.caption).foregroundStyle(.secondary)
                        Text(VoiceProfile.phrases[index]).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if voiceProfile.sample(at: index) != nil {
                        Label("合格", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            .labelStyle(.iconOnly).help("录音质量合格")
                    }
                    Button(voiceProfile.sample(at: index) == nil ? "录制" : "重录") {
                        Task { await voiceProfile.record(index) }
                    }
                    .disabled(voiceProfile.busy || !cloud.deviceConnected || voiceProfile.hasRemoteFiles)
                }
            }
            HStack {
                if let message = voiceProfile.message {
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if voiceProfile.hasLocalData {
                    Button("删除档案", role: .destructive) { confirmingVoiceDelete = true }
                        .disabled(voiceProfile.busy)
                } else if voiceProfile.hasRemoteFiles {
                    Button("重试删除网盘备份", role: .destructive) {
                        Task { await voiceProfile.delete(includeRemote: true) }
                    }
                    .disabled(voiceProfile.busy)
                }
                Button(voiceProfile.backedUp ? "已备份" : voiceProfile.hasRemoteFiles ? "继续备份" : "备份到网盘") {
                    Task { await voiceProfile.backup() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!voiceProfile.ready || voiceProfile.busy || voiceProfile.backedUp || !cloud.panLoggedIn)
            }
        } header: {
            Text("本人声纹")
        } footer: {
            Text("五段原始语音和声纹默认只保存在本机；只有点“备份到网盘”才会上传。打开菜单栏“只留本人声音”后，本地转文字和 BlackHole 会去掉不像本人的语段；你和别人同时说话时分不开。")
        }
    }

    // MARK: AI 润色

    private var aiPolishSection: some View {
        Section {
            LabeledContent("API Key") {
                status(aiPolish.hasKey ? "已保存在钥匙串" : "未填写", ok: aiPolish.hasKey)
            }
            HStack {
                SecureField("智谱 API Key", text: $zhipuKey, prompt: Text(aiPolish.hasKey ? "填新的 Key 覆盖" : "粘贴 Key"))
                Button("保存") {
                    zhipuMessage = aiPolish.saveKey(zhipuKey) ? nil : "保存失败,请检查 Key"
                    zhipuKey = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(zhipuKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if aiPolish.hasKey {
                    Button("删除", role: .destructive) { aiPolish.deleteKey() }
                }
            }
            if let zhipuMessage { warning(zhipuMessage) }
        } header: {
            Text("AI 润色（智谱 GLM Coding Plan）")
        } footer: {
            Text("在菜单栏打开「AI 润色」后，本地转出的文字会发给智谱 \(AIPolish.model) 去掉口头语、修标点再插入；录音标注仍存原文。Key 只存在本机钥匙串，失败或 10 秒超时插入原文。")
        }
    }

    // MARK: 工作台

    private var workbenchSection: some View {
        Section {
            LabeledContent("Mac 连接") {
                HStack {
                    Text(cloud.authenticationMode == .pkce ? "已恢复原有授权" : "内置连接").foregroundStyle(.secondary)
                    if cloud.authenticationMode == .pkce {
                        Button("重新授权", action: cloud.reauthorizeLegacyController)
                            .disabled(cloud.authorizationBusy || cloud.requestBusy)
                    }
                    if cloud.clientID == nil {
                        Button("重试", action: cloud.start).disabled(cloud.authorizationBusy || cloud.requestBusy)
                    }
                }
            }
            LabeledContent("设备授权") {
                HStack {
                    status(cloud.deviceCloudState.authorized ? "已授权" : "未授权", ok: cloud.deviceCloudState.authorized)
                    if cloud.authorizationBusy {
                        Button("取消", action: cloud.cancelAuthorization)
                    } else {
                        Button("授权设备", action: cloud.authorizeDevice)
                            .disabled(!canProvision || cloud.clientID == nil || cloud.requestBusy)
                    }
                }
            }
            if let message = cloud.authorizationMessage { progress(message, busy: cloud.authorizationBusy) }
            if !cloud.status.isEmpty { Text(cloud.status).foregroundStyle(.secondary) }
            if let error = cloud.lastError { warning(error) }
        } header: {
            Text("工作台")
        } footer: {
            Text("在浏览器完成授权后自动交付给当前设备。设备授权只保存在设备，Mac 退出后设备仍可接收内容。")
        }
    }

    // MARK: 辅助

    private func status(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(ok ? .green : .secondary)
    }

    /// 操作反馈:进行中带转圈,结束后留下结果文字。
    private func progress(_ text: String, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.small) }
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var selectedNetwork: WiFiNetwork? {
        manualSSID ? nil : cloud.wifiNetworks.first { $0.ssid == ssid }
    }
    private func signal(_ rssi: Int) -> String { rssi >= -60 ? "信号强" : rssi >= -75 ? "信号中" : "信号弱" }
    private var canProvision: Bool { cloud.deviceConnected && cloud.deviceSupported && !cloud.deviceBusy }
}
