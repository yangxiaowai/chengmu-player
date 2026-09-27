import SwiftUI
import CinemaCore

struct DiscoveryView: View {
    @ObservedObject var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if app.query.isEmpty && !app.browsing { hero }
            if !app.recentSearches.isEmpty && !app.browsing {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        Text("最近搜索").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
                        ForEach(app.recentSearches, id: \.self) { term in Button(term) { app.explore(term) }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 11).padding(.vertical, 6).background(CinemaStyle.panel, in: Capsule()) }
                    }
                }
            }
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(app.searchLabel).font(.system(size: 23, weight: .semibold))
                    Text(app.searching ? "正在检索已启用来源…" : "\(app.filteredGroups.count) 部作品 · \(app.results.count) 个来源版本")
                        .font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                }
                Spacer()
                Button { app.openBrowse() } label: { Label("浏览来源目录", systemImage: "square.grid.2x2") }.buttonStyle(.bordered)
            }
            if app.browsing { browseFilters }
            HStack(spacing: 14) {
                Picker("来源", selection: $app.filterProviderID) {
                    Text("全部来源").tag("")
                    ForEach(app.providers.filter(\.enabled)) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 215)
                Picker("年份", selection: $app.filterYear) {
                    Text("全部年份").tag("")
                    ForEach(app.availableYears, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 140)
                Spacer()
                Picker("排序", selection: $app.catalogSort) { ForEach(CatalogSort.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 175)
            }.font(.system(size: 11))
            if !app.failures.isEmpty {
                DisclosureGroup("\(app.failures.count) 个来源本次未能返回结果") {
                    ForEach(app.failures, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                }.font(.caption).foregroundStyle(CinemaStyle.secondary)
            }
            if app.searching && app.results.isEmpty {
                HStack { Spacer(); ProgressView("正在找到好故事…"); Spacer() }.padding(60)
            } else if app.filteredGroups.isEmpty {
                ContentUnavailableView(app.enabledProviderCount == 0 ? "还没有启用媒体来源" : "没有匹配的作品", systemImage: "film.stack", description: Text(app.enabledProviderCount == 0 ? "前往媒体来源启用目录，再回来搜索。" : "换个片名、放宽筛选，或继续加载其他页。"))
            }
            GroupGrid(app: app, groups: app.filteredGroups)
            if app.canLoadMore {
                HStack { Spacer(); Button { app.loadMore() } label: {
                    HStack { if app.loadingMore { ProgressView().controlSize(.small) }; Text(app.loadingMore ? "正在加载…" : "加载更多 / 重试未返回来源") }.padding(.horizontal, 14).padding(.vertical, 6)
                }.buttonStyle(.bordered).disabled(app.loadingMore || app.searching); Spacer() }
            }
            Text("同作品的来源已合并展示；分辨率与可播放性以实际资源为准。").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
        }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 13) {
                    Text("Y O U R   E V E N I N G   S T A R T S   H E R E").font(.system(size: 9, weight: .semibold)).foregroundStyle(CinemaStyle.accent)
                    Text("把好故事，\n留给今晚。").font(.system(size: 36, weight: .medium, design: .serif)).lineSpacing(3)
                    Text("电影、国产剧、美剧。多个来源，一间放映室。").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 9) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(CinemaStyle.accent)
                    Text("\(app.enabledProviderCount) 个来源\n边看，边增强").font(.system(size: 11)).lineSpacing(4).multilineTextAlignment(.trailing).foregroundStyle(CinemaStyle.secondary)
                }.padding(10)
            }
            HStack(spacing: 24) {
                picks("电影", terms: ["星际穿越", "流浪地球", "盗梦空间"])
                picks("国产剧", terms: ["庆余年", "琅琊榜", "漫长的季节"])
                picks("美剧", terms: ["怪奇物语", "绝命毒师", "火线"])
            }
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }
    private func picks(_ label: String, terms: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(CinemaStyle.accent)
            ForEach(terms, id: \.self) { term in Button { app.explore(term) } label: { HStack(spacing: 5) { Text(term); Image(systemName: "arrow.up.right").font(.system(size: 8)) }.font(.system(size: 11)) }.buttonStyle(.plain) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var browseFilters: some View {
        HStack(spacing: 18) {
            Picker("目录", selection: Binding(get: { app.browseProviderID }, set: { app.browseProviderID = $0; app.browseCategoryID = ""; app.browseCategories = []; app.browseCatalog() })) {
                ForEach(app.providers.filter(\.enabled)) { Text($0.name).tag($0.id) }
            }.frame(maxWidth: 260)
            Picker("分类", selection: Binding(get: { app.browseCategoryID }, set: { app.browseCategoryID = $0; app.browseCatalog() })) {
                Text("全部分类").tag("")
                ForEach(app.browseCategories, id: \.id) { Text($0.name).tag($0.id) }
            }.frame(maxWidth: 260)
            Spacer()
        }.font(.system(size: 12)).padding(15).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct GroupGrid: View {
    @ObservedObject var app: AppModel
    let groups: [MediaGroup]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 154, maximum: 210), spacing: 18)], spacing: 25) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 9) {
                    Button { app.selectGroup(group) } label: { MediaCard(title: group.representative) }.buttonStyle(.plain)
                    HStack {
                        Text("\(group.sources.count) 个版本").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
                        Spacer()
                        Button { app.toggleSaved(group) } label: { Image(systemName: app.isSaved(group) ? "bookmark.fill" : "bookmark").foregroundStyle(app.isSaved(group) ? CinemaStyle.accent : CinemaStyle.secondary) }.buttonStyle(.plain).help(app.isSaved(group) ? "移出待看" : "加入待看").accessibilityLabel((app.isSaved(group) ? "移出待看 " : "加入待看 ") + group.representative.title)
                    }
                }
            }
        }
    }
}

