import SwiftUI
import CinemaCore

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
                    VStack(spacing: 0) {
                        topbar
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                switch app.section {
                                case .discover: DiscoveryView(app: app)
                                case .watchlist: WatchlistView(app: app)
                                case .history: HistoryView(app: app)
                                case .quality: QualityStudio(playback: app.playback)
                                case .sources: SourcesView(app: app)
                                }
                            }.padding(.horizontal, CinemaStyle.gutter).padding(.top, 26).padding(.bottom, 36)
                        }
                    }
                }
            }
        }
        .background(CinemaStyle.background).foregroundStyle(CinemaStyle.primary).tint(CinemaStyle.accent).preferredColorScheme(.dark)
        .frame(minWidth: 1040, minHeight: 680)
        .sheet(isPresented: Binding(get: { !app.showPlayer && app.detailPresented }, set: { if !$0 && !app.showPlayer { app.dismissDetail() } })) {
            DetailView(app: app).frame(width: 900, height: 740)
        }
        .sheet(isPresented: $showLink) {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Image(systemName: "link").foregroundStyle(CinemaStyle.accent); Text("打开网络影片").font(.system(size: 23, weight: .semibold)) }
                Text("粘贴影片的 HLS 或 MP4 链接，开始观看。").foregroundStyle(CinemaStyle.secondary).font(.system(size: 13))
                TextField("https://…", text: $link).textFieldStyle(.plain).padding(14).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 10)).frame(width: 470)
                HStack { Button("取消") { showLink = false }.buttonStyle(CinemaActionStyle()); Spacer(); Button("开始播放") {
                    if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) { app.openURL(url); showLink = false }
                    else { app.message = "链接格式不正确。" }
                }.buttonStyle(CinemaActionStyle(prominent: true)) }
            }.padding(32).background(CinemaStyle.background)
        }
        .alert("澄幕", isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } })) {
            Button("知道了") { app.message = nil }
        } message: { Text(app.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(CinemaStyle.accent).frame(width: 33, height: 33)
                    Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).offset(x: 1)
                }
                Text("澄幕").font(.custom("PingFangSC-Semibold", size: 23)).tracking(1)
            }.padding(.horizontal, 23).padding(.top, 32).padding(.bottom, 36)
            Text("我的影院").font(.system(size: 10, weight: .medium)).foregroundStyle(CinemaStyle.tertiary).padding(.horizontal, 25).padding(.bottom, 12)
            ForEach([AppSection.discover, .watchlist, .history]) { section in
                SidebarButton(title: section.rawValue, icon: section.icon, selected: app.section == section) { app.section = section }.padding(.horizontal, 12).padding(.bottom, 5)
            }
            Rectangle().fill(CinemaStyle.border).frame(height: 1).padding(.horizontal, 24).padding(.vertical, 20)
            ForEach([AppSection.quality, .sources]) { section in
                SidebarButton(title: section.rawValue, icon: section.icon, selected: app.section == section) { app.section = section }.padding(.horizontal, 12).padding(.bottom, 5)
            }
            Spacer(minLength: 25)
            VStack(alignment: .leading, spacing: 5) {
                SidebarButton(title: "本地影片", icon: "folder", isNavigation: false) { app.importFile() }
                SidebarButton(title: "网络链接", icon: "link", isNavigation: false) { showLink = true }
            }.padding(.horizontal, 12).padding(.bottom, 20)
            HStack(spacing: 7) { Circle().fill(CinemaStyle.positive).frame(width: 5, height: 5); Text("\(app.enabledProviderCount) 个来源已开启").font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary) }.padding(.horizontal, 25).padding(.bottom, 23)
        }.frame(width: 174).background(Color(red: 0.055, green: 0.06, blue: 0.07))
        .overlay(alignment: .trailing) { Rectangle().fill(CinemaStyle.border).frame(width: 1) }
    }

    private var topbar: some View {
        HStack(spacing: 16) {
            Text(app.section.rawValue).font(.system(size: 14, weight: .medium)).foregroundStyle(CinemaStyle.secondary)
            Spacer(minLength: 18)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(CinemaStyle.secondary)
                TextField("搜索电影、电视剧", text: $app.query).font(.system(size: 13)).textFieldStyle(.plain).onSubmit { app.search() }.accessibilityIdentifier("searchField")
                if app.searching { ProgressView().controlSize(.mini) }
                else if !app.query.isEmpty {
                    Button { app.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(CinemaStyle.tertiary) }.buttonStyle(.plain).help("清空搜索")
                }
                Button { app.search() } label: { Text("搜索").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 15).frame(height: 29).background(CinemaStyle.accent, in: RoundedRectangle(cornerRadius: 6)) }
                    .buttonStyle(.plain).accessibilityIdentifier("searchButton").disabled(app.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.leading, 13).padding(.trailing, 5).frame(width: 370, height: 39).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 9))
            Button { app.importFile() } label: { Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 36, height: 36).background(CinemaStyle.panel, in: Circle()) }.buttonStyle(.plain).help("打开本地影片")
        }.padding(.horizontal, CinemaStyle.gutter).padding(.vertical, 17)
        .background(CinemaStyle.background).overlay(alignment: .bottom) { Rectangle().fill(CinemaStyle.border).frame(height: 1) }
    }
}

