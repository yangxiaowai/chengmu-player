import SwiftUI
import CinemaCore

// CLT ships the property wrapper but may omit the new SwiftUI State macro plugin.
typealias LegacyState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @ObservedObject var app: AppModel
    @LegacyState private var showLink = false
    @LegacyState private var link = ""
    var body: some View {
        Group {
            if app.showPlayer { PlayerView(app: app, playback: app.playback) }
            else {
                HStack(spacing: 0) {
                    sidebar
                    Divider().overlay(CinemaStyle.border)
                    VStack(spacing: 0) {
                        topbar
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                switch app.section {
                                case .discover: DiscoveryView(app: app)
                                case .watchlist: WatchlistView(app: app)
                                case .history: HistoryView(app: app)
                                case .quality: QualityStudio(playback: app.playback)
                                case .sources: SourcesView(app: app)
                                }
                            }.padding(32)
                        }
                    }
                }
            }
        }
        .background(CinemaStyle.background)
        .foregroundStyle(Color.white.opacity(0.93))
        .tint(CinemaStyle.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1040, minHeight: 680)
        .sheet(isPresented: Binding(get: { !app.showPlayer && app.detailPresented }, set: { if !$0 && !app.showPlayer { app.dismissDetail() } })) {
            DetailView(app: app).frame(width: 850, height: 650)
        }
        .sheet(isPresented: $showLink) {
            VStack(alignment: .leading, spacing: 20) {
                Text("打开网络影片").font(.title2.bold())
                Text("粘贴可直接播放的 HLS、MP4 等媒体链接。").foregroundStyle(.secondary)
                TextField("https://…", text: $link).textFieldStyle(.roundedBorder).frame(width: 480)
                HStack { Button("取消") { showLink = false }; Spacer(); Button("打开播放") { if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) { app.openURL(url); showLink = false } else { app.message = "链接格式不正确。" } }.buttonStyle(.borderedProminent) }
            }.padding(28)
        }
        .alert("澄幕", isPresented: Binding(get: {app.message != nil}, set: {if !$0 {app.message = nil}})) { Button("知道了") { app.message = nil } } message: { Text(app.message ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(CinemaStyle.accentSoft)
                    Image(systemName: "play.rectangle.fill").font(.system(size: 17, weight: .regular)).foregroundStyle(CinemaStyle.accent)
                }.frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("澄幕").font(.system(size: 21, weight: .semibold, design: .serif))
                    Text("C H E N G M U").font(.system(size: 7.5, weight: .medium)).tracking(1.4).foregroundStyle(CinemaStyle.tertiary)
                }
            }.padding(.top, 30).padding(.bottom, 34).padding(.horizontal, 20)
            Text("你的放映室").font(.system(size: 9.5, weight: .semibold)).tracking(1.1).foregroundStyle(CinemaStyle.tertiary).padding(.horizontal, 24).padding(.bottom, 11)
            ForEach(AppSection.allCases) { section in
                SidebarButton(title: section.rawValue, icon: section.icon, selected: app.section == section) {
                    app.section = section
                }.padding(.horizontal, 10).padding(.bottom, 3)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 3) {
                SidebarButton(title: "打开本地影片", icon: "folder.badge.plus", isNavigation: false) { app.importFile() }
                SidebarButton(title: "打开网络链接", icon: "link", isNavigation: false) { showLink = true }
            }.padding(.horizontal, 10).padding(.bottom, 14)
            Rectangle().fill(CinemaStyle.border).frame(height: 1).padding(.horizontal, 20)
            HStack(spacing: 8) {
                ZStack { Circle().fill(CinemaStyle.accent.opacity(0.18)).frame(width: 14, height: 14); Circle().fill(CinemaStyle.accent).frame(width: 5, height: 5) }
                Text("\(app.enabledProviderCount) 个检索来源已启用").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
            }.padding(.horizontal, 22).padding(.vertical, 18)
        }.frame(width: 204)
        .background(LinearGradient(colors: [Color.black.opacity(0.28), Color.black.opacity(0.12)], startPoint: .top, endPoint: .bottom))
    }
    private var topbar: some View {
        HStack(spacing: 18) {
            Text(app.section.rawValue).font(.system(size: 13, weight: .medium)).foregroundStyle(CinemaStyle.secondary)
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(app.query.isEmpty ? CinemaStyle.tertiary : CinemaStyle.accent)
                TextField("搜索电影、剧集…", text: $app.query).textFieldStyle(.plain).onSubmit { app.search() }.frame(width: 245).accessibilityIdentifier("searchField")
                if app.searching { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 12)).padding(.horizontal, 15).padding(.vertical, 10)
            .background(CinemaStyle.backgroundRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(app.query.isEmpty ? CinemaStyle.border : CinemaStyle.accent.opacity(0.45), lineWidth: 1))
            .animation(CinemaStyle.quick, value: app.query.isEmpty)
            Button { app.search() } label: { Text("搜索").font(.system(size: 12, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 6) }
                .buttonStyle(.plain).foregroundStyle(CinemaStyle.accent).accessibilityIdentifier("searchButton")
                .disabled(app.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(app.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }.padding(.horizontal, CinemaStyle.gutter).padding(.vertical, 18)
    }

}

struct PosterView: View {
    let url: URL?
    let title: String
    /// Keeps the placeholder until the artwork has decoded, so a poster fades in instead of
    /// flashing an empty frame.
    @LegacyState private var loaded = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                placeholder
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.28))) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                            .opacity(loaded ? 1 : 0)
                            .onAppear { loaded = true }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onChange(of: url) { _, _ in loaded = false }
        }
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.21, blue: 0.24), CinemaStyle.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 16) {
                Image(systemName: "film").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(CinemaStyle.accent.opacity(0.55))
                Text(title).font(.system(size: 17, weight: .medium, design: .serif)).multilineTextAlignment(.center).padding(.horizontal, 18).lineLimit(3)
            }
        }
    }
}
struct MediaCard: View {
    let title: MediaTitle
    @LegacyState private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PosterView(url: title.posterURL, title: title.title)
                .aspectRatio(2.0 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(title.providerName).font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.black.opacity(0.66), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                        .padding(8)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: CinemaStyle.radiusSmall, style: .continuous)
                        .strokeBorder(hovering ? CinemaStyle.accent.opacity(0.85) : CinemaStyle.border, lineWidth: hovering ? 1.5 : 1)
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.28)
                            Image(systemName: "play.circle.fill").font(.system(size: 36)).foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 8)
                        }
                        .transition(.opacity)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.45 : 0.22), radius: hovering ? 14 : 7, y: hovering ? 7 : 3)
                .scaleEffect(hovering ? 1.012 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(title.year.isEmpty ? "查看集数与线路" : "\(title.year) · 查看集数与线路").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary).lineLimit(1)
            }
        }
        .animation(CinemaStyle.quick, value: hovering)
        .onHover { hovering = $0 }
    }
}
struct DetailView: View {
    @ObservedObject var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text("影片详情").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary); Spacer(); Button { app.dismissDetail() } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            if app.detailLoading { Spacer(); ProgressView("正在获取可播放线路…").frame(maxWidth: .infinity); Spacer() }
            else if let detail = app.detail {
                HStack(alignment: .top, spacing: 25) {
                    PosterView(url: detail.title.posterURL, title: detail.title.title).frame(width: 140, height: 205).clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 15) {
                        Text(detail.title.providerName.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(CinemaStyle.accent)
                        Text(detail.title.title).font(.system(size: 29, weight: .medium, design: .serif))
                        Text("\(detail.title.year)  ·  \(detail.lines.count) 条播放线路").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
                        Text(detail.title.summary).font(.system(size: 12)).lineSpacing(5).foregroundStyle(CinemaStyle.secondary).lineLimit(4)
                        HStack {
                            Button { app.continueDetail() } label: { Label(app.detailHasHistory ? "继续观看" : "开始观看", systemImage: "play.fill").padding(.horizontal, 10).padding(.vertical, 4) }.buttonStyle(.borderedProminent)
                            if let group = CatalogGrouping.groups([detail.title] + app.detailSources.filter { CatalogGrouping.normalizedTitle($0.title) == CatalogGrouping.normalizedTitle(detail.title.title) && ($0.year.isEmpty || detail.title.year.isEmpty || $0.year == detail.title.year) }).first {
                                Button { app.toggleSaved(group) } label: { Label(app.isSaved(group) ? "已在待看" : "加入待看", systemImage: app.isSaved(group) ? "bookmark.fill" : "bookmark") }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
                if app.detailSources.count > 1 {
                    HStack { Text("播放来源").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
                        Picker("播放来源", selection: Binding(get: { detail.title.providerID + ":" + detail.title.id }, set: { key in if let title = app.detailSources.first(where: { $0.providerID + ":" + $0.id == key }) { app.select(title) } })) {
                            ForEach(app.detailSources, id: \.self) { source in Text(source.providerName + (app.providers.contains(where: { $0.id == source.providerID && $0.enabled }) ? "" : " · 未启用")).tag(source.providerID + ":" + source.id).disabled(!app.providers.contains { $0.id == source.providerID && $0.enabled }) }
                        }.labelsHidden()
                    }
                }
                HStack { Text("选择集数").font(.system(size: 17, weight: .semibold)); Spacer(); Picker("线路", selection: $app.selectedLineID) { ForEach(detail.lines) { line in Text("\(line.name) · \(line.episodes.count) 集").tag(line.id) } }.labelsHidden().frame(width: 220) }
                ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 9)], spacing: 9) { ForEach(app.selectedLine?.episodes ?? []) { episode in Button { app.play(episode) } label: { Text(episode.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 12).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain) } } }
                Text("线路与集数来自目录；源尺寸会在实际播放后显示。").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
            }
        }.padding(28).background(CinemaStyle.background).foregroundStyle(.white).tint(CinemaStyle.accent)
    }
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value % 3600 / 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
}
