import Foundation

/// Native JSON requests for dictionaries and bounded, concurrent text pieces.
struct YoudaoTranslation {
    let session: URLSession
    private let whole: YoudaoWholeTranslation
    private let streaming: YoudaoStreamingTranslation
    private let native: YoudaoNativeRequest
    var webpage: @MainActor (String) async throws -> BuiltinTranslationResult

    init(session: URLSession,
         webpage: @escaping @MainActor (String) async throws -> BuiltinTranslationResult = {
             try await YoudaoWebTranslation.translate($0)
         }) {
        self.session = session
        self.whole = YoudaoWholeTranslation(session: session)
        self.streaming = YoudaoStreamingTranslation(session: session)
        self.native = YoudaoNativeRequest(session: session)
        self.webpage = webpage
    }

    static let requestLimit = 600

    func translate(_ text: String, onUpdate: @escaping @MainActor (String) -> Void = { _ in }) async throws -> BuiltinTranslationResult {
        try Task.checkCancellation()
        if BuiltinTranslationClient.isEnglishWord(text), text.count <= 128 {
            do { if let result = try await native.dictionary(text) { return result } }
            catch let failure as YoudaoNativeRequest.Failure {
                if failure == .rateLimited { throw failure }
                if let result = try await dictionary(text) { return result }
            }
        }
        do { return try await fastTranslation(text, onUpdate: onUpdate) }
        catch let failure as YoudaoNativeRequest.Failure {
            if failure == .rateLimited { throw failure }
        } catch is YoudaoTextPlan.Failure { }
        try Task.checkCancellation()
        // Structural failures retain the original whole-text fallback. A
        // network cancellation or rate limit never starts another translation.
        do { return try await whole.translate(text) }
        catch let failure as YoudaoWholeTranslation.Failure {
            if failure == .rateLimited { throw failure }
            try Task.checkCancellation()
            if failure == .verification {
                do { return try await streaming.translate(text, onUpdate: onUpdate) }
                catch let error as YoudaoStreamingTranslation.Failure {
                    if case .rateLimited = error { throw error }
                    try Task.checkCancellation()
                }
            }
        }
        try Task.checkCancellation()
        return try await webpage(text)
    }

    private func fastTranslation(_ text: String, onUpdate: @escaping @MainActor (String) -> Void) async throws -> BuiltinTranslationResult {
        let plan = try YoudaoTextPlan(text, limit: Self.requestLimit)
        let client = self
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            let width = min(6, plan.pieces.count)
            for index in 0..<width {
                group.addTask {
                    let result = try await client.fastPiece(plan.pieces[index].source)
                    try Task.checkCancellation()
                    return (index, try plan.render(result, for: index))
                }
            }
            var next = width
            var results: [Int: String] = [:]
            var published = ""
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                results[index] = result
                var prefix = ""
                for index in plan.pieces.indices {
                    guard let value = results[index] else { break }
                    prefix += value
                }
                if !prefix.isEmpty, prefix != published {
                    await onUpdate(prefix); published = prefix
                }
                if next < plan.pieces.count {
                    let index = next; next += 1
                    group.addTask {
                        let result = try await client.fastPiece(plan.pieces[index].source)
                        try Task.checkCancellation()
                        return (index, try plan.render(result, for: index))
                    }
                }
            }
            try Task.checkCancellation()
            return BuiltinTranslationResult(text: plan.pieces.indices.compactMap { results[$0] }.joined())
        }
    }

    private func fastPiece(_ source: String) async throws -> String {
        do { return try await native.translate(source) }
        catch let failure as YoudaoNativeRequest.Failure {
            if failure == .rateLimited { throw failure }
            if let result = try await submit(source) { return result.text }
            throw failure
        }
    }

    private func dictionary(_ word: String) async throws -> BuiltinTranslationResult? {
        var url = URLComponents(string: "https://m.youdao.com/dict")!
        url.queryItems = [URLQueryItem(name: "q", value: word), URLQueryItem(name: "le", value: "eng")]
        let request = URLRequest(url: url.url!, timeoutInterval: 8)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.check(response)
        guard (response as? HTTPURLResponse)?.mimeType == "text/html" else { return nil }
        return Self.parseDictionary(data, source: word)
    }

    private func submit(_ text: String) async throws -> BuiltinTranslationResult? {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://m.youdao.com/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["inputtext": text, "type": "AUTO"])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.check(response)
        if let http = response as? HTTPURLResponse, http.statusCode == 200,
           http.mimeType == "text/html", let result = Self.parseHTML(data, source: text) { return result }
        return nil
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw QingyiError.message("有道未返回有效响应。") }
        guard http.statusCode != 429 else { throw QingyiError.message("有道请求过于频繁，请稍后重试。") }
        guard [200, 404, 410].contains(http.statusCode) else {
            throw QingyiError.message("有道翻译暂时不可用（HTTP \(http.statusCode)）。")
        }
    }

    static func parseDictionary(_ data: Data, source: String) -> BuiltinTranslationResult? {
        guard !data.isEmpty, data.count <= 1_048_576,
              let page = try? XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let head = try? page.nodes(forXPath: "//*[@id='ec']/h2/span[1]").first?.stringValue,
              TextPolicy.clean(head).lowercased() == source.lowercased(),
              let rows = try? page.nodes(forXPath: "//*[@id='ec']/ul/li") else { return nil }
        let meanings = rows.compactMap { row -> DictionaryMeaning? in
            let value = TextPolicy.clean(row.stringValue ?? "")
            guard !value.isEmpty else { return nil }
            if let range = value.range(of: #"^[A-Za-z][A-Za-z. /&-]{0,30}\.\s*"#, options: .regularExpression) {
                return DictionaryMeaning(part: TextPolicy.clean(String(value[range])), text: String(value[range.upperBound...]))
            }
            return DictionaryMeaning(part: "", text: value)
        }
        guard !meanings.isEmpty else { return nil }
        let phones = (try? page.nodes(forXPath: "//*[@id='ec']//span[contains(concat(' ',normalize-space(@class),' '),' phonetic ')]")) ?? []
        let phonetics = phones.compactMap { phone -> String? in
            guard let value = phone.parent?.stringValue else { return nil }
            let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        return BuiltinTranslationResult(text: "", phonetics: phonetics, meanings: meanings)
    }

    static func parseHTML(_ data: Data, source: String) -> BuiltinTranslationResult? {
        guard !data.isEmpty, data.count <= 524_288,
              let page = try? XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let input = try? page.nodes(forXPath: "//form//textarea[@id='inputText']").first?.stringValue,
              normalizedLineEndings(TextPolicy.clean(input)) == normalizedLineEndings(source),
              let items = try? page.nodes(forXPath: "//ul[@id='translateResult']/li") else { return nil }
        let text = items.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : BuiltinTranslationResult(text: text)
    }

    private static func normalizedLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
