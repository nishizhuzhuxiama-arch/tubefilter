import SwiftUI

/// 本地搜索历史的持久化。
final class SearchHistoryStore: ObservableObject {

    @Published private(set) var queries: [String] = []

    private let storageKey = "com.watt.tubefilter.searchHistory"
    private let limit = 40

    init() {
        queries = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }

    func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = queries.filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        if list.count > limit {
            list = Array(list.prefix(limit))
        }
        queries = list
        persist()
    }

    func remove(_ query: String) {
        queries = queries.filter { $0 != query }
        persist()
    }

    func clear() {
        queries = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(queries, forKey: storageKey)
    }
}

// MARK: - 浏览页

struct BrowseView: View {

    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var browser: BrowserController
    @EnvironmentObject private var localFeed: LocalFeedStore

    @StateObject private var searchHistory = SearchHistoryStore()

    @State private var searchText: String = ""
    @State private var suggestions: [String] = []
    @State private var showFilterSheet = false
    @State private var showSuggestions = false
    @State private var suggestionWorkItem: DispatchWorkItem?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                tabStrip
                Divider()

                if store.settings.feedMode == .local {
                    localModeBody
                } else {
                    webBody
                }
            }
            .navigationBarTitle(navigationTitle, displayMode: .inline)
            .navigationBarItems(
                leading: leadingBarItems,
                trailing: trailingBarItems
            )
            .sheet(isPresented: $showFilterSheet) {
                SearchFilterSheet(state: $browser.searchState) {
                    browser.performSearch()
                }
                .environmentObject(store)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            browser.loadInitialPageIfNeeded()
        }
    }

    // MARK: 顶部

    private var navigationTitle: String {
        if store.settings.feedMode == .local {
            return "本地流模式"
        }
        return "\(browser.activeTab.title) · \(browser.sourceLabel)"
    }

    private var tabStrip: some View {
        Picker("分区", selection: Binding(
            get: { browser.activeTab },
            set: { newValue in
                if newValue != browser.activeTab {
                    browser.select(tab: newValue)
                }
            }
        )) {
            ForEach(BrowseTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var leadingBarItems: some View {
        HStack(spacing: 14) {
            Button(action: { browser.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!browser.canGoBack)

            Button(action: { browser.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!browser.canGoForward)
        }
    }

    private var trailingBarItems: some View {
        HStack(spacing: 14) {
            if browser.isLoading {
                Button(action: { browser.stopLoading() }) {
                    Image(systemName: "xmark")
                }
            } else {
                Button(action: { browser.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
            Button(action: { browser.rescan() }) {
                Image(systemName: "shield.lefthalf.filled")
            }
        }
    }

    // MARK: 本地模式

    private var localModeBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .foregroundColor(.secondary)
                Text("本地模式：不加载远端推荐，只使用本机已采集内容")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button("切回网页") {
                    store.settings.feedMode = .hybrid
                }
                .font(.footnote)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.tfSurface)

            LocalFeedList(showBlocked: false)
        }
    }

    // MARK: 网页模式

    private var webBody: some View {
        VStack(spacing: 0) {
            if browser.activeTab == .search {
                searchBar
            }

            ZStack(alignment: .top) {
                WebViewContainer(controller: browser)

                if browser.isLoading {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                }
            }

            if browser.lastError != nil {
                errorBar
            }

            filterStatusBar
        }
    }

    // MARK: 搜索栏

    private var searchBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("搜索 YouTube", text: $searchText, onCommit: submitSearch)
                    .textFieldStyle(PlainTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        suggestions = []
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }

                Button(action: { showFilterSheet = true }) {
                    HStack(spacing: 3) {
                        Image(systemName: "line.horizontal.3.decrease")
                        if browser.searchState.activeCount > 0 {
                            Text("\(browser.searchState.activeCount)")
                                .font(.caption2)
                        }
                    }
                }
            }
            .padding(8)
            .background(Color.tfSurface)
            .cornerRadius(10)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            if !suggestions.isEmpty {
                suggestionStrip
            }

            if !searchHistory.queries.isEmpty {
                historyStrip
            }
        }
        .padding(.bottom, 6)
        .onChange(of: searchText) { newValue in
            scheduleSuggestion(for: newValue)
        }
    }

    private var suggestionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { item in
                    Button(action: {
                        searchText = item
                        submitSearch()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "flame")
                                .font(.caption2)
                            Text(item)
                                .font(.footnote)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.tfSurface)
                        .cornerRadius(14)
                    }
                    .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var historyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("历史")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                ForEach(searchHistory.queries.prefix(12), id: \.self) { item in
                    Button(action: {
                        searchText = item
                        submitSearch()
                    }) {
                        Text(item)
                            .font(.footnote)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.tfSurfaceElevated)
                            .cornerRadius(14)
                    }
                    .foregroundColor(.primary)
                    .contextMenu {
                        Button("删除这条历史") { searchHistory.remove(item) }
                    }
                }

                Button("清空") { searchHistory.clear() }
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: 状态条

    private var errorBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text(browser.lastError ?? "")
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button("重试") { browser.reload() }
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tfSurface)
    }

    private var filterStatusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label("本轮 \(browser.lastScanTotal) 条", systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Label("屏蔽 \(browser.lastScanBlocked)", systemImage: "shield.slash")
                    .font(.caption)
                    .foregroundColor(browser.lastScanBlocked > 0 ? .red : .secondary)

                Spacer()

                if browser.sessionBlocked > 0 {
                    Button("清空标记") { browser.clearPageMarks() }
                        .font(.caption)
                }
            }

            Text(browser.reasonSummary)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tfSurface)
    }

    // MARK: 行为

    private func submitSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        browser.searchState.query = trimmed
        searchHistory.add(trimmed)
        suggestions = []
        browser.performSearch()
    }

    private func scheduleSuggestion(for text: String) {
        suggestionWorkItem?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else {
            suggestions = []
            return
        }
        let workItem = DispatchWorkItem { [trimmed] in
            SuggestService.shared.suggestions(for: trimmed) { results in
                if trimmed == searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
                    suggestions = Array(results.prefix(10))
                }
            }
        }
        suggestionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
}

// MARK: - 筛选面板

struct SearchFilterSheet: View {

    @Binding var state: SearchFilterState
    var onApply: () -> Void

    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("排序")) {
                    Picker("排序", selection: $state.sort) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }

                Section(header: Text("类型")) {
                    Picker("类型", selection: $state.type) {
                        ForEach(TypeOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }

                Section(header: Text("上传时间")) {
                    Picker("上传时间", selection: $state.date) {
                        ForEach(DateOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }

                Section(header: Text("时长")) {
                    Picker("时长", selection: $state.duration) {
                        ForEach(DurationOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }

                Section(footer: Text("筛选条件会编码成 YouTube 的 sp 参数，四个维度可以同时叠加生效。")) {
                    Button("重置全部筛选") {
                        let query = state.query
                        state = SearchFilterState()
                        state.query = query
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationBarTitle("搜索筛选", displayMode: .inline)
            .navigationBarItems(
                leading: Button("取消") { presentationMode.wrappedValue.dismiss() },
                trailing: Button("应用") {
                    presentationMode.wrappedValue.dismiss()
                    onApply()
                }
                .font(.body.weight(.semibold))
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
