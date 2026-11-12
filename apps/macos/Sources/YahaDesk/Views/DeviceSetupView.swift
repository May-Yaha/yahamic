import DeskProtocol
import DeskShared
import SwiftUI
import Translation

/// 设备设置窗口:系统设置式侧栏(彩色方块图标)+ 右侧分组表单,一页一件事;迷你播放条切页不中断。
struct DeviceSetupView: View {
    @ObservedObject var cloud: CloudSync
    @ObservedObject var recordings: RecordingBackup
    @ObservedObject var voiceProfile: VoiceProfile
    @ObservedObject var firmware: FirmwareInstaller
    @ObservedObject var aiPolish: AIPolish
    @ObservedObject var training: TrainingSet
    @ObservedObject var models: OfflineModels
    var deviceFirmware: String
    @State private var pane: Pane? = .device
    @State private var ssid = ""
    @State private var password = ""
    @State private var manualSSID = false
    @State private var confirmingVoiceDelete = false
    @State private var zhipuKey = ""
    @State private var zhipuMessage: String?
    @State private var translationDownload: TranslationSession.Configuration?  // 设上就由系统弹下载确认

    enum Pane: CaseIterable, Identifiable {
        case device, firmware, wifi, voice, models, aiPolish, labeling, pan, recordings, workbench
        var id: Self { self }
        /// 侧栏三组:设备本身 → 语音处理 → 云与数据。
        static let groups: [(title: String, panes: [Pane])] = [
            ("设备", [.device, .firmware, .wifi]),
            ("语音", [.voice, .models, .aiPolish, .labeling]),
            ("云与数据", [.pan, .recordings, .workbench]),
        ]
        var title: String {
            switch self {
            case .device: "设备"
            case .firmware: "固件"
            case .wifi: "Wi-Fi"
            case .pan: "网盘"
            case .recordings: "录音"
            case .labeling: "标注"
            case .voice: "本人声纹"
            case .models: "离线模型"
            case .aiPolish: "AI 润色"
            case .workbench: "工作台"
            }
        }
        var symbol: String {
            switch self {
            case .device: "display"
            case .firmware: "cpu.fill"
            case .wifi: "wifi"
            case .pan: "externaldrive.fill"
            case .recordings: "waveform"
            case .labeling: "checklist"
            case .voice: "person.wave.2.fill"
            case .models: "arrow.down.circle.fill"
            case .aiPolish: "wand.and.sparkles"
            case .workbench: "rectangle.on.rectangle"
            }
        }
        var color: Color {
            switch self {
            case .device: .blue
            case .firmware: .gray
            case .wifi: .teal
            case .pan: .cyan
            case .recordings: .red
            case .labeling: .green
            case .voice: .purple
            case .models: .mint
            case .aiPolish: .orange
            case .workbench: .indigo
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.panes) { item in
                            Label(item.title, systemImage: item.symbol).labelStyle(.badge(item.color, size: 22)).tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Form {
                switch pane ?? .device {
                case .device: overview; deviceSection
                case .firmware: firmwareSection
                case .wifi: wifiSection
                case .pan: panSection
                case .recordings: recordingPane
                case .labeling: LabelingPane(training: training, aiPolish: aiPolish, panLoggedIn: cloud.panLoggedIn)
                case .voice: voiceProfileSection
                case .models: modelsSection
                case .aiPolish: aiPolishSection
                case .workbench: workbenchSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle((pane ?? .device).title)
            .safeAreaInset(edge: .bottom) { MiniPlayerBar(player: recordings.player).frame(maxWidth: 560) }
        }
        .frame(minWidth: 720, minHeight: 480)
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

    /// 首屏主角:设备大图标 + 版本,下面一排状态胶囊(形状 + 文字 + 颜色),一眼看出还差哪步。
    private var overview: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "display").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.blue.gradient, in: .rect(cornerRadius: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Yaha Desk").font(.title2.bold())
                    Text(deviceFirmware.isEmpty ? "固件版本未知" : "固件 \(deviceFirmware)").foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                chip("蓝牙", ok: cloud.deviceConnected)
                chip("Wi-Fi", ok: cloud.deviceConnected && cloud.deviceCloudState.wifiConnected)
                chip("网盘", ok: cloud.panLoggedIn)
                chip("工作台", ok: cloud.deviceCloudState.authorized)
            }
        }
    }

