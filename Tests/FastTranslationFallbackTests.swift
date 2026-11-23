import Foundation

extension QingyiTests {
    @MainActor static func fastTranslationFallbackTests() async {
        let source = "The train arrives at 09:42."
        let empty = #"{"choices":[{"message":{"content":"  \n","reasoning_content":"private"},"finish_reason":"stop"}]}"#
        let translated = #"{"choices":[{"message":{"content":"译文"},"finish_reason":"stop"}]}"#
        let usedThinking = #"{"choices":[{"message":{"content":"译文","reasoning_content":"private"},"finish_reason":"stop"}]}"#
        let unsupported = #"{"error":{"param":"thinking","code":"unsupported_parameter","message":"Unsupported parameter: thinking"}}"#
        typealias Gateway = (TranslationEngine, APIConfigurationStore, ModelReasoningKey)
        @MainActor func withGateway(domain: String = "qingyi-fast-retry-" + UUID().uuidString,
                                    vault: MemoryAPIKeyVault = MemoryAPIKeyVault(),
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
            let model = APIModel(id: "deepseek-v4-flash", name: "快译")
            provider.models = [model]
            let store = APIConfigurationStore(defaults: defaults, vault: vault)
            try store.save(provider, replacementKey: "test-only")
            try store.selectProvider(provider.id)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults, session: session), configuration: store,
                                          client: CustomAPIClient(session: session))
            try await test((engine, store, ModelReasoningKey(provider: provider, modelID: model.id)))
        }

        check("The fallback marker is stored alongside evidence and build 53 history survives upgrade") {
            let domain = "qingyi-retry-migration-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let key = ModelReasoningKey(accountID: "fixture", modelID: "gpt-5.2")
            let legacy = try JSONEncoder().encode([key: TranslationThinkingStatus.usedThinking])
            defaults.set(legacy, forKey: "ai.modelThinkingHistory.v1")
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            try expect(store.lastThinkingStatus(for: key) == .usedThinking && !store.lastTranslationUsedDefaultRetry(for: key))
            store.recordThinkingStatus(.usedThinking, for: key, usedDefaultRetry: true)
            let restored = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            try expect(restored.lastThinkingStatus(for: key) == .usedThinking && restored.lastTranslationUsedDefaultRetry(for: key))
            restored.recordThinkingStatus(.usedThinking, for: key)
            let direct = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            try expect(direct.lastThinkingStatus(for: key) == .usedThinking && !direct.lastTranslationUsedDefaultRetry(for: key))
        }

        await asyncCheck("A rejected fast control or a completed empty translation retries the identical request in default mode") {
            try await withGateway { engine, store, key in
                let forbidden = #"{"detail":[{"loc":["body","thinking","type"],"type":"extra_forbidden","msg":"Extra inputs are not permitted"}]}"#
                let finishedWithoutChoices = #"{"object":"chat.completion","choices":[]}"#
                let usageOnly = "data: {\"choices\":[],\"usage\":{\"completion_tokens\":0}}\n\ndata: [DONE]\n\n"
                for (status, first, second, evidence) in [(400, unsupported, usedThinking, TranslationThinkingStatus.usedThinking),
                                                          (422, forbidden, translated, .unreported),
                                                          (200, empty, translated, .unreported),
                                                          (200, finishedWithoutChoices, translated, .unreported),
                                                          (200, usageOnly, translated, .unreported),
                                                          (200, "", translated, .unreported),
                                                          (204, "", translated, .unreported)] {
                    store.clearFastTranslationRejection(for: key)
                    var bodies = [[String: Any]]()
                    var urls = [URL?]()
                    var notifications = 0
                    var updates = [String]()
                    FixtureAPIProtocol.handle = { request in
                        bodies.append(try bodyOfRequest(request))
                        urls.append(request.url)
                        let reply = bodies.count == 1 ? (status, first) : (200, second)
                        return (reply.0, reply.1.hasPrefix("data:") ? "text/event-stream" : "application/json", Data(reply.1.utf8))
                    }
                    let result = try await engine.translate(source, onDefaultRetry: { notifications += 1 }, onUpdate: { updates.append($0) })
                    try expect(result == "译文" && updates.last == result && !updates.contains(where: { $0.contains("private") }))
                    try expect(bodies.count == 2 && notifications == 1 && urls[0] == urls[1])
                    var fastBody = bodies[0]
                    try expect((fastBody.removeValue(forKey: "thinking") as? [String: String])?["type"] == "disabled")
                    try expect(NSDictionary(dictionary: fastBody).isEqual(to: bodies[1]), "Retry changed model, messages or non-fast options")
                    try expect(store.lastThinkingStatus(for: key) == evidence && store.lastTranslationUsedDefaultRetry(for: key))
                    try expect(store.fastTranslationEnabled(for: key))
                    if status < 400 { try expect(!store.hasRememberedFastTranslationRejection(for: key)) }
                }
                var attempts = 0
                FixtureAPIProtocol.handle = { request in
                    attempts += 1
                    try expect(try bodyOfRequest(request)["thinking"] != nil)
                    return (200, "application/json", Data(translated.utf8))
                }
                _ = try await engine.translate(source, onUpdate: { _ in })
                try expect(attempts == 1 && store.lastThinkingStatus(for: key) == .requestedOffUnconfirmed)
                try expect(!store.lastTranslationUsedDefaultRetry(for: key))
            }
        }

        await asyncCheck("Default retry is capped at one, and failed attempts preserve the previous successful history") {
            try await withGateway { engine, store, key in
                store.recordThinkingStatus(.confirmedOff, for: key)
                for fast in [true, false] {
                    store.setFastTranslation(fast, for: key)
                    var modes = [Bool]()
                    var fallbackNotices = 0
                    FixtureAPIProtocol.handle = { request in
                        modes.append(try bodyOfRequest(request)["thinking"] != nil)
                        return (200, "application/json", Data(empty.utf8))
                    }
                    var failure: Error?
                    do { _ = try await engine.translate(source, onDefaultRetry: { fallbackNotices += 1 }, onUpdate: { _ in }) }
                    catch { failure = error }
                    try expect(failure != nil && modes == (fast ? [true, false] : [false]))
                    try expect(fallbackNotices == (fast ? 1 : 0))
                    try expect(store.fastTranslationEnabled(for: key) == fast)
                    try expect(store.lastThinkingStatus(for: key) == .confirmedOff && !store.lastTranslationUsedDefaultRetry(for: key))
                }
            }
        }

        await asyncCheck("Rate, authentication, transport, malformed, incomplete and refusal failures never retransmit the source") {
            try await withGateway { engine, store, key in
                let cases: [(Int, String, String)] = [
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
                    do { _ = try await engine.translate(source, onDefaultRetry: { notices += 1 }, onUpdate: { _ in }) }
                    catch { failed = true }
                    try expect(failed && attempts == 1 && notices == 0, "Unexpected retry/success for \(status) \(reply)")
                    try expect(store.lastThinkingStatus(for: key) == nil)
                    try expect(!store.hasRememberedFastTranslationRejection(for: key))
                }
            }
        }

        await asyncCheck("Cancelling at the fallback boundary prevents a second model request and preserves history") {
            try await withGateway { engine, store, key in
                var requests = 0
                var fallbackNotices = 0
                store.recordThinkingStatus(.confirmedOff, for: key)
                FixtureAPIProtocol.handle = { _ in
                    requests += 1
                    return (400, "application/json", Data(unsupported.utf8))
                }
                let task = Task { @MainActor in
                    try await engine.translate(source, onDefaultRetry: {
                        fallbackNotices += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                    }, onUpdate: { _ in })
                }
                do { _ = try await task.value; throw QingyiError.message("Cancelled retry succeeded") }
                catch is CancellationError { }
                try expect(requests == 1 && fallbackNotices == 1)
                try expect(store.lastThinkingStatus(for: key) == .confirmedOff)
            }
        }

        await asyncCheck("A delayed rejection for an older same-model request cannot start a default retry") {
            try await withGateway { engine, store, key in
                var requests = 0
                var release: (() -> Void)?
                FixtureAPIProtocol.handle = { _ in
                    requests += 1
                    return requests == 1 ? (400, "application/json", Data(unsupported.utf8)) : (200, "application/json", Data(usedThinking.utf8))
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
                try expect(store.lastThinkingStatus(for: key) == .usedThinking && !store.lastTranslationUsedDefaultRetry(for: key))
                try expect(!store.hasRememberedFastTranslationRejection(for: key))
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
            for (status, reply) in [(400, #"{"error":{"param":"reasoning.effort","code":"unsupported_value","message":"The model does not support reasoning.effort none"}}"#),
                                    (200, "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n")] {
                var modes = [Bool]()
                FixtureAPIProtocol.handle = { request in
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer subscription-test")
                    if request.url?.path == "/v1/models" {
                        catalog += 1
                        return (200, "application/json", Data(#"{"models":[{"slug":"gpt-5.2","display_name":"GPT-5.2","visibility":"list"}]}"#.utf8))
                    }
                    try expect(request.url?.path == "/v1/responses")
                    let body = try bodyOfRequest(request)
                    try expect(body["model"] as? String == model)
                    modes.append(body["reasoning"] != nil)
                    if modes.count == 1 { return (status, status == 200 ? "text/event-stream" : "application/json", Data(reply.utf8)) }
                    return (200, "application/json", Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"默认译文"}]}]}"#.utf8))
                }
                let result = try await engine.translate(source, onUpdate: { _ in })
                try expect(result == "默认译文" && modes == [true, false])
                try expect(store.lastThinkingStatus(for: key) == .unreported && store.lastTranslationUsedDefaultRetry(for: key))
                try expect(store.hasRememberedFastTranslationRejection(for: key) == (status == 400))
                if status == 400 {
                    _ = try await engine.translate("Next selection", onUpdate: { _ in })
                    try expect(modes == [true, false, false] && !store.lastTranslationUsedDefaultRetry(for: key))
                    store.clearFastTranslationRejection(for: key)
                }
            }
            try expect(catalog == 1 && store.fastTranslationEnabled(for: key))
        }

        await asyncCheck("A rejected gateway fast parameter is remembered before default retry succeeds or fails and survives relaunch") {
            let domain = "qingyi-remember-gateway-" + UUID().uuidString
            let vault = MemoryAPIKeyVault()
            try await withGateway(domain: domain, vault: vault) { engine, store, key in
                var modes = [Bool]()
                var notices = 0
                FixtureAPIProtocol.handle = { request in
                    modes.append(try bodyOfRequest(request)["thinking"] != nil)
                    switch modes.count {
                    case 1: return (400, "application/json", Data(unsupported.utf8))
                    case 2: return (503, "application/json", Data())
                    default: return (200, "application/json", Data(translated.utf8))
                    }
                }
                var failed = false
                do { _ = try await engine.translate(source, onDefaultRetry: { notices += 1 }, onUpdate: { _ in }) }
                catch { failed = true }
                try expect(failed && modes == [true, false] && notices == 1)
                try expect(store.fastTranslationEnabled(for: key) && store.hasRememberedFastTranslationRejection(for: key))
                try expect(store.lastThinkingStatus(for: key) == nil)

                let defaults = UserDefaults(suiteName: domain)!
                let resumed = APIConfigurationStore(defaults: defaults, vault: vault)
                let session = FixtureAPIProtocol.session()
                defer { session.invalidateAndCancel() }
                let relaunched = TranslationEngine(chat: ChatGPT(defaults: defaults, session: session),
                    configuration: resumed, client: CustomAPIClient(session: session))
                let direct = try await relaunched.translate(source, onDefaultRetry: { notices += 1 }, onUpdate: { _ in })
                try expect(direct == "译文" && modes == [true, false, false] && notices == 1)
                try expect(resumed.lastThinkingStatus(for: key) == .unreported && !resumed.lastTranslationUsedDefaultRetry(for: key))

                resumed.clearFastTranslationRejection(for: key)
                try expect(!resumed.hasRememberedFastTranslationRejection(for: key) && modes.count == 3)
                _ = try await relaunched.translate(source, onUpdate: { _ in })
                try expect(modes == [true, false, false, true] && resumed.fastTranslationEnabled(for: key))
                try expect(resumed.lastThinkingStatus(for: key) == .requestedOffUnconfirmed)
            }
        }

        await asyncCheck("Ambiguous parameter validation falls back once and allows fast mode on the next request") {
            try await withGateway { engine, store, key in
                let cases = [
                    #"{"error":{"param":"thinking","code":"invalid_value","message":"Invalid value for this request"}}"#,
                    #"{"error":{"param":"thinking","code":"unsupported_parameter","message":"thinking is temporarily not supported"}}"#,
                    #"{"error":{"param":"thinking","code":"unsupported_parameter","message":"网关暂时不支持此参数"}}"#
                ]
                for reply in cases {
                    var modes = [Bool]()
                    FixtureAPIProtocol.handle = { request in
                        modes.append(try bodyOfRequest(request)["thinking"] != nil)
                        if modes.count == 1 { return (400, "application/json", Data(reply.utf8)) }
                        return (200, "application/json", Data(translated.utf8))
                    }
                    _ = try await engine.translate(source, onUpdate: { _ in })
                    _ = try await engine.translate(source, onUpdate: { _ in })
                    try expect(modes == [true, false, true] && !store.hasRememberedFastTranslationRejection(for: key))
                }
            }
        }

        check("Remembered capabilities isolate account, provider, endpoint, protocol and model; cleared probes cannot restore stale rejections") {
            let domain = "qingyi-rejection-isolation-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let model = "deepseek-v4-flash"
            let provider = fixtureProvider()
            let key = ModelReasoningKey(provider: provider, modelID: model)
            let subscription = ModelReasoningKey(accountID: "account-1", modelID: model)
            let generation = store.fastTranslationRejectionGeneration(for: key)
            store.rememberFastTranslationRejection(for: key, generation: generation)
            store.rememberFastTranslationRejection(for: subscription, generation: store.fastTranslationRejectionGeneration(for: subscription))
            var moved = provider
            moved.baseURL = "https://fixture.example/second/v1"
            var otherProtocol = provider
            otherProtocol.apiProtocol = .responses
            var equivalent = provider
            equivalent.baseURL = "https://FIXTURE.EXAMPLE:443/v1/"
            try expect(store.hasRememberedFastTranslationRejection(for: ModelReasoningKey(provider: equivalent, modelID: model)))
            let separate = [ModelReasoningKey(provider: provider, modelID: "other"), ModelReasoningKey(provider: moved, modelID: model),
                ModelReasoningKey(provider: otherProtocol, modelID: model), ModelReasoningKey(provider: fixtureProvider(), modelID: model),
                ModelReasoningKey(accountID: "account-2", modelID: model)]
            for other in separate { try expect(!store.hasRememberedFastTranslationRejection(for: other)) }
            store.clearFastTranslationRejection(for: key)
            store.rememberFastTranslationRejection(for: key, generation: generation)
            try expect(!store.hasRememberedFastTranslationRejection(for: key) && store.hasRememberedFastTranslationRejection(for: subscription))
            let restored = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            try expect(!restored.hasRememberedFastTranslationRejection(for: key) && restored.hasRememberedFastTranslationRejection(for: subscription))
        }
    }
}
