import Foundation
import CryptoKit
import CommonCrypto

extension QingyiTests {
    static let youdaoTestKeys = YoudaoWholeTranslation.Keys(secretKey: "fixture-signing", aesKey: "fixture-key", aesIv: "fixture-iv")
    static func youdaoEncrypted(_ source: String, target: String = "完整译文") throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: ["code": 0, "translateResult": [[["src": source, "tgt": target]]]])
        let key = Data(Insecure.MD5.hash(data: Data(youdaoTestKeys.aesKey.utf8)))
        let iv = Data(Insecure.MD5.hash(data: Data(youdaoTestKeys.aesIv.utf8)))
        var output = Data(count: json.count + kCCBlockSizeAES128)
        let capacity = output.count
        var used = 0
        let status = output.withUnsafeMutableBytes { out in json.withUnsafeBytes { input in
            key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key.baseAddress, kCCKeySizeAES128, iv.baseAddress, input.baseAddress, json.count, out.baseAddress, capacity, &used)
            } }
        } }
        try expect(status == kCCSuccess)
        return Data(output.prefix(used).base64URL.utf8)
    }
    static var youdaoKeyResponse: Data {
        Data(#"{"code":0,"data":{"secretKey":"fixture-signing","aesKey":"fixture-key","aesIv":"fixture-iv"}}"#.utf8)
    }
    static func youdaoInput(_ request: URLRequest) throws -> String {
        let data = try dataOfRequest(request)
        let parts = URLComponents(string: "https://fixture.example/?" + String(decoding: data, as: UTF8.self))
        guard let text = parts?.queryItems?.first(where: { $0.name == "i" })?.value else { throw QingyiError.message("Missing whole input") }
        return text
    }
    @MainActor static func youdaoDirectTests() async {
        check("Youdao streams require a begin event, matching request identity and successful nonempty end") {
            let begin = "id:one\nevent:begin\ndata:{\"requestId\":\"one\"}\n\n"
            let body = "id:one\nevent:message\ndata:{\"transIncre\":\"第一段\"}\n\n"
            let end = "id:one\nevent:end\ndata:{\"transIncre\":\"结束\"}\n\n"
            var decoder = YoudaoStreamDecoder()
            for line in (begin + body + end).components(separatedBy: "\n") { _ = try decoder.line(line) }
            try expect(try decoder.finish() == "第一段结束")
            for invalid in [
                body + end,
                begin + body,
                begin + body + end.replacingOccurrences(of: "id:one", with: "id:other"),
                begin + body + "event:error\ndata:{\"code\":50}\n\n",
                begin + body + "event:end\ndata:{\"code\":\"50\"}\n\n",
                begin + "event:end\ndata:{}\n\n"
            ] {
                try rejects {
                    var decoder = YoudaoStreamDecoder()
                    for line in invalid.components(separatedBy: "\n") { _ = try decoder.line(line) }
                    _ = try decoder.finish()
                }
            }
        }
        await asyncCheck("A rejected legacy Youdao request uses anonymous native streaming, sends the complete input and publishes partial text") {
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let source = TextPolicy.clean(String(repeating: "This installs the matching DLL beside the executable. ", count: 16))
            var streamRequests = 0
            var updates: [String] = []
            FixtureAPIProtocol.handle = { request in
                switch request.url?.path {
                case "/jsonapi_s": return (200, "application/json", Data("{}".utf8))
                case "/translate": return (200, "text/html", Data("<html></html>".utf8))
                case "/webtranslate/key": return (200, "application/json", youdaoKeyResponse)
                case "/webtranslate": return (200, "application/json", Data(#"{"code":50}"#.utf8))
                case "/translate/key":
                    try expect(request.httpMethod == "POST")
                    let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    try expect(fields.contains { $0.name == "targetKeyid" && $0.value == "translate-webfanyi-webmain" })
                    return (200, "application/json", Data(#"{"code":0,"data":{"secretKey":"fixture-public-secret","token":"fixture-guest-token"}}"#.utf8))
                case "/webtranslate/sse":
                    streamRequests += 1
                    let fields = URLComponents(string: "https://fixture.invalid/?" + String(decoding: try dataOfRequest(request), as: UTF8.self))?.queryItems ?? []
                    let submitted = fields.first { $0.name == "i" }?.value?.removingPercentEncoding
                    try expect(submitted == source && request.httpMethod == "POST")
                    try expect(fields.contains { $0.name == "modelName" && $0.value == "llmLite" })
                    let text = "id:fixture\nevent:begin\ndata:{\"requestId\":\"fixture\"}\n\nid:fixture\nevent:message\ndata:{\"transIncre\":\"第一段\"}\n\nid:fixture\nevent:end\ndata:{\"transIncre\":\"完整结束\"}\n\n"
                    return (200, "text/event-stream", Data(text.utf8))
                default: throw QingyiError.message("Unexpected website fallback")
                }
            }
            let result = try await BuiltinTranslationClient(session: session).translate(source, service: .youdao) { updates.append($0) }
            try expect(result.text == "第一段完整结束" && streamRequests == 1)
            try expect(updates.first == "第一段" && updates.last == result.text)
        }
        await asyncCheck("A cancelled Youdao stream never publishes text and rate limits do not launch another translation") {
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            var requests = 0
            var updates = 0
            FixtureAPIProtocol.handle = { request in
                requests += 1
                return (429, "application/json", Data())
            }
            let client = YoudaoStreamingTranslation(session: session)
            do { _ = try await client.translate("Long source") { _ in updates += 1 }; throw QingyiError.message("Rate limit ignored") }
            catch let failure as YoudaoStreamingTranslation.Failure {
                if case .rateLimited = failure { } else { throw failure }
            }
            try expect(requests == 1)
            let cancelled = Task { @MainActor in try await client.translate("New source") { _ in updates += 1 } }
            cancelled.cancel()
            do { _ = try await cancelled.value; throw QingyiError.message("Cancellation ignored") }
            catch is CancellationError { }
            try expect(requests == 1 && updates == 0)
        }
        check("Direct dictionary parsing keeps phonetics, parts and markup and rejects a mismatched entry") {
            let page = """
                <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"></head><body><div id="ec"><h2><span>queue</span>
                <div><span>英 <span class="phonetic">[kjuː]</span></span>
                <span>美 <span class="phonetic">[kjuː]</span></span></div></h2>
                <ul><li>n. &lt;英&gt;队列；行列</li><li>v. 排队</li></ul></div></body></html>
                """
            let result = YoudaoTranslation.parseDictionary(Data(page.utf8), source: "queue")
            try expect(result?.phonetics == ["英 [kjuː]", "美 [kjuː]"], "Unexpected phonetics \(String(describing: result))")
            try expect(result?.meanings == [.init(part: "n.", text: "<英>队列；行列"), .init(part: "v.", text: "排队")], "Unexpected meanings \(String(describing: result))")
            try expect(YoudaoTranslation.parseDictionary(Data(page.utf8), source: "resilience") == nil)
            try expect(YoudaoTranslation.parseDictionary(Data("<div id=ec><h2><span>queue</span></h2></div>".utf8), source: "queue") == nil)
        }
        await asyncCheck("Long input is submitted intact once, shares temporary parameters, and refreshes them after expiry") {
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            var time = Date()
            let whole = YoudaoWholeTranslation(session: session, now: { time })
            let source = String(repeating: "Train 42 carries a violin & an apple. ", count: 30) + "\n\n最后一段 🧑🏽‍💻 + <tag>."
            var keyRequests = 0
            var inputs: [String] = []
            FixtureAPIProtocol.handle = { request in
                if request.url?.path == "/jsonapi_s" { return (200, "application/json", Data("{}".utf8)) }
                if request.url?.path == "/translate" { return (200, "text/html", Data("<html></html>".utf8)) }
                if request.url?.path == "/webtranslate/key" {
                    keyRequests += 1
                    return (200, "application/json", youdaoKeyResponse)
                }
                try expect(request.url?.path == "/webtranslate" && request.httpMethod == "POST")
                let input = try youdaoInput(request)
                inputs.append(input)
                return (200, "text/plain", try youdaoEncrypted(input))
            }
            let first = try await whole.translate(source)
            let second = try await whole.translate(source + "\nAnother ending.")
            try expect(first.text == "完整译文" && second.text == first.text)
            try expect(keyRequests == 1 && inputs == [source, source + "\nAnother ending."])
            time.addTimeInterval(61)
            _ = try await whole.translate(source)
            try expect(keyRequests == 2 && inputs == [source, source + "\nAnother ending.", source])
            try rejects { _ = try YoudaoWholeTranslation.decode(try youdaoEncrypted("truncated source"), keys: youdaoTestKeys, source: source) }
        }
        await asyncCheck("Cached verification failures refresh once while incomplete or mismatched whole responses use the whole-page fallback") {
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let source = String(repeating: "First paragraph.\n\nSecond paragraph.\n", count: 20)
            var keyRequests = 0
            var posts = 0
            var fallbacks = 0
            let client = YoudaoTranslation(session: session, webpage: { input in
                try expect(input == source)
                fallbacks += 1
                return BuiltinTranslationResult(text: "网页完整结果")
            })
            FixtureAPIProtocol.handle = { request in
                if request.url?.path == "/jsonapi_s" { return (200, "application/json", Data("{}".utf8)) }
                if request.url?.path == "/translate" { return (200, "text/html", Data("<html></html>".utf8)) }
                if request.url?.path == "/webtranslate/key" {
                    keyRequests += 1
                    return (200, "application/json", youdaoKeyResponse)
                }
                posts += 1
                let input = try youdaoInput(request)
                return (200, "text/plain", posts == 2 ? Data(#"{"code":50}"#.utf8) : try youdaoEncrypted(input))
            }
            _ = try await client.translate(source)
            let refreshed = try await client.translate(source)
            try expect(refreshed.text == "完整译文" && keyRequests == 2 && posts == 3 && fallbacks == 0)
            FixtureAPIProtocol.handle = { request in
                if request.url?.path == "/jsonapi_s" { return (200, "application/json", Data("{}".utf8)) }
                if request.url?.path == "/translate" { return (200, "text/html", Data("<html></html>".utf8)) }
                posts += 1
                return (200, "text/plain", try youdaoEncrypted("First paragraph."))
            }
            let fallback = try await client.translate(source)
            try expect(fallback.text == "网页完整结果" && fallbacks == 1 && posts == 4)
        }
        await asyncCheck("Cancelling a shared parameter lookup never submits the old source and the next selection reuses the lookup") {
            let session = FixtureAPIProtocol.session()
            defer {
                session.invalidateAndCancel()
                FixtureAPIProtocol.handle = nil
                FixtureAPIProtocol.scheduleResponse = nil
            }
            let whole = YoudaoWholeTranslation(session: session)
            let lock = NSLock()
            var keyRequests = 0
            var inputs: [String] = []
            var release: (() -> Void)?
            FixtureAPIProtocol.handle = { request in
                if request.url?.path == "/webtranslate/key" {
                    lock.withLock { keyRequests += 1 }
                    return (200, "application/json", youdaoKeyResponse)
                }
                let input = try youdaoInput(request)
                lock.withLock { inputs.append(input) }
                return (200, "text/plain", try youdaoEncrypted(input))
            }
            FixtureAPIProtocol.scheduleResponse = { request, deliver in
                if request.url?.path == "/webtranslate/key" { lock.withLock { release = deliver } }
                else { deliver() }
            }
            let old = Task { try await whole.translate("Old source.\nAnother paragraph.") }
            for _ in 0..<100 {
                let ready = lock.withLock { release != nil }
                if ready { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            old.cancel()
            do { _ = try await old.value; throw QingyiError.message("Cancellation ignored") }
            catch is CancellationError { }
            let next = Task { try await whole.translate("New source.\nFinal paragraph.") }
            try await Task.sleep(for: .milliseconds(30))
            let deliver = lock.withLock { release }
            guard let deliver else { throw QingyiError.message("Missing key request") }
            deliver()
            let result = try await next.value
            try expect(result.text == "完整译文" && keyRequests == 1 && inputs == ["New source.\nFinal paragraph."])
        }
        await asyncCheck("Invalid direct responses fall back with the whole source and cancelled or rate-limited tasks do not") {
            let session = FixtureAPIProtocol.session()
            defer {
                session.invalidateAndCancel()
                FixtureAPIProtocol.handle = nil
                FixtureAPIProtocol.scheduleResponse = nil
            }
            var fallbackSources: [String] = []
            let client = YoudaoTranslation(session: session, webpage: { source in
                fallbackSources.append(source)
                return BuiltinTranslationResult(text: "全文页面结果")
            })
            FixtureAPIProtocol.handle = { _ in (200, "text/html", Data("<form><textarea id=inputText>wrong source</textarea></form>".utf8)) }
            let source = "First paragraph.\n\nSecond paragraph."
            let result = try await client.translate(source)
            try expect(result.text == "全文页面结果" && fallbackSources == [source])
            FixtureAPIProtocol.handle = { _ in (429, "text/html", Data()) }
            do { _ = try await client.translate(source); throw QingyiError.message("Rate limit was ignored") }
            catch { try expect(error.localizedDescription.contains("频繁")) }
            try expect(fallbackSources == [source])
            let lock = NSLock()
            var started = false
            FixtureAPIProtocol.handle = { _ in
                lock.withLock { started = true }
                return (200, "text/html", Data("<html></html>".utf8))
            }
            FixtureAPIProtocol.scheduleResponse = { _, _ in }
            let cancelled = Task { @MainActor in try await client.translate(source) }
            for _ in 0..<100 {
                let ready = lock.withLock { started }
                if ready { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let ready = lock.withLock { started }
            try expect(ready, "Requests did not start")
            cancelled.cancel()
            do { _ = try await cancelled.value; throw QingyiError.message("Cancellation was ignored") }
            catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            try expect(fallbackSources == [source])
        }
    }
}
