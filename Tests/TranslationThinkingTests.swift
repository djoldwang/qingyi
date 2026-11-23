import Foundation

extension QingyiTests {
    @MainActor static func translationThinkingTests() async {
        check("Fast translation sends only a documented switch for the actual model, provider and protocol") {
            let flash = APIModel(id: "deepseek-v4-flash", name: "自定义显示名")
            let gpt = APIModel(id: "gpt-5.2", name: "GPT")
            func body(_ provider: APIProvider, _ model: APIModel, enabled: Bool) throws -> [String: Any] {
                let request = try APIRequestBuilder.request(provider: provider, model: model, key: "fixture",
                    input: .translation("Hello"), fastTranslation: enabled)
                return try bodyOfRequest(request)
            }
            let gateway = fixtureProvider()
            try expect(FastTranslationCapability.supports(provider: gateway, model: flash))
            try expect(try (body(gateway, flash, enabled: true)["thinking"] as? [String: String])?["type"] == "disabled")
            try expect(try body(gateway, flash, enabled: false)["thinking"] == nil)
            let unknown = APIModel(id: "user-alias", name: "deepseek-v4-flash")
            try expect(!FastTranslationCapability.supports(provider: gateway, model: unknown))
            try expect(try body(gateway, unknown, enabled: true)["thinking"] == nil)
            let wrongProtocol = fixtureProvider(.responses)
            try expect(!FastTranslationCapability.supports(provider: wrongProtocol, model: flash))
            let unsupportedBody = try body(wrongProtocol, flash, enabled: true)
            try expect(unsupportedBody["reasoning"] == nil && unsupportedBody["thinking"] == nil)
            var anthropic = fixtureProvider(.anthropic)
            let sonnet = APIModel(id: "claude-sonnet-4-6", name: "Sonnet")
            try expect(!FastTranslationCapability.supports(provider: anthropic, model: sonnet))
            anthropic.baseURL = "https://api.anthropic.com/v1"
            try expect(try (body(anthropic, sonnet, enabled: true)["thinking"] as? [String:String])?["type"] == "disabled")
            for id in ["claude-sonnet-5-5", "claude-opus-5-5"] {
                let model = APIModel(id: id, name: id)
                try expect(!FastTranslationCapability.supports(provider: anthropic, model: model))
                try expect(try body(anthropic, model, enabled: true)["thinking"] == nil)
            }
            for proto in [APIProtocol.chatCompletions, .responses] {
                var official = fixtureProvider(proto)
                official.baseURL = "https://api.openai.com/v1"
                let enabled = try body(official, gpt, enabled: true)
                if proto == .responses {
                    try expect((enabled["reasoning"] as? [String: String])?["effort"] == "none")
                } else {
                    try expect(enabled["reasoning_effort"] as? String == "none")
                }
                let disabled = try body(official, gpt, enabled: false)
                try expect(disabled["reasoning"] == nil && disabled["reasoning_effort"] == nil)
            }
            try expect(FastTranslationCapability.supportsChatGPT(modelID: gpt.id))
            try expect(!FastTranslationCapability.supportsChatGPT(modelID: "gpt-5"))
            @MainActor func accountBody(_ modelID: String, fast: Bool) throws -> [String: Any] {
                let data = try ChatGPT.translationBody(text: "Hello", model: modelID, fastTranslation: fast)
                return try JSONSerialization.jsonObject(with: data) as! [String: Any]
            }
            try expect(try (accountBody(gpt.id, fast: true)["reasoning"] as? [String: String])?["effort"] == "none")
            try expect(try accountBody(gpt.id, fast: false)["reasoning"] == nil)
            try expect(try accountBody("gpt-5", fast: true)["reasoning"] == nil)
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

        check("Fast preference and history persist separately across accounts, models, protocols and endpoints") {
            let domain = "qingyi-thinking-state-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let provider = fixtureProvider()
            let model = "deepseek-v4-flash"
            let first = ModelReasoningKey(provider: provider, modelID: model)
            try expect(store.isUnconfigured && store.fastTranslationEnabled(for: first))
            try expect(store.lastThinkingStatus(for: first) == nil)
            let revision = store.revision
            store.recordThinkingStatus(.usedThinking, for: first)
            store.setFastTranslation(false, for: first)
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
                try expect(store.fastTranslationEnabled(for: key) && store.lastThinkingStatus(for: key) == nil)
            }
            try expect(store.revision == revision && store.lastThinkingStatus(for: first) == .usedThinking)
            let restored = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            try expect(!restored.fastTranslationEnabled(for: first) && restored.lastThinkingStatus(for: first) == .usedThinking)
            try expect(restored.isUnconfigured)
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
            func respond(_ json: String, expectFast: Bool, model: String) {
                FixtureAPIProtocol.handle = { request in
                    let body = try bodyOfRequest(request)
                    try expect(body["model"] as? String == model)
                    if expectFast { try expect((body["thinking"] as? [String:String])?["type"] == "disabled") }
                    else { try expect(body["thinking"] == nil) }
                    return (200, "application/json", Data(json.utf8))
                }
            }
            respond(translated, expectFast: true, model: provider.models[0].id)
            let firstValue = try await engine.translate("Hello", onUpdate: { _ in })
            try expect(firstValue == "译文" && store.lastThinkingStatus(for: first) == .requestedOffUnconfirmed)
            store.setFastTranslation(false, for: first)
            try expect(store.lastThinkingStatus(for: first) == .requestedOffUnconfirmed)
            respond(translated, expectFast: false, model: provider.models[0].id)
            _ = try await engine.translate("Again", onUpdate: { _ in })
            try expect(store.lastThinkingStatus(for: first) == .unreported)
            respond(#"{"choices":[{"message":{"content":"译文","reasoning_content":"private"},"finish_reason":"stop"}]}"#, expectFast: false, model: "other")
            let target = TranslationTarget(service: .customAPI(provider.id), modelID: "other")
            _ = try await engine.translate("Temporary", target: target, onUpdate: { _ in })
            try expect(store.lastThinkingStatus(for: other) == .usedThinking && store.lastThinkingStatus(for: first) == .unreported)
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
            let earlier = Task { @MainActor in try await engine.translate("Earlier", onUpdate: { _ in }) }
            defer { earlier.cancel(); releaseFirst?() }
            for _ in 0..<200 where releaseFirst == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(releaseFirst != nil, "Earlier request did not reach the mock server")
            store.setFastTranslation(false, for: modelKey)
            let newer = try await engine.translate("Newer", onUpdate: { _ in })
            try expect(newer == "较晚译文" && store.lastThinkingStatus(for: modelKey) == .usedThinking)
            releaseFirst?()
            releaseFirst = nil
            let older = try await earlier.value
            try expect(older == "较早译文" && store.lastThinkingStatus(for: modelKey) == .usedThinking)
        }
    }
}
