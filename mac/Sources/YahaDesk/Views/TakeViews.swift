import SwiftUI

// Mac 设置窗口与 iPhone 录音页共用:录音行(带确认过的文字)和底部迷你播放条。

/// 录音行:点一下播放、再点暂停;随录音保存的听写文字显示在下面,正在播放的那条展开全文。
struct TakeRow: View {
    let take: PanFiles.Take
    @ObservedObject var player: TakePlayer
    var showsDate = false

    var body: some View {
        let current = player.current?.id == take.id
        Button { Task { await player.play(take) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: current && player.playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2).foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(take.mtime.formatted(date: showsDate ? .abbreviated : .omitted, time: .shortened))
                            .font(current ? .body.weight(.semibold) : .body)
                            .foregroundStyle(current ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        Spacer()
                        if current && player.loading { ProgressView().controlSize(.small) }
                        if current && player.playing {
                            Image(systemName: "waveform").foregroundStyle(.tint)
                                .symbolEffect(.variableColor.iterative, isActive: true)
                                .accessibilityHidden(true)
                        }
                        Text(ByteCountFormatter.string(fromByteCount: Int64(take.size), countStyle: .file))
                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let text = player.texts[take.id] {
                        Text(text).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(current ? nil : 2).multilineTextAlignment(.leading)
                    } else if take.transcript != nil {
                        Text("正在读取文字…").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // ponytail: 每条文字单独下载一次,列表懒加载只取看得见的;条数多了再改成批量 filemetas。
        .task(id: take.id) { await player.loadText(take) }
        .accessibilityLabel((current && player.playing ? "暂停 " : "播放 ")
            + take.mtime.formatted(date: .omitted, time: .shortened) + (player.texts[take.id].map { "，\($0)" } ?? ""))
    }
}

/// 底部迷你播放条(同播客 App):当前录音、文字摘要、播放/暂停、进度拖动、关闭。没在播时只显示播放失败原因,都没有就不占位。
struct MiniPlayerBar: View {
    @ObservedObject var player: TakePlayer

    var body: some View {
        VStack(spacing: 0) {
            if let take = player.current { bar(take) }
            else if !player.message.isEmpty {
                Text(player.message).font(.footnote).foregroundStyle(.orange).padding(8)
            }
        }
        .animation(.snappy, value: player.current)
    }

    private func bar(_ take: PanFiles.Take) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.title3).foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: player.playing)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(take.mtime.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.semibold))
                    Text(player.texts[take.id] ?? "讲话录音").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: player.toggle) {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(player.playing ? "暂停" : "播放")
                }
                Button(action: player.stop) { Image(systemName: "xmark").font(.subheadline.weight(.semibold)) }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("关闭播放")
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(TakePlayer.clock(player.position))
                // 必须写成闭包:直接传 player.seek 会让 iOS 的 Swift 6.3 编译器在生成 thunk 时崩溃。
                Slider(value: Binding(get: { min(player.position, player.duration) }, set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 0.1))
                    .controlSize(.mini)
                    .disabled(player.duration == 0)
                    .accessibilityLabel("播放进度")
                Text(TakePlayer.clock(player.duration))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
