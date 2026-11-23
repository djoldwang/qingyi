import Foundation

// Native client for Google's public JSON responses on two service origins.
// Both routes return translation, dictionary and pronunciation in one request.
struct GoogleWebTranslation {
    let session: URLSession

    private struct Payload: Decodable {
        struct Sentence: Decodable {
            let trans: String?
            let src_translit: String?
        }
        struct Entry: Decodable {
            let pos: String?
            let terms: [String]?
        }
        let sentences: [Sentence]?
        let dict: [Entry]?
    }

    private enum Failure: LocalizedError {
        case invalidResponse, rateLimited, http(Int)
        var errorDescription: String? {
            switch self {
            case .rateLimited: return "Google 请求过于频繁，请稍后重试。"
            case .http(let code): return "Google 翻译暂时不可用（HTTP \(code)）。"
            case .invalidResponse: return "Google 未返回可用译文或释义，请稍后重试。"
            }
        }
    }

    static func form(_ pairs: [(String, String)]) -> String {
        var query = URLComponents()
        query.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
        return (query.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    private func request(_ text: String, dictionary: Bool, alternate: Bool) async throws -> Data {
        try Task.checkCancellation()
        var fields = [("client", "gtx"), ("sl", "auto"), ("tl", "zh-CN"),
                      ("q", text), ("ie", "UTF-8"), ("dt", "t")]
        if dictionary { fields += [("hl", "en"), ("dt", "bd"), ("dt", "rm")] }
        fields.append(("dj", "1"))
        let host = alternate ? "translate.googleapis.com" : "translate.google.com"
        let endpoint = URL(string: "https://" + host + "/translate_a/single?" + Self.form(fields))!
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/77.0.3865.120 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if response.statusCode == 429 { throw Failure.rateLimited }
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        guard !data.isEmpty, data.count <= 2_097_152 else { throw Failure.invalidResponse }
        return data
    }

    func translate(_ text: String) async throws -> BuiltinTranslationResult {
        let dictionary = BuiltinTranslationClient.isEnglishWord(text)
        do {
            let data = try await request(text, dictionary: dictionary, alternate: false)
            return try Self.parseGoogleGTX(data)
        } catch {
            try Task.checkCancellation()
            if case Failure.rateLimited = error { throw error }
            if let error = error as? URLError, error.code == .cancelled { throw error }
            let data = try await request(text, dictionary: dictionary, alternate: true)
            return try Self.parseGoogleGTX(data)
        }
    }

    static func parseGoogleGTX(_ data: Data) throws -> BuiltinTranslationResult {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw Failure.invalidResponse }
        let meanings = (payload.dict ?? []).compactMap { entry -> DictionaryMeaning? in
            guard let terms = entry.terms else { return nil }
            let text = terms.map(TextPolicy.clean).filter { !$0.isEmpty }.joined(separator: "；")
            guard !text.isEmpty else { return nil }
            return DictionaryMeaning(part: entry.pos ?? "", text: text)
        }
        let text = (payload.sentences ?? []).compactMap(\.trans).joined()
        let phonetics = (payload.sentences ?? []).compactMap(\.src_translit)
        return try result(text: text, meanings: meanings, phonetics: phonetics)
    }

    private static func result(text: String, meanings: [DictionaryMeaning], phonetics: [String]) throws -> BuiltinTranslationResult {
        guard !TextPolicy.clean(text).isEmpty || !meanings.isEmpty else { throw Failure.invalidResponse }
        var pronunciations: [String] = []
        for value in phonetics {
            let raw = TextPolicy.clean(value).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let formatted = "/\(raw)/"
            if !raw.isEmpty, !pronunciations.contains(formatted) { pronunciations.append(formatted) }
        }
        return BuiltinTranslationResult(text: text, phonetics: pronunciations, meanings: meanings)
    }
}
