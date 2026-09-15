import Foundation

/// 过滤引擎：把「规则 + 开关」应用到一批内容上，输出每条内容的处置结论。
///
/// 设计原则：
/// 1. 先做零成本的类型判断（会员/直播/短视频），再做字符串匹配，语义相似度放最后，
///    因为它是唯一有真实计算开销的一步。
/// 2. 规则一旦命中即返回，不做多规则归因，避免同一内容被重复计入历史。
/// 3. 编译结果按规则签名缓存，规则不变时不重复编译正则。
final class FilterEngine {

    private struct CompiledRule {
        var rule: BlockRule
        var regex: NSRegularExpression?
        /// 纯文本模式下用于匹配的目标串（按需小写）。
        var literal: String
    }

    private var compiledRules: [CompiledRule] = []
    private var compiledSignature: Int?
    private var compiledSemantic: [CompiledRule] = []

    // MARK: 对外入口

    func evaluate(items: [FeedItemSnapshot], settings: AppSettings) -> [FilterVerdict] {
        guard !items.isEmpty else { return [] }
        prepare(rules: settings.rules, filter: settings.filter)

        var verdicts: [FilterVerdict] = []
        verdicts.reserveCapacity(items.count)
        for item in items {
            verdicts.append(evaluate(item: item, filter: settings.filter))
        }
        return verdicts
    }

    // MARK: 单条评估

    func evaluate(item: FeedItemSnapshot, filter: FilterSettings) -> FilterVerdict {
        // 1) 内容类型开关（零成本）
        if let verdict = typeVerdict(for: item, filter: filter) {
            return verdict
        }

        // 2) 频道屏蔽
        for compiled in compiledRules where compiled.rule.kind == .channel {
            if let detail = matchReason(compiled: compiled, candidate: item.channelName) {
                return .block(item.videoID, reason: .channel, detail: detail, ruleID: compiled.rule.id)
            }
            if !item.channelID.isEmpty,
               let detail = matchReason(compiled: compiled, candidate: item.channelID) {
                return .block(item.videoID, reason: .channel, detail: detail, ruleID: compiled.rule.id)
            }
        }

        // 3) 标题与话题上的屏蔽词（纯文本 / 正则）
        let textTargets: [(text: String, label: String)] = [
            (item.title, "标题"),
            (item.topics.joined(separator: " "), "话题"),
            (item.channelName, "频道名")
        ]
        for compiled in compiledRules where compiled.rule.kind == .keyword {
            for target in textTargets where !target.text.isEmpty {
                if let detail = matchReason(compiled: compiled, candidate: target.text) {
                    let reason: FilterReason = compiled.rule.matchMode == .regex ? .regex : .keyword
                    return .block(
                        item.videoID,
                        reason: reason,
                        detail: "\(target.label)\(detail)",
                        ruleID: compiled.rule.id
                    )
                }
            }
        }

        // 4) 话题屏蔽
        let topicText = item.topics.joined(separator: " ")
        for compiled in compiledRules where compiled.rule.kind == .topic {
            for candidate in item.topics + [topicText] where !candidate.isEmpty {
                if let detail = matchReason(compiled: compiled, candidate: candidate) {
                    return .block(item.videoID, reason: .topic, detail: "话题\(detail)", ruleID: compiled.rule.id)
                }
            }
        }

        // 5) 质量过滤
        if filter.qualityFilterEnabled, let detail = qualityVerdict(for: item, filter: filter) {
            return .block(item.videoID, reason: .quality, detail: detail, ruleID: nil)
        }

        // 6) NLP 语义屏蔽（开销最大，放最后）
        if filter.semanticEnabled, !compiledSemantic.isEmpty, !item.title.isEmpty {
            for compiled in compiledSemantic {
                let result = SemanticVectorizer.shared.similarity(item.title, compiled.rule.pattern)
                let threshold = SemanticVectorizer.shared.effectiveThreshold(
                    base: filter.semanticThreshold,
                    space: result.space
                )
                if result.score >= threshold {
                    let percent = Int((result.score * 100).rounded())
                    return .block(
                        item.videoID,
                        reason: .semantic,
                        detail: "语义相似度 \(percent)% ≥ 阈值 \(Int((threshold * 100).rounded()))%，参照词「\(compiled.rule.pattern)」",
                        ruleID: compiled.rule.id
                    )
                }
            }
        }

        return .allow(item.videoID)
    }

