import Foundation

/// 本地流：把采集到的内容留在本地，用本地规则重新排序，不依赖任何远端推荐算法。
///
/// 这是「本地模式」与「防信息茧房」的数据基础：网页只负责提供原料，
/// 排序与取舍完全发生在设备上。
final class LocalFeedStore: ObservableObject {

    @Published private(set) var items: [LocalFeedItem] = []

    private let fileURL: URL
    private let limit: Int
    private var pendingSave = false

    init(limit: Int = 600) {
        self.limit = limit
        self.fileURL = StoragePaths.supportDirectory.appendingPathComponent("local-feed.json")
        self.items = Self.load(from: fileURL) ?? []
    }

    /// 把一次采集结果并入本地流，并按 videoID 去重、按最近出现时间排序。
    func ingest(_ snapshots: [FeedItemSnapshot], blocked: Set<String>) {
        guard !snapshots.isEmpty else { return }
        var index = Dictionary(items.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })

        for snapshot in snapshots {
            let blockedByRule = blocked.contains(snapshot.videoID)
            if var existing = index[snapshot.videoID] {
                existing.title = snapshot.title.isEmpty ? existing.title : snapshot.title
                existing.channelName = snapshot.channelName.isEmpty ? existing.channelName : snapshot.channelName
                existing.channelID = snapshot.channelID.isEmpty ? existing.channelID : snapshot.channelID
                existing.badges = snapshot.badges.isEmpty ? existing.badges : snapshot.badges
                existing.durationSeconds = snapshot.durationSeconds > 0 ? snapshot.durationSeconds : existing.durationSeconds
                existing.topics = snapshot.topics.isEmpty ? existing.topics : snapshot.topics
                existing.lastSeenAt = Date()
                existing.seenCount += 1
                existing.blockedByRule = blockedByRule
                index[snapshot.videoID] = existing
            } else {
                index[snapshot.videoID] = LocalFeedItem(snapshot: snapshot, blockedByRule: blockedByRule)
            }
        }

        var merged = Array(index.values)
        merged.sort { $0.lastSeenAt > $1.lastSeenAt }
        if merged.count > limit {
            merged = Array(merged.prefix(limit))
        }
        items = merged
        scheduleSave()
    }

    func clear() {
        items = []
        scheduleSave()
    }

    /// 供本地流页面使用：只保留未被屏蔽的内容。
    var visibleItems: [LocalFeedItem] {
        items.filter { !$0.blockedByRule }
    }

    var blockedCount: Int {
        items.filter { $0.blockedByRule }.count
    }

    // MARK: 持久化

    private func scheduleSave() {
        if pendingSave { return }
        pendingSave = true
        let snapshot = items
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) { [fileURL] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pendingSave = false
        }
    }

    private static func load(from url: URL) -> [LocalFeedItem]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([LocalFeedItem].self, from: data)
    }
}

/// 本地流中的一条内容。
struct LocalFeedItem: Identifiable, Codable, Equatable {
    var videoID: String
    var title: String
    var channelName: String
    var channelID: String
    var badges: [String]
    var durationSeconds: Int
    var topics: [String]
    var url: String
    var source: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    var seenCount: Int
    /// 最近一次判定结果，用于在本地流里标注为什么被屏蔽。
    var blockedByRule: Bool

    var id: String { videoID }

    var watchURL: URL? {
        if url.hasPrefix("http") { return URL(string: url) }
        if url.hasPrefix("/") { return URL(string: "https://www.youtube.com" + url) }
        return URL(string: "https://www.youtube.com/watch?v=" + videoID)
    }

    init(snapshot: FeedItemSnapshot, blockedByRule: Bool) {
        self.videoID = snapshot.videoID
        self.title = snapshot.title
        self.channelName = snapshot.channelName
        self.channelID = snapshot.channelID
        self.badges = snapshot.badges
        self.durationSeconds = snapshot.durationSeconds
        self.topics = snapshot.topics
        self.url = snapshot.url
        self.source = snapshot.source
        self.firstSeenAt = Date()
        self.lastSeenAt = Date()
        self.seenCount = 1
        self.blockedByRule = blockedByRule
    }
}

/// 页面类型，用于把「动态来源说明」展示给用户。
enum PageSource {
    static func label(for raw: String) -> String {
        switch raw {
        case "home": return "首页推荐"
        case "subscriptions": return "关注动态"
        case "trending": return "热榜"
        case "explore": return "探索"
        case "search": return "搜索结果"
        case "watch": return "播放页推荐"
        case "shorts": return "Shorts"
        case "channel": return "频道页"
        case "playlist": return "播放列表"
        default: return "其他来源"
        }
    }
}