struct PosterView: View {
    let url: URL?
    let title: String
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PosterFallback(title: title)
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}

/// Original typographic artwork for titles whose source does not supply a cover.
private struct PosterFallback: View {
    let title: String
    private var seed: Int { title.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 997 } }
    private var hue: Double { Double(seed % 360) / 360 }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Color(hue: hue, saturation: 0.27, brightness: 0.18)
                LinearGradient(colors: [Color(hue: hue, saturation: 0.5, brightness: 0.53), .black.opacity(0.35)], startPoint: .topTrailing, endPoint: .bottomLeading)
                Circle().stroke(Color.white.opacity(0.11), lineWidth: geo.size.width * 0.16).frame(width: geo.size.width * 0.95).offset(x: geo.size.width * 0.28, y: -geo.size.height * 0.25)
                Rectangle().fill(Color.white.opacity(0.075)).frame(width: geo.size.width * 0.22).rotationEffect(.degrees(28)).offset(x: geo.size.width * 0.22)
                VStack(alignment: .leading, spacing: 11) {
                    Text("CHENGMU / CINEMA").font(.system(size: max(6, geo.size.width * 0.04), weight: .medium)).tracking(1.8).foregroundStyle(.white.opacity(0.58))
                    Text(title).font(.custom("Songti SC", size: max(18, geo.size.width * 0.16))).fontWeight(.bold).lineLimit(4).lineSpacing(5).foregroundStyle(.white.opacity(0.94))
                    Rectangle().fill(.white.opacity(0.5)).frame(width: 22, height: 2)
                }.padding(geo.size.width * 0.11).padding(.bottom, geo.size.height * 0.05)
            }
        }
    }
}

struct MediaCard: View {
    let title: MediaTitle
    var sourceCount = 1
    var quality: MediaQualityState?
    @LegacyState private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PosterView(url: title.posterURL, title: title.title).aspectRatio(0.70, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
                    HStack { Text(title.year).font(.system(size: 10, weight: .medium)); Spacer(); if sourceCount > 1 { Text("\(sourceCount) 个来源").font(.system(size: 9)) } }.padding(10).frame(maxHeight: .infinity, alignment: .bottom)
                }
                .overlay(alignment: .topTrailing) { QualityBadge(state: quality).padding(8) }
                .overlay {
                    if hovering { ZStack { Color.black.opacity(0.22); Image(systemName: "play.circle.fill").font(.system(size: 42)).foregroundStyle(.white) }.transition(.opacity) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hovering ? CinemaStyle.accent : .white.opacity(0.05), lineWidth: 1))
            Text(title.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(hovering ? CinemaStyle.accent : CinemaStyle.primary).lineLimit(1)
            HStack(spacing: 5) {
                Text(providerLabel).lineLimit(1)
                Spacer(minLength: 0)
                if case .ready(let value) = quality, let fps = value.sample.frameRate {
                    Text(consumerFrameRate(fps)).fixedSize()
                }
            }.font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary)
        }.contentShape(Rectangle()).onHover { hovering = $0 }.animation(CinemaStyle.quick, value: hovering)
    }
    private var providerLabel: String {
        if case .ready(let value) = quality, !value.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value.providerName }
        return title.providerName.isEmpty ? "网络影片" : title.providerName
    }
}

private func consumerResolution(_ sample: MediaQualitySample) -> String {
    if sample.width == 3840 && sample.height == 2160 { return "4K" }
    return sample.resolutionLabel.components(separatedBy: " · ")[0].uppercased()
}
private func consumerFrameRate(_ fps: Double) -> String {
    String(format: abs(fps.rounded() - fps) < 0.02 ? "%.0f 帧" : "%.2f 帧", fps)
}
private func consumerQuality(_ sample: MediaQualitySample) -> String {
    consumerResolution(sample) + " · " + (sample.frameRate.map(consumerFrameRate) ?? "帧率未知")
}

