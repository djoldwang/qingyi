import Foundation
import CryptoKit
import Security
import NaturalLanguage

enum QingyiError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum CredentialWait {
    static func value<T>(_ task: Task<T, Error>, timeout: UInt64 = 15_000_000_000) async throws -> T {
        let stream = AsyncThrowingStream<T, Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let waiter = Task {
                do { continuation.yield(try await task.value); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            let timer = Task {
                do {
                    try await Task.sleep(nanoseconds: timeout)
                    continuation.finish(throwing: QingyiError.message("macOS 钥匙串访问尚未完成。请确认登录钥匙串已解锁，或处理系统访问提示后重试。"))
                } catch { }
            }
            continuation.onTermination = { _ in waiter.cancel(); timer.cancel() }
        }
        var iterator = stream.makeAsyncIterator()
        let value = try await iterator.next()
        try Task.checkCancellation()
        guard let value = value else { throw CancellationError() }
        return value
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let normalized = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    }
}

func secureRandom(_ count: Int = 32) throws -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw QingyiError.message("无法生成登录所需的安全随机数。") }
    return Data(bytes).base64URL
}

func pkceChallenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }

func formBody(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return Data(fields.sorted(by: { $0.key < $1.key }).map {
        "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&").utf8)
}

enum AppVersion {
    static var display: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1" }
    static var menuTitle: String { "轻译 \(display)" }
}

enum TextPolicy {
    static let maximumLength = 12_000
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let opaqueURISchemes: Set<String> = ["mailto", "tel", "sms", "urn", "data", "geo", "magnet"]
    static func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func isStandaloneAddress(_ raw: String) -> Bool {
        let text = clean(raw)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return false }
        if let components = URLComponents(string: text), let scheme = components.scheme?.lowercased() {
            let hierarchical = text.lowercased().hasPrefix(scheme + "://")
            if hierarchical || opaqueURISchemes.contains(scheme) {
                // URLComponents validates the scheme and escaping; a scheme by
                // itself is not an address. Do not classify arbitrary label:value.
                let remainder = text.dropFirst(scheme.count + 1)
                let needsHost = ["http", "https", "ftp", "ftps", "ws", "wss"].contains(scheme)
                if !remainder.isEmpty, remainder != "//", components.url != nil,
                   !needsHost || components.host?.isEmpty == false { return true }
            }
        }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = linkDetector?.firstMatch(in: text, range: whole), match.range == whole else { return false }
        return match.url != nil
    }
    static func shouldOfferAutomaticTranslation(_ text: String) -> Bool {
        let text = clean(text)
        // Punctuation, symbols and emoji alone have no text to translate.
        // Keep digits meaningful here; manual translation uses validate instead.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        if text.count == 1, text.first?.isLetter == true { return false }
        return !isStandaloneAddress(text) && needsTranslation(text)
    }
    static func needsTranslation(_ text: String) -> Bool {
        let text = clean(text)
        guard !text.isEmpty else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let language = recognizer.dominantLanguage, language == .simplifiedChinese || language == .traditionalChinese { return false }
        // Chinese text containing only a product name/acronym should not trigger a request.
        let han = text.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) }.count
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return han == 0 || Double(han) / Double(max(letters, 1)) < 0.65
    }
    static func validate(_ text: String) throws -> String {
        let text = clean(text)
        guard !text.isEmpty else { throw QingyiError.message("没有可翻译的文字。请先选中文字，或复制文字后按快捷键。") }
        guard text.count <= maximumLength else { throw QingyiError.message("这段文字超过 12,000 字，请缩小选区后再翻译。") }
        guard needsTranslation(text) else { throw QingyiError.message("这段文字已经是中文。默认只将外语翻译为简体中文。") }
        return text
    }
}

struct ModelChoice: Identifiable, Equatable {
    let id: String
    let name: String
    static func parse(_ data: Data) throws -> [ModelChoice] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // The ChatGPT-plan endpoint returns `models` (not the API-key `data` catalog).
        guard let models = object?["models"] as? [[String: Any]] else { throw QingyiError.message("模型列表格式不符合 ChatGPT 订阅接口，无法安全选择模型。") }
        var seen = Set<String>()
        return models.compactMap { value in
            guard value["visibility"] as? String == "list", let slug = value["slug"] as? String, !slug.isEmpty, seen.insert(slug).inserted else { return nil }
            return ModelChoice(id: slug, name: value["display_name"] as? String ?? slug)
        }
    }
}