    // MARK: 类型判断

    private func typeVerdict(for item: FeedItemSnapshot, filter: FilterSettings) -> FilterVerdict? {
        let badges = Set(item.badges.map { $0.lowercased() })
        let looksLikeShort = badges.contains("shorts") || item.url.contains("/shorts/")

        if filter.blockShorts, looksLikeShort {
            return .block(item.videoID, reason: .shorts, detail: "短视频被屏蔽")
        }
        if filter.blockMemberOnly, badges.contains("member") || badges.contains("premium") {
            return .block(item.videoID, reason: .memberOnly, detail: "会员专属 / 付费内容被屏蔽")
        }
        if filter.blockLive, badges.contains("live") {
            return .block(item.videoID, reason: .live, detail: "直播被屏蔽")
        }
        if filter.blockUpcoming, badges.contains("upcoming") || badges.contains("premiere") {
            return .block(item.videoID, reason: .upcoming, detail: "首播 / 预告被屏蔽")
        }
        return nil
    }

    // MARK: 质量过滤

    private func qualityVerdict(for item: FeedItemSnapshot, filter: FilterSettings) -> String? {
        if filter.qualityMinDurationSeconds > 0,
           item.durationSeconds > 0,
           item.durationSeconds < filter.qualityMinDurationSeconds {
            let actual = Self.formatDuration(item.durationSeconds)
            let minimum = Self.formatDuration(filter.qualityMinDurationSeconds)
            return "时长 \(actual) 低于下限 \(minimum)"
        }

        if filter.qualityMaxTitleLength > 0, item.title.count > filter.qualityMaxTitleLength {
            return "标题长度 \(item.title.count) 超过上限 \(filter.qualityMaxTitleLength)"
        }

        if filter.qualityBlockClickbait {
            let signals = QualityHeuristics.clickbaitSignals(in: item.title)
            if !signals.isEmpty {
                return "标题党特征：" + signals.joined(separator: "、")
            }
        }

        return nil
    }

    // MARK: 匹配

    private func matchReason(compiled: CompiledRule, candidate: String) -> String? {
        guard !candidate.isEmpty, !compiled.rule.pattern.isEmpty else { return nil }

        if compiled.rule.matchMode == .regex {
            guard let regex = compiled.regex else { return nil }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, options: [], range: range) else { return nil }
            let matched = (candidate as NSString).substring(with: match.range)
            return "命中「\(matched)」（正则 \(compiled.rule.pattern)）"
        }

