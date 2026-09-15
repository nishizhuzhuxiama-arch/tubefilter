import Foundation

// MARK: - 浏览分区

enum BrowseTab: String, CaseIterable, Identifiable {
    case home
    case subscriptions
    case trending
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .subscriptions: return "关注"
        case .trending: return "热榜"
        case .search: return "搜索"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .subscriptions: return "rectangle.stack"
        case .trending: return "flame"
        case .search: return "magnifyingglass"
        }
    }

    /// 该分区在 YouTube 上的路径。
    var path: String {
        switch self {
        case .home: return "/"
        case .subscriptions: return "/feed/subscriptions"
        case .trending: return "/feed/trending"
        case .search: return "/results"
        }
    }

    /// 是否支持排序 / 类型 / 时间筛选。首页与关注页是固定信息流，不接受筛选参数。
    var supportsFilters: Bool {
        self == .search || self == .trending
    }
}

// MARK: - 筛选维度

enum SortOption: String, CaseIterable, Identifiable {
    case relevance
    case uploadDate
    case viewCount
    case rating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: return "相关度"
        case .uploadDate: return "最新"
        case .viewCount: return "播放量"
        case .rating: return "评分"
        }
    }

    /// 对应搜索参数 protobuf 的 sortBy 字段取值。
    var rawValueForParam: Int {
        switch self {
        case .relevance: return 0
        case .rating: return 1
        case .uploadDate: return 2
        case .viewCount: return 3
        }
    }
}

enum TypeOption: String, CaseIterable, Identifiable {
    case any
    case video
    case channel
    case playlist
    case movie

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "全部"
        case .video: return "视频"
        case .channel: return "频道"
        case .playlist: return "播放列表"
        case .movie: return "电影"
        }
    }

    var rawValueForParam: Int {
        switch self {
        case .any: return 0
        case .video: return 1
        case .channel: return 2
        case .playlist: return 3
        case .movie: return 4
        }
    }
}

enum DateOption: String, CaseIterable, Identifiable {
    case any
    case hour
    case today
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "不限"
        case .hour: return "1 小时内"
        case .today: return "今天"
        case .week: return "本周"
        case .month: return "本月"
        case .year: return "今年"
        }
    }

    var rawValueForParam: Int {
        switch self {
        case .any: return 0
        case .hour: return 1
        case .today: return 2
        case .week: return 3
        case .month: return 4
        case .year: return 5
        }
    }
}

enum DurationOption: String, CaseIterable, Identifiable {
    case any
    case short
    case medium
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "不限"
        case .short: return "4 分钟以内"
        case .medium: return "4-20 分钟"
        case .long: return "20 分钟以上"
        }
    }

    var rawValueForParam: Int {
        switch self {
        case .any: return 0
        case .short: return 1
        case .long: return 2
        case .medium: return 3
        }
    }
}

/// 搜索筛选状态。
struct SearchFilterState: Equatable {
    var query: String = ""
    var sort: SortOption = .relevance
    var type: TypeOption = .any
    var date: DateOption = .any
    var duration: DurationOption = .any

    var isDefault: Bool {
        sort == .relevance && type == .any && date == .any && duration == .any
    }

    var activeCount: Int {
        var count = 0
        if sort != .relevance { count += 1 }
        if type != .any { count += 1 }
        if date != .any { count += 1 }
        if duration != .any { count += 1 }
        return count
    }
}

// MARK: - 搜索参数构造

/// 把筛选条件编码成 YouTube 的 `sp` 查询参数。
///
/// `sp` 是 protobuf 的 base64 编码，结构为：
///
///     message Params {
///       optional int32 sortBy  = 1;   // 0 相关度 / 1 评分 / 2 最新 / 3 播放量
///       optional Filters filters = 2;
///     }
///     message Filters {
///       optional int32 uploadDate = 1;  // 1 小时 / 2 今天 / 3 本周 / 4 本月 / 5 今年
///       optional int32 type       = 2;  // 1 视频 / 2 频道 / 3 播放列表 / 4 电影
///       optional int32 duration   = 3;  // 1 短 / 2 长 / 3 中
///     }
///
/// 手写常量只能一次用一组筛选，这里直接编码 protobuf，因此四个维度可以任意叠加。
enum SearchParamBuilder {

    static func encodedParameter(for state: SearchFilterState) -> String? {
        var filters: [UInt8] = []
        if state.date.rawValueForParam > 0 {
            filters += varintField(1, state.date.rawValueForParam)
        }
        if state.type.rawValueForParam > 0 {
            filters += varintField(2, state.type.rawValueForParam)
        }
        if state.duration.rawValueForParam > 0 {
            filters += varintField(3, state.duration.rawValueForParam)
        }

        var payload: [UInt8] = []
        if state.sort.rawValueForParam > 0 {
            payload += varintField(1, state.sort.rawValueForParam)
        }
        if !filters.isEmpty {
            payload += bytesField(2, filters)
        }

        guard !payload.isEmpty else { return nil }
        return base64URL(Data(payload))
    }

    /// 构造完整的搜索相对路径。
    static func searchPath(for state: SearchFilterState) -> String {
        let trimmed = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components: [String] = []
        components.append("search_query=" + percentEncode(trimmed))
        if let sp = encodedParameter(for: state) {
            components.append("sp=" + percentEncode(sp))
        }
        return "/results?" + components.joined(separator: "&")
    }

    // MARK: protobuf 基础编码

    private static func varint(_ value: Int) -> [UInt8] {
        var remaining = UInt64(bitPattern: Int64(value))
        var output: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            output.append(byte)
        } while remaining != 0
        return output
    }

    private static func varintField(_ number: Int, _ value: Int) -> [UInt8] {
        return varint(number << 3 | 0) + varint(value)
    }

    private static func bytesField(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
        return varint(number << 3 | 2) + varint(bytes.count) + bytes
    }

    /// URL 安全的 base64：把 +/ 换成 -_，并去掉补位等号。
    private static func base64URL(_ data: Data) -> String {
        var text = data.base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-")
        text = text.replacingOccurrences(of: "/", with: "_")
        text = text.replacingOccurrences(of: "=", with: "")
        return text
    }

    private static func percentEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
