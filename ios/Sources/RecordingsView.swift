import SwiftUI

/// 网盘录音按天分组；点一下播放，再点暂停；确认过的听写文字显示在每条下面，底部是迷你播放条。
/// 每天的标题右侧「AI 总结」把当天的文字整理成工作总结。
struct RecordingsView: View {
    @EnvironmentObject private var recordings: RecordingStore
    @State private var summaryDay: Date?

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
                    ForEach(PanFiles.days(recordings.items), id: \.day) { group in
                        Section {
                            ForEach(group.items) { take in TakeRow(take: take, player: recordings.player) }
                        } header: {
                            HStack {
                                Text(Calendar.current.isDateInToday(group.day) ? "今天" : group.day.formatted(.dateTime.month().day().weekday()))
                                Spacer()
                                Button { summaryDay = group.day } label: { Label("AI 总结", systemImage: "sparkles") }
                                    .buttonStyle(.borderless).textCase(nil)
                                    .disabled(!group.items.contains { $0.transcript != nil || recordings.player.texts[$0.id] != nil })
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("录音")
        .sheet(isPresented: Binding(get: { summaryDay != nil }, set: { if !$0 { summaryDay = nil } })) {
            if let day = summaryDay {
                DaySummarySheet(day: day, takes: PanFiles.days(recordings.items).first { $0.day == day }?.items ?? [])
            }
        }
        .refreshable { await recordings.refresh() }
        .task { if recordings.loggedIn && recordings.items.isEmpty { await recordings.refresh() } }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                MiniPlayerBar(player: recordings.player)
                Banner(text: recordings.message)
            }
        }
    }
}

