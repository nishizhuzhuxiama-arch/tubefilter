import SwiftUI
import WebKit

// MARK: - 设置页

struct SettingsView: View {

    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var browser: BrowserController
    @EnvironmentObject private var localFeed: LocalFeedStore

    @State private var showClearDataConfirm = false
    @State private var showLocalClearConfirm = false

    var body: some View {
        NavigationView {
            Form {
                feedSection
                sessionSection
                playbackSection
                recordSection
                aboutSection
            }
            .navigationBarTitle("设置", displayMode: .inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .actionSheet(isPresented: $showClearDataConfirm) {
            ActionSheet(
                title: Text("清理网页数据？"),
                message: Text("会清空登录态 WebView 的 Cookie、缓存与本地存储。你当前的分区会重新加载一次。"),
                buttons: [
                    .destructive(Text("清理并重新加载")) { browser.clearWebsiteData() },
                    .cancel(Text("取消"))
                ]
            )
        }
        .actionSheet(isPresented: $showLocalClearConfirm) {
            ActionSheet(
                title: Text("清空本地流？"),
                message: Text("本地采集内容会被全部删除，规则与统计不受影响。"),
                buttons: [
                    .destructive(Text("清空")) { localFeed.clear() },
                    .cancel(Text("取消"))
                ]
            )
        }
    }

    // MARK: 信息流与推荐

    private var feedSection: some View {
        Section(
            header: Text("信息流与推荐"),
            footer: Text(feedFooter)
        ) {
            Picker("信息流模式", selection: $store.settings.feedMode) {
                ForEach(FeedMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(MenuPickerStyle())

            Text(store.settings.feedMode.subtitle)
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("强制桌面版用户代理", isOn: $store.settings.desktopUserAgent)

            Button("重新加载当前分区") {
                browser.applyFeedModeChange()
            }
        }
        .onChange(of: store.settings.feedMode) { _ in
            browser.applyFeedModeChange()
        }
    }

    private var feedFooter: String {
        switch store.settings.feedMode {
        case .mobileWeb:
            return "加载 m.youtube.com 移动版页面，观感更接近原生应用，页面结构较简单。"
        case .desktopWeb:
            return "加载 www.youtube.com，元素信息最完整，屏蔽规则的命中率最高。"
        case .local:
            return "完全不加载远端推荐，首页只展示本机采集并过滤后的内容。"
        case .hybrid:
            return "默认方案：加载桌面版页面并用本地引擎实时过滤，兼顾覆盖面与命中率。"
        }
    }

    // MARK: 会话

    private var sessionSection: some View {
        Section(
            header: Text("会话"),
            footer: Text("打开非登录态后，应用会切换到一个不写 Cookie、不落缓存的临时会话。这是对抗信息茧房最直接的一招：同一批内容，登录态和非登录态看到的推荐会明显不同，可以随时对比。")
        ) {
            Toggle("使用非登录态会话", isOn: $store.settings.loggedOutSession)

            if store.settings.loggedOutSession {
                Label("当前为临时会话，退出应用后痕迹不保留", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Label("当前为登录态会话", systemImage: "person.crop.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button("清理网页数据") {
                showClearDataConfirm = true
            }
            .foregroundColor(.red)
        }
        .onChange(of: store.settings.loggedOutSession) { _ in
            browser.applySessionChange()
        }
    }

    // MARK: 播放

    private var playbackSection: some View {
        Section(
            header: Text("播放"),
            footer: Text("播放由页面内的播放器完成，这部分的开关是通过注入脚本回写页面配置实现的。")
        ) {
            Toggle("允许自动播放", isOn: $store.settings.autoplayEnabled)
        }
        .onDisappear {
            browser.applyConfigToPage()
        }
    }

    // MARK: 记录

    private var recordSection: some View {
        Section(
            header: Text("记录"),
            footer: Text("关闭后只更新统计数字，不再逐条落盘，适合长期使用以控制占用。")
        ) {
            Toggle("保留屏蔽历史", isOn: $store.settings.keepHistory)

            Stepper(
                value: $store.settings.historyLimit,
                in: 50...5000,
                step: 50
            ) {
                Text("历史上限：\(store.settings.historyLimit) 条")
            }
            .disabled(!store.settings.keepHistory)

            Button("清空本地流") {
                showLocalClearConfirm = true
            }
            .foregroundColor(.red)
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section(
            header: Text("关于"),
            footer: Text("本应用是第三方 YouTube 前端，通过网页承载内容并在本机完成过滤，与 YouTube 官方无关。屏蔽规则、历史与统计全部存储在本机，不上传任何数据。")
        ) {
            infoRow("版本", AppInfo.version)
            infoRow("部署目标", "iOS 14.2 及以上")
            infoRow("语义引擎", SemanticVectorizer.shared.isEmbeddingAvailable ? "系统句向量可用" : "已降级为本地 n-gram")
            infoRow("规则总数", "\(store.settings.rules.count)")
            infoRow("本地流条目", "\(localFeed.items.count)")
            infoRow("当前分区", browser.activeTab.title)
            infoRow("页面类型", browser.sourceLabel)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