enum HTTP {
    static func check(_ response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw QingyiError.message("服务器返回了无法识别的响应。") }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let code = error?["code"] as? String ?? object?["error"] as? String ?? ""
            switch response.statusCode {
            case 401: throw QingyiError.message("ChatGPT 登录已失效，请在设置中重新登录。")
            case 403: throw QingyiError.message("账号未获准使用此模型或订阅额度。请在设置中检查授权或切换模型。\(code.isEmpty ? "" : "（\(code)）")")
            case 429: throw QingyiError.message("ChatGPT 使用额度不足或请求过于频繁，请稍后重试，或打开 ChatGPT 用量管理。")
            default: throw QingyiError.message("服务请求失败（HTTP \(response.statusCode)\(code.isEmpty ? "" : "，\(code)")）。请稍后重试。")
            }
        }
    }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }
}

// Never forward authorization headers or selected text to a redirected host.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum AppRuntime {
    static func filesPresent(bundle: URL?, executable: URL?) -> Bool {
        guard let bundle = bundle, let executable = executable else { return false }
        return FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path)
            && FileManager.default.isExecutableFile(atPath: executable.path)
    }
    static func validate() throws {
        guard filesPresent(bundle: Bundle.main.bundleURL, executable: Bundle.main.executableURL) else {
            throw QingyiError.message("轻译的程序文件已移动或被清理。请从菜单栏退出轻译，再从固定安装位置重新打开，然后继续上次授权。")
        }
        var code: SecCode?
        let copied = SecCodeCopySelf([], &code)
        guard copied == errSecSuccess, let code = code else { throw QingyiError.message("无法确认轻译的程序身份（\(copied)）。请退出后重新打开已安装的轻译。") }
        let status = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard status == errSecSuccess else { throw QingyiError.message("轻译的运行版本与磁盘上的签名不一致（\(status)）。请完整退出，再打开最新安装版本。") }
    }
}

enum CredentialStore {
    static let service = "com.laowang.qingyi.chatgpt"
    static func failure(_ action: String, status: OSStatus) -> QingyiError {
        if status == errSecCSStaticCodeNotFound {
            return .message("无法\(action)登录凭据：轻译的程序文件已移动或被清理。请退出旧进程，从固定安装位置重新打开轻译，再继续上次授权。（\(status)）")
        }
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "钥匙串操作未完成"
        return .message("无法\(action)登录凭据（\(status)，\(detail)）。请检查钥匙串是否已解锁，并允许轻译访问自己的凭据。")
    }
    // Exercise the real app's keychain identity before sending the user into OAuth.
    // This short-lived record contains a random diagnostic value, never an account token.
    static func probe() throws {
        let account = "__qingyi_health_" + UUID().uuidString
        let value = try secureRandom()
        try save(value, account: account)
        defer { try? remove(account: account) }
        let loaded = try read(String.self, account: account)
        guard loaded == value else { throw QingyiError.message("钥匙串读写检查未通过，请退出轻译后重新打开。") }
        try remove(account: account)
    }
    static func read<T: Decodable>(_ type: T.Type, account: String, service: String = CredentialStore.service) throws -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure("读取", status: status) }
        return try JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, account: String, service: String = CredentialStore.service, label: String = "轻译 ChatGPT 登录") throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            // Local ad-hoc builds use the macOS login keychain's app ACL. Data-protection
            // keychain access groups require a provisioned signing identity; do not request
            // those entitlements or silently fall back to a plaintext file.
            addition[kSecAttrLabel as String] = label
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure("保存", status: added) }
        } else if status != errSecSuccess { throw failure("更新", status: status) }
    }
    static func remove(account: String, service: String = CredentialStore.service) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("删除", status: status) }
    }
}

// Stateful SSE parser, kept independent of URLSession so fragmented/multi-line events can be tested.
struct ResponseStream {
    var dataLines: [String] = []
    private(set) var text = ""
    private(set) var completed = false
    mutating func line(_ raw: String) throws -> String? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if !line.isEmpty {
            if line.hasPrefix("data:") { dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .init(charactersIn: " "))) }
            return nil
        }
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        if payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8), let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else { throw QingyiError.message("翻译响应格式错误，请重试。") }
        switch type {
        case "response.output_text.delta":
            guard !completed else { return nil }
            text += event["delta"] as? String ?? ""
            return text
        case "response.completed":
            let response = event["response"] as? [String: Any]
            guard response?["status"] as? String == "completed" else { throw QingyiError.message("翻译未完整结束，请重试。") }
            // Some models return only the final output rather than text deltas.
            if text.isEmpty, let output = response?["output"] as? [[String: Any]] {
                text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
            }
            completed = true
            return text
        case "response.failed", "response.incomplete", "error":
            throw QingyiError.message("模型未能完成翻译，请重试或在设置中切换模型。")
        default: return nil
        }
    }
    mutating func finish() throws -> String {
        _ = try line("")
        guard completed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QingyiError.message("翻译连接提前结束，结果不完整，请重试。") }
        return text
    }
}

