import DeskProtocol
import SwiftUI

/// 换场景切 Wi-Fi：进页即连蓝牙并扫描，点网络即切；连上过的网络密码记在本机钥匙串，下次点一下就连。
struct WiFiView: View {
    @EnvironmentObject private var device: DeviceStore
    @EnvironmentObject private var cloud: CloudStore
    @State private var asking: WiFiNetwork?
    @State private var other = false
    @State private var ssid = ""
    @State private var password = ""
    @State private var joining: String?

    var body: some View {
        List {
            if !device.ready {
                Section {
                    HStack(spacing: 12) { ProgressView(); Text("正在连接设备…") }
                } footer: { Text("设备蓝牙同一时间只连一台。连不上时，在 Mac 菜单栏的 Yaha Desk 里点“暂时断开”；切完回到 Mac 点“恢复连接”。") }
            }
            Section {
                ForEach(device.networks, id: \.ssid) { network in
                    row(network.ssid, secure: network.secure, rssi: network.rssi) { tap(network) }
                }
                Button("其他网络…") { ssid = ""; password = ""; other = true }.disabled(!device.ready || device.busy)
            } header: { Text("附近网络") } footer: {
                if device.ready && device.networks.isEmpty && !device.busy { Text("下拉重新扫描。设备只能连 2.4 GHz 网络。") }
            }
            let away = device.saved.keys.filter { name in !device.networks.contains { $0.ssid == name } }.sorted()
            if !away.isEmpty {
                Section("已保存（不在附近）") {
                    ForEach(away, id: \.self) { name in
                        row(name, secure: !(device.saved[name] ?? "").isEmpty, rssi: nil) {
                            join(WiFiNetwork(ssid: name, rssi: 0, secure: !(device.saved[name] ?? "").isEmpty), device.saved[name] ?? "")
                        }
                    }
                }
            }
        }
        .navigationTitle("切换 Wi-Fi")
        .refreshable { await device.scanWiFi() }
        .toolbar { if device.busy { ProgressView() } }
        .onAppear { device.start(); if device.ready { scan() } }
        .onDisappear { device.stop() }
        .onChange(of: device.ready) { _, ready in if ready { scan() } }
        .alert("输入“\(asking?.ssid ?? "")”的密码", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            SecureField("密码", text: $password)
            Button("加入") { if let network = asking { join(network, password) } }.disabled(password.count < 8)
            Button("取消", role: .cancel) {}
        }
        .alert("加入其他网络", isPresented: $other) {
            TextField("网络名称", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("密码（开放网络留空）", text: $password)
            Button("加入") { join(WiFiNetwork(ssid: ssid, rssi: 0, secure: !password.isEmpty), password) }.disabled(ssid.isEmpty)
            Button("取消", role: .cancel) {}
        }
        .safeAreaInset(edge: .bottom) { Banner(text: device.message) }
    }

    private func row(_ name: String, secure: Bool, rssi: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").foregroundStyle(.tint).opacity(current == name ? 1 : 0).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary)
                    if device.saved[name] != nil { Text("已保存").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if joining == name { ProgressView() }
                if secure { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                if let rssi { Image(systemName: "wifi", variableValue: Self.strength(rssi)).foregroundStyle(.secondary) }
            }
        }
        .disabled(!device.ready || device.busy)
        .accessibilityLabel(current == name ? "\(name)，当前网络" : name)
        .swipeActions {
            if device.saved[name] != nil { Button("忽略", role: .destructive) { device.forget(name) } }
        }
    }

    private var current: String? {
        Self.current(connected: device.cloud.wifiConnected, joined: device.joined, reported: cloud.status?.ssid)
    }

    /// 设备当前连着的网络：本页刚切过的优先（切换开始或失败即清空），否则用最近一次云端上报。
    nonisolated static func current(connected: Bool, joined: String?, reported: String?) -> String? {
        connected ? joined ?? reported : nil
    }

    private func tap(_ network: WiFiNetwork) {
        // 只拦本页刚连上的网络；云端上报最多晚一分钟，不能拿它挡住用户切回去。
        if network.ssid == device.joined { device.message = "设备已连着“\(network.ssid)”"; return }
        if let known = DeviceStore.knownPassword(for: network, saved: device.saved) { join(network, known); return }
        password = ""
        asking = network
    }

    /// 用已存密码连失败且设备报密码错误时，改问密码，不让旧密码反复重试。
    private func join(_ network: WiFiNetwork, _ secret: String) {
        joining = network.ssid
        Task {
            let ok = await device.joinWiFi(ssid: network.ssid, password: secret)
            joining = nil
            if !ok, network.secure, DeviceStore.wrongPassword(reason: device.cloud.wifiReason) {
                password = ""
                asking = network
            }
        }
    }

    private func scan() { Task { await device.scanWiFi() } }

    /// 信号格：-90 dBm 及以下一格，-50 dBm 及以上满格。
    nonisolated static func strength(_ rssi: Int) -> Double { min(1, max(0.2, Double(rssi + 90) / 40)) }
}