struct WatchlistView: View {
    @ObservedObject var app: AppModel
    @LegacyState private var confirmReset = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("好故事，先收起来。").font(.system(size: 30, weight: .medium, design: .serif))
            Text("\(app.watchlist.count) 部待看 · 保存在这台 Mac 上").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary)
            if app.canResetWatchlist { Button("重建损坏的待看文件…") { confirmReset = true }.foregroundStyle(CinemaStyle.accent) }
            if app.watchlist.isEmpty { ContentUnavailableView("你的片单，从这里开始", systemImage: "bookmark", description: Text("搜索后点击卡片旁的书签，或在详情中加入待看。")) }
            GroupGrid(app: app, groups: app.watchlist.compactMap(\.group))
        }.confirmationDialog("重建将清空原待看文件，是否继续？", isPresented: $confirmReset) { Button("重建待看", role: .destructive) { app.resetWatchlist() }; Button("取消", role: .cancel) {} }
    }
}

struct HistoryView: View {
    @ObservedObject var app: AppModel
    @LegacyState private var showAll = false
    @LegacyState private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 8) { Text("接着上次，继续入戏。").font(.system(size: 29, weight: .medium, design: .serif)); Text("同作品优先展示最近一集，进度始终属于实际观看的来源版本。").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary) }
                Spacer(); Button("清除历史…") { confirmClear = true }.foregroundStyle(CinemaStyle.secondary)
            }
            Toggle("显示所有集目记录", isOn: $showAll).toggleStyle(.switch).font(.system(size: 12))
            if app.history.isEmpty { ContentUnavailableView("还没有观看记录", systemImage: "clock", description: Text("开始播放后，进度会自动保存在这里。")) }
            ForEach(showAll ? app.history : app.latestHistory) { record in
                HStack(spacing: 18) {
                    Button { app.resume(record) } label: {
                        HStack(spacing: 20) {
                            PosterView(url: record.posterURL, title: record.title).frame(width: 76, height: 102).clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 9) {
                                Text(record.title).font(.system(size: 17, weight: .semibold))
                                Text(record.episode + " · " + (record.mediaDetail?.title.providerName ?? "自选媒体")).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                                ProgressView(value: record.progress).tint(CinemaStyle.accent).frame(maxWidth: 340)
                                Text("\(timeString(record.position)) / \(timeString(record.duration))").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary)
                            }; Spacer(); Image(systemName: "play.circle").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(CinemaStyle.accent)
                        }
                    }.buttonStyle(.plain)
                    Button { app.removeHistory(record.id) } label: { Image(systemName: "xmark").padding(8) }.buttonStyle(.plain).help("移除此条记录")
                }.padding(15).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            }
        }.confirmationDialog("清除这台 Mac 的全部观看历史？", isPresented: $confirmClear) { Button("清除全部历史", role: .destructive) { app.clearHistory() }; Button("取消", role: .cancel) {} }
    }
}
