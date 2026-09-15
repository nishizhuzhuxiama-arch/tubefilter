import Foundation
import Combine

// MARK: - 信息流模式

/// 首页推荐的四档模式，对应「Web / iOS / 本地 / 混合」。
enum FeedMode: String, Codable, CaseIterable, Identifiable {
    /// 移动网页版（m.youtube.com），最接近 iOS 原生观感。
    case mobileWeb
    /// 桌面网页版（www.youtube.com），信息最完整，适合配合过滤使用。
    case desktopWeb
    /// 本地流：把采集到的内容留在本地，用本地规则重新排序与过滤。
    case local
    /// 混合：网页流照常加载，本地引擎在渲染前完成过滤。
    case hybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mobileWeb: return "iOS 网页"
        case .desktopWeb: return "Web 网页"
        case .local: return "本地流"
        case .hybrid: return "混合"
        }
    }

    var subtitle: String {
        switch self {
        case .mobileWeb: return "加载 m.youtube.com，观感接近原生"
        case .desktopWeb: return "加载 www.youtube.com，信息最完整"
        case .local: return "只用本地已采集内容，完全离线排序"
        case .hybrid: return "网页加载 + 本地引擎实时过滤"
        }
    }

    var systemImage: String {
        switch self {
        case .mobileWeb: return "iphone"
        case .desktopWeb: return "safari"
        case .local: return "internaldrive"
        case .hybrid: return "square.stack.3d.up"
        }
    }
}

// MARK: - 过滤偏好

/// 过滤行为开关。与规则列表分开存储，便于单独导出/重置。
struct FilterSettings: Codable, Equatable {
    // 内容类型
    var blockShorts: Bool = false
    var blockLive: Bool = false
    var blockUpcoming: Bool = false
    /// 屏蔽付费内容：会员专属视频、频道会员内容、Premium 专属。
    var blockMemberOnly: Bool = false

    // 页面清理
    var removeAds: Bool = true
    /// 反向屏蔽：移除「接下来播放」与推荐墙，打断无限下滑。
    var removeWatchPageRecommendations: Bool = true
    var removeHomeShelves: Bool = false
    var removeComments: Bool = false

    // 质量过滤
    var qualityFilterEnabled: Bool = false
    var qualityMinDurationSeconds: Int = 0
    var qualityBlockClickbait: Bool = false
    var qualityMaxTitleLength: Int = 0

    // 语义屏蔽
    var semanticEnabled: Bool = true
    /// 余弦相似度阈值，越高越严格。
    var semanticThreshold: Double = 0.66

    // 展示
    var showBlockedPlaceholder: Bool = true

    static let `default` = FilterSettings()
}

// MARK: - 应用设置

struct AppSettings: Codable, Equatable {
    var rules: [BlockRule] = []
    var filter: FilterSettings = .default
    var feedMode: FeedMode = .hybrid
    /// 非登录态：使用临时数据存储，不带 Cookie，真正跳出个性化推荐的茧房。
    var loggedOutSession: Bool = false
    var desktopUserAgent: Bool = false
    var autoplayEnabled: Bool = false
    var keepHistory: Bool = true
    var historyLimit: Int = 800

    static let `default` = AppSettings()

    /// 按类别分组，界面直接使用。
    func rules(of kind: RuleKind) -> [BlockRule] {
        rules.filter { $0.kind == kind }
    }
}

// MARK: - 存储

