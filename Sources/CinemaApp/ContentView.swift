import SwiftUI
import CinemaCore

// CLT ships the property wrapper but may omit the new SwiftUI State macro plugin.
typealias LegacyState<Value> = SwiftUI.State<Value>

enum CinemaStyle {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.075)
    static let panel = Color(red: 0.09, green: 0.10, blue: 0.115)
    static let border = Color.white.opacity(0.085)
    static let accent = Color(red: 0.94, green: 0.66, blue: 0.29)
    static let secondary = Color(red: 0.56, green: 0.59, blue: 0.62)
}

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
                                case .discover: discovery
                                case .history: history
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
        .sheet(isPresented: Binding(get: { !app.showPlayer && (app.detailLoading || app.detail != nil) }, set: { if !$0 && !app.showPlayer { app.dismissDetail() } })) {
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
        .alert("映川", isPresented: Binding(get: {app.message != nil}, set: {if !$0 {app.message = nil}})) { Button("知道了") { app.message = nil } } message: { Text(app.message ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill").font(.system(size: 28, weight: .light)).foregroundStyle(CinemaStyle.accent)
                VStack(alignment: .leading, spacing: 2) { Text("映川").font(.system(size: 23, weight: .semibold, design: .serif)); Text("Y I N G C H U A N").font(.system(size: 8, weight: .medium)).foregroundStyle(CinemaStyle.secondary) }
            }.padding(.top, 33).padding(.bottom, 48).padding(.horizontal, 24)
            Text("你的放映室").font(.system(size: 10, weight: .medium)).foregroundStyle(CinemaStyle.secondary).padding(.horizontal, 26).padding(.bottom, 13)
            ForEach(AppSection.allCases) { section in
                Button { app.section = section } label: {
                    HStack(spacing: 13) { Image(systemName: section.icon).frame(width: 18); Text(section.rawValue).font(.system(size: 13, weight: app.section == section ? .semibold : .regular)); Spacer(); if app.section == section { RoundedRectangle(cornerRadius: 1).fill(CinemaStyle.accent).frame(width: 3, height: 16) } }
                        .padding(.horizontal, 14).padding(.vertical, 13)
                        .background(app.section == section ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(app.section == section ? .white : CinemaStyle.secondary)
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 13) {
                Button { app.importFile() } label: { Label("打开本地影片", systemImage: "folder.badge.plus") }
                Button { showLink = true } label: { Label("打开网络链接", systemImage: "link") }
            }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(CinemaStyle.secondary).padding(26)
            Rectangle().fill(CinemaStyle.border).frame(height: 1).padding(.horizontal, 24)
            HStack(spacing: 7) { Circle().fill(CinemaStyle.accent).frame(width: 5, height: 5); Text("\(app.enabledProviderCount) 个检索来源已启用").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary) }.padding(24)
        }.frame(width: 204).background(Color.black.opacity(0.16))
    }
    private var topbar: some View {
        HStack(spacing: 18) {
            Text(app.section.rawValue).font(.system(size: 13, weight: .medium)).foregroundStyle(CinemaStyle.secondary)
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(CinemaStyle.secondary)
                TextField("搜索电影、剧集…", text: $app.query).textFieldStyle(.plain).onSubmit { app.search() }.frame(width: 245).accessibilityIdentifier("searchField")
                if app.searching { ProgressView().controlSize(.small) }
            }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 11).background(CinemaStyle.panel, in: Capsule())
            Button { app.search() } label: { Text("搜索").font(.system(size: 12, weight: .medium)) }.buttonStyle(.plain).foregroundStyle(CinemaStyle.accent).accessibilityIdentifier("searchButton")
        }.padding(.horizontal, 32).padding(.vertical, 20)
    }
    private var discovery: some View {
        Group {
            if app.query.isEmpty {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("YOUR PRIVATE CINEMA").font(.system(size: 10, weight: .semibold)).tracking(3).foregroundStyle(CinemaStyle.accent)
                        Text("好故事，\n值得好好看。").font(.system(size: 40, weight: .medium, design: .serif)).lineSpacing(4)
                        Text("找到影片，选好一集。\n让画面在播放中变得更清楚。").font(.system(size: 13)).lineSpacing(6).foregroundStyle(CinemaStyle.secondary)
                        HStack(spacing: 10) {
                            ForEach(["怪奇物语", "绝命毒师", "火线"], id: \.self) { title in
                                Button { app.query = title; app.search() } label: { HStack(spacing: 5) { Text(title); Image(systemName: "arrow.up.right").font(.system(size: 8)) }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 8).background(Color.white.opacity(0.055), in: Capsule()) }.buttonStyle(.plain)
                            }
                        }.padding(.top, 7)
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(CinemaStyle.accent.opacity(0.08), lineWidth: 1).frame(width: 230, height: 230)
                        Circle().stroke(CinemaStyle.accent.opacity(0.15), lineWidth: 1).frame(width: 174, height: 174)
                        Circle().fill(CinemaStyle.accent.opacity(0.06)).frame(width: 120, height: 120)
                        Image(systemName: "play.fill").font(.system(size: 35, weight: .ultraLight)).foregroundStyle(CinemaStyle.accent).offset(x: 4)
                        Text("PRESS PLAY. STAY A WHILE.").font(.system(size: 8, weight: .medium)).tracking(2).foregroundStyle(CinemaStyle.secondary).offset(y: 135)
                    }.frame(width: 270, height: 290)
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
            }
            HStack(alignment: .lastTextBaseline) {
                Text(app.searchLabel).font(.system(size: 21, weight: .semibold))
                Spacer()
                Text(app.searching ? "正在检索来源…" : "\(app.results.count) 个目录结果").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
            }
            if !app.failures.isEmpty {
                DisclosureGroup("部分来源暂不可用（\(app.failures.count)）") { ForEach(app.failures, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity, alignment: .leading) } }.font(.caption).foregroundStyle(CinemaStyle.secondary)
            }
            if app.results.isEmpty && !app.searching {
                ContentUnavailableView("没有找到可用目录", systemImage: "film.stack", description: Text("试试其他关键词，或在媒体来源中检查接口。"))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)], spacing: 25) {
                ForEach(Array(app.results.enumerated()), id: \.offset) { _, title in
                    Button { app.select(title) } label: { MediaCard(title: title) }.buttonStyle(.plain)
                }
            }
            Text("目录信息由媒体来源提供；实际播放及画质以当前资源为准。").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary.opacity(0.7)).padding(.top, 6)
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { VStack(alignment: .leading, spacing: 8) { Text("接着上次，继续入戏。").font(.system(size: 29, weight: .medium, design: .serif)); Text("观看进度保存在这台 Mac 上。").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary) }; Spacer(); Button("清除历史") { app.clearHistory() }.foregroundStyle(CinemaStyle.secondary) }
            if app.history.isEmpty { ContentUnavailableView("还没有观看记录", systemImage: "clock", description: Text("开始播放后，你的进度会自动出现在这里。")) }
            ForEach(app.history) { record in
                Button { app.resume(record) } label: {
                    HStack(spacing: 20) {
                        PosterView(url: record.posterURL, title: record.title).frame(width: 82, height: 108).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 10) {
                            Text(record.title).font(.system(size: 18, weight: .semibold)); Text(record.episode).font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
                            ProgressView(value: record.progress).tint(CinemaStyle.accent).frame(maxWidth: 340)
                            Text("看到 \(timeString(record.position)) / \(timeString(record.duration))").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
                        }; Spacer(); Image(systemName: "play.circle").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(CinemaStyle.accent)
                    }.padding(15).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
        }
    }
}

