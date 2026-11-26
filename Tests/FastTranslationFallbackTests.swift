import Foundation

extension QingyiTests {
    @MainActor static func fastTranslationFallbackTests() async {
        let source = "The train arrives at 09:42."
        let empty = #"{"choices":[{"message":{"content":"  \n","reasoning_content":"private"},"finish_reason":"stop"}]}"#
        let translated = #"{"choices":[{"message":{"content":"译文"},"finish_reason":"stop"}]}"#
        let usedThinking = #"{"choices":[{"message":{"content":"译文","reasoning_content":"private"},"finish_reason":"stop"}]}"#
        let unsupported = #"{"error":{"param":"thinking","code":"unsupported_parameter","message":"Unsupported parameter: thinking (remote-private-marker)"}}"#
        typealias Gateway = (TranslationEngine, APIConfigurationStore, ModelReasoningKey)
        @MainActor func withGateway(domain: String = "qingyi-fast-retry-" + UUID().uuidString,
                                    vault: MemoryAPIKeyVault = MemoryAPIKeyVault(), modelID: String = "deepseek-v4-flash",
                                    _ test: (Gateway) async throws -> Void) async throws {
            let defaults = UserDefaults(suiteName: domain)!
            let session = FixtureAPIProtocol.session()
            defer {
                session.invalidateAndCancel()
                FixtureAPIProtocol.scheduleResponse = nil
                FixtureAPIProtocol.handle = nil
                defaults.removePersistentDomain(forName: domain)
            }
            var provider = fixtureProvider()
            let model = APIModel(id: modelID, name: "Fixture")
            provider.models = [model]
            let store = APIConfigurationStore(defaults: defaults, vault: vault)
            try store.save(provider, replacementKey: "test-only")
            try store.selectProvider(provider.id)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults, session: session), configuration: store,
                                          client: CustomAPIClient(session: session))
            let key = ModelReasoningKey(provider: provider, modelID: model.id)
            try await test((engine, store, key))
        }

        check("Legacy default-mode retries and new empty-response retries retain distinct history after restart") {
            struct OldRecord: Codable { let status: TranslationThinkingStatus; let usedDefaultRetry: Bool }
            let domain = "qingyi-retry-migration-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let key = ModelReasoningKey(accountID: "fixture", modelID: "gpt-5.2")
            let other = ModelReasoningKey(accountID: "fixture", modelID: "gpt-5.1")
            @MainActor func load() -> APIConfigurationStore { APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault()) }
            defaults.set(try JSONEncoder().encode([key: TranslationThinkingStatus.usedThinking]), forKey: "ai.modelThinkingHistory.v1")
            let v1 = load()
            try expect(v1.lastThinkingStatus(for: key) == .usedThinking && v1.lastThinkingRetry(for: key) == .none)
            let v2 = [key: OldRecord(status: .unreported, usedDefaultRetry: true), other: OldRecord(status: .confirmedOff, usedDefaultRetry: false)]
            defaults.set(try JSONEncoder().encode(v2), forKey: "ai.modelThinkingHistory.v2")
            let migrated = load()
            try expect(migrated.lastThinkingStatus(for: key) == .unreported && migrated.lastThinkingRetry(for: key) == .legacyDefault)
            try expect(migrated.lastThinkingStatus(for: other) == .confirmedOff && migrated.lastThinkingRetry(for: other) == .none)
            migrated.recordThinkingStatus(.requestedOnUnconfirmed, for: key, retry: .emptyResponse)
            let restored = load()
            try expect(restored.lastThinkingStatus(for: key) == .requestedOnUnconfirmed && restored.lastThinkingRetry(for: key) == .emptyResponse)
            try expect(restored.lastThinkingStatus(for: other) == .confirmedOff && restored.lastThinkingRetry(for: other) == .none)
            restored.recordThinkingStatus(.usedThinking, for: key)
            try expect(load().lastThinkingRetry(for: key) == .none)
        }

        await asyncCheck("An empty completed response retries once with the identical model, mode, instructions and source") {
            try await withGateway { engine, store, key in
                let finishedWithoutChoices = #"{"object":"chat.completion","choices":[]}"#
                let usageOnly = "data: {\"choices\":[],\"usage\":{\"completion_tokens\":0}}\n\ndata: [DONE]\n\n"
                for enabled in [true, false] {
                    store.setThinkingMode(enabled, for: key)
                    for (status, first) in [(200, empty), (200, finishedWithoutChoices), (200, usageOnly), (200, ""), (204, "")] {
                        var bodies = [[String: Any]]()
                        var urls = [URL?]()
                        var notifications = 0
                        var updates = [String]()
                        FixtureAPIProtocol.handle = { request in
                            bodies.append(try bodyOfRequest(request))
                            urls.append(request.url)
                            let reply = bodies.count == 1 ? (status, first) : (200, translated)
                            return (reply.0, reply.1.hasPrefix("data:") ? "text/event-stream" : "application/json", Data(reply.1.utf8))
                        }
                        let result = try await engine.translate(source, onEmptyRetry: { notifications += 1 }, onUpdate: { updates.append($0) })
                        try expect(result == "译文" && updates.last == result && !updates.contains(where: { $0.contains("private") }))
                        try expect(bodies.count == 2 && notifications == 1 && urls[0] == urls[1])
                        try expect((bodies[0]["thinking"] as? [String: String])?["type"] == (enabled ? "enabled" : "disabled"))
                        try expect(NSDictionary(dictionary: bodies[0]).isEqual(to: bodies[1]), "Retry must preserve the entire payload")
                        try expect(store.lastThinkingStatus(for: key) == (enabled ? .requestedOnUnconfirmed : .requestedOffUnconfirmed))
                        try expect(store.lastThinkingRetry(for: key) == .emptyResponse)
                    }
                }
            }
        }

        await asyncCheck("A second empty response fails in either thinking mode and preserves the previous successful history") {
            try await withGateway { engine, store, key in
                store.recordThinkingStatus(.confirmedOff, for: key)
                for enabled in [true, false] {
                    store.setThinkingMode(enabled, for: key)
                    var modes = [String?]()
                    var notices = 0
                    FixtureAPIProtocol.handle = { request in
                        let body = try bodyOfRequest(request)
                        modes.append((body["thinking"] as? [String: String])?["type"])
                        return (200, "application/json", Data(empty.utf8))
                    }
                    let value = enabled ? "enabled" : "disabled"
                    var failure: Error?
                    do { _ = try await engine.translate(source, onEmptyRetry: { notices += 1 }, onUpdate: { _ in }) }
                    catch { failure = error }
                    try expect(failure != nil && modes == [value, value] && notices == 1)
                    try expect(store.thinkingModeEnabled(for: key) == enabled && store.lastThinkingRetry(for: key) == .none)
                    try expect(store.lastThinkingStatus(for: key) == .confirmedOff)
                }
            }
        }

        await asyncCheck("Unknown models retry an empty completion once without adding thinking controls") {
            try await withGateway(modelID: "user-alias") { engine, store, key in
                var bodies = [[String: Any]]()
                FixtureAPIProtocol.handle = { request in
                    bodies.append(try bodyOfRequest(request))
                    return (200, "application/json", Data((bodies.count == 1 ? empty : translated).utf8))
                }
                let result = try await engine.translate(source, onUpdate: { _ in })
                try expect(result == "译文" && bodies.count == 2)
                try expect(["thinking", "reasoning", "reasoning_effort"].allSatisfy { bodies[0][$0] == nil })
                try expect(NSDictionary(dictionary: bodies[0]).isEqual(to: bodies[1]))
                try expect(store.lastThinkingStatus(for: key) == .unreported && store.lastThinkingRetry(for: key) == .emptyResponse)
            }
        }

        await asyncCheck("Rate, authentication, transport, malformed, incomplete and refusal failures never retransmit the source") {
            try await withGateway { engine, store, key in
                let cases: [(Int, String, String)] = [
                    (400, "application/json", unsupported),
                    (422, "application/json", #"{"detail":[{"loc":["body","thinking","type"],"type":"extra_forbidden","msg":"Extra inputs are not permitted"}]}"#),
                    (400, "application/json", #"{"error":{"param":"thinking","code":"invalid_value","message":"Invalid value for this request"}}"#),
                    (400, "application/json", #"{"error":{"param":"thinking","code":"unsupported_parameter","message":"网关暂时不支持此参数"}}"#),
                    (401, "application/json", unsupported), (429, "application/json", unsupported), (503, "application/json", unsupported),
                    (400, "application/json", #"{"error":{"param":"model","message":"Unsupported model"}}"#),
                    (400, "application/json", #"{"error":{"param":"temperature","message":"Temperature is unsupported for thinking models"}}"#),
                    (200, "application/json", #"{"choices":[{"message":{"refusal":"declined"},"finish_reason":"stop"}]}"#),
                    (200, "application/json", #"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#),
                    (200, "application/json", "malformed"),
                    (200, "text/event-stream", "data: [DONE]\n\n"),
                    (200, "text/event-stream", "data: {\"choices\":[{\"delta\":{\"content\":\"部分\"}}]}\n\n"),
                    (200, "text/event-stream", "data: {\"choices\":[{\"delta\":{\"content\":\"部分\"}}]}\n\ndata: \(unsupported)\n\n"),
                    (200, "text/event-stream", "data: {\"choices\":[{\"delta\":{\"content\":\" \"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"部分\"}}]}\n\ndata: \(unsupported)\n\n"),
                    (0, "", "")
                ]
                for (status, type, reply) in cases {
                    var attempts = 0
                    var notices = 0
                    FixtureAPIProtocol.handle = { _ in
                        attempts += 1
                        if status == 0 { throw URLError(.timedOut) }
                        return (status, type, Data(reply.utf8))
                    }
                    var failed = false
                    do { _ = try await engine.translate(source, onEmptyRetry: { notices += 1 }, onUpdate: { _ in }) }
                    catch { failed = true }
                    try expect(failed && attempts == 1 && notices == 0, "Unexpected retry/success for \(status) \(reply)")
                    try expect(store.lastThinkingStatus(for: key) == nil)
                }
            }
        }

        await asyncCheck("Cancelling at the empty-response retry boundary prevents a second model request and preserves history") {
            try await withGateway { engine, store, key in
                var requests = 0
                var retryNotices = 0
                store.recordThinkingStatus(.confirmedOff, for: key)
                FixtureAPIProtocol.handle = { _ in
                    requests += 1
                    return (200, "application/json", Data(empty.utf8))
                }
                let task = Task { @MainActor in
                    try await engine.translate(source, onEmptyRetry: {
                        retryNotices += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                    }, onUpdate: { _ in })
                }
                do { _ = try await task.value; throw QingyiError.message("Cancelled retry succeeded") }
                catch is CancellationError { }
                try expect(requests == 1 && retryNotices == 1)
                try expect(store.lastThinkingStatus(for: key) == .confirmedOff)
            }
        }

        await asyncCheck("A delayed empty response for an older same-model request cannot start another request") {
            try await withGateway { engine, store, key in
                var requests = 0
                var release: (() -> Void)?
                FixtureAPIProtocol.handle = { _ in
                    requests += 1
                    return requests == 1 ? (200, "application/json", Data(empty.utf8)) : (200, "application/json", Data(usedThinking.utf8))
                }
                FixtureAPIProtocol.scheduleResponse = { _, deliver in
                    if requests == 1 { DispatchQueue.main.async { release = deliver } }
                    else { deliver() }
                }
                let first = Task { @MainActor in try await engine.translate("Earlier", onUpdate: { _ in }) }
                defer { first.cancel(); release?() }
                for _ in 0..<200 where release == nil { try await Task.sleep(nanoseconds: 10_000_000) }
                try expect(release != nil)
                let recent = try await engine.translate("Latest", onUpdate: { _ in })
                release?()
                release = nil
                let older = await first.result
                if case .success = older { throw QingyiError.message("Stale request retried") }
                try expect(requests == 2 && recent == "译文")
                try expect(store.lastThinkingStatus(for: key) == .usedThinking && store.lastThinkingRetry(for: key) == .none)
            }
        }

        await asyncCheck("ChatGPT subscription retries compatible Responses with the same account and model and no second catalog fetch") {
            let domain = "qingyi-chat-retry-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil; defaults.removePersistentDomain(forName: domain) }
            let model = "gpt-5.2"
            let account = Registration(id: "retry-account", subject: "fixture", email: "fixture@example.invalid")
            defaults.set(try JSONEncoder().encode([account]), forKey: "registrations")
            defaults.set(account.id, forKey: "activeRegistration")
            defaults.set(model, forKey: "model.\(account.id)")
            let vault = MemoryChatGPTVault()
            vault.credentials = Credentials(access: "subscription-test", refresh: nil, idToken: "", scopes: ["chatgpt.tokens.use.direct"], expiry: Date().addingTimeInterval(3600))
            let chat = ChatGPT(defaults: defaults, session: session, vault: vault)
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: chat, configuration: store, client: CustomAPIClient(session: session))
            let key = ModelReasoningKey(accountID: account.id, modelID: model)
            var catalog = 0
            for enabled in [true, false] {
                store.setThinkingMode(enabled, for: key)
                var bodies = [[String: Any]]()
                FixtureAPIProtocol.handle = { request in
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer subscription-test")
                    if request.url?.path == "/v1/models" {
                        catalog += 1
                        return (200, "application/json", Data(#"{"models":[{"slug":"gpt-5.2","display_name":"GPT-5.2","visibility":"list"}]}"#.utf8))
                    }
                    try expect(request.url?.path == "/v1/responses")
                    bodies.append(try bodyOfRequest(request))
                    if bodies.count == 1 {
                        return (200, "text/event-stream", Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n".utf8))
                    }
                    return (200, "application/json", Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"译文"}]}]}"#.utf8))
                }
                let result = try await engine.translate(source, onUpdate: { _ in })
                try expect(result == "译文" && bodies.count == 2 && bodies[0]["model"] as? String == model)
                try expect((bodies[0]["reasoning"] as? [String: String])?["effort"] == (enabled ? "medium" : "none"))
                try expect(NSDictionary(dictionary: bodies[0]).isEqual(to: bodies[1]) && store.lastThinkingRetry(for: key) == .emptyResponse)
            }
            try expect(catalog == 1)
            for enabled in [false, true] {
                store.setThinkingMode(enabled, for: key)
                var calls = 0
                FixtureAPIProtocol.handle = { _ in
                    calls += 1
                    if enabled && calls == 1 {
                        return (200, "application/json", Data(#"{"status":"completed","output":[]}"#.utf8))
                    }
                    return (400, "application/json", Data(#"{"error":{"param":"reasoning.effort","code":"unsupported_value","message":"Unsupported effort (remote-private-marker)"}}"#.utf8))
                }
                var feedback = ""
                do { _ = try await engine.translate(source, onUpdate: { _ in }) } catch { feedback = error.localizedDescription }
                let mode = enabled ? "开启" : "关闭"
                let effort = enabled ? "medium" : "none"
                try expect(feedback.contains(model) && feedback.contains(mode) && feedback.contains("reasoning.effort=\(effort)"))
                try expect(!feedback.contains("remote-private-marker") && calls == (enabled ? 2 : 1))
            }
        }

        await asyncCheck("Relaunch ignores old gateway rejection records and keeps the saved model preference after a rejection") {
            let domain = "qingyi-gateway-rejection-" + UUID().uuidString
            let vault = MemoryAPIKeyVault()
            try await withGateway(domain: domain, vault: vault) { _, store, key in
                let defaults = UserDefaults(suiteName: domain)!
                defaults.set(try JSONEncoder().encode(Set([key])), forKey: "ai.modelFastTranslationRejections.v1")
                store.setThinkingMode(false, for: key)
                let network = FixtureAPIProtocol.session()
                defer { network.invalidateAndCancel() }
                @MainActor func reopen() -> TranslationEngine {
                    TranslationEngine(chat: ChatGPT(defaults: defaults, session: network), configuration: APIConfigurationStore(defaults: defaults, vault: vault),
                                      client: CustomAPIClient(session: network))
                }
                var modes = [String?]()
                FixtureAPIProtocol.handle = { request in
                    let body = try bodyOfRequest(request)
                    modes.append((body["thinking"] as? [String: String])?["type"])
                    return modes.count == 1 ? (400, "application/json", Data(unsupported.utf8)) : (200, "application/json", Data(translated.utf8))
                }
                var feedback = ""
                do { _ = try await reopen().translate(source, onUpdate: { _ in }) } catch { feedback = error.localizedDescription }
                try expect(feedback.contains("deepseek-v4-flash") && feedback.contains("关闭") && feedback.contains("thinking.type=disabled"))
                try expect(!feedback.contains("remote-private-marker") && modes == ["disabled"])
                let relaunched = reopen()
                let result = try await relaunched.translate(source, onUpdate: { _ in })
                try expect(result == "译文" && modes == ["disabled", "disabled"])
                try expect(!relaunched.configuration.thinkingModeEnabled(for: key) && relaunched.configuration.lastThinkingRetry(for: key) == .none)
                relaunched.configuration.setThinkingMode(true, for: key)
                _ = try await reopen().translate(source, onUpdate: { _ in })
                try expect(modes == ["disabled", "disabled", "enabled"])
                var retryCalls = 0
                FixtureAPIProtocol.handle = { _ in
                    retryCalls += 1
                    return (200, "application/json", Data((retryCalls == 1 ? empty : unsupported).utf8))
                }
                feedback = ""
                do { _ = try await relaunched.translate(source, onUpdate: { _ in }) } catch { feedback = error.localizedDescription }
                try expect(feedback.contains("deepseek-v4-flash") && feedback.contains("开启") && feedback.contains("thinking.type=enabled"))
                try expect(!feedback.contains("remote-private-marker") && retryCalls == 2)
            }
        }
    }
}