struct QualityBadge: View {
    let state: MediaQualityState?
    var body: some View {
        Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.2).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(isReady ? CinemaStyle.accent.opacity(0.92) : .black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
            .help(explanation)
            .accessibilityLabel("片源画质：" + label)
    }
    private var isReady: Bool { if case .ready = state { return true }; return false }
    private var label: String {
        switch state {
        case .ready(let value): return consumerResolution(value.sample)
        case .queued: return "等待识别"
        case .reading: return "识别中"
        case .unavailable: return "暂未获取"
        case nil: return "画质待识别"
        }
    }
    private var explanation: String {
        switch state {
        case .ready(let value): return value.providerName + " · " + value.sampleLabel + "\n" + consumerQuality(value.sample) + " · " + value.sample.dimensionsLabel
        case .queued: return "正在等待获取这部影片的画质信息。"
        case .reading: return "正在获取片源分辨率和帧率。"
        case .unavailable: return "暂时无法获取画质信息，仍可打开影片观看；右键选择更新画质可再次尝试。"
        case nil: return "尚未获取片源画质；右键选择更新画质可立即开始。"
        }
    }
}

struct QualityReadout: View {
    let state: MediaQualityState?
    var body: some View {
        Group {
            switch state {
            case .ready(let value): Text(consumerQuality(value.sample)).foregroundStyle(CinemaStyle.accent).help(value.providerName + " · " + value.sampleLabel + " · " + value.sample.dimensionsLabel)
            case .reading, .queued: Text("正在获取画质…").foregroundStyle(CinemaStyle.secondary)
            case .unavailable: Text("画质信息暂不可用").foregroundStyle(CinemaStyle.tertiary)
            case nil: Text("画质待获取").foregroundStyle(CinemaStyle.tertiary)
            }
        }.font(.system(size: 11)).lineLimit(1)
    }
}

struct MediaResponseReadout: View {
    let state: MediaResponseState?
    var playbackActive = false
    var body: some View {
        Text(state?.label ?? (playbackActive ? "播放中暂停检测" : "响应待检测"))
            .font(.system(size: 11)).foregroundStyle(isReady ? CinemaStyle.accent : CinemaStyle.tertiary)
            .lineLimit(1).help(explanation)
            .accessibilityLabel("媒体延时：" + (state?.label ?? "尚未检测"))
    }
    private var isReady: Bool { if case .ready = state { return true }; return false }
    private var explanation: String {
        let method = "媒体地址的 HTTP HEAD 响应时间，含本次连接开销；不下载影片正文，不是 Ping、起播时间或带宽。同一线路其他集数可能不同。"
        switch state {
        case .ready(let value): return method + "\n检测于 " + value.checkedAt.formatted(date: .omitted, time: .standard) + "，可更新画质与延时重新检测。"
        case .unavailable(let reason, _): return reason + "。仍可尝试播放或换线路。\n" + method
        case .queued: return "等待与画质检查一起执行。\n" + method
        case .reading: return "正在准备媒体响应检查。取得媒体地址后的单次检查最长约3秒，目录加载和画质读取另计。\n" + method
        case nil: return (playbackActive ? "为优先保障播放，后台检测已暂停；已有结果仍可查看。\n" : "尚未检测，可更新画质与延时。\n") + method
        }
    }
}

