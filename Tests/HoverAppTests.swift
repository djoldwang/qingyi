import AppKit

final class DelayedSettingsVault: ChatGPTCredentialVault {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var mainRead = false
    var snapshot: (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (count, mainRead) }
    func read(_ id: String) throws -> Credentials? {
        lock.lock(); count += 1; mainRead = Thread.isMainThread; lock.unlock()
        _ = gate.wait(timeout: .now() + 2)
        return Credentials(access: "fixture", refresh: nil, idToken: "", scopes: ["chatgpt.tokens.use.direct"], expiry: Date().addingTimeInterval(3600))
    }
    func save(_ credentials: Credentials, id: String) throws {}
    func remove(_ id: String) throws {}
}

extension QingyiTests {
    @MainActor static func hoverAppTests() async {
        await asyncCheck("Settings credential restoration stays off the main thread and coalesces a delayed read") {
            let name = "qingyi-settings-async-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name); FixtureAPIProtocol.handle = nil }
            defaults.set(try JSONEncoder().encode([Registration(id: "fixture", subject: "fixture", email: "fixture@example.com")]), forKey: "registrations")
            defaults.set("fixture", forKey: "activeRegistration")
            let vault = DelayedSettingsVault()
            let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: vault)
            FixtureAPIProtocol.handle = { _ in (200, "application/json", Data(#"{"models":[]}"#.utf8)) }
            chat.restoreForSettings(); chat.restoreForSettings()
            for _ in 0..<30 where vault.snapshot.0 == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            try expect(vault.snapshot.0 == 1 && !vault.snapshot.1 && !chat.signedIn)
            vault.gate.signal()
            for _ in 0..<100 where !chat.signedIn { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(chat.signedIn)
            chat.cancelLogin()
        }
        await asyncCheck("Production hover skips Chinese silently and preserves pinned translation, retry and mouse-up ownership") {
            let domain = "qingyi-hover-app-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain); FixtureAPIProtocol.handle = nil }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            var provider = APIProvider(); provider.name = "hover fixture"; provider.baseURL = "https://fixture.example/v1"
            provider.models = [APIModel(id: "fixture", name: "fixture")]
            try store.save(provider, replacementKey: "fixture-only"); try store.selectProvider(provider.id)
            let paragraph = "Read the helpful link and bold words together. Keep the entire second sentence too."
            var sources: [String] = []
            FixtureAPIProtocol.handle = { request in
                guard request.url?.host == "fixture.example" else { throw QingyiError.message("Unexpected real request") }
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let messages = body["messages"] as? [[String: Any]] else { throw QingyiError.message("Missing fixture request body") }
                if let content = messages.last?["content"] as? String { sources.append(content) }
                else if let content = messages.last?["content"] as? [[String: Any]] { sources.append(content.compactMap { $0["text"] as? String }.joined()) }
                else { throw QingyiError.message("Missing text content") }
                return (200, "application/json", Data(#"{"choices":[{"message":{"content":"完整段落的测试中文译文"},"finish_reason":"stop"}]}"#.utf8))
            }
            let app = AppDelegate()
            app.prepareHoverFixture(engine: TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: store, client: CustomAPIClient(session: FixtureAPIProtocol.session())))
            defer { app.dismissHoverFixture() }
            app.preferences.paused = true // The hover entry remains independent.
            let chinese = [
                "这段文字已经是简体中文。",
                "這段文字已經是繁體中文，不需要翻譯。",
                "你好，云朵剧场的纸龙正准备第 3 场月光舞会，需要 2 张会唱歌的请柬：Lumi Puff（8 拍），花纹编号 MOON-27-B。请让纸龙念出暗号，再把银色丝带系在请柬上。"
            ]
            for text in chinese { app.feedHoverFixture(text) }
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(sources.isEmpty && !app.floating.resultPanel.isVisible && !app.floating.state.error)
            try expect(app.monitor.hoverOwnsSelection && !app.floating.buttonPanel.isVisible)
            app.feedHoverFixture(paragraph)
            for _ in 0..<100 where !app.floating.state.complete { try await Task.sleep(nanoseconds: 20_000_000) }
            try expect(sources == [paragraph] && app.floating.state.complete && app.floating.resultPanel.isVisible, "Hover completion: sources=\(sources), complete=\(app.floating.state.complete), error=\(app.floating.state.error), text=\(app.floating.state.text)")
            let release = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            app.monitor.onExternalEvent = { $0.type == .leftMouseUp }
            app.monitor.event(release)
            try expect(app.monitor.hoverOwnsSelection && app.floating.resultPanel.isVisible && sources.count == 1)
            app.floating.state.pinned = true
            let previousID = app.floating.state.sessionID
            let previousText = app.floating.state.text
            for text in chinese { app.feedHoverFixture(text) }
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(sources == [paragraph] && app.floating.resultPanel.isVisible && app.floating.state.pinned)
            try expect(app.floating.state.sessionID == previousID && app.floating.state.text == previousText && app.floating.state.complete)
            app.floating.onRetry?()
            for _ in 0..<100 where !app.floating.state.complete { try await Task.sleep(nanoseconds: 20_000_000) }
            try expect(sources == [paragraph, paragraph] && app.floating.state.complete)
            app.feedHoverFixture("A new paragraph that will be cancelled immediately.")
            app.dismissHoverFixture()
            try await Task.sleep(nanoseconds: 100_000_000)
            try expect(!app.floating.resultPanel.isVisible && sources.count == 2)
        }
    }
}
