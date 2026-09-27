import SwiftUI
import CinemaCore

struct JumpToTimeDialog: View {
    let current: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @LegacyState private var input = ""
    @LegacyState private var notice: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("跳转到时间").font(.title2.bold())
            Text("当前 \(timeString(current)) · 总时长 \(timeString(duration))").foregroundStyle(CinemaStyle.secondary)
            TextField("例如 24:04 或 1:02:03", text: $input)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit { submit() }
                .accessibilityLabel("目标时间")
            Text(notice ?? "支持秒数、分:秒、时:分:秒。跳转后保持当前播放或暂停状态。")
                .font(.system(size: 12)).foregroundStyle(notice == nil ? CinemaStyle.secondary : CinemaStyle.accent)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("跳转") { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 430).background(CinemaStyle.background)
            .onAppear { input = timeString(current); focused = true }
    }
    private func submit() {
        do { let target = try PlaybackTimecode.seconds(from: input, duration: duration); onSeek(target); dismiss() }
        catch { notice = error.localizedDescription }
    }
}

struct PlaybackShortcutsDialog: View {
    @Environment(\.dismiss) private var dismiss
    private let shortcuts = [
        ("播放 / 暂停", "空格 或 ⌘P"), ("快退 / 快进 10 秒", "← / → 或 ⌥⌘← / ⌥⌘→"),
        ("精确跳转", "⌘J 或点击播放时间"), ("上一集 / 下一集", "⌘← / ⌘→"),
        ("调节音量", "↑ / ↓"), ("静音 / 恢复音量", "M"), ("全屏 / 退出全屏", "F / Esc 或双击画面")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("播放快捷键").font(.title2.bold())
            ForEach(shortcuts, id: \.0) { name, key in
                HStack { Text(name); Spacer(); Text(key).foregroundStyle(CinemaStyle.accent) }.font(.system(size: 12))
            }
            Text("单键快捷键在影片画面获得焦点时生效；输入框和滑块保留原生键盘操作。")
                .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 480).background(CinemaStyle.background)
    }
}
