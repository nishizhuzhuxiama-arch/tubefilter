import SwiftUI

struct RootView: View {

    @EnvironmentObject private var store: SettingsStore

    @State private var selection: Int = 0
    @State private var banner: BannerMessage?

    var body: some View {
        TabView(selection: $selection) {
            BrowseView()
                .tabItem { Label("浏览", systemImage: "play.rectangle") }
                .tag(0)

            LocalFeedView()
                .tabItem { Label("本地流", systemImage: "internaldrive") }
                .tag(1)

            BlockCenterView()
                .tabItem { Label("屏蔽中心", systemImage: "shield.lefthalf.filled") }
                .tag(2)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .alert(item: $banner) { message in
            Alert(
                title: Text("提示"),
                message: Text(message.text),
                dismissButton: .default(Text("好"))
            )
        }
        .onReceive(store.$importMessage) { message in
            guard let message = message else { return }
            banner = BannerMessage(text: message)
            store.clearImportMessage()
        }
    }
}

/// 提示条内容。
///
/// 用独立类型而不是给 String 加全局 Identifiable 扩展，避免与其他模块产生协议一致性歧义。
struct BannerMessage: Identifiable {
    let id = UUID()
    let text: String
}
