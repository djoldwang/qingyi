import Foundation
import CryptoKit
import NaturalLanguage

// Native adaptation of the public website's anonymous stream protocol.
// Guest credentials remain in memory and are separate from user API credentials.
actor YoudaoStreamingTranslation {
    enum Failure: LocalizedError {
        case unavailable, invalidResponse, rateLimited
        var errorDescription: String? {
            switch self {
            case .rateLimited: return "有道请求过于频繁，请稍后重试。"
            default: return "有道流式翻译暂时不可用，请稍后重试。"
            }
        }
    }
    private struct Guest: Decodable {
        let secretKey: String
        let token: String
    }
    private struct Envelope: Decodable {
        let code: Int
        let data: Guest?
    }
    private let session: URLSession
    private let anonymousID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var guest: (value: Guest, expires: Date)?
    private var pending: (id: UUID, task: Task<Guest, Error>)?

    init(session: URLSession) { self.session = session }

    static func signed(_ values: [String: String], secret: String, anonymousID: String,
                       version: String, timestamp: String) -> [String: String] {
        var fields = [
            "product": "webfanyi", "appVersion": version, "client": "webmain", "mid": "1", "vendor": "web",
            "screen": "1", "model": "1", "imei": "1", "network": "wifi", "keyfrom": "webfanyi.webmain",
            "mysticTime": timestamp, "yduuid": anonymousID
        ]
        fields.merge(values) { _, new in new }
        fields = fields.filter { !$0.value.isEmpty }
        let names = fields.keys.sorted()
        let material = names.map { "\($0)=\(fields[$0]!)" }.joined(separator: "&") + "&key=" + secret
        fields["sign"] = Insecure.MD5.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        fields["pointParam"] = (names + ["key"]).joined(separator: ",")
        return fields
    }
    private func signed(_ fields: [String: String], secret: String, version: String) -> [String: String] {
        Self.signed(fields, secret: secret, anonymousID: anonymousID, version: version,
                    timestamp: String(Int64(Date().timeIntervalSince1970 * 1000)))
    }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("https://fanyi.youdao.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://fanyi.youdao.com", forHTTPHeaderField: "Origin")
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return request
    }
    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if http.statusCode == 429 { throw Failure.rateLimited }
        guard http.statusCode == 200 else { throw Failure.unavailable }
    }
    private func loadGuest() async throws -> Guest {
        let fields = signed(["keyid": "translate-webmain-key-getter",
                             "targetKeyid": "translate-webfanyi-webmain", "abtest": "0"],
                            secret: "kSy5gtKA4yRUxAVPJPrdYKZ0jBKyd3t1", version: "12.0.0")
        var url = URLComponents(string: "https://dict-trans.youdao.com/translate/key")!
        url.percentEncodedQuery = String(decoding: formBody(fields), as: UTF8.self)
        var request = request(url.url!)
        request.httpBody = Data()
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard data.count <= 65_536, let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw Failure.invalidResponse
        }
        if envelope.code == 429 { throw Failure.rateLimited }
        guard envelope.code == 0, let value = envelope.data, !value.secretKey.isEmpty, !value.token.isEmpty else {
            throw Failure.invalidResponse
        }
        return value
    }
    private func currentGuest() async throws -> Guest {
        try Task.checkCancellation()
        if let guest, guest.expires > Date() { return guest.value }
        let work: (id: UUID, task: Task<Guest, Error>)
        if let pending { work = pending }
        else {
            let id = UUID()
            work = (id, Task {
                defer { if self.pending?.id == id { self.pending = nil } }
                let value = try await self.loadGuest()
                if self.pending?.id == id { self.guest = (value, Date().addingTimeInterval(60)) }
                return value
            })
            pending = work
        }
        let stream = AsyncThrowingStream<Guest, Error> { continuation in
            let observer = Task {
                do { continuation.yield(try await work.task.value); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in observer.cancel() }
        }
        var iterator = stream.makeAsyncIterator()
        let result = try await iterator.next()
        try Task.checkCancellation()
        guard let result else { throw CancellationError() }
        return result
    }
    func translate(_ source: String, onUpdate: @escaping @MainActor (String) -> Void) async throws -> BuiltinTranslationResult {
        let credentials = try await currentGuest()
        guard let language = NLLanguageRecognizer.dominantLanguage(for: source)?.rawValue else { throw Failure.unavailable }
        let from = ["zh-Hans": "zh-CHS", "zh-Hant": "zh-CHT"][language] ?? language
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        guard let input = source.addingPercentEncoding(withAllowedCharacters: allowed) else { throw Failure.invalidResponse }
        let fields = signed([
            "i": input, "modelName": "llmLite", "useTerm": "false", "from": from, "to": "zh-CHS",
            "token": credentials.token, "signSecretKey": credentials.secretKey, "source": "webmain",
            "keyid": "translate-webfanyi-webmain", "keyId": "translate-webfanyi-webmain"
        ], secret: credentials.secretKey, version: "1")
        var request = request(URL(string: "https://dict-trans.youdao.com/webtranslate/sse")!)
        request.httpBody = formBody(fields)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try Self.check(response)
        var decoder = YoudaoStreamDecoder()
        var wire = WireLines()
        var count = 0
        var lastUpdate = Date.distantPast
        for try await byte in bytes {
            try Task.checkCancellation()
            count += 1
            guard count <= 2_097_152 else { throw Failure.invalidResponse }
            if let line = try wire.append(byte) {
                if let text = try decoder.line(line), !text.isEmpty, Date().timeIntervalSince(lastUpdate) >= 0.04 || decoder.completed {
                    await onUpdate(text)
                    lastUpdate = Date()
                }
                if decoder.completed { break }
            }
        }
        if !decoder.completed, let tail = try wire.finish() { _ = try decoder.line(tail) }
        let text = try decoder.finish()
        try Task.checkCancellation()
        await onUpdate(text)
        return BuiltinTranslationResult(text: text)
    }
}

