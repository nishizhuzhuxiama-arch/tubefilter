import SwiftUI

@main
struct TubeFilterApp: App {

    @StateObject private var store: SettingsStore
    @StateObject private var localFeed: LocalFeedStore
    @StateObject private var browser: BrowserController

    init() {
        let settingsStore = SettingsStore()
        let feedStore = LocalFeedStore()
        _store = StateObject(wrappedValue: settingsStore)
        _localFeed = StateObject(wrappedValue: feedStore)
        _browser = StateObject(wrappedValue: BrowserController(store: settingsStore, localFeed: feedStore))
        // 首次启动会把种子规则落盘，保证屏蔽系统开箱可用。
        settingsStore.saveNow()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(localFeed)
                .environmentObject(browser)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    store.saveNow()
                }
        }
    }
}