// Foundation's AsyncBytes.lines can omit empty lines. SSE uses those empty lines as
// event boundaries, so split raw bytes ourselves and preserve every empty line.
struct WireLines {
    private var buffer = Data()
    private var skipLF = false
    mutating func append(_ byte: UInt8) throws -> String? {
        if byte == 10 && skipLF { skipLF = false; return nil }
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            guard let line = String(data: buffer, encoding: .utf8) else { throw QingyiError.message("翻译响应不是有效的 UTF-8 文本。") }
            buffer.removeAll(keepingCapacity: true)
            return line
        }
        skipLF = false; buffer.append(byte)
        guard buffer.count < 1_048_576 else { throw QingyiError.message("翻译响应过长，请缩小选区后重试。") }
        return nil
    }
    mutating func finish() throws -> String? {
        guard !buffer.isEmpty else { return nil }
        guard let line = String(data: buffer, encoding: .utf8) else { throw QingyiError.message("翻译响应不是有效的 UTF-8 文本。") }
        buffer.removeAll(); return line
    }
}

// Decode the response body as well as its headers. Some HTTP intermediaries return a
// completed Responses JSON object, or relay SSE with an inaccurate Content-Type.
// Both paths still require a successful Responses completion and nonempty output.
struct TranslationDecoder {
    enum Format: String { case unknown, sse, json, jsonEvents }
    private(set) var format: Format = .unknown
    private var stream = ResponseStream()
    private var json = ""
    private var eventSize = 0
    let contentType: String
    var completed: Bool { (format == .sse || format == .jsonEvents) && stream.completed }
    mutating func line(_ raw: String) throws -> String? {
        var line = raw
        if format == .unknown {
            line = line.replacingOccurrences(of: "\u{feff}", with: "")
            let start = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if start.isEmpty { return nil }
            if start.hasPrefix("data:") || start.hasPrefix("event:") || start.hasPrefix(":") { format = .sse }
            else if start.hasPrefix("{") {
                if let data = start.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String, type.hasPrefix("response.") || type == "error" { format = .jsonEvents }
                else { format = .json }
            }
            else {
                throw QingyiError.message("翻译接口返回了无法识别的内容（\(contentType.isEmpty ? "未标明类型" : contentType)）。请检查系统代理或稍后重试。")
            }
        }
        switch format {
        case .sse:
            eventSize += line.utf8.count
            guard eventSize < 1_048_576 else { throw QingyiError.message("翻译响应过长，请缩小选区后重试。") }
            if line.trimmingCharacters(in: .newlines).isEmpty { eventSize = 0 }
            return try stream.line(line)
        case .json:
            json += line + "\n"
            guard json.utf8.count < 1_048_576 else { throw QingyiError.message("翻译响应过长，请缩小选区后重试。") }
            return nil
        case .jsonEvents:
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard line.utf8.count < 1_048_576 else { throw QingyiError.message("翻译响应过长，请缩小选区后重试。") }
            _ = try stream.line("data: " + line)
            return try stream.line("")
        case .unknown: return nil
        }
    }
    mutating func finish() throws -> String {
        if format == .sse || format == .jsonEvents { return try stream.finish() }
        guard format == .json, let data = json.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QingyiError.message("翻译接口没有返回完整结果，请重试。") }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "unknown"
            throw QingyiError.message("翻译服务返回错误（\(code)），请重试或切换模型。")
        }
        let response: [String: Any]
        if object["type"] as? String == "response.completed", let wrapped = object["response"] as? [String: Any] { response = wrapped }
        else { response = object }
        guard response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else { throw QingyiError.message("模型未返回已完成的翻译结果，请重试或切换模型。") }
        let text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QingyiError.message("模型没有返回可用译文，请重试或切换模型。") }
        return text
    }
}
