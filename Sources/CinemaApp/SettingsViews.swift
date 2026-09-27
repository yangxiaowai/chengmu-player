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
    @ObservedObject var access: SourceAccessController
    @LegacyState private var name = ""
    @LegacyState private var endpoint = ""
    init(app: AppModel) { self.app = app; self.access = app.sourceAccess }
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            Text("每个故事，都有来处。").font(.system(size: 30, weight: .medium, design: .serif))
            Text("应用会检索已启用的来源，读取真实线路与集数。你可以添加兼容的公开 CMS JSON 接口。").font(.system(size: 13)).foregroundStyle(CinemaStyle.secondary)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Label("连接与优先来源", systemImage: "network").font(.system(size: 15, weight: .medium))
                    Spacer()
                    Picker("优先尝试", selection: $app.preferredProviderID) {
                        Text("按结果顺序").tag("")
                        ForEach(app.providers) { provider in Text(provider.name + (provider.enabled ? "" : "（已停用）")).tag(provider.id) }
                    }.frame(maxWidth: 300)
                }
                Text("打开作品时优先选择此来源；手动筛选和详情中的选择优先，已停用的来源不会使用。").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                Text("魔都的《怪奇物语第一季》清单与首分片已取得大陆三家运营商节点响应（2026-09-27），仍需以你的实际连接为准。").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true)
                Divider().overlay(CinemaStyle.border)
                Label(access.networkNotice, systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true)
                Text("媒体检测依次读取代表影片的目录、播放清单和首段数据；不解码、不代表整集稳定，也不改变播放器的网络路由。").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(22).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("\(app.enabledProviderCount) 个已启用 / \(app.providers.count) 个来源").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
                Spacer()
                if !access.pending.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("剩余 \(access.pending.count)").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                    Button("取消检测") { access.cancelAll() }
                }
                Button("检测全部媒体") { access.check(app.providers.filter(\.enabled)) }
                    .disabled(!access.pending.isEmpty || app.enabledProviderCount == 0)
                Button("补全内置来源") { app.restoreBuiltinProviders() }
            }.buttonStyle(.bordered)
            ForEach(app.providers) { provider in
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 16) {
                        Image(systemName: "network").font(.system(size: 25, weight: .light)).foregroundStyle(CinemaStyle.accent)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text(provider.name).font(.system(size: 15, weight: .medium))
                                if app.preferredProviderID == provider.id { Text("优先").font(.system(size: 10)).foregroundStyle(CinemaStyle.accent) }
                            }
                            Text(provider.endpoint.host ?? "来源接口").font(.system(size: 11, design: .monospaced)).foregroundStyle(CinemaStyle.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("查目录") { app.checkProvider(provider) }
                            .disabled(app.checkingProviders.contains(provider.id) || app.checkingProviders.count >= 3)
                        Button(access.pending.contains(provider.id) ? (access.running.contains(provider.id) ? "检测中…" : "排队中…") : "检测媒体") { access.check([provider]) }
                            .disabled(access.pending.contains(provider.id))
                        Toggle("启用", isOn: Binding(get: {provider.enabled}, set: {app.updateProvider(provider.id, enabled: $0)})).toggleStyle(.switch).labelsHidden()
                        Button { app.removeProvider(provider.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(CinemaStyle.secondary).help("移除此来源")
                    }.buttonStyle(.bordered)
                    if let report = access.reports[provider.id] { accessResult(report) }
                    else {
                        Text(access.pending.contains(provider.id) ? "正在检查代表影片的连接，可随时取消。" : "尚未进行媒体检测")
                            .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                    }
                    if let health = app.sourceHealth[provider.id] {
                        Text("目录查询：" + health).font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary).lineLimit(2)
                    }
                }.padding(22).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("添加来源").font(.system(size: 17, weight: .semibold))
                TextField("来源名称", text: $name).textFieldStyle(.roundedBorder)
                TextField("https://…/api.php/provide/vod", text: $endpoint).textFieldStyle(.roundedBorder)
                HStack { Text("仅读取公开目录，不读取浏览器登录信息。").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary); Spacer(); Button("添加接口") { app.addProvider(name: name, endpoint: endpoint); if app.message == nil { name = ""; endpoint = "" } }.buttonStyle(.borderedProminent).disabled(endpoint.isEmpty) }
            }.padding(24).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            Button { app.discover() } label: { Label("刷新发现页", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
        }.onAppear { access.refreshNetworkNotice() }
    }
    private func accessResult(_ report: SourceAccessReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                phase("目录", reached: report.catalogReachable)
                phase("清单", reached: report.playlistReachable)
                phase("分片", reached: report.segmentReachable)
                Spacer()
                Text(report.checkedAt, style: .time).font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
            }
            if let sample = report.sampleTitle {
                Text("样本《\(sample)》 · \(report.elapsedMS) ms" + (report.sampleBytes > 0 ? " · 已读取 \(report.sampleBytes / 1024) KiB 前缀" : ""))
                    .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
            }
            if let failure = report.failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(CinemaStyle.accent).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if report.passed {
                Text("本次样本可读取 · 大陆直连尚未单独确认").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
            }
        }
    }
    private func phase(_ name: String, reached: Bool) -> some View {
        Label(name + (reached ? "已读取" : "待确认"), systemImage: reached ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 11)).foregroundStyle(reached ? Color.green.opacity(0.85) : CinemaStyle.secondary)
    }
}
