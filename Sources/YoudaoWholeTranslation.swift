import Foundation
import CryptoKit
import CommonCrypto

// Native macOS adapter for Youdao's public whole-text website protocol.
// Protocol reference: translation-website 1.1.6, app.14248eec.js modules 87797/3557
// and textTranslate.7037008a.js. Cryptographic operations use CryptoKit/CommonCrypto.
actor YoudaoWholeTranslation {
    struct Keys: Decodable {
        let secretKey: String
        let aesKey: String
        let aesIv: String
    }
    private struct KeyResponse: Decodable {
        let code: Int
        let data: Keys?
    }
    private struct TranslationResponse: Decodable {
        struct Sentence: Decodable {
            let src: String
            let tgt: String
        }
        let code: Int
        let translateResult: [[Sentence]]?
    }
    private struct KeySnapshot {
        let id = UUID()
        let keys: Keys
        let expiry: Date
    }
    enum Failure: LocalizedError, Equatable {
        case unavailable, invalidResponse, verification, decryption, mismatch, rateLimited
        var errorDescription: String? {
            switch self {
            case .rateLimited: return "有道请求过于频繁，请稍后重试。"
            case .verification: return "有道网页验证失败，请稍后重试。"
            case .mismatch: return "有道未返回与完整原文对应的译文。"
            default: return "有道全文翻译接口已变化，请稍后重试。"
            }
        }
    }

    private let session: URLSession
    private let now: () -> Date
    private let anonymousID = UUID().uuidString
    private var cachedKeys: KeySnapshot?
    private var pendingKeys: (id: UUID, task: Task<KeySnapshot, Error>)?

    init(session: URLSession, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    private static func digest(_ value: String) -> Data {
        Data(Insecure.MD5.hash(data: Data(value.utf8)))
    }

    private func parameters(secret: String, keyID: String) -> [String: String] {
        let timestamp = String(Int64(now().timeIntervalSince1970 * 1000))
        let signature = Self.digest("client=fanyideskweb&mysticTime=\(timestamp)&product=webfanyi&key=\(secret)")
            .map { String(format: "%02x", $0) }.joined()
        return [
            "client": "fanyideskweb", "product": "webfanyi", "appVersion": "12.0.0",
            "vendor": "web", "pointParam": "client,mysticTime,product", "mysticTime": timestamp,
            "keyfrom": "fanyi.web", "mid": "1", "screen": "1", "model": "1", "network": "wifi",
            "abtest": "0", "yduuid": anonymousID, "keyid": keyID, "sign": signature
        ]
    }

    private func request(path: String, values: [String: String], post: Bool) async throws -> Data {
        try Task.checkCancellation()
        let body = formBody(values)
        var components = URLComponents(string: "https://dict.youdao.com" + path)!
        if !post { components.percentEncodedQuery = String(decoding: body, as: UTF8.self) }
        var request = URLRequest(url: components.url!, timeoutInterval: 12)
        request.setValue("https://fanyi.youdao.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://fanyi.youdao.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        if post {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 404, 410: throw Failure.unavailable
        case 429: throw Failure.rateLimited
        default: throw QingyiError.message("有道全文翻译暂时不可用（HTTP \(http.statusCode)）。")
        }
        guard !data.isEmpty, data.count <= 2_097_152 else { throw Failure.invalidResponse }
        return data
    }

    private func loadKeys() async throws -> KeySnapshot {
        let data = try await request(path: "/webtranslate/key",
            values: parameters(secret: "yU5nT5dK3eZ1pI4j", keyID: "webfanyi-key-getter-2025"), post: false)
        guard let envelope = try? JSONDecoder().decode(KeyResponse.self, from: data),
              envelope.code == 0, let keys = envelope.data,
              !keys.secretKey.isEmpty, !keys.aesKey.isEmpty, !keys.aesIv.isEmpty else { throw Failure.invalidResponse }
        // The site does not expose a stable expiry contract. Keep parameters
        // only briefly in memory, and refresh once if cached parameters fail.
        return KeySnapshot(keys: keys, expiry: now().addingTimeInterval(60))
    }

    private func currentKeys() async throws -> KeySnapshot {
        try Task.checkCancellation()
        if let cachedKeys, cachedKeys.expiry > now() { return cachedKeys }
        let pending: (id: UUID, task: Task<KeySnapshot, Error>)
        if let pendingKeys { pending = pendingKeys }
        else {
            let id = UUID()
            pending = (id, Task {
                defer { if self.pendingKeys?.id == id { self.pendingKeys = nil } }
                let snapshot = try await self.loadKeys()
                if self.pendingKeys?.id == id { self.cachedKeys = snapshot }
                return snapshot
            })
            pendingKeys = pending
        }
        // Waiting callers may cancel independently. The shared lookup contains
        // no source text and remains available to the next selection.
        let stream = AsyncThrowingStream<KeySnapshot, Error> { continuation in
            let observer = Task {
                do {
                    continuation.yield(try await pending.task.value)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in observer.cancel() }
        }
        var iterator = stream.makeAsyncIterator()
        let snapshot = try await iterator.next()
        try Task.checkCancellation()
        guard let snapshot else { throw CancellationError() }
        return snapshot
    }

    static func decode(_ data: Data, keys: Keys, source: String) throws -> BuiltinTranslationResult {
        // Some verification failures are returned as clear JSON.
        if let error = try? JSONDecoder().decode(TranslationResponse.self, from: data) {
            if error.code == 50 { throw Failure.verification }
            throw Failure.invalidResponse
        }
        var encoded = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let ciphertext = Data(base64Encoded: encoded), !ciphertext.isEmpty,
              ciphertext.count % kCCBlockSizeAES128 == 0 else { throw Failure.decryption }
        let key = digest(keys.aesKey)
        let iv = digest(keys.aesIv)
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = plaintext.count
        var used = 0
        let status = plaintext.withUnsafeMutableBytes { output in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { secret in
                    iv.withUnsafeBytes { vector in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), secret.baseAddress, key.count,
                            vector.baseAddress, input.baseAddress, ciphertext.count,
                            output.baseAddress, capacity, &used)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.decryption }
        plaintext.count = used
        guard let response = try? JSONDecoder().decode(TranslationResponse.self, from: plaintext) else { throw Failure.invalidResponse }
        if response.code == 50 { throw Failure.verification }
        guard response.code == 0, let groups = response.translateResult, !groups.isEmpty else { throw Failure.invalidResponse }
        let sentences = groups.flatMap { $0 }
        let original = sentences.map(\.src).joined()
        guard original.filter({ !$0.isWhitespace }) == source.filter({ !$0.isWhitespace }),
              sentences.allSatisfy({ TextPolicy.clean($0.src).isEmpty || !TextPolicy.clean($0.tgt).isEmpty }) else { throw Failure.mismatch }
        let text = groups.map { $0.map(\.tgt).joined() }.joined(separator: "\n")
        guard !TextPolicy.clean(text).isEmpty else { throw Failure.mismatch }
        return BuiltinTranslationResult(text: text)
    }

    private func translate(_ source: String, using keys: Keys) async throws -> BuiltinTranslationResult {
        var values = parameters(secret: keys.secretKey, keyID: "webfanyi")
        values["i"] = source
        values["from"] = "auto"
        values["to"] = "zh-CHS"
        values["dictResult"] = "false"
        values["noCheckPrivate"] = "false"
        let data = try await request(path: "/webtranslate", values: values, post: true)
        return try Self.decode(data, keys: keys, source: source)
    }

    func translate(_ source: String) async throws -> BuiltinTranslationResult {
        let reused = (cachedKeys?.expiry ?? .distantPast) > now()
        let snapshot = try await currentKeys()
        do {
            return try await translate(source, using: snapshot.keys)
        } catch let failure as Failure where reused && (failure == .verification || failure == .decryption) {
            try Task.checkCancellation()
            if cachedKeys?.id == snapshot.id { cachedKeys = nil }
            let refreshed = try await currentKeys()
            return try await translate(source, using: refreshed.keys)
        }
    }
}
