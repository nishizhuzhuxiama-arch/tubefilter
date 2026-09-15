import SwiftUI

// MARK: - 本地流列表

/// 本地流列表。既用于独立的「本地流」标签页，也内嵌在首页的本地模式里。
struct LocalFeedList: View {

    @EnvironmentObject private var localFeed: LocalFeedStore

    /// 是否同时展示被规则挡下的内容，用于核对规则松紧。
    var showBlocked: Bool

    @State private var filterText: String = ""
    @State private var sourceFilter: String = "all"

    private var sourceOptions: [String] {
        var set = Set(localFeed.items.map { $0.source })
        set.insert("all")
        return Array(set).sorted()
    }

    private var displayedItems: [LocalFeedItem] {
        var list = showBlocked ? localFeed.items : localFeed.visibleItems
        if sourceFilter != "all" {
            list = list.filter { $0.source == sourceFilter }
        }
        let keyword = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(keyword)
                    || $0.channelName.localizedCaseInsensitiveContains(keyword)
            }
        }
        return list
    }

    var body: some View {
        Group {
            if localFeed.items.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    summaryBar
                    List {
                        ForEach(displayedItems) { item in
                            LocalFeedRow(item: item)
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("本地流还没有内容")
                .font(.headline)
            Text("在「浏览」页正常刷一会儿，采集到的内容会留在本机并同步过滤。\n本地流不依赖任何远端推荐算法。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summaryBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Label("\(localFeed.visibleItems.count) 条可见", systemImage: "eye")
                    .font(.caption)
                Label("\(localFeed.blockedCount) 条被挡", systemImage: "shield.slash")
                    .font(.caption)
                    .foregroundColor(localFeed.blockedCount > 0 ? .red : .secondary)
                Spacer()
                Text("共 \(localFeed.items.count) 条")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                TextField("在本地流中筛选", text: $filterText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.footnote)

                if sourceOptions.count > 2 {
                    Menu {
                        ForEach(sourceOptions, id: \.self) { option in
                            Button(action: { sourceFilter = option }) {
                                Text(option == "all" ? "全部来源" : PageSource.label(for: option))
                            }
                        }
                    } label: {
                        Image(systemName: "line.horizontal.3.decrease.circle")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tfSurface)
    }
}

// MARK: - 行

struct LocalFeedRow: View {

    let item: LocalFeedItem

    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var browser: BrowserController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.isEmpty ? "（标题未采集到）" : item.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundColor(item.blockedByRule ? .secondary : .primary)

                HStack(spacing: 6) {
                    if !item.channelName.isEmpty {
                        Text(item.channelName).lineLimit(1)
                    }
                    if item.durationSeconds > 0 {
                        Text(FilterEngine.formatDuration(item.durationSeconds))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    sourceTag
                    if item.blockedByRule {
                        Text("已被规则挡下")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    if item.seenCount > 1 {
                        Text("见到 \(item.seenCount) 次")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(item.blockedByRule ? 0.55 : 1)
        .contextMenu {
            Button("打开播放") {
                browser.navigate(to: item.url.isEmpty ? "/watch?v=\(item.videoID)" : item.url)
            }
            if !item.channelName.isEmpty {
                Button("屏蔽频道：\(item.channelName)") {
                    store.addRule(BlockRule(kind: .channel, pattern: item.channelName, note: "来自本地流"))
                }
            }
            if !item.title.isEmpty {
                Button("用这条标题加屏蔽词") {
                    store.addRule(BlockRule(kind: .keyword, pattern: item.title, note: "来自本地流"))
                }
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.tfSurface)
                .frame(width: 84, height: 48)
            Image(systemName: "play.rectangle")
                .foregroundColor(.secondary)
        }
    }

    private var sourceTag: some View {
        Text(PageSource.label(for: item.source))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.tfSurfaceElevated)
            .cornerRadius(4)
    }
}

// MARK: - 独立页面

struct LocalFeedView: View {

    @State private var showBlocked = false

    var body: some View {
        NavigationView {
            LocalFeedList(showBlocked: showBlocked)
                .navigationBarTitle("本地流", displayMode: .inline)
                .navigationBarItems(trailing: toggleButton)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var toggleButton: some View {
        Button(action: { showBlocked.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: showBlocked ? "eye.slash" : "eye")
                Text(showBlocked ? "隐藏被挡" : "显示被挡")
                    .font(.footnote)
            }
        }
    }
}
