import SwiftUI
import CinemaCore

struct QualityStudio: View {
    @ObservedObject var playback: PlaybackController
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("让好画面，更舒服").font(.system(size: 29, weight: .bold))
                Text("按影片选择清晰度与流畅度，找到适合这台 Mac 的观影方式。")
                    .font(.system(size: 13)).foregroundStyle(CinemaStyle.secondary)
            }
            QualityControlPanel(playback: playback, performance: playback.performance, allows60FPS: playback.supportsFrameInterpolation)
        }.frame(maxWidth: 1020, alignment: .leading)
    }
}

struct SourcesView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var access: SourceAccessController
    @LegacyState private var name = ""
    @LegacyState private var endpoint = ""
    @LegacyState private var showAdd = false
    init(app: AppModel) { self.app = app; self.access = app.sourceAccess }
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("管理你的片源").font(.system(size: 29, weight: .bold))
                    Text("搜索会同时查找已开启的来源。连接不佳时，可以随时切换。")
                        .font(.system(size: 13)).foregroundStyle(CinemaStyle.secondary)
                }
                Spacer()
                Button { withAnimation(CinemaStyle.standard) { showAdd.toggle() } } label: {
                    Label("添加来源", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16).frame(height: 38)
                        .background(CinemaStyle.accent, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 21)).foregroundStyle(CinemaStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(app.enabledProviderCount) 个来源已开启").font(.system(size: 14, weight: .semibold))
                    Text("优先来源会在打开影片时率先尝试").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                }
                Spacer()
                Menu {
                    Button("按搜索结果顺序") { app.preferredProviderID = "" }
                    ForEach(app.providers.filter(\.enabled)) { provider in
                        Button { app.preferredProviderID = provider.id } label: {
                            if app.preferredProviderID == provider.id { Label(provider.name, systemImage: "checkmark") }
                            else { Text(provider.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(app.providers.first(where: { $0.id == app.preferredProviderID })?.name ?? "自动选择")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.font(.system(size: 12)).padding(.horizontal, 13).frame(height: 36)
                        .background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                }.menuStyle(.borderlessButton).fixedSize()
            }.padding(19).background(CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: 12))
            if showAdd { addSource }
            VStack(spacing: 0) {
                HStack {
                    Text("全部来源").font(.system(size: 15, weight: .semibold))
                    Text("\(app.providers.count)").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                    Spacer()
                    if !access.pending.isEmpty {
                        ProgressView().controlSize(.small)
                        Button("停止检查") { access.cancelAll() }.buttonStyle(.plain).foregroundStyle(CinemaStyle.secondary)
                    } else {
                        Button { access.check(app.providers.filter(\.enabled)) } label: { Label("检查连接", systemImage: "arrow.clockwise") }
                            .buttonStyle(.plain).foregroundStyle(CinemaStyle.secondary).disabled(app.enabledProviderCount == 0)
                    }
                }.font(.system(size: 12)).padding(.bottom, 18)
                ForEach(app.providers) { provider in
                    sourceRow(provider)
                    if provider.id != app.providers.last?.id { Rectangle().fill(CinemaStyle.border).frame(height: 1) }
                }
            }
            HStack(spacing: 18) {
                Button("恢复内置来源") { app.restoreBuiltinProviders() }
                Button("刷新探索") { app.discover() }
                Spacer()
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text(access.networkNotice)
                    Text("连接检查会读取一个影片的播放信息与少量媒体数据，不能保证每部影片都能播放。中国大陆网络的可用性以你当前的实际连接为准。")
                }.font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).padding(.top, 8)
            } label: { Text("关于来源与网络").font(.system(size: 11)).foregroundStyle(CinemaStyle.tertiary) }
        }.frame(maxWidth: 1060, alignment: .leading).onAppear { access.refreshNetworkNotice() }
    }
    private func sourceRow(_ provider: SourceProvider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(provider.enabled ? CinemaStyle.accentSoft : CinemaStyle.panel)
                    Text(String(provider.name.prefix(1))).font(.system(size: 19, weight: .semibold)).foregroundStyle(provider.enabled ? CinemaStyle.accent : CinemaStyle.secondary)
                }.frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(provider.name).font(.system(size: 14, weight: .semibold))
                        if app.preferredProviderID == provider.id { Text("优先").font(.system(size: 9, weight: .semibold)).foregroundStyle(CinemaStyle.accent).padding(.horizontal, 6).padding(.vertical, 3).background(CinemaStyle.accentSoft, in: Capsule()) }
                    }
                    Text(provider.endpoint.host ?? "自定义来源").font(.system(size: 11)).foregroundStyle(CinemaStyle.tertiary)
                }
                Spacer()
                connectionStatus(provider)
                Toggle("启用 \(provider.name)", isOn: Binding(get: { provider.enabled }, set: { app.updateProvider(provider.id, enabled: $0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                Menu {
                    Button("设为优先来源") { app.preferredProviderID = provider.id }
                    Button("检查播放连接") { access.check([provider]) }.disabled(access.pending.contains(provider.id))
                    Button("刷新影片目录") { app.checkProvider(provider) }.disabled(app.checkingProviders.contains(provider.id) || app.checkingProviders.count >= 3)
                    Divider()
                    Button("移除来源", role: .destructive) { app.removeProvider(provider.id) }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 36).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).fixedSize().help("来源操作")
            }
            if access.reports[provider.id] != nil || app.sourceHealth[provider.id] != nil {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        if let report = access.reports[provider.id] {
                            Text(report.passed ? "已成功读取一个影片的播放数据；其他影片的可用性以实际播放为准。" : "暂未确认可播放，建议尝试其他来源。")
                            if let failure = report.failure { Text(failure).textSelection(.enabled) }
                            Text("上次检查：" + report.checkedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let health = app.sourceHealth[provider.id] { Text(health) }
                    }.font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).padding(.top, 5)
                } label: { Text("连接详情").font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary) }.padding(.leading, 60)
            }
        }.padding(.vertical, 18)
    }
    @ViewBuilder private func connectionStatus(_ provider: SourceProvider) -> some View {
        if access.pending.contains(provider.id) {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("连接中") }.font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
        } else if let report = access.reports[provider.id] {
            Label(report.passed ? "连接正常" : "连接待恢复", systemImage: report.passed ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(report.passed ? CinemaStyle.positive : CinemaStyle.secondary)
        } else {
            Text(provider.enabled ? "已开启" : "已关闭").font(.system(size: 11)).foregroundStyle(CinemaStyle.tertiary)
        }
    }
    private var addSource: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加你的媒体来源").font(.system(size: 15, weight: .semibold))
            Text("支持公开的 CMS JSON 影片接口").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
            HStack(spacing: 12) {
                TextField("来源名称", text: $name).textFieldStyle(.plain).padding(12).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 8)).frame(width: 170)
                TextField("https://…/api.php/provide/vod", text: $endpoint).textFieldStyle(.plain).padding(12).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                Button("添加") { app.addProvider(name: name, endpoint: endpoint); if app.message == nil { name = ""; endpoint = ""; showAdd = false } }
                    .buttonStyle(.borderedProminent).disabled(endpoint.isEmpty)
            }.font(.system(size: 12))
        }.padding(20).background(CinemaStyle.backgroundRaised, in: RoundedRectangle(cornerRadius: 12))
    }
}
