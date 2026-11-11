import SwiftUI

/// 一次性与不可轻易撤回的操作：蓝牙绑定/解绑网盘、远程解绑。解绑都要二次确认。
struct DeviceManageView: View {
    @EnvironmentObject private var device: DeviceStore
    @EnvironmentObject private var cloud: CloudStore
    @EnvironmentObject private var recordings: RecordingStore
    @State private var confirmLocal = false
    @State private var confirmRemote = false

    var body: some View {
        List {
            Section {
                LabeledContent("蓝牙", value: device.ready ? "已连接" : "未连接")
                LabeledContent("设备", value: device.deviceName)
                if !device.firmware.isEmpty { LabeledContent("固件", value: device.firmware) }
                LabeledContent("网络", value: device.cloud.wifiConnected ? "已联网" : "未联网")
                if let error = device.cloud.errorMessage { Text(error).foregroundStyle(.orange) }
            } header: { Text("附近的设备") } footer: {
                if !device.ready { Text("连不上时，在 Mac 菜单栏的 Yaha Desk 里点“暂时断开”。") }
            }
            Section {
                LabeledContent("网盘设备服务", value: ContentView.dmsLabel(device.ready ? device.cloud.dms : cloud.status?.dms))
                if recordings.token == nil {
                    Button("登录百度网盘") { Task { await recordings.login() } }.disabled(recordings.busy)
                } else if device.ready && device.cloud.dms.isEmpty {
                    Button("绑定此设备") { Task { await device.bindPan(token: recordings.token) } }.disabled(device.busy)
                } else if device.ready {
                    Button("解绑此设备", role: .destructive) { confirmLocal = true }.disabled(device.busy)
                } else if cloud.status?.panDevice?.isEmpty == false {
                    Button("远程解绑", role: .destructive) { confirmRemote = true }.disabled(cloud.busy)
                }
            } header: { Text("网盘") } footer: {
                Text("绑定后可远程静音、发卡片，录音自动备份到网盘。绑定需要靠近设备。")
            }
            if cloud.status?.panDevice?.isEmpty == false, recordings.token != nil {
                Section {
                    Button("清除设备上的卡片") { Task { await cloud.clearCards(panToken: recordings.token) } }.disabled(cloud.busy)
                }
            }
        }
        .navigationTitle("设备管理")
        .toolbar { if device.busy { ProgressView() } else { Button("重新连接") { device.reconnect() } } }
        .onAppear { device.start() }
        .onDisappear { device.stop() }
        .confirmationDialog("解绑后需要重新靠近设备绑定，远程静音和录音备份会停止。", isPresented: $confirmLocal, titleVisibility: .visible) {
            Button("解绑此设备", role: .destructive) { Task { await device.unbindPan(token: recordings.token) } }
        }
        .confirmationDialog("只解除网盘账号上的绑定；设备下次上报后更新状态。", isPresented: $confirmRemote, titleVisibility: .visible) {
            Button("远程解绑", role: .destructive) { Task { await cloud.unbind(panToken: recordings.token) } }
        }
        .safeAreaInset(edge: .bottom) {
            Banner(text: [device.message, cloud.message, recordings.message].first { !$0.isEmpty } ?? "")
        }
    }
}

/// 发卡片：标题必填，标题加正文不超过固件上限，超出时实时提示。
struct CardSheet: View {
    @EnvironmentObject private var cloud: CloudStore
    @EnvironmentObject private var recordings: RecordingStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $title)
                TextField("正文（可选）", text: $text, axis: .vertical).lineLimit(4...10)
                Section {} footer: {
                    Text("\(title.utf8.count + text.utf8.count) / \(CloudStore.cardMax) 字节")
                        .foregroundStyle(title.utf8.count + text.utf8.count > CloudStore.cardMax ? .red : .secondary)
                    if !cloud.message.isEmpty { Text(cloud.message) }  // 发送失败时表单不关，原因显示在这里
                }
            }
            .navigationTitle("发送卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        Task {
                            if await cloud.sendCard(title: title, body: text, panToken: recordings.token) { dismiss() }
                        }
                    }.disabled(cloud.busy || !CloudStore.cardFits(title: title, body: text))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
