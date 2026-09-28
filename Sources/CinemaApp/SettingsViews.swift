import SwiftUI
import CinemaCore

struct QualityStudio: View {
    @ObservedObject var playback: PlaybackController
    @LegacyState private var hoveredMode: EnhancementMode?
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("保留质感，按需调整。").font(.system(size: 30, weight: .medium, design: .serif))
            Text("优先使用清晰片源。画面处理在这台 Mac 上进行，播放时可随时与原片对照。").font(.system(size: 13)).foregroundStyle(CinemaStyle.secondary)
            ForEach(EnhancementMode.allCases) { mode in
                Button { playback.selectEnhancementMode(mode) } label: {
                    CinemaCard {
                        HStack(spacing: 22) {
                            Image(systemName: icon(mode)).font(.system(size: 26, weight: .light)).frame(width: 40)
                                .foregroundStyle(playback.selectedPictureMode == mode ? CinemaStyle.accent : CinemaStyle.secondary)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(mode.title).font(.system(size: 17, weight: .medium))
                                Text(mode.detail).font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
                            }
                            Spacer()
                            Image(systemName: playback.selectedPictureMode == mode ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(playback.selectedPictureMode == mode ? CinemaStyle.accent : CinemaStyle.secondary)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radius, style: .continuous)
                        .fill(playback.selectedPictureMode == mode ? CinemaStyle.accentSoft : (hoveredMode == mode ? CinemaStyle.panelHover : Color.clear)))
                    .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radius, style: .continuous)
                        .strokeBorder(playback.selectedPictureMode == mode ? CinemaStyle.accent.opacity(0.45) : CinemaStyle.border, lineWidth: playback.selectedPictureMode == mode ? 1.5 : 1))
                }.buttonStyle(.plain)
                    .animation(CinemaStyle.quick, value: hoveredMode)
                    .animation(CinemaStyle.quick, value: playback.selectedPictureMode)
                    .onHover { hoveredMode = $0 ? mode : nil }
                    .accessibilityLabel("\(mode.title)，\(playback.selectedPictureMode == mode ? "已选择" : "未选择")")
            }
            if playback.player.currentItem != nil {
                CinemaCard(title: "当前播放", icon: playback.pictureIsEnhanced ? "sparkles" : "film") {
                    Text(playback.pictureStatusTitle).font(.system(size: 13, weight: .medium))
                    Text(playback.pictureStatusDetail).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                    Button(playback.isComparingOriginal ? "结束对照，恢复所选模式" : "临时查看原片") {
                        playback.toggleOriginalComparison()
                    }.disabled(!playback.canCompareOriginal && !playback.isComparingOriginal)
                }
            }
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "info.circle").foregroundStyle(CinemaStyle.accent)
                Text("自然降噪用于减轻噪点；4K 缩放改变输出尺寸，无法保证补回原片缺失的细节。Apple AI 的输出取决于系统、设备和片源。杜比视界与 HDR 保持原生呈现，处理跟不上时也会回到原片，播放页会显示实际状态。").font(.system(size: 12)).lineSpacing(6).foregroundStyle(CinemaStyle.secondary)
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
    @LegacyState private var hoveredProvider: String?
    init(app: AppModel) { self.app = app; self.access = app.sourceAccess }
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            Text("每个故事，都有来处。").font(.system(size: 30, weight: .medium, design: .serif))
            Text("应用会检索已启用的来源，读取真实线路与集数。你可以添加兼容的公开 CMS JSON 接口。").font(.system(size: 13)).foregroundStyle(CinemaStyle.secondary)
            CinemaCard(title: "连接与优先来源", icon: "network", trailing: AnyView(
                Picker("优先尝试", selection: $app.preferredProviderID) {
                    Text("按结果顺序").tag("")
                    ForEach(app.providers) { provider in Text(provider.name + (provider.enabled ? "" : "（已停用）")).tag(provider.id) }
                }.frame(maxWidth: 300)
            )) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("打开作品时优先选择此来源；手动筛选和详情中的选择优先，已停用的来源不会使用。").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                    Text("魔都的《怪奇物语第一季》清单与首分片已取得大陆三家运营商节点响应（2026-09-27），仍需以你的实际连接为准。").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(CinemaStyle.border)
                    Label(access.networkNotice, systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("媒体检测依次读取代表影片的目录、播放清单和首段数据；不解码、不代表整集稳定，也不改变播放器的网络路由。").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
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
                CinemaCard {
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
                            Text("目录查询：" + health).font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary).lineLimit(2)
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radius, style: .continuous)
                    .fill(hoveredProvider == provider.id && app.preferredProviderID != provider.id ? CinemaStyle.panelHover : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: CinemaStyle.radius, style: .continuous)
                    .strokeBorder(app.preferredProviderID == provider.id ? CinemaStyle.accent.opacity(0.45) : CinemaStyle.border, lineWidth: app.preferredProviderID == provider.id ? 1.5 : 1))
                .animation(CinemaStyle.quick, value: hoveredProvider)
                .onHover { hoveredProvider = $0 ? provider.id : nil }
            }
            CinemaCard(title: "添加来源") {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("来源名称", text: $name).textFieldStyle(.roundedBorder)
                    TextField("https://…/api.php/provide/vod", text: $endpoint).textFieldStyle(.roundedBorder)
                    HStack { Text("仅读取公开目录，不读取浏览器登录信息。").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary); Spacer(); Button("添加接口") { app.addProvider(name: name, endpoint: endpoint); if app.message == nil { name = ""; endpoint = "" } }.buttonStyle(.borderedProminent).disabled(endpoint.isEmpty) }
                }
            }
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
                Text(report.checkedAt, style: .time).font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary)
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
            .font(.system(size: 11)).foregroundStyle(reached ? CinemaStyle.positive : CinemaStyle.secondary)
    }
}
