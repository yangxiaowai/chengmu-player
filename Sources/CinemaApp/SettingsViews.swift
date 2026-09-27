import SwiftUI
import CinemaCore

struct QualityStudio: View {
    @ObservedObject var playback: PlaybackController
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("让每一帧，更值得看。").font(.system(size: 30, weight: .medium, design: .serif))
            Text("先选择更好的片源，再为当前画面增强。所有处理都在这台 Mac 上进行。").font(.system(size: 13)).foregroundStyle(CinemaStyle.secondary)
            ForEach(EnhancementMode.allCases) { mode in
                Button { playback.enhancementMode = mode } label: {
                    HStack(spacing: 22) {
                        Image(systemName: icon(mode)).font(.system(size: 26, weight: .light)).frame(width: 40).foregroundStyle(playback.enhancementMode == mode ? CinemaStyle.accent : CinemaStyle.secondary)
                        VStack(alignment: .leading, spacing: 8) { Text(mode.title).font(.system(size: 17, weight: .medium)); Text(mode.detail).font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary) }
                        Spacer(); Image(systemName: playback.enhancementMode == mode ? "checkmark.circle.fill" : "circle").foregroundStyle(playback.enhancementMode == mode ? CinemaStyle.accent : CinemaStyle.secondary)
                    }.padding(24).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(playback.enhancementMode == mode ? CinemaStyle.accent.opacity(0.45) : CinemaStyle.border))
                }.buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "info.circle").foregroundStyle(CinemaStyle.accent)
                Text("GPU 增强至 4K 使用去噪、等比例缩放和锐化。Apple AI 是否可用取决于输入尺寸与设备；本机目前可处理720p→1080p。播放页会显示实际模式，处理跟不上时回到原片，保持流畅。").font(.system(size: 12)).lineSpacing(6).foregroundStyle(CinemaStyle.secondary)
            }.padding(.top, 8)
        }
    }
    private func icon(_ mode: EnhancementMode) -> String {
        switch mode { case .original: return "film"; case .clarity: return "viewfinder"; case .upscale4K: return "4k.tv"; case .appleAI: return "sparkles" }
    }
}

struct SourcesView: View {
    @ObservedObject var app: AppModel
    @LegacyState private var name = ""
    @LegacyState private var endpoint = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            Text("每个故事，都有来处。").font(.system(size: 30, weight: .medium, design: .serif))
            Text("应用会检索已启用的来源，读取真实线路与集数。你可以添加兼容的公开 CMS JSON 接口。").font(.system(size: 13)).foregroundStyle(CinemaStyle.secondary)
            ForEach(app.providers) { provider in
                HStack(spacing: 18) {
                    Image(systemName: "network").font(.system(size: 25, weight: .light)).foregroundStyle(CinemaStyle.accent)
                    VStack(alignment: .leading, spacing: 7) { Text(provider.name).font(.system(size: 15, weight: .medium)); Text(provider.endpoint.absoluteString).font(.system(size: 11, design: .monospaced)).foregroundStyle(CinemaStyle.secondary).textSelection(.enabled) }
                    Spacer()
                    Toggle("启用", isOn: Binding(get: {provider.enabled}, set: {app.updateProvider(provider.id, enabled: $0)})).toggleStyle(.switch).labelsHidden()
                    Button { app.removeProvider(provider.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(CinemaStyle.secondary).help("移除此来源")
                }.padding(22).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("添加来源").font(.system(size: 17, weight: .semibold))
                TextField("来源名称", text: $name).textFieldStyle(.roundedBorder)
                TextField("https://…/api.php/provide/vod", text: $endpoint).textFieldStyle(.roundedBorder)
                HStack { Text("仅读取公开目录，不读取浏览器登录信息。").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary); Spacer(); Button("添加接口") { app.addProvider(name: name, endpoint: endpoint); if app.message == nil { name = ""; endpoint = "" } }.buttonStyle(.borderedProminent).disabled(endpoint.isEmpty) }
            }.padding(24).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            Button { app.discover() } label: { Label("重新检索我的三部剧", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
        }
    }
}