    private func chip(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption.weight(.medium))
            .foregroundStyle(ok ? .green : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((ok ? Color.green : Color.secondary).opacity(0.12), in: .capsule)
    }

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

    @ViewBuilder private var recordingPane: some View {
        Section {
            LabeledContent("网盘备份") {
                HStack {
                    if recordings.pending > 0 { Text("\(recordings.pending) 段待上传").foregroundStyle(.orange) }
                    else { Text("\(recordings.items.count) 条").foregroundStyle(.secondary) }
                    if recordings.busy { ProgressView().controlSize(.small) }
                    Button {
                        Task { await recordings.upload(); await recordings.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("上传待传录音并刷新列表")
                    .accessibilityLabel("刷新录音列表")
                    .disabled(recordings.busy || !cloud.panLoggedIn)
                }
            }
            if let message = recordings.message { Text(message).foregroundStyle(.secondary) }
            if recordings.items.isEmpty {
                ContentUnavailableView {
                    Label(cloud.panLoggedIn ? "还没有已备份的录音" : "未登录网盘", systemImage: "waveform")
                } description: {
                    Text(cloud.panLoggedIn ? "开麦讲话后静音，录音会自动上传" : "登录网盘后显示已备份的录音")
                }
            }
        } footer: {
            Text("每次讲话的录音存到网盘兼容目录 /apps/拾见/录音，本地转文字写入的文本以同名 .txt 一起保存并显示在录音下面；点录音播放，最多显示最近 100 条。")
        }
        ForEach(PanFiles.days(recordings.items), id: \.day) { group in
            Section(group.day.formatted(.dateTime.month().day().weekday())) {
                ForEach(group.items) { take in TakeRow(take: take, player: recordings.player) }
            }
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

    // MARK: 离线模型

    private var modelsSection: some View {
        Group {
            Section {
                LabeledContent("Qwen3-ASR 0.6B") {
                    switch models.asr {
                    case .missing: status("未下载(约 820 MB)", ok: false)
                    case .downloading(let percent): progress("下载中 \(percent)%", busy: true)
                    case .ready(let bytes): status("已下载 · \(OfflineModels.size(bytes))", ok: true)
                    case .failed(let message): warning(message)
                    }
                }
                if case .downloading(let percent) = models.asr {
                    ProgressView(value: Double(percent), total: 100)
                }
                HStack {
                    if case .ready = models.asr {
                        Button("在访达中显示") { models.revealASR() }
                        Spacer()
                        Button("删除", role: .destructive) { Task { await models.deleteASR() } }
                            .disabled(models.inUse())
                            .help(models.inUse() ? "本地转文字或视频字幕正在用,先关掉再删" : "删除本机权重,用到时重新下载")
                    } else if case .downloading = models.asr {
                        Spacer()
                        Button("取消") { models.cancelDownload() }
                    } else {
                        Spacer()
                        Button("下载") { models.downloadASR() }.buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                Text("语音识别")
            } footer: {
                Text("本地转文字与视频字幕共用,离线运行、声音不出本机。权重存在 ~/Library/Application Support/YahaDesk/Models,中断后再点下载会接着下。")
            }
            Section {
                ForEach(models.pairs) { pair in
                    LabeledContent(pair.title) {
                        HStack(spacing: 8) {
                            switch pair.status {
                            case .installed: status("已安装", ok: true)
                            case .supported:
                                Button("下载") {
                                    if translationDownload?.source == pair.source && translationDownload?.target == pair.target {
                                        translationDownload?.invalidate()
                                    } else {
                                        translationDownload = .init(source: pair.source, target: pair.target)
                                    }
                                }
                            default: Text("不支持").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("刷新") { Task { await models.refreshPairs() } }
                    Button("在系统设置中管理") { models.openSystemTranslationSettings() }
                }
            } header: {
                Text("字幕翻译语言包")
            } footer: {
                Text("视频字幕翻译优先用系统离线翻译;没装的语言对填了 AI Key 时走 AI 翻译。语言包由系统下载与删除,删除到 系统设置 → 通用 → 语言与地区 → 翻译语言。")
            }
        }
        .task {
            models.refreshASR()
            // 语言包点「完成」后在后台接着下,页面开着就每 5 秒查一次,装好自动变「已安装」。
            while !Task.isCancelled {
                await models.refreshPairs()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .translationTask(translationDownload) { session in
            do {
                try await session.prepareTranslation()  // 系统弹框确认下载,装好才返回
            } catch {
                models.log("⚠️ 离线模型:翻译语言包下载失败:\(error.localizedDescription)")
            }
            await models.refreshPairs()
        }
    }

    // MARK: AI 润色

    /// 取到的列表里没有当前模型(手填过或旧默认)时也放进去,Picker 才有选中项。
    private var modelChoices: [String] {
        aiPolish.models.contains(aiPolish.model) ? aiPolish.models : [aiPolish.model] + aiPolish.models
    }

    private var aiPolishSection: some View {
        Group {
            Section {
                TextField("接口地址", text: $aiPolish.endpoint, prompt: Text(AIPolish.defaultEndpoint))
                    .onSubmit { Task { await aiPolish.fetchModels() } }
                if !aiPolish.endpoint.isEmpty && AIPolish.chatURL(aiPolish.endpoint) == nil {
                    warning("地址需以 https:// 开头(本机服务可用 http://localhost)")
                }
                LabeledContent("API Key") {
                    status(aiPolish.hasKey ? "已保存在钥匙串" : "未填写", ok: aiPolish.hasKey)
                }
                HStack {
                    SecureField("新 Key", text: $zhipuKey, prompt: Text(aiPolish.hasKey ? "填新的 Key 覆盖" : "粘贴 Key"))
                    Button("保存") {
                        zhipuMessage = aiPolish.saveKey(zhipuKey) ? nil : "保存失败,请检查 Key"
                        zhipuKey = ""
                        if zhipuMessage == nil { Task { await aiPolish.fetchModels() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(zhipuKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if aiPolish.hasKey {
                        Button("删除", role: .destructive) { aiPolish.deleteKey() }
                    }
                }
                if let zhipuMessage { warning(zhipuMessage) }
                HStack {
                    if aiPolish.models.isEmpty {
                        TextField("模型", text: $aiPolish.model, prompt: Text(AIPolish.defaultModel))
                    } else {
                        Picker("模型", selection: $aiPolish.model) {
                            ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if aiPolish.modelsBusy { ProgressView().controlSize(.small) }
                    Button(aiPolish.models.isEmpty ? "获取模型列表" : "刷新") { Task { await aiPolish.fetchModels() } }
                        .disabled(!aiPolish.hasKey || AIPolish.chatURL(aiPolish.endpoint) == nil || aiPolish.modelsBusy)
                }
                if let message = aiPolish.modelsMessage { warning(message) }
                if aiPolish.endpoint != AIPolish.defaultEndpoint || aiPolish.model != AIPolish.defaultModel {
                    Button("恢复智谱 Coding Plan") {
                        aiPolish.endpoint = AIPolish.defaultEndpoint
                        aiPolish.model = AIPolish.defaultModel
                        Task { await aiPolish.fetchModels() }
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("接口")
            } footer: {
                Text("填好地址和 Key 后自动请求一次模型列表,从中选一个即生效;接口不支持列出模型时可直接手填。默认是智谱 GLM Coding Plan,也可填任何 OpenAI 兼容的 Chat Completions 接口(base URL 到 /v1 这一级)。Key 只存在本机钥匙串,换接口时记得换 Key。")
            }
            .task { if aiPolish.hasKey && aiPolish.models.isEmpty { await aiPolish.fetchModels() } }
            Section {
                TextEditor(text: $aiPolish.prompt)
                    .font(.body)
                    .frame(minHeight: 120)
                if aiPolish.prompt != AIPolish.defaultPrompt {
                    Button("恢复默认提示词") { aiPolish.prompt = AIPolish.defaultPrompt }.buttonStyle(.link)
                }
            } header: {
                Text("提示词")
            } footer: {
                Text("作为 system 消息发送,转写文字作为 user 消息。在菜单栏打开「AI 润色」后,定稿先发到上面的接口再插入;录音标注仍存原文。失败或 10 秒超时插入原文。")
            }
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
