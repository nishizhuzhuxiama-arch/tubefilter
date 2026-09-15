import Foundation
import SwiftUI
import WebKit

/// 浏览控制器：持有 WKWebView，接收网页采集结果，跑过滤引擎，再把结论推回页面。
///
/// 单一 WebView 实例设计：四个浏览分区共用同一个 WebView，切换分区即导航。
/// 这样内存占用与真实 YouTube 应用一致，也避免了多实例互相争抢媒体会话。
final class BrowserController: NSObject, ObservableObject {

    // MARK: 对外状态

    @Published var pageType: String = "home"
    @Published var lastScanTotal: Int = 0
    @Published var lastScanBlocked: Int = 0
    @Published var sessionBlocked: Int = 0
    @Published var scanCount: Int = 0
    @Published var reasonSummary: String = ""
    @Published var isLoading: Bool = false
    @Published var progress: Double = 0
    @Published var currentURL: String = ""
    @Published var lastError: String?
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var activeTab: BrowseTab = .home
    @Published var searchState = SearchFilterState()

    var sourceLabel: String { PageSource.label(for: pageType) }

    // MARK: 依赖

    private let store: SettingsStore
    private let localFeed: LocalFeedStore
    private let engine = FilterEngine()

    // MARK: 内部

    private var webViews: [Bool: WKWebView] = [:]
    private var activeLoggedOut = false
    private var observations: [NSKeyValueObservation] = []
    private weak var hostView: UIView?
    private var didLoadInitialPage = false

    init(store: SettingsStore, localFeed: LocalFeedStore) {
        self.store = store
        self.localFeed = localFeed
        self.activeLoggedOut = store.settings.loggedOutSession
        super.init()
    }

    // MARK: 视图挂载

    /// 把当前生效的 WebView 挂到宿主视图上。切换登录态时会在这里换实例。
    func attach(to host: UIView) {
        hostView = host
        let webView = activeWebView
        if webView.superview !== host {
            webView.removeFromSuperview()
            webView.frame = host.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(webView)
            webView.frame = host.bounds
        }
    }

    var activeWebView: WKWebView {
        if let existing = webViews[activeLoggedOut] {
            return existing
        }
        let created = makeWebView(loggedOut: activeLoggedOut)
        webViews[activeLoggedOut] = created
        return created
    }

    // MARK: WebView 构建

    private func makeWebView(loggedOut: Bool) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 非登录态使用临时数据存储：不写 Cookie、不落地缓存，从根上切断个性化画像。
        configuration.websiteDataStore = loggedOut ? .nonPersistent() : .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let contentController = WKUserContentController()
        contentController.add(self, name: "tf")
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag

        installScripts(on: webView)
        observe(webView)
        loadInitialPage(in: webView)
        return webView
    }

    private func installScripts(on webView: WKWebView) {
        let contentController = webView.configuration.userContentController
        contentController.removeAllUserScripts()
        let script = WKUserScript(
            source: InjectedScript.source(configJSON: configJSON()),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(script)
    }

    private func observe(_ webView: WKWebView) {
        let keys: [KeyPath<WKWebView, Bool>] = [\WKWebView.canGoBack, \WKWebView.canGoForward]
        for keyPath in keys {
            let observation = webView.observe(keyPath, options: [.new]) { [weak self] view, _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.canGoBack = view.canGoBack
                    self.canGoForward = view.canGoForward
                }
            }
            observations.append(observation)
        }

        let loading = webView.observe(\WKWebView.isLoading, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.isLoading = view.isLoading }
        }
        observations.append(loading)

        let progress = webView.observe(\WKWebView.estimatedProgress, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.progress = view.estimatedProgress }
        }
        observations.append(progress)

        let url = webView.observe(\WKWebView.url, options: [.new]) { [weak self] view, _ in
            let value = view.url?.absoluteString ?? ""
            DispatchQueue.main.async { self?.currentURL = value }
        }
        observations.append(url)
    }

    // MARK: 配置

    private func configJSON() -> String {
        let filter = store.settings.filter
        let payload: [String: Any] = [
            "enabled": true,
            "removeAds": filter.removeAds,
            "removeWatchRecommendations": filter.removeWatchRecommendations,
            "removeComments": filter.removeComments,
            "removeHomeShelves": filter.removeHomeShelves,
            "blockShorts": filter.blockShorts,
            "showPlaceholder": filter.showBlockedPlaceholder
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// 设置变化后调用：先让当前页面立刻生效，再为后续导航重建脚本。
    func applyConfigToPage() {
        let webView = activeWebView
        let json = configJSON()
        webView.evaluateJavaScript("window.__tf_updateConfig && window.__tf_updateConfig(\(json));", completionHandler: nil)
        installScripts(on: webView)
    }

    // MARK: 导航

    private var host: String {
        switch store.settings.feedMode {
        case .mobileWeb:
            return "m.youtube.com"
        case .desktopWeb, .local, .hybrid:
            return "www.youtube.com"
        }
    }

    private var shouldForceDesktopUserAgent: Bool {
        if store.settings.desktopUserAgent { return true }
        return store.settings.feedMode == .hybrid
    }

    private func applyUserAgent(to webView: WKWebView) {
        if shouldForceDesktopUserAgent {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        } else {
            webView.customUserAgent = nil
        }
    }

    private func url(for path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        let normalized = path.hasPrefix("/") ? path : "/" + path
        return URL(string: "https://" + host + normalized)
    }

    func navigate(to path: String) {
        let webView = activeWebView
        applyUserAgent(to: webView)
        guard let target = url(for: path) else { return }
        lastError = nil
        webView.load(URLRequest(url: target))
    }

    private func loadInitialPage(in webView: WKWebView) {
        applyUserAgent(to: webView)
        let path = store.settings.feedMode == .local ? BrowseTab.home.path : activeTab.path
        guard let target = url(for: path) else { return }
        webView.load(URLRequest(url: target))
    }

    func loadInitialPageIfNeeded() {
        guard !didLoadInitialPage else { return }
        didLoadInitialPage = true
        navigateToActiveTab()
    }

    func navigateToActiveTab() {
        switch activeTab {
        case .search:
            navigate(to: SearchParamBuilder.searchPath(for: searchState))
        default:
            navigate(to: activeTab.path)
        }
    }

    func performSearch() {
        activeTab = .search
        navigateToActiveTab()
    }

    func select(tab: BrowseTab) {
        activeTab = tab
        navigateToActiveTab()
    }

    func goBack() {
        guard activeWebView.canGoBack else { return }
        activeWebView.goBack()
    }

    func goForward() {
        guard activeWebView.canGoForward else { return }
        activeWebView.goForward()
    }

    func reload() {
        activeWebView.reload()
    }

    func stopLoading() {
        activeWebView.stopLoading()
    }

    /// 重新扫描当前页面，把最新规则立即套用上去。
    func rescan() {
        activeWebView.evaluateJavaScript("window.__tf_rescan && window.__tf_rescan();", completionHandler: nil)
    }

    /// 清空页面上的屏蔽标记，用于核对某条规则是否误伤。
    func clearPageMarks() {
        activeWebView.evaluateJavaScript("window.__tf_clearVerdicts && window.__tf_clearVerdicts();", completionHandler: nil)
    }

    // MARK: 模式与登录态切换

    func applyFeedModeChange() {
        let webView = activeWebView
        installScripts(on: webView)
        navigateToActiveTab()
    }

    /// 切换登录态需要换用不同的数据存储，因此整体替换 WebView 实例。
    func applySessionChange() {
        let desired = store.settings.loggedOutSession
        guard desired != activeLoggedOut else { return }

        if let current = webViews[activeLoggedOut] {
            current.removeFromSuperview()
        }
        activeLoggedOut = desired

        let replacement = activeWebView
        if let host = hostView {
            attach(to: host)
        }
        applyUserAgent(to: replacement)
        sessionBlocked = 0
        navigateToActiveTab()
    }

    /// 清空网页侧的全部本地数据（登录态实例才会累积数据）。
    func clearWebsiteData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            DispatchQueue.main.async {
                self.reload()
            }
        }
    }

    // MARK: 采集结果处理

    private func handleItems(_ body: [String: Any]) {
        guard let rawItems = body["items"] as? [[String: Any]] else { return }
        let snapshots = rawItems.compactMap { FeedItemSnapshot(json: $0) }
        guard !snapshots.isEmpty else { return }

        if let pageType = body["pageType"] as? String, !pageType.isEmpty {
            self.pageType = pageType
        }

        let settings = store.settings
        let verdicts = engine.evaluate(items: snapshots, settings: settings)

        store.record(verdicts: verdicts, items: snapshots)

        let blockedIDs = Set(verdicts.filter { $0.blocked }.map { $0.videoID })
        localFeed.ingest(snapshots, blocked: blockedIDs)

        lastScanTotal = snapshots.count
        lastScanBlocked = blockedIDs.count
        sessionBlocked += blockedIDs.count
        scanCount += 1
        reasonSummary = Self.summarize(verdicts)

        pushVerdicts(verdicts, snapshots: snapshots)
    }

    private func pushVerdicts(_ verdicts: [FilterVerdict], snapshots: [FeedItemSnapshot]) {
        let filter = store.settings.filter
        let encoded: [[String: Any]] = verdicts.map { verdict in
            [
                "videoID": verdict.videoID,
                "blocked": verdict.blocked,
                "reason": verdict.reason?.rawValue ?? "",
                "reasonTitle": verdict.reason?.title ?? "",
                "detail": verdict.detail
            ]
        }
        let payload: [String: Any] = [
            "verdicts": encoded,
            "showPlaceholder": filter.showBlockedPlaceholder,
            "removeAds": filter.removeAds,
            "removeWatchRecommendations": filter.removeWatchRecommendations,
            "removeComments": filter.removeComments,
            "removeHomeShelves": filter.removeHomeShelves,
            "blockShorts": filter.blockShorts
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        activeWebView.evaluateJavaScript("window.__tf_apply && window.__tf_apply(\(json));", completionHandler: nil)
    }

    private static func summarize(_ verdicts: [FilterVerdict]) -> String {
        var counts: [FilterReason: Int] = [:]
        for verdict in verdicts where verdict.blocked {
            guard let reason = verdict.reason else { continue }
            counts[reason] = (counts[reason] ?? 0) + 1
        }
        guard !counts.isEmpty else { return "本次扫描未命中任何规则" }
        let parts = counts
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key.title) \($0.value)" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 消息桥

extension BrowserController: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "tf", let body = message.body as? [String: Any] else { return }
        guard let type = body["type"] as? String else { return }

        switch type {
        case "items":
            handleItems(body)
        case "page", "ready":
            if let pageType = body["pageType"] as? String, !pageType.isEmpty {
                pageType_apply(pageType)
            }
            if type == "ready" {
                rescan()
            }
        default:
            break
        }
    }

    private func pageType_apply(_ value: String) {
        if Thread.isMainThread {
            pageType = value
        } else {
            DispatchQueue.main.async { self.pageType = value }
        }
    }
}

// MARK: - 导航

extension BrowserController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastError = nil
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        rescan()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        lastError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "file" {
            decisionHandler(.allow)
            return
        }
        // 非网页协议交给系统处理，避免点击后卡死。
        decisionHandler(.cancel)
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}

// MARK: - 新窗口

extension BrowserController: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // target=_blank 一律在当前 WebView 内打开，保证过滤管线不中断。
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - SwiftUI 容器

/// 承载共享 WebView 的 SwiftUI 容器。
struct WebViewContainer: UIViewRepresentable {

    @ObservedObject var controller: BrowserController

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = UIColor.systemBackground
        controller.attach(to: host)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.attach(to: uiView)
    }
}
