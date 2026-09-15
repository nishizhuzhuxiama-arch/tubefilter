import Foundation

/// YouTube 搜索联想服务，对应「热搜 / 搜索建议」。
///
/// 使用 YouTube 搜索框背后的公开补全接口，不需要登录、不需要解析签名，
/// 因此可以在任何设备上稳定工作。
final class SuggestService {

    static let shared = SuggestService()

    private var cache: [String: [String]] = [:]

    func suggestions(for query: String, completion: @escaping ([String]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion([])
            return
        }
        if let cached = cache[trimmed] {
            completion(cached)
            return
        }

        var components = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "youtube"),
            URLQueryItem(name: "hl", value: "zh-CN"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "xssi", value: "t"),
            URLQueryItem(name: "q", value: trimmed)
        ]
        guard let url = components?.url else {
            completion([])
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 14_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            var results: [String] = []
            if let data = data {
                results = Self.parse(data)
            }
            self?.cache[trimmed] = results
            DispatchQueue.main.async {
                completion(results)
            }
        }.resume()
    }

    /// 响应是 JSONP，开头有 `)]}'` 防劫持前缀。去掉前缀后第二项是联想列表。
    private static func parse(_ data: Data) -> [String] {
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        if let range = text.range(of: ")]}'") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let payload = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: payload) as? [Any],
            json.count > 1,
            let entries = json[1] as? [Any]
        else {
            return []
        }

        var results: [String] = []
        for entry in entries {
            if let row = entry as? [Any], let first = row.first as? String, !first.isEmpty {
                results.append(first)
            }
        }
        return results
    }
}
