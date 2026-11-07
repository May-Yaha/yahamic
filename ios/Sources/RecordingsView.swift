import SwiftUI

/// 网盘录音按天分组；点一下播放，再点停止。
struct RecordingsView: View {
    @EnvironmentObject private var recordings: RecordingStore

    var body: some View {
        Group {
            if !recordings.loggedIn {
                ContentUnavailableView {
                    Label("登录后查看录音", systemImage: "waveform")
                } description: {
                    Text("只读取网盘里 Mac 备份的录音，iPhone 不录音。")
                } actions: {
                    Button("登录百度网盘") { Task { await recordings.login() } }
                        .buttonStyle(.borderedProminent).disabled(recordings.busy)
                }
            } else if recordings.items.isEmpty && !recordings.busy {
                ContentUnavailableView("暂无录音", systemImage: "waveform", description: Text("Mac 上按讲话键说话后会自动备份到网盘。"))
            } else {
                List {
                    ForEach(Self.days(recordings.items), id: \.day) { group in
                        Section(group.day.formatted(.dateTime.month().day().weekday())) {
                            ForEach(group.items) { item in row(item) }
                        }
                    }
                }
            }
        }
        .navigationTitle("录音")
        .refreshable { await recordings.refresh() }
        .task { if recordings.loggedIn && recordings.items.isEmpty { await recordings.refresh() } }
        .safeAreaInset(edge: .bottom) { Banner(text: recordings.message) }
    }

    private func row(_ item: PanFiles.Item) -> some View {
        let playing = recordings.playingID == item.id
        return Button { Task { await recordings.play(item) } } label: {
            HStack(spacing: 12) {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill").font(.title2).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(item.mtime.formatted(date: .omitted, time: .shortened)).foregroundStyle(.primary)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .disabled(recordings.busy && !playing)
        .accessibilityLabel((playing ? "停止 " : "播放 ") + item.mtime.formatted(date: .omitted, time: .shortened))
    }

    /// 按本地日期分组，组与组内都新的在前。
    nonisolated static func days(_ items: [PanFiles.Item], calendar: Calendar = .current) -> [(day: Date, items: [PanFiles.Item])] {
        Dictionary(grouping: items) { calendar.startOfDay(for: $0.mtime) }
            .map { (day: $0.key, items: $0.value.sorted { $0.mtime > $1.mtime }) }
            .sorted { $0.day > $1.day }
    }
}