enum StoragePaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TubeFilter", isDirectory: true)
        ensure(dir)
        return dir
    }

    static var documentsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TubeFilter", isDirectory: true)
        ensure(dir)
        return dir
    }

    static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var statsFile: URL { supportDirectory.appendingPathComponent("stats.json") }
    static var historyFile: URL { supportDirectory.appendingPathComponent("history.json") }

    private static func ensure(_ dir: URL) {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - 设置中心

/// 全局设置与规则仓库。所有界面通过 `@EnvironmentObject` 访问。
final class SettingsStore: ObservableObject {

    @Published var settings: AppSettings {
        didSet { if settings != oldValue { scheduleSave() } }
    }

    @Published private(set) var stats: FilterStats = FilterStats()
    @Published private(set) var history: [BlockHistoryEntry] = []

    /// 导入结果提示，界面读取后需调用 `clearImportMessage()`。
    @Published var importMessage: String?

    private let queue = DispatchQueue(label: "com.watt.tubefilter.settings", qos: .utility)
    private var pendingSave = false

    init() {
        self.settings = Self.load(AppSettings.self, from: StoragePaths.settingsFile) ?? .default
        self.stats = Self.load(FilterStats.self, from: StoragePaths.statsFile) ?? FilterStats()
        self.history = Self.load([BlockHistoryEntry].self, from: StoragePaths.historyFile) ?? []
        if settings.rules.isEmpty {
            settings.rules = SampleRules.builtIn()
        }
    }

    // MARK: 持久化

    private func scheduleSave() {
        if pendingSave { return }
        pendingSave = true
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            self.pendingSave = false
            self.saveNow()
        }
    }

    func saveNow() {
        Self.write(settings, to: StoragePaths.settingsFile)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: 规则增删改

    func addRule(_ rule: BlockRule) {
        let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        guard !settings.rules.contains(where: {
            $0.kind == rule.kind && $0.pattern == pattern && $0.matchMode == rule.matchMode
        }) else {
            importMessage = "规则已存在：\(pattern)"
            return
        }
        var normalized = rule
        normalized.pattern = pattern
        settings.rules.append(normalized)
    }

    func updateRule(_ rule: BlockRule) {
        guard let index = settings.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        settings.rules[index] = rule
    }

    func removeRules(_ kind: RuleKind, at offsets: IndexSet) {
        var list = settings.rules(of: kind)
        list.remove(atOffsets: offsets)
        let keepIDs = Set(list.map { $0.id })
        settings.rules = settings.rules.filter { $0.kind != kind || keepIDs.contains($0.id) }
    }

    func removeRule(id: UUID) {
        settings.rules.removeAll { $0.id == id }
    }

    func toggleRule(id: UUID) {
        guard let index = settings.rules.firstIndex(where: { $0.id == id }) else { return }
        settings.rules[index].enabled.toggle()
    }

    func clearRules(_ kind: RuleKind) {
        settings.rules.removeAll { $0.kind == kind }
    }

    /// 统计命中次数，供规则列表按热度排序。
    func bumpHitCounts(for rules: [UUID]) {
        guard !rules.isEmpty else { return }
        let idSet = Set(rules)
        for index in settings.rules.indices where idSet.contains(settings.rules[index].id) {
            settings.rules[index].hitCount += 1
        }
    }

    // MARK: 运行期记录

    /// 记录一次过滤结果：更新统计与屏蔽历史。
    func record(verdicts: [FilterVerdict], items: [FeedItemSnapshot]) {
        guard !verdicts.isEmpty else { return }

        var newStats = stats
        newStats.record(verdicts)
        stats = newStats

        let hitRuleIDs = verdicts.compactMap { $0.ruleID }
        bumpHitCounts(for: hitRuleIDs)

        guard settings.keepHistory else { return }
        let byID = Dictionary(items.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [BlockHistoryEntry] = []
        for verdict in verdicts where verdict.blocked {
            let item = byID[verdict.videoID]
            entries.append(BlockHistoryEntry(
                videoID: verdict.videoID,
                title: item?.title ?? "",
                channelName: item?.channelName ?? "",
                reason: verdict.reason ?? .keyword,
                detail: verdict.detail,
                rulePattern: item == nil ? "" : rulePattern(for: verdict.ruleID)
            ))
        }
        guard !entries.isEmpty else { return }
        var merged = entries + history
        let limit = max(50, settings.historyLimit)
        if merged.count > limit {
            merged = Array(merged.prefix(limit))
        }
        history = merged
        Self.write(history, to: StoragePaths.historyFile)
        Self.write(stats, to: StoragePaths.statsFile)
    }

    private func rulePattern(for id: UUID?) -> String {
        guard let id = id else { return "" }
        return settings.rules.first(where: { $0.id == id })?.pattern ?? ""
    }

    func clearHistory() {
        history = []
        Self.write(history, to: StoragePaths.historyFile)
    }

    func resetStats() {
        stats.reset()
        Self.write(stats, to: StoragePaths.statsFile)
    }

    func resetHitCounts() {
        for index in settings.rules.indices {
            settings.rules[index].hitCount = 0
        }
    }

    func clearImportMessage() {
        importMessage = nil
    }

    // MARK: 导入导出

    /// 导出为文件，返回可分享的 URL。
    @discardableResult
    func exportRules(includeSettings: Bool) -> URL? {
        let bundle = RuleBundle(rules: settings.rules, settings: includeSettings ? settings.filter : nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundle) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "tubefilter-rules-\(formatter.string(from: Date())).json"
        let url = StoragePaths.documentsDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 从文件导入。兼容三种格式：RuleBundle、裸规则数组、以及单条规则对象。
    func importRules(from url: URL, replace: Bool) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            importMessage = "读取失败：无法打开该文件"
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var imported: [BlockRule] = []
        var importedFilter: FilterSettings?

        if let bundle = try? decoder.decode(RuleBundle.self, from: data) {
            imported = bundle.rules
            importedFilter = bundle.settings
        } else if let list = try? decoder.decode([BlockRule].self, from: data) {
            imported = list
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // 兜底：从通用 JSON 中提取 patterns / blockedKeywords 之类的字段
            imported = Self.rulesFromLooseJSON(json)
        }

        guard !imported.isEmpty else {
            importMessage = "未在该文件中找到可用规则"
            return
        }

        var added = 0
        var skipped = 0
        var working: [BlockRule] = replace ? [] : settings.rules
        var seen = Set(working.map { "\($0.kind.rawValue)|\($0.matchMode.rawValue)|\($0.pattern)" })

        for rule in imported {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { skipped += 1; continue }
            let key = "\(rule.kind.rawValue)|\(rule.matchMode.rawValue)|\(pattern)"
            if seen.contains(key) { skipped += 1; continue }
            seen.insert(key)
            var fresh = rule
            fresh.pattern = pattern
            fresh.id = UUID()
            working.append(fresh)
            added += 1
        }

        settings.rules = working
        if replace, let filter = importedFilter {
            settings.filter = filter
        }
        importMessage = "导入完成：新增 \(added) 条，跳过重复 \(skipped) 条"
        saveNow()
    }

    /// 尝试从杂乱的第三方 JSON 中提取规则，提升跨应用迁移的成功率。
    private static func rulesFromLooseJSON(_ json: [String: Any]) -> [BlockRule] {
        var result: [BlockRule] = []
        let mappings: [(keys: [String], kind: RuleKind)] = [
            (["blockedKeywords", "keywords", "blockWords", "words", "blockedWords"], .keyword),
            (["blockedUsers", "users", "blockedChannels", "channels"], .channel),
            (["blockedTopics", "topics", "tags"], .topic),
            (["semanticKeywords", "nlpWords"], .semantic)
        ]
        for mapping in mappings {
            for key in mapping.keys {
                guard let raw = json[key] as? [Any] else { continue }
                for element in raw {
                    if let text = element as? String {
                        result.append(BlockRule(kind: mapping.kind, pattern: text))
                    } else if let object = element as? [String: Any] {
                        let text = (object["pattern"] as? String)
                            ?? (object["value"] as? String)
                            ?? (object["name"] as? String)
                            ?? ""
                        if !text.isEmpty {
                            result.append(BlockRule(kind: mapping.kind, pattern: text))
                        }
                    }
                }
            }
        }
        return result
    }

    func resetAllRules() {
        settings.rules = []
        saveNow()
    }

    func restoreSampleRules() {
        settings.rules = SampleRules.builtIn()
        saveNow()
    }
}

// MARK: - 内置示例规则

/// 首次启动时写入的种子规则，保证屏蔽系统开箱即用而不是空壳。
enum SampleRules {
    static func builtIn() -> [BlockRule] {
        [
            BlockRule(kind: .keyword, pattern: "低质", note: "示例：标题含低质标记"),
            BlockRule(kind: .keyword, pattern: "(?i)\\b(clickbait|subscribe now)\\b", matchMode: .regex, note: "示例：正则屏蔽英文标题党"),
            BlockRule(kind: .keyword, pattern: "震惊|必看|不看后悔|100%有效", matchMode: .regex, note: "示例：中文标题党正则"),
            BlockRule(kind: .semantic, pattern: "夸张标题诱导点击", note: "示例：语义相近即命中"),
            BlockRule(kind: .semantic, pattern: "纯广告带货推广", note: "示例：语义相近即命中"),
            BlockRule(kind: .channel, pattern: "示例频道", enabled: false, note: "示例：把频道名填进来即可生效"),
            BlockRule(kind: .topic, pattern: "Shorts", enabled: false, note: "示例：屏蔽话题标签")
        ]
    }
}
