import Foundation

extension QingyiTests {
    static func youdaoQuery(_ request: URLRequest) throws -> String {
        let fields = URLComponents(string: "https://fixture.invalid/?" + String(decoding: try dataOfRequest(request), as: UTF8.self))?.queryItems ?? []
        guard let source = fields.first(where: { $0.name == "q" })?.value else { throw QingyiError.message("Missing native query") }
        return source
    }
    static func youdaoNativeReply(_ source: String, target: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["input": source,
            "fanyi": ["input": source, "type": "en2zh-CHS", "tran": target ?? source]])
    }
    @MainActor static func youdaoFastTests() async {
        check("Youdao segmentation retains complete paragraphs, sentence endings, emoji and every source character") {
            let paragraph = String(repeating: "A complete sentence includes a bicycle and a violin. 😀 ", count: 30)
            let original = "First paragraph.\r\n\r\n" + paragraph + "\n\nThe final passenger has a purple umbrella."
            let plan = try YoudaoTextPlan(original)
            try expect(plan.pieces.count > 2 && plan.pieces.allSatisfy { $0.source.utf16.count <= 600 })
            let restored = try plan.pieces.indices.map { try plan.render(plan.pieces[$0].source, for: $0) }.joined()
            try expect(restored == original.replacingOccurrences(of: "\r\n", with: "\n"))
            try expect(restored.hasSuffix("purple umbrella."))
            try rejects { _ = try YoudaoTextPlan(String(repeating: "x", count: 601)) }
        }
        check("Native fast translation protects code, URLs, versions and recovery markers and rejects lost or duplicated literals") {
            let original = "Install `easytier-core` via crates.io. Visit https://example.com/v1.0.3?q=one&x=2. Keep AMBER-7309 and €42.50.\n\n```sh\necho one\necho two\n```"
            let plan = try YoudaoTextPlan(original)
            try expect(plan.pieces.count == 1)
            let masked = plan.pieces[0].source
            try expect(try YoudaoTextPlan(original).pieces.map(\.source) == plan.pieces.map(\.source), "Repeated source must not invalidate provider caching")
            try expect(!masked.contains("easytier-core") && !masked.contains("crates.io") && !masked.contains("AMBER-7309"))
            try expect(try plan.render(masked, for: 0) == original)
            let marker = try NSRegularExpression(pattern: #"QY[A-F0-9]{8}X\d+QY"#).firstMatch(in: masked, range: NSRange(masked.startIndex..., in: masked))!
            let token = (masked as NSString).substring(with: marker.range)
            try rejects { _ = try plan.render(masked.replacingOccurrences(of: token, with: ""), for: 0) }
            try rejects { _ = try plan.render(masked + " " + token, for: 0) }
            let command = try YoudaoTextPlan("binstall only installs executables.")
            try expect(try command.render("Binstall 只安装可执行文件。", for: 0) == "binstall 只安装可执行文件。")
        }
        check("Native Youdao results reject clipped or mismatched input and the wrong target language") {
            let source = "The complete original."
            try expect(try YoudaoNativeRequest.parseTranslation(youdaoNativeReply(source, target: "完整译文。"), source: source) == "完整译文。")
            for object: [String: Any] in [
                ["input": "The complete", "fanyi": ["input": source, "type": "en2zh-CHS", "tran": "译文"]],
                ["input": source, "fanyi": ["input": "The complete", "type": "en2zh-CHS", "tran": "译文"]],
                ["input": source, "fanyi": ["input": source, "type": "en2ja", "tran": "译文"]],
                ["input": source, "fanyi": ["input": source, "type": "en2zh-CHS", "tran": " "]]
            ] {
                try rejects { _ = try YoudaoNativeRequest.parseTranslation(JSONSerialization.data(withJSONObject: object), source: source) }
            }
            do {
                _ = try YoudaoNativeRequest.parseTranslation(Data(#"{"code":429}"#.utf8), source: source)
                throw QingyiError.message("Rate limit ignored")
            } catch let failure as YoudaoNativeRequest.Failure { try expect(failure == .rateLimited) }
        }
        await asyncCheck("Native Youdao dictionary keeps both pronunciations and parts of speech in one request") {
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            var requests = 0
            FixtureAPIProtocol.handle = { request in
                requests += 1
                try expect(request.url?.path == "/jsonapi_s" && request.httpMethod == "POST")
                try expect(try youdaoQuery(request) == "queue")
                let reply = #"{"input":"queue","ec":{"word":{"return-phrase":"queue","ukphone":"kjuː","usphone":"kjuː","trs":[{"pos":"n.","tran":"队列"},{"pos":"v.","tran":"排队"}]}}}"#
                return (200, "application/json", Data(reply.utf8))
            }
            let result = try await BuiltinTranslationClient(session: session).translate("queue", service: .youdao)
            try expect(requests == 1 && result.phonetics == ["英 [kjuː]", "美 [kjuː]"])
            try expect(result.meanings == [.init(part: "n.", text: "队列"), .init(part: "v.", text: "排队")])
            let generic = Data(#"{"input":"co-operate","ec":{"word":{"return-phrase":"co-operate","phone":"kəu'ɔpəreit","trs":[{"pos":"vi.","tran":"合作；配合"}]}}}"#.utf8)
            let parsed = try YoudaoNativeRequest.parseDictionary(generic, source: "co-operate")
            try expect(parsed?.phonetics == ["[kəu'ɔpəreit]"] && parsed?.meanings.first?.part == "vi.")
        }
        await asyncCheck("Youdao connection preparation sends only one source-free HEAD and remains cancellable") {
            let session = FixtureAPIProtocol.session()
            let lock = NSLock()
            var requests = 0
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil; FixtureAPIProtocol.scheduleResponse = nil }
            FixtureAPIProtocol.handle = { request in
                lock.withLock { requests += 1 }
                try expect(request.url?.absoluteString == "https://dict.youdao.com/" && request.httpMethod == "HEAD")
                try expect(request.httpBody == nil && request.httpBodyStream == nil)
                try expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
                return (200, "text/html", Data())
            }
            FixtureAPIProtocol.scheduleResponse = { _, _ in }
            let client = BuiltinTranslationClient(session: session)
            client.prepareYoudaoConnection(); client.prepareYoudaoConnection()
            for _ in 0..<100 where lock.withLock({ requests == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
            client.cancelYoudaoPreparation()
            try expect(lock.withLock { requests == 1 })
        }
        await asyncCheck("Concurrent Youdao paragraphs have at most six requests and publish only an ordered contiguous prefix") {
            let session = FixtureAPIProtocol.session()
            let lock = NSLock()
            var deliveries: [(String, () -> Void)] = []
            var active = 0, maximum = 0, requests = 0
            var updates: [String] = []
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil; FixtureAPIProtocol.scheduleResponse = nil }
            let paragraphs = (0..<8).map { index in
                "Paragraph \(index). " + String(repeating: "A complete sentence remains in the original order. ", count: 8) + "AMBER-73\(index)."
            }
            let source = paragraphs.joined(separator: "\n\n")
            FixtureAPIProtocol.handle = { request in
                try expect(request.url?.path == "/jsonapi_s")
                let input = try youdaoQuery(request)
                try expect(input.utf16.count <= 600)
                lock.withLock { requests += 1; active += 1; maximum = max(maximum, active) }
                return (200, "application/json", try youdaoNativeReply(input))
            }
            FixtureAPIProtocol.scheduleResponse = { request, deliver in
                let input = try! youdaoQuery(request)
                lock.withLock { deliveries.append((input, deliver)) }
            }
            let task = Task { @MainActor in
                try await BuiltinTranslationClient(session: session).translate(source, service: .youdao) { updates.append($0) }
            }
            defer { task.cancel() }
            for _ in 0..<100 where lock.withLock({ deliveries.count < 6 }) { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(lock.withLock { deliveries.count == 6 })
            // Hold the first paragraph while later paragraphs finish in reverse
            // order. No later paragraph may appear in its place in the card.
            for _ in 0..<7 {
                var release: (() -> Void)?
                for _ in 0..<100 {
                    release = lock.withLock {
                        guard let index = deliveries.lastIndex(where: { !$0.0.hasPrefix("Paragraph 0.") }) else { return nil }
                        active -= 1
                        return deliveries.remove(at: index).1
                    }
                    if release != nil { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard let release else { throw QingyiError.message("Missing concurrent paragraph") }
                release()
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            try expect(updates.isEmpty)
            let first = lock.withLock { active -= 1; return deliveries.removeFirst().1 }
            first()
            let result = try await task.value
            try expect(result.text == source && updates.last == source)
            try expect(lock.withLock { requests == 8 && maximum == 6 && active == 0 })
        }
        await asyncCheck("Cancelling concurrent Youdao paragraphs starts no remaining chunks, publishes no late text and never opens a page") {
            let session = FixtureAPIProtocol.session()
            let lock = NSLock()
            var requests = 0, updates = 0, pages = 0
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil; FixtureAPIProtocol.scheduleResponse = nil }
            let source = (0..<7).map { index in "Paragraph \(index). " + String(repeating: "Keep this complete sentence together. ", count: 11) }.joined(separator: "\n\n")
            FixtureAPIProtocol.handle = { request in
                lock.withLock { requests += 1 }
                return (200, "application/json", try youdaoNativeReply(youdaoQuery(request)))
            }
            FixtureAPIProtocol.scheduleResponse = { _, _ in }
            let client = YoudaoTranslation(session: session, webpage: { _ in pages += 1; return .init(text: "wrong page") })
            let task = Task { @MainActor in try await client.translate(source) { _ in updates += 1 } }
            for _ in 0..<100 where lock.withLock({ requests < 6 }) { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(lock.withLock { requests == 6 })
            task.cancel()
            do { _ = try await task.value; throw QingyiError.message("Cancellation ignored") }
            catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            try expect(lock.withLock { requests == 6 } && updates == 0 && pages == 0)
        }
        await asyncCheck("A rate-limited native Youdao response stops the batch without mobile, whole-text or page retries") {
            let session = FixtureAPIProtocol.session()
            let lock = NSLock()
            var requests = 0, pages = 0
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            FixtureAPIProtocol.handle = { request in
                try expect(request.url?.path == "/jsonapi_s")
                lock.withLock { requests += 1 }
                return (200, "application/json", Data(#"{"code":429}"#.utf8))
            }
            let client = YoudaoTranslation(session: session, webpage: { _ in pages += 1; return .init(text: "wrong page") })
            let source = String(repeating: "A complete sentence must remain in order. ", count: 40)
            do { _ = try await client.translate(source); throw QingyiError.message("Rate limit ignored") }
            catch let failure as YoudaoNativeRequest.Failure { try expect(failure == .rateLimited) }
            try expect(lock.withLock { requests > 0 && requests <= 6 } && pages == 0)
        }
    }
}
