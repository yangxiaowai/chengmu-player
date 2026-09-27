import SwiftUI

struct PlayerCommandContext {
    let playing: Bool
    let canSeek: Bool
    let canPrevious: Bool
    let canNext: Bool
    let fullscreen: Bool
    let episodesShown: Bool
    let togglePlayback: () -> Void
    let skip: (Double) -> Void
    let jumpToTime: () -> Void
    let previous: () -> Void
    let next: () -> Void
    let toggleFullscreen: () -> Void
    let toggleEpisodes: () -> Void
    let showShortcuts: () -> Void
}

private struct PlayerCommandKey: FocusedValueKey { typealias Value = PlayerCommandContext }
extension FocusedValues {
    var playerCommands: PlayerCommandContext? {
        get { self[PlayerCommandKey.self] }
        set { self[PlayerCommandKey.self] = newValue }
    }
}

struct PlaybackCommands: Commands {
    @FocusedValue(\.playerCommands) private var player
    var body: some Commands {
        CommandMenu("播放") {
            Button(player?.playing == true ? "暂停" : "播放") { player?.togglePlayback() }
                .keyboardShortcut("p", modifiers: .command).disabled(player == nil)
            Divider()
            Button("快退 10 秒") { player?.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(player?.canSeek != true)
            Button("快进 10 秒") { player?.skip(10) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(player?.canSeek != true)
            Button("跳转到时间…") { player?.jumpToTime() }.keyboardShortcut("j", modifiers: .command).disabled(player?.canSeek != true)
            Divider()
            Button("上一集") { player?.previous() }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(player?.canPrevious != true)
            Button("下一集") { player?.next() }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(player?.canNext != true)
            Divider()
            Button(player?.fullscreen == true ? "退出全屏" : "进入全屏") { player?.toggleFullscreen() }.disabled(player == nil)
            Button(player?.episodesShown == true ? "隐藏选集" : "显示选集") { player?.toggleEpisodes() }.disabled(player == nil)
            Divider()
            Button("播放快捷键…") { player?.showShortcuts() }.disabled(player == nil)
        }
    }
}
