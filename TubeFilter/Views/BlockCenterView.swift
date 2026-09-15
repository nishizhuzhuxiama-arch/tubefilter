import SwiftUI
import UniformTypeIdentifiers

// MARK: - 屏蔽中心

struct BlockCenterView: View {

    @EnvironmentObject private var store: SettingsStore

    @State private var exportURL: URL?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var replaceOnImport = false
    @State private var importerError: String?
    @State private var showResetConfirm = false

    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text("规则"),
                    footer: Text("四类规则全部在设备本地即时生效，改完不需要重新加载页面，点浏览页的盾牌图标即可重扫。")
                ) {
                    ForEach(RuleKind.allCases) { kind in
                        NavigationLink(destination: RuleEditorView(kind: kind)) {
                            ruleRow(kind)
                        }
                    }
                }

                Section(header: Text("过滤开关")) {
                    NavigationLink(destination: ContentFilterView()) {
                        Label("内容类型与页面清理", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink(destination: SemanticFilterView()) {
                        Label("语义屏蔽与质量过滤", systemImage: "wand.and.stars")
                    }
                }

                Section(header: Text("统计与记录")) {
                    NavigationLink(destination: FilterStatsView()) {
                        Label("过滤统计", systemImage: "chart.bar")
                    }
                    NavigationLink(destination: BlockHistoryView()) {
                        Label("屏蔽历史", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section(
                    header: Text("规则迁移"),
                    footer: Text("导出的是标准 JSON，可在任意设备导入，用于换机迁移或备份。导入时兼容其他客户端导出的关键词列表。")
                ) {
                    Button("导出全部规则") {
                        if let url = store.exportRules(includeSettings: true) {
                            exportURL = url
                            showExporter = true
                        }
                    }
                    Button("导入规则（合并到现有）") {
                        replaceOnImport = false
                        showImporter = true
                    }
                    Button("导入规则（替换全部）") {
                        replaceOnImport = true
                        showImporter = true
                    }
                    Button("恢复示例规则") {
                        store.restoreSampleRules()
                    }
                    Button("清空全部规则") {
                        showResetConfirm = true
                    }
                    .foregroundColor(.red)
                }

                Section(header: Text("当前规模")) {
                    infoRow("规则总数", "\(store.settings.rules.count)")
                    infoRow("启用中", "\(store.settings.rules.filter { $0.enabled }.count)")
                    infoRow("累计命中", "\(store.settings.rules.reduce(0) { $0 + $1.hitCount })")
                }
            }
            .navigationBarTitle("屏蔽中心", displayMode: .inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showExporter) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType.json, UTType.text, UTType.data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(item: Binding(
            get: { importerError.map { BannerMessage(text: $0) } },
            set: { if $0 == nil { importerError = nil } }
        )) { message in
            Alert(title: Text("导入失败"), message: Text(message.text), dismissButton: .default(Text("好")))
        }
        .actionSheet(isPresented: $showResetConfirm) {
            ActionSheet(
                title: Text("清空全部规则？"),
                message: Text("这会删除四类规则的全部条目，且无法撤销。建议先导出备份。"),
                buttons: [
                    .destructive(Text("清空")) { store.resetAllRules() },
                    .cancel(Text("取消"))
                ]
            )
        }
    }

    private func ruleRow(_ kind: RuleKind) -> some View {
        let rules = store.settings.rules(of: kind)
        let hits = rules.reduce(0) { $0 + $1.hitCount }
        return HStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text("\(rules.count) 条 · 命中 \(hits)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            store.importRules(from: url, replace: replaceOnImport)
        case .failure(let error):
            importerError = error.localizedDescription
        }
    }
}

// MARK: - 分享面板

struct ShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

// MARK: - 内容类型与页面清理

struct ContentFilterView: View {

    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var browser: BrowserController

    var body: some View {
        Form {
            Section(
                header: Text("内容类型"),
                footer: Text("命中的内容会从页面上移除，并按对应原因计入过滤统计。")
            ) {
                Toggle("屏蔽付费内容（会员专属 / Premium）", isOn: $store.settings.filter.blockMemberOnly)
                Toggle("屏蔽 Shorts 短视频", isOn: $store.settings.filter.blockShorts)
                Toggle("屏蔽直播", isOn: $store.settings.filter.blockLive)
                Toggle("屏蔽首播 / 预告", isOn: $store.settings.filter.blockUpcoming)
            }

            Section(
                header: Text("页面清理"),
                footer: Text("「反向屏蔽」指移除播放页的推荐墙与播放结束推荐，从结构上打断无限下滑的连锁推荐，而不是逐条过滤。")
            ) {
                Toggle("移除广告与推广位", isOn: $store.settings.filter.removeAds)
                Toggle("反向屏蔽：移除播放页推荐墙", isOn: $store.settings.filter.removeWatchPageRecommendations)
                Toggle("移除首页 Shorts 货架", isOn: $store.settings.filter.removeHomeShelves)
                Toggle("移除评论区", isOn: $store.settings.filter.removeComments)
            }

            Section(
                header: Text("展示"),
                footer: Text("打开占位后，被屏蔽的内容会折叠成一条说明条并写明命中了哪条规则，方便你判断规则是不是写得太宽。关掉则直接消失。")
            ) {
                Toggle("显示被屏蔽项占位", isOn: $store.settings.filter.showBlockedPlaceholder)
            }
        }
        .navigationBarTitle("内容类型与页面清理", displayMode: .inline)
        .onDisappear {
            browser.applyConfigToPage()
        }
    }
}

// MARK: - 语义与质量过滤

struct SemanticFilterView: View {

    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var browser: BrowserController

    var body: some View {
        Form {
            Section(
                header: Text("语义引擎"),
                footer: Text(SemanticVectorizer.shared.backendDescription)
            ) {
                Toggle("启用 NLP 语义屏蔽", isOn: $store.settings.filter.semanticEnabled)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("相似度阈值")
                        Spacer()
                        Text("\(Int((store.settings.filter.semanticThreshold * 100).rounded()))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $store.settings.filter.semanticThreshold, in: 0.30...0.95, step: 0.01)
                    Text("阈值越高越严格。系统句向量与本地 n-gram 向量会自动换算阈值，无需分别设置。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                NavigationLink(destination: RuleEditorView(kind: .semantic)) {
                    HStack {
                        Text("管理语义参照词")
                        Spacer()
                        Text("\(store.settings.rules(of: .semantic).count) 条")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(
                header: Text("质量过滤"),
                footer: Text("质量过滤用标题特征与时长做启发式判断，不依赖远端评分。命中后按「质量过滤」计入统计。")
            ) {
                Toggle("启用质量过滤", isOn: $store.settings.filter.qualityFilterEnabled)
                Toggle("屏蔽标题党标题", isOn: $store.settings.filter.qualityBlockClickbait)

                Stepper(
                    value: $store.settings.filter.qualityMinDurationSeconds,
                    in: 0...7200,
                    step: 30
                ) {
                    Text(store.settings.filter.qualityMinDurationSeconds == 0
                        ? "最短时长：不限"
                        : "最短时长：\(store.settings.filter.qualityMinDurationSeconds) 秒")
                }

                Stepper(
                    value: $store.settings.filter.qualityMaxTitleLength,
                    in: 0...200,
                    step: 5
                ) {
                    Text(store.settings.filter.qualityMaxTitleLength == 0
                        ? "标题长度上限：不限"
                        : "标题长度上限：\(store.settings.filter.qualityMaxTitleLength) 字")
                }
            }
        }
        .navigationBarTitle("语义与质量过滤", displayMode: .inline)
        .onDisappear {
            browser.applyConfigToPage()
        }
    }
}
