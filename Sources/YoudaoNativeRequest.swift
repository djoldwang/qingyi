import Foundation
import CryptoKit

// Native macOS adapter for the public website's jsonapi_s request contract.
// Protocol reference: app.14248eec.js, getDictTranslateResult; no guest-key exchange.
struct YoudaoNativeRequest {
    enum Failure: LocalizedError, Equatable {
        case invalidResponse, rateLimited
        var errorDescription: String? {
            self == .rateLimited ? "有道请求过于频繁，请稍后重试。" : "有道未返回与完整原文对应的结果。"
        }
    }
    let session: URLSession

    static func parameters(_ source: String, dictionary: Bool, milliseconds: Int64) -> [String: String] {
        func md5(_ value: String) -> String {
            Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let client = "webmain", keyfrom = "webfanyi.webmain"
        let timestamp = String(milliseconds) + String((source + keyfrom).utf16.count % 10)
        let signature = md5(client + source + timestamp + "t2he2k4m2g6QKRigK0KAmSpXKgAezywG" + md5(source + keyfrom))
        return ["q": source, "needTranslate": dictionary ? "false" : "true",
                "dicts": dictionary ? #"{"count":"1","dicts":["ec"]}"# : #"{"count":"1","dicts":["fanyi"]}"#,
                "t": timestamp, "client": client, "keyfrom": keyfrom, "sign": signature]
    }

    private func request(_ source: String, dictionary: Bool) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://dict.youdao.com/jsonapi_s?doctype=json&jsonversion=4")!, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.httpBody = formBody(Self.parameters(source, dictionary: dictionary,
            milliseconds: Int64(Date().timeIntervalSince1970 * 1000)))
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://fanyi.youdao.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://fanyi.youdao.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if response.statusCode == 429 { throw Failure.rateLimited }
        guard response.statusCode == 200, !data.isEmpty, data.count <= 1_048_576 else { throw Failure.invalidResponse }
        return data
    }

    private struct Payload: Decodable {
        struct Translation: Decodable { let input: String; let type: String; let tran: String }
        struct Dictionary: Decodable {
            struct Word: Decodable {
                struct Meaning: Decodable { let pos: String?; let tran: String? }
                let phrase: String
                let ukphone: String?
                let usphone: String?
                let phone: String?
                let trs: [Meaning]
                enum CodingKeys: String, CodingKey { case phrase = "return-phrase", ukphone, usphone, phone, trs }
            }
            let word: Word?
        }
        let input: String?
        let fanyi: Translation?
        let ec: Dictionary?
        let code: Int?
        let errorCode: Int?
    }
    private static func payload(_ data: Data, source: String) throws -> Payload {
        guard let value = try? JSONDecoder().decode(Payload.self, from: data) else { throw Failure.invalidResponse }
        if value.code == 429 || value.errorCode == 429 { throw Failure.rateLimited }
        guard value.code == nil || value.code == 0, value.errorCode == nil || value.errorCode == 0,
              value.input == source else { throw Failure.invalidResponse }
        return value
    }
    static func parseTranslation(_ data: Data, source: String) throws -> String {
        let value = try payload(data, source: source)
        guard let translation = value.fanyi, translation.input == source,
              translation.type.hasSuffix("2zh-CHS"), !TextPolicy.clean(translation.tran).isEmpty else { throw Failure.invalidResponse }
        return translation.tran
    }
    static func parseDictionary(_ data: Data, source: String) throws -> BuiltinTranslationResult? {
        let value = try payload(data, source: source)
        guard let word = value.ec?.word else { return nil }
        guard word.phrase.caseInsensitiveCompare(source) == .orderedSame else { throw Failure.invalidResponse }
        let meanings = word.trs.compactMap { item -> DictionaryMeaning? in
            guard let text = item.tran.map(TextPolicy.clean), !text.isEmpty else { return nil }
            return DictionaryMeaning(part: item.pos ?? "", text: text)
        }
        guard !meanings.isEmpty else { return nil }
        var phones = [("英", word.ukphone), ("美", word.usphone)].compactMap { label, value -> String? in
            guard let phone = value.map(TextPolicy.clean), !phone.isEmpty else { return nil }
            return "\(label) [\(phone)]"
        }
        if phones.isEmpty, let phone = word.phone.map(TextPolicy.clean), !phone.isEmpty { phones = ["[\(phone)]"] }
        return BuiltinTranslationResult(text: "", phonetics: phones, meanings: meanings)
    }
    func translate(_ source: String) async throws -> String {
        try Self.parseTranslation(await request(source, dictionary: false), source: source)
    }
    func dictionary(_ source: String) async throws -> BuiltinTranslationResult? {
        try Self.parseDictionary(await request(source, dictionary: true), source: source)
    }
}