        let haystack = compiled.rule.caseSensitive ? candidate : candidate.lowercased()
        let needle = compiled.literal
        guard !needle.isEmpty, haystack.contains(needle) else { return nil }
        return "命中「\(compiled.rule.pattern)」"
    }

    // MARK: 编译

    private func prepare(rules: [BlockRule], filter: FilterSettings) {
        let signature = Self.signature(of: rules, filter: filter)
        if compiledSignature == signature, compiledSignature != nil { return }

        var normal: [CompiledRule] = []
        var semantic: [CompiledRule] = []

        for rule in rules where rule.enabled {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }

            var regex: NSRegularExpression?
            if rule.matchMode == .regex {
                var options: NSRegularExpression.Options = []
                if !rule.caseSensitive { options.insert(.caseInsensitive) }
                regex = try? NSRegularExpression(pattern: pattern, options: options)
                // 正则写错时跳过该条，而不是让整条管线失败。
                if regex == nil { continue }
            }

            let literal = rule.caseSensitive ? pattern : pattern.lowercased()
            let compiled = CompiledRule(rule: rule, regex: regex, literal: literal)

            if rule.kind == .semantic {
                semantic.append(compiled)
            } else {
                normal.append(compiled)
            }
        }

        compiledRules = normal
        compiledSemantic = semantic
        compiledSignature = signature
    }

    /// 规则或开关变化时使缓存失效。
    private static func signature(of rules: [BlockRule], filter: FilterSettings) -> Int {
        var hasher = Hasher()
        hasher.combine(filter.semanticEnabled)
        hasher.combine(filter.qualityFilterEnabled)
        hasher.combine(filter.blockShorts)
        hasher.combine(filter.blockLive)
        hasher.combine(filter.blockUpcoming)
        hasher.combine(filter.blockMemberOnly)
        hasher.combine(filter.qualityMinDurationSeconds)
        hasher.combine(filter.qualityMaxTitleLength)
        hasher.combine(filter.qualityBlockClickbait)
        for rule in rules where rule.enabled {
            hasher.combine(rule.id)
            hasher.combine(rule.pattern)
            hasher.combine(rule.matchMode)
            hasher.combine(rule.caseSensitive)
        }
        return hasher.finalize()
    }

    static func formatDuration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0:00" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - 质量过滤启发式

enum QualityHeuristics {

    /// 中文标题党特征词。
    private static let clickbaitWords = [
        "震惊", "必看", "后悔", "速看", "揭秘", "内幕", "太可怕",
        "千万", "竟然", "居然", "免费领", "限时", "不看就", "最后一天",
        "顶级", "天花板", "史上最", "绝了", "逆天", "偷偷"
    ]

    /// 英文标题党特征词。
    private static let clickbaitEnglishWords = [
        "you won't believe", "shocking", "must watch", "gone wrong",
        "insane", "clickbait", "subscribe now", "top 10 secrets"
    ]

    /// 返回命中的特征描述，空数组表示不像标题党。
    static func clickbaitSignals(in title: String) -> [String] {
        var signals: [String] = []
        let lowered = title.lowercased()

        let chineseHit = clickbaitWords.filter { title.contains($0) }
        if !chineseHit.isEmpty {
            signals.append("诱导词 " + chineseHit.prefix(3).joined(separator: "/"))
        }

        let englishHit = clickbaitEnglishWords.filter { lowered.contains($0) }
        if !englishHit.isEmpty {
            signals.append("英文诱导短语")
        }

        let exclamationCount = title.filter { $0 == "!" || $0 == "！" }.count
        if exclamationCount >= 2 {
            signals.append("感叹号 ×\(exclamationCount)")
        }

        let questionCount = title.filter { $0 == "?" || $0 == "？" }.count
        if questionCount >= 2 {
            signals.append("问号 ×\(questionCount)")
        }

        if hasShoutingCase(lowered) {
            signals.append("全大写刷屏")
        }

        if containsPercentBait(title) {
            signals.append("百分比诱导")
        }

        return signals
    }

    /// 拉丁字母占比高且全为大写时，视为刷屏标题。
    ///
    /// 这里必须传入原始大小写文本：调用方传进来的 `lowered` 已经转成小写，
    /// 用它判断大写比例会永远为 0，这个分支就永远不会命中。
    private static func hasShoutingCase(_ original: String) -> Bool {
        var asciiLetters = 0
        var uppercaseLetters = 0
        for character in original where character.isLetter && character.isASCII {
            asciiLetters += 1
            if character.isUppercase { uppercaseLetters += 1 }
        }
        guard asciiLetters >= 12 else { return false }
        return Double(uppercaseLetters) / Double(asciiLetters) >= 0.9
    }

    private static func containsPercentBait(_ title: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "\\d{2,3}\\s*%") else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.firstMatch(in: title, options: [], range: range) != nil
    }
}