struct DetailView: View {
    @ObservedObject var app: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("影片详情").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary); Spacer(); Button { app.dismissDetail() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 29, height: 29).background(CinemaStyle.panel, in: Circle()) }.buttonStyle(.plain).help("关闭详情") }.padding(.horizontal, 30).padding(.vertical, 15)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if app.detailLoading { ProgressView("正在加载影片…").frame(maxWidth: .infinity).padding(.vertical, 80) }
                    else if let detail = app.detail { overview(detail) }
                    if !app.detailSources.isEmpty { sources }
                    if let detail = app.detail, !app.detailLoading { lines(detail); episodes }
                }.padding(.horizontal, 30).padding(.top, 6).padding(.bottom, 30)
            }
        }.background(CinemaStyle.background).foregroundStyle(CinemaStyle.primary).tint(CinemaStyle.accent)
        .onChange(of: app.selectedLineID) { _, _ in inspectSelectedLine() }
        .onChange(of: app.automaticQualityInspection) { _, enabled in if enabled, let detail = app.detail { app.inspectDetailQuality(detail) } }
        .onChange(of: app.providers) { _, _ in if let detail = app.detail { app.inspectDetailQuality(detail) } }
        .onAppear { if let detail = app.detail { app.inspectDetailQuality(detail) } }
    }
    private func overview(_ detail: MediaDetail) -> some View {
        HStack(alignment: .top, spacing: 28) {
            PosterView(url: detail.title.posterURL, title: detail.title.title).frame(width: 145, height: 207).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 13) {
                Text(detail.title.year.isEmpty ? "电影 · 剧集" : detail.title.year + "  /  " + detail.title.providerName).font(.system(size: 11, weight: .medium)).foregroundStyle(CinemaStyle.secondary)
                Text(detail.title.title).font(.custom("PingFangSC-Semibold", size: 29)).lineLimit(2)
                Text(detail.title.summary.isEmpty ? "暂无简介。选择来源与集数，即可开始观看。" : detail.title.summary).font(.system(size: 12)).lineSpacing(5).foregroundStyle(CinemaStyle.secondary).lineLimit(3)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Button { app.continueDetail() } label: { Label(app.detailHasHistory ? "继续观看" : "立即播放", systemImage: "play.fill") }.buttonStyle(CinemaActionStyle(prominent: true))
                    if let group = detailGroup(detail) { Button { app.toggleSaved(group) } label: { Label(app.isSaved(group) ? "已加入待看" : "加入待看", systemImage: app.isSaved(group) ? "bookmark.fill" : "bookmark") }.buttonStyle(CinemaActionStyle()) }
                }
            }.frame(minHeight: 207, alignment: .topLeading)
        }
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("播放来源").font(.system(size: 16, weight: .semibold)); Text("\(app.detailSources.count)").font(.system(size: 11)).foregroundStyle(CinemaStyle.tertiary); Spacer(); Button { app.mediaQuality.check(app.detailSources, providers: app.providers, force: true) } label: { Label("更新画质与延时", systemImage: "arrow.clockwise").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(CinemaStyle.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 9)], spacing: 9) { ForEach(app.detailSources, id: \.self) { source in sourceRow(source) } }
        }
    }
    private func sourceRow(_ source: MediaTitle) -> some View {
        let selected = app.detail?.title.providerID == source.providerID && app.detail?.title.id == source.id
        let enabled = app.providers.contains { $0.id == source.providerID && $0.enabled }
        return Button { app.select(source) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) { Text(source.providerName).font(.system(size: 12, weight: .medium)); QualityReadout(state: app.mediaQuality.state(for: source, providers: app.providers)); MediaResponseReadout(state: app.mediaQuality.responseState(for: source, providers: app.providers)) }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(CinemaStyle.accent) }
            }.padding(14).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading).background(selected ? CinemaStyle.accent.opacity(0.10) : CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? CinemaStyle.accent.opacity(0.6) : .clear, lineWidth: 1)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
    }
    private func lines(_ detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("播放线路").font(.system(size: 16, weight: .semibold)); Spacer(); Text("画质因来源和集数而异").font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 9)], spacing: 9) {
                ForEach(detail.lines) { line in
                    let state = line.episodes.first.flatMap { app.mediaQuality.state(for: $0.url) }
                    HStack(spacing: 5) {
                        Button { app.selectedLineID = line.id } label: {
                            VStack(alignment: .leading, spacing: 7) { HStack { Text(line.name).font(.system(size: 12, weight: .medium)); Text("\(line.episodes.count) 集").font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary); Spacer(); if app.selectedLineID == line.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(CinemaStyle.accent) } }; QualityReadout(state: state); MediaResponseReadout(state: line.episodes.first.flatMap { app.mediaQuality.responseState(for: $0.url) }) }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { app.mediaQuality.check(line: line, providerName: detail.title.providerName, force: true) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary).frame(width: 28, height: 35).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(line.episodes.isEmpty || isBusy(state)).help("更新画质与延时")
                    }.padding(13).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(app.selectedLineID == line.id ? CinemaStyle.accent.opacity(0.6) : .clear, lineWidth: 1))
                }
            }
        }
    }
    private var episodes: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text("选集").font(.system(size: 16, weight: .semibold)); Spacer(); Text(app.selectedLine?.name ?? "暂无线路").font(.system(size: 11)).foregroundStyle(CinemaStyle.tertiary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 91), spacing: 9)], spacing: 9) { ForEach(app.selectedLine?.episodes ?? []) { episode in Button { app.play(episode) } label: { Text(episode.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 12).contentShape(Rectangle()) }.buttonStyle(CinemaEpisodeStyle()) } }
        }
    }
    private func detailGroup(_ detail: MediaDetail) -> MediaGroup? { CatalogGrouping.groups([detail.title] + app.detailSources.filter { CatalogGrouping.normalizedTitle($0.title) == CatalogGrouping.normalizedTitle(detail.title.title) && ($0.year.isEmpty || detail.title.year.isEmpty || $0.year == detail.title.year) }).first }
    private func inspectSelectedLine() { guard app.automaticQualityInspection, let line = app.selectedLine, let detail = app.detail else { return }; app.mediaQuality.check(line: line, providerName: detail.title.providerName) }
    private func isBusy(_ state: MediaQualityState?) -> Bool { switch state { case .queued, .reading: return true; default: return false } }
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }; let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value % 3600 / 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
}
