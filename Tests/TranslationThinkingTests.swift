import Foundation

extension QingyiTests {
    @MainActor static func translationThinkingTests() async {
        check("Each supported model receives its protocol-specific thinking setting; unknown endpoints and aliases use service defaults") {
            let flash = APIModel(id: "deepseek-v4-flash", name: "Display name")
            let gpt = APIModel(id: "gpt-5.2", name: "GPT")
            let sonnet = APIModel(id: "claude-sonnet-4-6", name: "Sonnet")
            let legacy = APIModel(id: "claude-sonnet-4-5", name: "Older Sonnet", maximumOutputTokens: 2048)
            func checkBody(_ proto: APIProtocol, _ url: String, _ model: APIModel, field: String?,
                           on: Any? = nil, off: Any? = nil) throws {
                var provider = fixtureProvider(proto)
                provider.baseURL = url
                try expect(ThinkingCapability.supports(provider: provider, model: model) == (field != nil))
                for enabled in [true, false] {
                    let request = try APIRequestBuilder.request(provider: provider, model: model, key: "fixture",
                                                               input: .translation("Hello"), thinkingEnabled: enabled)
                    let body = try bodyOfRequest(request)
                    let control = body.filter { ["thinking", "reasoning", "reasoning_effort"].contains($0.key) }
                    let expected = enabled ? on : off
                    if let field, let expected {
                        try expect(NSDictionary(dictionary: control).isEqual(to: [field: expected]),
                                   "Wrong thinking control for \(model.id), \(proto), enabled=\(enabled): \(control)")
                    } else { try expect(control.isEmpty, "Unsupported model/endpoint must use service defaults") }
                    if model.id == legacy.id { try expect(body["max_tokens"] as? Int == 2048) }
                }
            }
            let on = ["type": "enabled"], off = ["type": "disabled"]
            try checkBody(.chatCompletions, "https://fixture.example/v1", flash, field: "thinking", on: on, off: off)
            try checkBody(.chatCompletions, "https://api.deepseek.com/v1", flash, field: "thinking", on: on, off: off)
            try checkBody(.anthropic, "https://api.deepseek.com/anthropic/v1", flash, field: "thinking", on: on, off: off)
            try checkBody(.responses, "https://api.deepseek.com/v1", flash, field: "reasoning", on: ["effort": "high"], off: ["effort": "none"])
            try checkBody(.chatCompletions, "https://api.openai.com/v1", gpt, field: "reasoning_effort", on: "medium", off: "none")
            try checkBody(.responses, "https://api.openai.com/v1", gpt, field: "reasoning", on: ["effort": "medium"], off: ["effort": "none"])
            try checkBody(.anthropic, "https://api.anthropic.com/v1", sonnet, field: "thinking", on: ["type": "adaptive"], off: off)
            try checkBody(.anthropic, "https://api.anthropic.com/v1", legacy, field: "thinking", on: ["type": "enabled", "budget_tokens": 1024], off: off)
            try checkBody(.chatCompletions, "https://fixture.example/v1", APIModel(id: "user-alias", name: flash.id), field: nil)
            try checkBody(.responses, "https://fixture.example/v1", flash, field: nil)
            try checkBody(.anthropic, "https://fixture.example/v1", sonnet, field: nil)
            for id in ["claude-sonnet-5-5", "claude-opus-5-5"] {
                try checkBody(.anthropic, "https://api.anthropic.com/v1", APIModel(id: id, name: id), field: nil)
            }
            for model in [gpt.id, "user-defined-alias"] {
                try expect(ThinkingCapability.supportsChatGPT(modelID: model) == (model == gpt.id))
                for enabled in [true, false] {
                    let data = try ChatGPT.translationBody(text: "Hello", model: model, thinkingEnabled: enabled)
                    let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    let expected: String? = model == gpt.id ? (enabled ? "medium" : "none") : nil
                    try expect((body["reasoning"] as? [String: String])?["effort"] == expected)
                    if expected == nil { try expect(body["reasoning"] == nil) }
                }
            }
        }

        await asyncCheck("Older Claude rejects an insufficient output budget before sending source and accepts the same limit with thinking off") {
            let domain = "qingyi-thinking-budget-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            var provider = fixtureProvider(.anthropic)
            provider.baseURL = "https://api.anthropic.com/v1"
            let model = APIModel(id: "claude-sonnet-4-5", name: "Fixture", maximumOutputTokens: 1024)
            provider.models = [model]
            try store.save(provider, replacementKey: "fixture-only"); try store.selectProvider(provider.id)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: store, client: CustomAPIClient(session: network))
            var requests = 0
            FixtureAPIProtocol.handle = { request in
                requests += 1
                let body = try bodyOfRequest(request)
                try expect(body["max_tokens"] as? Int == 1024 && (body["thinking"] as? [String: String])?["type"] == "disabled")
                return (200, "application/json", Data(#"{"content":[{"type":"text","text":"译文"}],"stop_reason":"end_turn"}"#.utf8))
            }
            do { _ = try await engine.translate("Budget validation", onUpdate: { _ in }); throw QingyiError.message("Expected budget error") }
            catch { try expect(error.localizedDescription.contains("1024"), error.localizedDescription) }
            try expect(requests == 0)
            store.setThinkingMode(false, for: ModelReasoningKey(provider: provider, modelID: model.id))
            let translated = try await engine.translate("Budget validation", onUpdate: { _ in })
            try expect(requests == 1 && translated == "译文")
        }

        check("The wire decoder distinguishes used, explicitly off and unreported reasoning without displaying private text") {
            let chat: APIProtocol = .chatCompletions
            let cases: [(APIProtocol, String, TranslationThinkingEvidence)] = [
                (chat, #"{"choices":[{"message":{"content":"译文","reasoning_content":""},"finish_reason":"stop"}],"usage":{"completion_tokens_details":{"reasoning_tokens":0}}}"#, .unreported),
                (chat, #"{"choices":[{"message":{"content":"译文"},"finish_reason":"stop"}],"thinking":{"type":"disabled"}}"#, .confirmedOff),
                (chat, #"{"choices":[{"message":{"content":"译文","reasoning_content":"private"},"finish_reason":"stop"}],"thinking":{"type":"disabled"}}"#, .used),
                (chat, """
                    data: {"choices":[{"index":0,"delta":{"content":"译文"},"finish_reason":"stop"}]}

                    data: {"choices":[],"usage":{"completion_tokens_details":{"reasoning_tokens":3}}}

                    data: [DONE]

                    """, .used),
                (.responses, #"{"status":"completed","output":[{"type":"reasoning","id":"rs_test","summary":[]},{"content":[{"type":"output_text","text":"译文"}]}]}"#, .unreported),
                (.responses, #"{"status":"completed","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"private"}]},{"content":[{"type":"output_text","text":"译文"}]}]}"#, .used),
                (.anthropic, #"{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"译文"}],"stop_reason":"end_turn"}"#, .used)
            ]
            for (proto, value, expected) in cases {
                var decoder = CustomAPIDecoder(apiProtocol: proto)
                var lines = WireLines()
                for byte in value.utf8 {
                    if let line = try lines.append(byte) { _ = try decoder.line(line) }
                }
                if let tail = try lines.finish() { _ = try decoder.line(tail) }
                try expect(try decoder.finish() == "译文")
                try expect(decoder.thinkingEvidence == expected, "Wrong evidence for \(proto) and \(expected)")
            }
        }

        check("Thinking mode defaults on and preferences persist separately across accounts, models, protocols and endpoints") {
            let domain = "qingyi-thinking-state-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let provider = fixtureProvider()
            let model = "deepseek-v4-flash"
            let first = ModelReasoningKey(provider: provider, modelID: model)
            try expect(store.isUnconfigured && store.thinkingModeEnabled(for: first))
            try expect(store.lastThinkingStatus(for: first) == nil)
            let revision = store.revision
            store.recordThinkingStatus(.usedThinking, for: first)
            store.setThinkingMode(false, for: first)
            var moved = provider
            moved.baseURL = "https://different.example/v1"
            var changedProtocol = provider
            changedProtocol.apiProtocol = .responses
            let unrelated = [ModelReasoningKey(provider: fixtureProvider(), modelID: model),
                ModelReasoningKey(provider: provider, modelID: "another"),
                ModelReasoningKey(provider: moved, modelID: model),
                ModelReasoningKey(provider: changedProtocol, modelID: model),
                ModelReasoningKey(accountID: provider.id, modelID: model)]
            for key in unrelated {
                try expect(store.thinkingModeEnabled(for: key) && store.lastThinkingStatus(for: key) == nil)
            }
            try expect(store.revision == revision && store.lastThinkingStatus(for: first) == .usedThinking)
            let restored = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            try expect(!restored.thinkingModeEnabled(for: first) && restored.lastThinkingStatus(for: first) == .usedThinking)
            try expect(restored.isUnconfigured)
        }

        check("Explicit legacy fast settings are preserved as inverse thinking settings") {
            let domain = "qingyi-thinking-legacy-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let off = ModelReasoningKey(accountID: "old-off", modelID: "gpt-5.2")
            let on = ModelReasoningKey(accountID: "old-on", modelID: "gpt-5.2")
            let saved = try JSONEncoder().encode([off: true, on: false])
            defaults.set(saved, forKey: APIConfigurationStore.fastTranslationStorageKey)
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            try expect(!store.thinkingModeEnabled(for: off) && store.thinkingModeEnabled(for: on))
            try expect(defaults.data(forKey: APIConfigurationStore.fastTranslationStorageKey) == saved)
            store.setThinkingMode(true, for: off)
            let restored = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            try expect(restored.thinkingModeEnabled(for: off))
        }

        await asyncCheck("Actual engine requests and completed history follow the chosen mode, model and response") {
            let domain = "qingyi-thinking-engine-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            var provider = fixtureProvider()
            provider.models = [APIModel(id: "deepseek-v4-flash", name: "快译"), APIModel(id: "other", name: "其他")]
            try store.save(provider, replacementKey: "fixture")
            try store.selectProvider(provider.id)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: store,
                client: CustomAPIClient(session: network))
            let first = ModelReasoningKey(provider: provider, modelID: provider.models[0].id)
            let other = ModelReasoningKey(provider: provider, modelID: "other")
            let translated = #"{"choices":[{"message":{"content":"译文"},"finish_reason":"stop"}]}"#
            func respond(_ json: String, expectedMode: String?, model: String) {
                FixtureAPIProtocol.handle = { request in
                    let body = try bodyOfRequest(request)
                    try expect(body["model"] as? String == model)
                    if let expectedMode { try expect((body["thinking"] as? [String:String])?["type"] == expectedMode) }
                    else { try expect(body["thinking"] == nil) }
                    return (200, "application/json", Data(json.utf8))
                }
            }
            respond(translated, expectedMode: "enabled", model: provider.models[0].id)
            let initial = try await engine.translate("Default thinking", onUpdate: { _ in })
            try expect(initial == "译文" && store.lastThinkingStatus(for: first) == .requestedOnUnconfirmed)
            store.setThinkingMode(false, for: first)
            respond(translated, expectedMode: "disabled", model: provider.models[0].id)
            let firstValue = try await engine.translate("Hello", onUpdate: { _ in })
            try expect(firstValue == "译文" && store.lastThinkingStatus(for: first) == .requestedOffUnconfirmed)
            store.setThinkingMode(true, for: first)
            try expect(store.lastThinkingStatus(for: first) == .requestedOffUnconfirmed)
            respond(translated, expectedMode: "enabled", model: provider.models[0].id)
            _ = try await engine.translate("Again", onUpdate: { _ in })
            try expect(store.lastThinkingStatus(for: first) == .requestedOnUnconfirmed)
            respond(#"{"choices":[{"message":{"content":"译文","reasoning_content":"private"},"finish_reason":"stop"}]}"#, expectedMode: nil, model: "other")
            let target = TranslationTarget(service: .customAPI(provider.id), modelID: "other")
            _ = try await engine.translate("Temporary", target: target, onUpdate: { _ in })
            try expect(store.lastThinkingStatus(for: other) == .usedThinking && store.lastThinkingStatus(for: first) == .requestedOnUnconfirmed)
            FixtureAPIProtocol.handle = { _ in (502, "text/plain", Data()) }
            do {
                _ = try await engine.translate("Failure", target: target, onUpdate: { _ in })
                throw QingyiError.message("Expected upstream error")
            } catch { try expect(error.localizedDescription.contains("502")) }
            try expect(store.lastThinkingStatus(for: other) == .usedThinking)
        }

        await asyncCheck("A later same-model translation keeps its thinking status when an older response finishes last") {
            let domain = "qingyi-thinking-overlap-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer {
                defaults.removePersistentDomain(forName: domain)
                FixtureAPIProtocol.scheduleResponse = nil
                FixtureAPIProtocol.handle = nil
                network.invalidateAndCancel()
            }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            var provider = fixtureProvider()
            provider.models = [APIModel(id: "deepseek-v4-flash", name: "快译")]
            try store.save(provider, replacementKey: "fixture")
            try store.selectProvider(provider.id)
            let modelKey = ModelReasoningKey(provider: provider, modelID: provider.models[0].id)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: store,
                client: CustomAPIClient(session: network))
            var releaseFirst: (() -> Void)?
            var calls = 0
            FixtureAPIProtocol.handle = { _ in
                calls += 1
                let body = calls == 1
                    ? #"{"choices":[{"message":{"content":"较早译文"},"finish_reason":"stop"}],"thinking":{"type":"disabled"}}"#
                    : #"{"choices":[{"message":{"content":"较晚译文","reasoning_content":"private"},"finish_reason":"stop"}]}"#
                return (200, "application/json", Data(body.utf8))
            }
            FixtureAPIProtocol.scheduleResponse = { _, deliver in
                if calls == 1 { DispatchQueue.main.async { releaseFirst = deliver } }
                else { deliver() }
            }
            store.setThinkingMode(false, for: modelKey)
            let earlier = Task { @MainActor in try await engine.translate("Earlier", onUpdate: { _ in }) }
            defer { earlier.cancel(); releaseFirst?() }
            for _ in 0..<200 where releaseFirst == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(releaseFirst != nil, "Earlier request did not reach the mock server")
            store.setThinkingMode(true, for: modelKey)
            let newer = try await engine.translate("Newer", onUpdate: { _ in })
            try expect(newer == "较晚译文" && store.lastThinkingStatus(for: modelKey) == .usedThinking)
            releaseFirst?()
            releaseFirst = nil
            let older = try await earlier.value
            try expect(older == "较早译文" && store.lastThinkingStatus(for: modelKey) == .usedThinking)
        }
    }
}
