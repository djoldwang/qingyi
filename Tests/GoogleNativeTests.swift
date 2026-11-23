import Foundation

extension QingyiTests {
    @MainActor static func googleNativeTests() async {
        await asyncCheck("The unsigned Google request returns translation, pronunciation and all parts in one call") {
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            var requests = 0
            FixtureAPIProtocol.handle = { request in
                requests += 1
                let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                try expect(fields.first { $0.name == "q" }?.value == "queue")
                try expect(fields.first { $0.name == "client" }?.value == "gtx")
                try expect(fields.filter { $0.name == "dt" }.compactMap(\.value) == ["t", "bd", "rm"])
                try expect(!fields.contains { $0.name == "tk" })
                return (200, "application/json", Data(#"{"sentences":[{"trans":"队列","orig":"queue"},{"src_translit":"kyo͞o","translit":"Duìliè"}],"dict":[{"pos":"noun","terms":["队列","辫子"]},{"pos":"verb","terms":["排队"]}]}"#.utf8))
            }
            let result = try await BuiltinTranslationClient(session: session).translate("queue", service: .google)
            try expect(requests == 1 && result.text == "队列" && result.phonetics == ["/kyo͞o/"])
            try expect(result.meanings == [.init(part: "noun", text: "队列；辫子"), .init(part: "verb", text: "排队")])
            try expect(result.copyText == "noun 队列；辫子\nverb 排队")
        }
        await asyncCheck("Malformed Google primary responses use the unsigned alternate origin with the intact original") {
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let source = "Hello + 中文 & symbols.\n\nKeep the last line."
            var requests = 0
            FixtureAPIProtocol.handle = { request in
                requests += 1
                let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                try expect(fields.first { $0.name == "q" }?.value == source)
                try expect(fields.first { $0.name == "client" }?.value == "gtx")
                try expect(!fields.contains { ["tk", "key", "token", "sign"].contains($0.name) })
                if requests == 1 {
                    try expect(request.url?.host == "translate.google.com")
                    return (200, "text/html", Data("<html>Temporary error</html>".utf8))
                }
                try expect(request.url?.host == "translate.googleapis.com")
                return (200, "application/json", Data(#"{"sentences":[{"trans":"你好。"},{"trans":"\n\n保留末行。"}]}"#.utf8))
            }
            let result = try await BuiltinTranslationClient(session: session).translate(source, service: .google)
            try expect(result.text == "你好。\n\n保留末行。" && requests == 2)
        }
        await asyncCheck("The alternate Google origin preserves all dictionary fields and stops after a second failure") {
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            var requests = 0
            FixtureAPIProtocol.handle = { request in
                requests += 1
                if request.url?.host == "translate.google.com" { return (503, "text/plain", Data()) }
                let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                try expect(fields.filter { $0.name == "dt" }.compactMap(\.value) == ["t", "bd", "rm"])
                try expect(fields.first { $0.name == "client" }?.value == "gtx")
                try expect(!fields.contains { $0.name == "tk" })
                return (200, "application/json", Data(#"{"sentences":[{"trans":"队列"},{"src_translit":"kyo͞o"}],"dict":[{"pos":"noun","terms":["队列"]},{"pos":"verb","terms":["排队"]}]}"#.utf8))
            }
            let client = BuiltinTranslationClient(session: session)
            let result = try await client.translate("queue", service: .google)
            try expect(requests == 2 && result.phonetics == ["/kyo͞o/"] && result.meanings.count == 2)
            requests = 0
            FixtureAPIProtocol.handle = { _ in requests += 1; return (503, "text/plain", Data()) }
            do { _ = try await client.translate("queue", service: .google); throw QingyiError.message("Second failure ignored") }
            catch { try expect(error.localizedDescription.contains("503")) }
            try expect(requests == 2)
        }
        await asyncCheck("Google rate limits and cancellation stop without another request") {
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            var requests = 0
            FixtureAPIProtocol.handle = { _ in
                requests += 1
                return (429, "text/html", Data())
            }
            do {
                _ = try await BuiltinTranslationClient(session: session).translate("resilience", service: .google)
                throw QingyiError.message("Rate limit ignored")
            } catch { try expect(error.localizedDescription.contains("频繁")) }
            try expect(requests == 1)
            let task = Task { @MainActor in
                try await BuiltinTranslationClient(session: session).translate("Cancelled source", service: .google)
            }
            task.cancel()
            do { _ = try await task.value; throw QingyiError.message("Cancellation ignored") }
            catch is CancellationError { }
            try expect(requests == 1)
        }
        check("Google native parsers retain dictionary-only results and reject empty or HTML responses") {
            let result = try GoogleWebTranslation.parseGoogleGTX(Data(#"{"sentences":[],"dict":[{"pos":"noun","terms":["恢复力"]}]}"#.utf8))
            try expect(result.meanings == [.init(part: "noun", text: "恢复力")])
            try rejects { _ = try GoogleWebTranslation.parseGoogleGTX(Data(#"{"sentences":[]}"#.utf8)) }
            try rejects { _ = try GoogleWebTranslation.parseGoogleGTX(Data("<html>Consent</html>".utf8)) }
            let nilPhone = try GoogleWebTranslation.parseGoogleGTX(Data(#"{"sentences":[{"trans":"你好","src_translit":null}],"dict":null}"#.utf8))
            try expect(nilPhone.text == "你好" && nilPhone.phonetics.isEmpty)
        }
    }
}
