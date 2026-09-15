import Foundation

// MARK: - 规则类型

/// 屏蔽系统的四大规则类别，对应「屏蔽词 / NLP 屏蔽词 / 屏蔽用户 / 屏蔽话题」。
enum RuleKind: String, Codable, CaseIterable, Identifiable {
    case keyword
    case semantic
    case channel
    case topic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyword: return "屏蔽词"
        case .semantic: return "NLP 屏蔽词"
        case .channel: return "屏蔽用户 / 频道"
        case .topic: return "屏蔽话题"
        }
    }

    var subtitle: String {
        switch self {
        case .keyword: return "支持纯文本与正则表达式"
        case .semantic: return "向量相似度匹配，命中语义相近内容"
        case .channel: return "命中频道名或频道 ID，含评论作者"
        case .topic: return "命中话题标签、分区与视频标签"
        }
    }

    var systemImage: String {
        switch self {
        case .keyword: return "textformat.abc"
        case .semantic: return "wand.and.stars"
        case .channel: return "person.crop.circle.badge.xmark"
        case .topic: return "tag"
        }
    }

    /// 该类别允许的匹配方式。
    var allowedModes: [MatchMode] {
        switch self {
        case .keyword: return [.literal, .regex]
        case .semantic: return [.similarity]
        case .channel: return [.literal, .regex]
        case .topic: return [.literal, .regex]
        }
    }

    var defaultMode: MatchMode {
        switch self {
        case .keyword: return .literal
        case .semantic: return .similarity
        case .channel: return .literal
        case .topic: return .literal
        }
    }
}

/// 匹配方式。
enum MatchMode: String, Codable, CaseIterable, Identifiable {
    case literal
    case regex
    case similarity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .literal: return "纯文本"
        case .regex: return "正则"
        case .similarity: return "向量相似"
        }
    }
}

// MARK: - 规则

/// 一条屏蔽规则。
struct BlockRule: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: RuleKind
    var pattern: String
    var matchMode: MatchMode
    var caseSensitive: Bool
    var enabled: Bool
    var note: String
    var createdAt: Date
    var hitCount: Int

    init(
        id: UUID = UUID(),
        kind: RuleKind,
        pattern: String,
        matchMode: MatchMode? = nil,
        caseSensitive: Bool = false,
        enabled: Bool = true,
        note: String = "",
        createdAt: Date = Date(),
        hitCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.matchMode = matchMode ?? kind.defaultMode
        self.caseSensitive = caseSensitive
        self.enabled = enabled
        self.note = note
        self.createdAt = createdAt
        self.hitCount = hitCount
    }

    /// 正则是否可编译，用于在编辑界面即时提示语法错误。
    var regexIsValid: Bool {
        guard matchMode == .regex else { return true }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }
}

// MARK: - 信息流条目快照

/// 从网页中采集出来的一条内容，是过滤引擎的唯一输入。
struct FeedItemSnapshot: Codable, Equatable, Identifiable {
    var videoID: String
    var title: String
    var channelName: String
    var channelID: String
    var badges: [String]
    var durationSeconds: Int
    var viewCountText: String
    var topics: [String]
    var url: String
    var source: String

    var id: String { videoID }

    init(
        videoID: String,
        title: String = "",
        channelName: String = "",
        channelID: String = "",
        badges: [String] = [],
        durationSeconds: Int = 0,
        viewCountText: String = "",
        topics: [String] = [],
        url: String = "",
        source: String = ""
    ) {
        self.videoID = videoID
        self.title = title
        self.channelName = channelName
        self.channelID = channelID
        self.badges = badges
        self.durationSeconds = durationSeconds
        self.viewCountText = viewCountText
        self.topics = topics
        self.url = url
        self.source = source
    }

    /// 从 JS 桥传来的字典构造。字段缺失时使用空值，只有 videoID 是必需的。
    init?(json: [String: Any]) {
        guard let rawID = json["videoID"] as? String else { return nil }
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.init(
            videoID: trimmed,
            title: Self.string(json["title"]),
            channelName: Self.string(json["channelName"]),
            channelID: Self.string(json["channelID"]),
            badges: json["badges"] as? [String] ?? [],
            durationSeconds: Self.int(json["durationSeconds"]),
            viewCountText: Self.string(json["viewCountText"]),
            topics: json["topics"] as? [String] ?? [],
            url: Self.string(json["url"]),
            source: Self.string(json["source"])
        )
    }

