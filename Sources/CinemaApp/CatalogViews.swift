import SwiftUI
import CinemaCore

struct DiscoveryView: View {
    @ObservedObject var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            if !app.recentSearches.isEmpty && !app.browsing { recentSearches }
            HStack(alignment: .firstTextBaseline) {
                Text(app.catalogQuery.isEmpty && !app.browsing ? "为你发现" : app.searchLabel).font(.custom("PingFangSC-Semibold", size: 25)).lineLimit(1)
                if app.catalogQuery.isEmpty && !app.browsing { quickSearches }
                if app.searching { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(app.filteredGroups.count) 部作品").font(.system(size: 11)).foregroundStyle(CinemaStyle.tertiary)
                Button { app.openBrowse() } label: { Label("浏览片库", systemImage: "square.grid.2x2").font(.system(size: 11)) }.buttonStyle(CinemaActionStyle(compact: true))
            }
            if app.browsing { browseFilters }
            filterBar
            if !app.failures.isEmpty {
                DisclosureGroup("部分来源暂时不可用") { ForEach(app.failures, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity, alignment: .leading) } }.font(.system(size: 11)).foregroundStyle(CinemaStyle.tertiary)
            }
            if app.searching && app.results.isEmpty { HStack { Spacer(); ProgressView("正在寻找影片…"); Spacer() }.padding(60) }
            else if app.filteredGroups.isEmpty { ContentUnavailableView(app.enabledProviderCount == 0 ? "启用来源，开启观影" : "还没有找到这部作品", systemImage: "film.stack", description: Text(app.enabledProviderCount == 0 ? "在媒体来源中选择片库，然后搜索喜欢的影片。" : "试试其他片名，或放宽筛选条件。")) }
            GroupGrid(app: app, groups: app.filteredGroups)
            if app.canLoadMore {
                HStack { Spacer(); Button { app.loadMore() } label: { HStack(spacing: 8) { if app.loadingMore { ProgressView().controlSize(.mini) }; Text(app.loadingMore ? "正在加载…" : "发现更多"); if !app.loadingMore { Image(systemName: "chevron.down").font(.system(size: 9)) } } }.buttonStyle(CinemaActionStyle()).disabled(app.loadingMore || app.searching); Spacer() }.padding(.top, 12)
            }
        }
    }
    private var quickSearches: some View {
        HStack(spacing: 7) {
            ForEach(["星际穿越", "漫长的季节", "绝命毒师"], id: \.self) { term in
                Button { app.explore(term) } label: {
                    Text(term).font(.system(size: 10)).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(CinemaStyle.panel, in: Capsule())
                }.buttonStyle(.plain).foregroundStyle(CinemaStyle.secondary)
            }
        }
    }
    private var recentSearches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary)
                ForEach(app.recentSearches, id: \.self) { term in Button(term) { app.explore(term) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary) }
            }
        }
    }
    private var filterBar: some View {
        HStack(spacing: 9) {
            Menu { Button("全部来源") { app.filterProviderID = "" }; ForEach(app.providers.filter(\.enabled)) { provider in Button(provider.name) { app.filterProviderID = provider.id } } } label: { FilterPill(title: app.providers.first { $0.id == app.filterProviderID }?.name ?? "全部来源", active: !app.filterProviderID.isEmpty) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Menu { Button("全部年份") { app.filterYear = "" }; ForEach(app.availableYears, id: \.self) { year in Button(year) { app.filterYear = year } } } label: { FilterPill(title: app.filterYear.isEmpty ? "全部年份" : app.filterYear, active: !app.filterYear.isEmpty) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Menu {
                ForEach(CatalogContentFilter.allCases) { filter in
                    Button { app.filterContent = filter } label: {
                        if app.filterContent == filter { Label(filter.title, systemImage: "checkmark") }
                        else { Text(filter.title) }
                    }
                }
            } label: { FilterPill(title: app.filterContent.title, active: app.filterContent != .all) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("影片与剧集会隐藏明确标记为解说、预告或短剧的内容；未分类影片仍保留。")
            Menu { ForEach(CatalogSort.allCases) { sort in Button(sortLabel(sort)) { app.catalogSort = sort } } } label: { FilterPill(title: sortLabel(app.catalogSort)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Spacer(minLength: 4)
            if app.hasCatalogFilters {
                Button { app.resetCatalogFilters() } label: { Text("重置").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(CinemaStyle.secondary).help("清除筛选并恢复相关性排序")
            }
            Toggle(isOn: $app.automaticQualityInspection) { Label("自动识别画质", systemImage: "4k.tv").font(.system(size: 10)).foregroundStyle(CinemaStyle.secondary) }.toggleStyle(.switch).controlSize(.mini).fixedSize().help("自动获取可见影片的分辨率。播放时暂停后台读取。")
        }.padding(.bottom, 3)
    }
    private func sortLabel(_ sort: CatalogSort) -> String {
        if sort == .resolution { return "清晰度优先" }
        return sort.rawValue
    }
    private var browseFilters: some View {
        HStack(spacing: 12) {
            Menu { ForEach(app.providers.filter(\.enabled)) { provider in Button(provider.name) { app.browseProviderID = provider.id; app.browseCategoryID = ""; app.browseCategories = []; app.browseCatalog() } } } label: { FilterPill(title: app.providers.first { $0.id == app.browseProviderID }?.name ?? "选择片库") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 5) {
                categoryButton("全部", id: "")
                ForEach(app.browseCategories, id: \.id) { category in categoryButton(category.name, id: category.id) }
            } }
        }
    }
    private func categoryButton(_ title: String, id: String) -> some View {
        Button { app.browseCategoryID = id; app.browseCatalog() } label: { Text(title).font(.system(size: 11, weight: app.browseCategoryID == id ? .semibold : .regular)).foregroundStyle(app.browseCategoryID == id ? CinemaStyle.accent : CinemaStyle.secondary).padding(.horizontal, 12).padding(.vertical, 7).background(app.browseCategoryID == id ? CinemaStyle.accent.opacity(0.1) : .clear, in: Capsule()) }.buttonStyle(.plain)
    }
}
private struct FilterPill: View {
    let title: String
    var active = false
    var body: some View { HStack(spacing: 8) { Text(title).font(.system(size: 11)); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }.foregroundStyle(active ? CinemaStyle.accent : CinemaStyle.secondary).padding(.horizontal, 12).padding(.vertical, 8).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 7)) }
}
struct GroupGrid: View {
    @ObservedObject var app: AppModel
    let groups: [MediaGroup]
    var body: some View { LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 210), spacing: 19)], spacing: 25) { ForEach(groups) { group in GroupCard(app: app, group: group) } } }
}
private struct GroupCard: View {
    @ObservedObject var app: AppModel
    let group: MediaGroup
    var body: some View {
        ZStack(alignment: .topLeading) {
            Button { app.selectGroup(group) } label: {
                MediaCard(title: group.representative, sourceCount: group.sources.count, quality: quality)
            }.buttonStyle(.plain)
            Button { app.toggleSaved(group) } label: {
                Image(systemName: app.isSaved(group) ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(app.isSaved(group) ? CinemaStyle.bookmark : .white)
                    .frame(width: 29, height: 29)
                    .background(.black.opacity(0.55), in: Circle())
                    .contentShape(Circle())
            }.buttonStyle(.plain).padding(8)
                .help(app.isSaved(group) ? "移出待看" : "加入待看")
                .accessibilityLabel((app.isSaved(group) ? "移出待看 " : "加入待看 ") + group.representative.title)
        }.contextMenu {
            Button { app.refreshQuality(group) } label: { Label("更新画质", systemImage: "arrow.clockwise") }
        }
        .onAppear { app.inspectVisibleQuality(group) }
        .onChange(of: app.automaticQualityInspection) { _, enabled in if enabled { app.inspectVisibleQuality(group) } }
        .onChange(of: app.searching) { _, searching in if !searching { app.inspectVisibleQuality(group) } }
        .onChange(of: app.loadingMore) { _, loading in if !loading { app.inspectVisibleQuality(group) } }
        .onChange(of: app.providers) { _, _ in app.inspectVisibleQuality(group) }
    }
    private var quality: MediaQualityState? {
        if let best = app.mediaQuality.best(in: group.sources, providers: app.providers) { return .ready(best) }
        let states = group.sources.compactMap { app.mediaQuality.state(for: $0, providers: app.providers) }
        if states.contains(where: { if case .reading = $0 { return true }; return false }) { return .reading }
        if states.contains(where: { if case .queued = $0 { return true }; return false }) { return .queued }
        return states.first
    }
}
struct WatchlistView: View {
    @ObservedObject var app: AppModel
    @LegacyState private var confirmReset = false
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(alignment: .bottom) { VStack(alignment: .leading, spacing: 8) { Text("留给下一次心动").font(.custom("Songti SC", size: 30)).fontWeight(.semibold); Text("我的待看  /  \(app.watchlist.count) 部作品").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary) }; Spacer(); Image(systemName: "bookmark").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(CinemaStyle.accent) }.padding(.bottom, 8)
            if app.canResetWatchlist { Button("恢复待看片单…") { confirmReset = true }.buttonStyle(CinemaActionStyle()) }
            if app.watchlist.isEmpty { ContentUnavailableView("收藏下一部想看的影片", systemImage: "bookmark", description: Text("点亮影片旁的书签，让好故事在这里等你。")) }
            GroupGrid(app: app, groups: app.watchlist.compactMap(\.group))
        }.confirmationDialog("重建将清空原待看文件，是否继续？", isPresented: $confirmReset) { Button("重建待看", role: .destructive) { app.resetWatchlist() }; Button("取消", role: .cancel) {} }
    }
}
struct HistoryView: View {
    @ObservedObject var app: AppModel
    @LegacyState private var showAll = false
    @LegacyState private var unfinishedOnly = true
    @LegacyState private var confirmClear = false
    init(app: AppModel, unfinishedOnly: Bool = true) {
        self.app = app
        _unfinishedOnly = LegacyState(initialValue: unfinishedOnly)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .bottom) { VStack(alignment: .leading, spacing: 8) { Text("故事，继续。").font(.custom("Songti SC", size: 30)).fontWeight(.semibold); Text("回到上次离开的那一刻").font(.system(size: 12)).foregroundStyle(CinemaStyle.secondary) }; Spacer(); Button { confirmClear = true } label: { Label("清空记录", systemImage: "trash").font(.system(size: 11)) }.buttonStyle(CinemaActionStyle(compact: true)) }
            HStack(spacing: 14) {
                HStack(spacing: 3) {
                    historyFilter("未看完", unfinished: true)
                    historyFilter("全部记录", unfinished: false)
                }.padding(4).background(CinemaStyle.panel, in: Capsule())
                Text("\(records.count) 项").font(.system(size: 11)).foregroundStyle(CinemaStyle.tertiary)
                Spacer()
                Toggle("显示全部剧集", isOn: $showAll).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
            }
            if app.history.isEmpty { ContentUnavailableView("你的观影时光，从这里开始", systemImage: "clock", description: Text("播放过的影片会自动记录进度。")) }
            else if records.isEmpty {
                ContentUnavailableView("故事都看完了", systemImage: "checkmark.circle", description: Text("切换到全部记录，随时重温喜欢的影片。"))
            }
            ForEach(records) { record in
                HStack(spacing: 12) {
                    Button {
                        var target = record
                        if target.isCompleted { target.position = 0 }
                        app.resume(target)
                    } label: {
                        HStack(spacing: 21) {
                            PosterView(url: record.posterURL, title: record.title).frame(width: 86, height: 116).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 9) {
                                    Text(record.title).font(.system(size: 17, weight: .semibold))
                                    if record.isCompleted { Label("已看完", systemImage: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(CinemaStyle.positive) }
                                }
                                Text(record.episode + " · " + (record.mediaDetail?.title.providerName ?? "本地与网络影片")).font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary)
                                ProgressView(value: record.progress).tint(CinemaStyle.accent).frame(maxWidth: 360).padding(.top, 6)
                                Text("已看 " + timeString(record.position) + " / " + (record.duration > 0 ? timeString(record.duration) : "时长未知")).font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 7) { Image(systemName: record.isCompleted ? "arrow.counterclockwise" : "play.fill"); Text(record.isCompleted ? "重新观看" : "继续观看") }.font(.system(size: 11, weight: .medium)).foregroundStyle(CinemaStyle.accent).padding(.horizontal, 17).padding(.vertical, 10).background(CinemaStyle.accent.opacity(0.1), in: Capsule())
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button { app.removeHistory(record.id) } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(CinemaStyle.tertiary).frame(width: 28, height: 34).contentShape(Rectangle()) }.buttonStyle(.plain).help("移除此条记录")
                }.padding(15).background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            }
        }.confirmationDialog("清除这台 Mac 的全部观看历史？", isPresented: $confirmClear) { Button("清除全部历史", role: .destructive) { app.clearHistory() }; Button("取消", role: .cancel) {} }
    }
    private var records: [WatchRecord] { app.historyRecords(showAllEpisodes: showAll, unfinishedOnly: unfinishedOnly) }
    private func historyFilter(_ title: String, unfinished: Bool) -> some View {
        Button { unfinishedOnly = unfinished } label: {
            Text(title).font(.system(size: 11, weight: unfinishedOnly == unfinished ? .semibold : .regular))
                .foregroundStyle(unfinishedOnly == unfinished ? CinemaStyle.accent : CinemaStyle.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(unfinishedOnly == unfinished ? CinemaStyle.accentSoft : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(unfinishedOnly == unfinished ? .isSelected : [])
    }
}
