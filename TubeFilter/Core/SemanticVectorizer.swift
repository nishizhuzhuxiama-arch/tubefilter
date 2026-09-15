import Foundation
import NaturalLanguage

/// 向量空间标识。
///
/// 系统句向量与本地 n-gram 向量处于两个完全不同的空间，维度和语义都不可比，
/// 因此任何一次相似度比较都必须保证两侧来自同一空间，绝不允许混算。
enum VectorSpace {
    case embedding
    case ngram
}

/// 语义向量器：优先使用 NaturalLanguage 提供的系统句向量，缺失时降级到
/// 纯 Swift 实现的字符 n-gram TF 向量。降级路径保证该功能在任何设备上都可用，
/// 不会因为系统语言模型未下载而变成一个空壳开关。
final class SemanticVectorizer {

    static let shared = SemanticVectorizer()

    private let chineseEmbedding: NLEmbedding?
    private let englishEmbedding: NLEmbedding?

    private var embeddingCache: [String: [Float]] = [:]
    private var embeddingMisses: Set<String> = []
    private var ngramCache: [String: [Float]] = [:]
    private let cacheLimit = 3000

    private init() {
        chineseEmbedding = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)
        englishEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    // MARK: 能力描述（展示在设置页，便于确认当前实际走的是哪条路径）

    var isEmbeddingAvailable: Bool {
        chineseEmbedding != nil || englishEmbedding != nil
    }

    var backendDescription: String {
        var parts: [String] = []
        if chineseEmbedding != nil { parts.append("中文句向量") }
        if englishEmbedding != nil { parts.append("英文句向量") }
        if parts.isEmpty {
            return "系统句向量不可用，已降级为本地字符 n-gram 向量"
        }
        return parts.joined(separator: " + ") + "，缺失词条时自动降级"
    }

    // MARK: 相似度

    struct SimilarityResult {
        var score: Double
        var space: VectorSpace
    }

    /// 计算两段文本的余弦相似度，取值 0~1。
    func similarity(_ lhs: String, _ rhs: String) -> SimilarityResult {
        let left = Self.normalized(lhs)
        let right = Self.normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else {
            return SimilarityResult(score: 0, space: .ngram)
        }
        if left == right {
            return SimilarityResult(score: 1, space: isEmbeddingAvailable ? .embedding : .ngram)
        }

        if let leftVector = embeddingVector(for: left, original: lhs),
           let rightVector = embeddingVector(for: right, original: rhs) {
            return SimilarityResult(score: Self.cosine(leftVector, rightVector), space: .embedding)
        }

        let fallbackScore = Self.cosine(ngramVector(left), ngramVector(right))
        return SimilarityResult(score: fallbackScore, space: .ngram)
    }

    /// 根据向量空间换算实际生效的阈值。n-gram 空间的相似度整体偏低，需要下修。
    func effectiveThreshold(base: Double, space: VectorSpace) -> Double {
        switch space {
        case .embedding:
            return base
        case .ngram:
            return max(0.20, base * 0.72)
        }
    }

    func clearCache() {
        embeddingCache.removeAll()
        embeddingMisses.removeAll()
        ngramCache.removeAll()
    }

    // MARK: 句向量

    private func embeddingVector(for normalizedText: String, original: String) -> [Float]? {
        if let cached = embeddingCache[normalizedText] { return cached }
        if embeddingMisses.contains(normalizedText) { return nil }

        guard let embedding = embedding(for: original) else { return nil }

        let raw: [Double]?
        if let vector = embedding.vector(for: original) {
            raw = vector
        } else {
            raw = embedding.vector(for: normalizedText)
        }

        guard let doubles = raw, !doubles.isEmpty else {
            embeddingMisses.insert(normalizedText)
            return nil
        }

        let floats = doubles.map { Float($0) }
        let normalized = Self.l2Normalized(floats)
        if embeddingCache.count >= cacheLimit { embeddingCache.removeAll(keepingCapacity: true) }
        embeddingCache[normalizedText] = normalized
        return normalized
    }

    private func embedding(for text: String) -> NLEmbedding? {
        if Self.containsCJK(text) {
            return chineseEmbedding ?? englishEmbedding
        }
        return englishEmbedding ?? chineseEmbedding
    }

    // MARK: n-gram 兜底向量

    private func ngramVector(_ text: String) -> [Float] {
        if let cached = ngramCache[text] { return cached }
        let dimension = 512
        var values = [Float](repeating: 0, count: dimension)
        let characters = Array(text)

        guard !characters.isEmpty else { return values }

        func add(_ token: String, weight: Float) {
            guard !token.isEmpty else { return }
            let index = Int(Self.djb2(token) % UInt64(dimension))
            values[index] += weight
        }

        if characters.count == 1 {
            add(String(characters[0]), weight: 1.0)
        }
        let maxN = min(3, characters.count)
        if maxN >= 2 {
            for n in 2...maxN {
                let weight: Float = (n == 2) ? 1.0 : 0.6
                var index = 0
                while index + n <= characters.count {
                    add(String(characters[index..<(index + n)]), weight: weight)
                    index += 1
                }
            }
        }

        let normalized = Self.l2Normalized(values)
        if ngramCache.count >= cacheLimit { ngramCache.removeAll(keepingCapacity: true) }
        ngramCache[text] = normalized
        return normalized
    }

    // MARK: 工具

    /// 文本归一化：转小写、去标点、压缩空白。中日韩字符区分大小写无意义，但英文有效。
    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || isCJK(scalar) {
                scalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                scalars.append(" ")
                lastWasSpace = true
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // 日文假名
             0x3400...0x4DBF,   // 扩展 A
             0x4E00...0x9FFF,   // 基本区
             0xF900...0xFAFF,   // 兼容表意
             0xAC00...0xD7AF:   // 谚文
            return true
        default:
            return false
        }
    }

    static func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where isCJK(scalar) {
            return true
        }
        return false
    }

    /// 确定性哈希。不能用 Swift 的 hashValue，它每个进程都会变，会导致缓存与向量不稳定。
    private static func djb2(_ text: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return hash
    }

    private static func l2Normalized(_ values: [Float]) -> [Float] {
        var sum: Float = 0
        for value in values { sum += value * value }
        guard sum > 0 else { return values }
        let norm = sum.squareRoot()
        return values.map { $0 / norm }
    }

    /// 两个向量都已做 L2 归一化，点积即余弦相似度。
    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        for index in 0..<lhs.count {
            dot += lhs[index] * rhs[index]
        }
        return Double(min(1, max(0, dot)))
    }
}