    private static func string(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) ?? 0 }
        return 0
    }

    /// 供 JS 使用的紧凑字典（只回传屏蔽所需的最小字段）。
    var verdictJSON: [String: Any] {
        [
            "videoID": videoID,
            "blocked": true
        ]
    }
}

// MARK: - 过滤原因

enum FilterReason: String, Codable, CaseIterable {
    case ad
    case keyword
    case regex
    case semantic
    case channel
    case topic
    case memberOnly
    case shorts
    case live
    case upcoming
    case quality

    var title: String {
        switch self {
        case .ad: return "广告 / 推广"
        case .keyword: return "屏蔽词"
        case .regex: return "正则屏蔽"
        case .semantic: return "NLP 语义屏蔽"
        case .channel: return "屏蔽频道"
        case .topic: return "屏蔽话题"
        case .memberOnly: return "付费 / 会员内容"
        case .shorts: return "Shorts 短视频"
        case .live: return "直播"
        case .upcoming: return "首播 / 预告"
        case .quality: return "质量过滤"
        }
    }
}

/// 单条内容的过滤结论。
struct FilterVerdict: Equatable {
    var videoID: String
    var blocked: Bool
    var reason: FilterReason?
    var detail: String
    var ruleID: UUID?

    static func allow(_ videoID: String) -> FilterVerdict {
        FilterVerdict(videoID: videoID, blocked: false, reason: nil, detail: "", ruleID: nil)
    }

    static func block(_ videoID: String, reason: FilterReason, detail: String, ruleID: UUID? = nil) -> FilterVerdict {
        FilterVerdict(videoID: videoID, blocked: true, reason: reason, detail: detail, ruleID: ruleID)
    }
}

// MARK: - 屏蔽历史与统计

struct BlockHistoryEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var videoID: String
    var title: String
    var channelName: String
    var reason: FilterReason
    var detail: String
    var rulePattern: String

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        videoID: String,
        title: String,
        channelName: String,
        reason: FilterReason,
        detail: String,
        rulePattern: String = ""
    ) {
        self.id = id
        self.date = date
        self.videoID = videoID
        self.title = title
        self.channelName = channelName
        self.reason = reason
        self.detail = detail
        self.rulePattern = rulePattern
    }
}

/// 过滤统计。`byReason` 用原始值字符串做 key，保证 Codable 稳定。
struct FilterStats: Codable, Equatable {
    var totalScanned: Int = 0
    var totalBlocked: Int = 0
    var byReason: [String: Int] = [:]

    var blockRate: Double {
        guard totalScanned > 0 else { return 0 }
        return Double(totalBlocked) / Double(totalScanned)
    }

    mutating func record(_ verdicts: [FilterVerdict]) {
        totalScanned += verdicts.count
        for verdict in verdicts where verdict.blocked {
            totalBlocked += 1
            let key = (verdict.reason ?? .keyword).rawValue
            byReason[key] = (byReason[key] ?? 0) + 1
        }
    }

    mutating func reset() {
        totalScanned = 0
        totalBlocked = 0
        byReason = [:]
    }

    /// 按命中次数降序排列的原因列表。
    ///
    /// 注意：Swift 不支持指向元组成员的 key path，因此这里用具名结构体而不是元组，
    /// 否则界面里的 ForEach 无法编译。
    var rankedReasons: [ReasonCount] {
        byReason
            .compactMap { key, value -> ReasonCount? in
                guard let reason = FilterReason(rawValue: key) else { return nil }
                return ReasonCount(reason: reason, count: value)
            }
            .sorted { $0.count > $1.count }
    }
}

/// 过滤原因与命中次数的组合。
struct ReasonCount: Identifiable, Equatable {
    var reason: FilterReason
    var count: Int

    var id: String { reason.rawValue }
}

// MARK: - 规则文件（导入导出）

/// 导出/导入用的顶层结构，带版本号，便于跨设备迁移与后续兼容。
struct RuleBundle: Codable {
    var schema: String
    var version: Int
    var exportedAt: Date
    var appVersion: String
    var rules: [BlockRule]
    /// 导出时可选带上设置项，方便整机迁移。
    var settings: FilterSettings?

    static let currentSchema = "com.watt.tubefilter.rules"
    static let currentVersion = 1

    init(rules: [BlockRule], settings: FilterSettings?) {
        self.schema = RuleBundle.currentSchema
        self.version = RuleBundle.currentVersion
        self.exportedAt = Date()
        self.appVersion = AppInfo.version
        self.rules = rules
        self.settings = settings
    }
}

enum AppInfo {
    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short)(\(build))"
    }
}