struct PosterView: View {
    let url: URL?
    let title: String
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                ZStack { LinearGradient(colors: [Color(red: 0.18, green: 0.23, blue: 0.25), CinemaStyle.panel], startPoint: .topLeading, endPoint: .bottomTrailing); VStack(spacing: 18) { Image(systemName: "film").font(.system(size: 29, weight: .ultraLight)).foregroundStyle(CinemaStyle.accent.opacity(0.6)); Text(title).font(.system(size: 18, weight: .medium, design: .serif)).multilineTextAlignment(.center).padding(.horizontal, 20) } }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}
struct MediaCard: View {
    let title: MediaTitle
    @LegacyState private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PosterView(url: title.posterURL, title: title.title).aspectRatio(2.0 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottomLeading) { Text(title.providerName).font(.system(size: 9, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.75), in: Capsule()).padding(8) }
                .overlay { if hovering { RoundedRectangle(cornerRadius: 9).stroke(CinemaStyle.accent.opacity(0.8), lineWidth: 1.5); Image(systemName: "play.circle.fill").font(.system(size: 37)).foregroundStyle(.white).shadow(radius: 10) } }
            Text(title.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(title.year.isEmpty ? "查看集数与线路" : "\(title.year) · 查看集数与线路").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary).lineLimit(1)
        }.onHover { hovering = $0 }
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
                        if let first = app.selectedLine?.episodes.first { Button { app.play(first) } label: { Label("开始观看", systemImage: "play.fill").padding(.horizontal, 10).padding(.vertical, 4) }.buttonStyle(.borderedProminent) }
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