struct YoudaoStreamDecoder {
    private var event = ""
    private var eventID = ""
    private var data: [String] = []
    private var requestID: String?
    private(set) var text = ""
    private(set) var completed = false
    mutating func line(_ line: String) throws -> String? {
        if line.hasPrefix("event:") { event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); return nil }
        if line.hasPrefix("id:") { eventID = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); return nil }
        if line.hasPrefix("data:") { data.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)); return nil }
        guard line.isEmpty else { return nil }
        guard !data.isEmpty else { event = ""; return nil }
        let payload = data.joined(separator: "\n")
        defer { data.removeAll(keepingCapacity: true); event = "" }
        guard let bytes = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["error"] == nil, !completed else { throw YoudaoStreamingTranslation.Failure.invalidResponse }
        if let code = object["code"] {
            if code as? Int == 429 { throw YoudaoStreamingTranslation.Failure.rateLimited }
            guard let code = code as? Int, code == 0 else { throw YoudaoStreamingTranslation.Failure.invalidResponse }
        }
        switch event {
        case "begin":
            guard requestID == nil, let id = object["requestId"] as? String, !id.isEmpty,
                  eventID.isEmpty || eventID == id else { throw YoudaoStreamingTranslation.Failure.invalidResponse }
            requestID = id
            return nil
        case "message", "end":
            guard let requestID, eventID.isEmpty || eventID == requestID else { throw YoudaoStreamingTranslation.Failure.invalidResponse }
            text += object["transIncre"] as? String ?? ""
            if event == "end" { completed = true }
            return text
        default: throw YoudaoStreamingTranslation.Failure.invalidResponse
        }
    }
    mutating func finish() throws -> String {
        _ = try line("")
        guard completed, !TextPolicy.clean(text).isEmpty else { throw YoudaoStreamingTranslation.Failure.invalidResponse }
        return text
    }
}
