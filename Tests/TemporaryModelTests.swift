import Foundation
import AppKit
import Security

final class MemoryChatGPTVault: ChatGPTCredentialVault {
    var credentials: Credentials?
    var saves = 0
    func read(_ id: String) throws -> Credentials? { credentials }
    func save(_ credentials: Credentials, id: String) throws { self.credentials = credentials; saves += 1 }
    func remove(_ id: String) throws { credentials = nil }
}

final class WaitingAPIKeyVault: APIKeyVault {
    let gate = DispatchSemaphore(value: 0)
    func read(_ id: String) throws -> String? {
        guard gate.wait(timeout: .now() + 0.4) == .success else { throw QingyiError.message("UI thread could not release the fixture Keychain wait") }
        return "fixture"
    }
    func save(_ key: String, id: String) throws { }
    func remove(_ id: String) throws { }
}

final class AuthorizationGate<Value> {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var count = 0
    let value: Value
    init(_ value: Value) { self.value = value }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    func read() throws -> Value {
        lock.lock(); count += 1; lock.unlock()
        guard gate.wait(timeout: .now() + 25) == .success else { throw QingyiError.message("Authorization fixture was not released") }
        return value
    }
    func release() { gate.signal() }
}

final class AuthorizedAPIKeyVault: APIKeyVault {
    let authorization = AuthorizationGate("fixture")
    func read(_ id: String) throws -> String? { try authorization.read() }
    func save(_ key: String, id: String) throws { }
    func remove(_ id: String) throws { }
}

final class AuthorizedChatGPTVault: ChatGPTCredentialVault {
    let authorization = AuthorizationGate(Credentials(access: "fixture-chat-token", refresh: nil, idToken: "",
        scopes: ["chatgpt.tokens.use.direct"], expiry: Date().addingTimeInterval(3600)))
    func read(_ id: String) throws -> Credentials? { try authorization.read() }
    func save(_ credentials: Credentials, id: String) throws { }
    func remove(_ id: String) throws { }
}

extension QingyiTests {
    static func dataOfRequest(_ request: URLRequest) throws -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw QingyiError.message("Unable to read fixture request") }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return data
    }

    static func bodyOfRequest(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: dataOfRequest(request)) as! [String: Any]
    }
    @MainActor static func temporaryModelTests() async {
        check("Translation window defaults to upper-right and saves its own placement without changing button placement") {
            let domain = "qingyi-window-placement-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set("upperLeft", forKey: "selectionButtonPosition")
            let preferences = Preferences(defaults: defaults)
            try expect(preferences.translationWindowPosition == .upperRight && preferences.buttonPosition == .upperLeft)
            preferences.translationWindowPosition = .belowPointer
            let restored = Preferences(defaults: defaults)
            try expect(restored.translationWindowPosition == .belowPointer && restored.buttonPosition == .upperLeft)
        }
        check("Notification-like fixed width and both placements fit primary and negative-coordinate screens") {
            for screen in [NSRect(x: 0, y: 25, width: 1440, height: 875), NSRect(x: -1920, y: -200, width: 1920, height: 1080)] {
                let pointer = NSPoint(x: screen.midX, y: screen.midY)
                let short = TranslationWindowLayout.frame(contentHeight: 200, position: .upperRight, pointer: pointer, screen: screen)
                let long = TranslationWindowLayout.frame(contentHeight: 20_000, position: .upperRight, pointer: pointer, screen: screen)
                try expect(short.width == 360 && long.width == 360)
                try expect(short.maxX == screen.maxX && short.maxY == screen.maxY)
                try expect(long.maxX == screen.maxX && long.maxY == short.maxY && screen.contains(long))
                try expect(long.minY == screen.minY + 16)
                let below = TranslationWindowLayout.frame(contentHeight: 200, position: .belowPointer, pointer: pointer, screen: screen)
                try expect(below.minX == pointer.x + 12 && below.maxY == pointer.y - 12)
                let moved = TranslationWindowLayout.frame(contentHeight: 250, position: .upperRight, pointer: pointer, screen: screen, manualTopLeft: NSPoint(x: screen.minX + 60, y: screen.maxY - 70))
                try expect(moved.minX == screen.minX + 60 && moved.maxY == screen.maxY - 70)
                let edge = NSPoint(x: screen.maxX, y: screen.maxY)
                let manualEdge = TranslationWindowLayout.frame(contentHeight: 200, position: .upperRight, pointer: pointer, screen: screen, manualTopLeft: edge)
                try expect(manualEdge.maxX == screen.maxX - 10 && manualEdge.maxY == screen.maxY - 10)
                let pointerEdge = TranslationWindowLayout.frame(contentHeight: 200, position: .belowPointer, pointer: edge, screen: screen)
                try expect(pointerEdge.maxX == screen.maxX - 10)
                let button = FloatingController.clamped(edge, size: NSSize(width: 38, height: 38), screen: screen)
                try expect(button.x == screen.maxX - 48 && button.y == screen.maxY - 48)
            }
        }
        check("Translation height grows with content and caps at available screen height for internal scrolling") {
            let short = TranslationWindowLayout.contentHeight(source: "Hello", text: "你好。")
            let medium = TranslationWindowLayout.contentHeight(source: "Hello", text: String(repeating: "较长的一段中文译文。", count: 30))
            let long = TranslationWindowLayout.contentHeight(source: "Hello", text: String(repeating: "较长的一段中文译文。", count: 1000))
            try expect(short >= 128 && short < 160 && medium > short && long > medium)
            let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let frame = TranslationWindowLayout.frame(contentHeight: long, position: .upperRight, pointer: .zero, screen: screen)
            try expect(frame.height == 884 && frame.width == 360)
        }
        check("Upper-right panel stays flush while loading and growing, with no placement preference changes") {
            let controller = FloatingController()
            controller.showResult(source: "Hello", preview: true)
            defer { controller.hide() }
            let initial = controller.resultPanel.frame
            for text in ["", "你好。", String(repeating: "用于验证贴边和内部滚动的长译文。", count: 1000)] {
                controller.state.text = text; controller.state.loading = text.isEmpty
                controller.fitContent()
                let frame = controller.resultPanel.frame
                try expect(frame.width == 360 && frame.maxX == initial.maxX && frame.maxY == initial.maxY)
            }
        }
        check("Pinned window keeps its result while another selection button appears and resets on explicit close") {
            let controller = FloatingController()
            controller.showResult(source: "Hello", preview: true)
            controller.state.text = "译文"; controller.state.pinned = true
            controller.showButton(position: .lowerLeft, preserveResult: true)
            try expect(controller.state.text == "译文" && controller.state.pinned)
            controller.showResult(source: "New source", keepPosition: false)
            try expect(controller.state.pinned)
            controller.onClose = { [weak controller] in controller?.hide() }
            controller.resultPanel.cancelOperation(nil)
            try expect(!controller.state.pinned && !controller.resultPanel.isVisible)
        }
        check("Temporary targets distinguish providers, ChatGPT accounts and equal model IDs") {
            let a = TranslationTarget(service: .customAPI("one"), modelID: "same")
            let b = TranslationTarget(service: .customAPI("two"), modelID: "same")
            let c = TranslationTarget(service: .chatGPT("account"), modelID: "same")
            let d = TranslationTarget(service: .chatGPT("another"), modelID: "same")
            try expect(Set([a,b,c,d]).count == 4)
        }
        check("Temporary session preserves full source, duplicate selections, retry target, default and new-session reset") {
            let a = TranslationChoice(target: .init(service: .customAPI("one"), modelID: "a"), providerName: "One", modelName: "A")
            let b = TranslationChoice(target: .init(service: .customAPI("two"), modelID: "b"), providerName: "Two", modelName: "B")
            let source = String(repeating: "Full original source. ", count: 100) + "END"
            var session = TranslationSession(source: source, defaultChoice: a)
            let initialRun = session.runID
            try expect(!session.temporary && !session.select(a) && session.runID == initialRun)
            try expect(session.select(b) && session.temporary)
            try expect(!session.accepts(sessionID: session.id, runID: initialRun))
            let switchedRun = session.runID
            session.restart()
            try expect(session.choice == b && session.runID != switchedRun)
            try expect(session.source == source && session.source.count > 600)
            try expect(session.restoreDefault() && session.choice == a && !session.temporary)
            try expect(!session.restoreDefault())
            let next = TranslationSession(source: "New original", defaultChoice: a)
            try expect(next.id != session.id && next.choice == a && !next.temporary)
            try expect(!next.accepts(sessionID: session.id, runID: session.runID))
        }
        check("Native model menu groups providers, checks exact targets and offers restore and lazy loading") {
            _ = NSApplication.shared
            let a = TranslationChoice(target: .init(service: .customAPI("one"), modelID: "same"), providerName: "One", modelName: "A")
            let b = TranslationChoice(target: .init(service: .customAPI("two"), modelID: "same"), providerName: "Two", modelName: "B")
            let button = ModelMenuButton()
            button.menuContent = {
                ([.init(name: "One", choices: [a]), .init(name: "Two", choices: [b]), .init(name: "ChatGPT", choices: [], canLoadChatGPT: true)], b, a, "", false)
            }
            let menu = button.buildMenu()
            try expect(menu.items.filter { $0.state == .on }.map(\.title) == ["B"])
            try expect(menu.items.first { $0.title == "恢复默认模型" }?.isEnabled == true)
            try expect(menu.items.contains { $0.title == "加载 ChatGPT 模型…" && $0.isEnabled })
            try expect(menu.items.filter { $0.title == "A" || $0.title == "B" }.allSatisfy { $0.indentationLevel == 1 })
            button.menuContent = { ([.init(name: "ChatGPT", choices: [], canLoadChatGPT: true)], a, a, "加载失败", true) }
            let loading = button.buildMenu()
            try expect(loading.items.first { $0.title == "恢复默认模型" }?.isEnabled == false)
            try expect(loading.items.first { $0.title == "正在加载 ChatGPT 模型…" }?.isEnabled == false)
        }
        check("Selection monitor ignores internal clicks and menu Escape but preserves external close events") {
            let monitor = SelectionMonitor()
            var outside = 0; var escapes = 0; var menuCancels = 0
            monitor.onOutsideClick = { _ in outside += 1 }; monitor.onScroll = { escapes += 1 }
            monitor.onMenuCancel = { menuCancels += 1 }
            monitor.isInternalInteraction = { _ in true }
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            monitor.event(click)
            try expect(outside == 0)
            monitor.isInternalInteraction = { _ in false }
            monitor.event(click)
            try expect(outside == 1)
            monitor.setModelMenuTracking(true); monitor.event(click); monitor.event(escape)
            try expect(outside == 1 && escapes == 0 && menuCancels == 1)
            monitor.setModelMenuTracking(false); monitor.event(escape); monitor.event(click)
            try expect(escapes == 0 && outside == 1)
            let freshEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            monitor.event(freshEscape)
            try expect(escapes == 1)
        }
        await asyncCheck("Explicit custom targets route all three protocols without changing global settings or losing original text") {
            let domain = "qingyi-temp-api-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let vault = MemoryAPIKeyVault()
            let store = APIConfigurationStore(defaults: defaults, vault: vault)
            var providers: [APIProvider] = []
            for (index, protocolValue) in APIProtocol.allCases.enumerated() {
                var provider = fixtureProvider(protocolValue)
                provider.name = "Provider \(index)"
                provider.baseURL = "https://fixture\(index).example/v1"
                provider.models = [APIModel(id: "default", name: "Default"), APIModel(id: "shared", name: "Alternative")]
                try store.save(provider, replacementKey: "key-\(index)")
                providers.append(provider)
            }
            try store.selectProvider(providers[0].id)
            let before = defaults.persistentDomain(forName: domain)!
            let revision = store.revision
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: store, client: CustomAPIClient(session: network))
            let original = String(repeating: "Translate the complete source. ", count: 70) + "TAIL"
            for (index, provider) in providers.enumerated() {
                var calls = 0
                FixtureAPIProtocol.handle = { request in
                    calls += 1
                    try expect(request.url?.host == "fixture\(index).example")
                    let body = try bodyOfRequest(request)
                    try expect(body["model"] as? String == "shared")
                    if provider.apiProtocol == .anthropic { try expect(request.value(forHTTPHeaderField: "x-api-key") == "key-\(index)") }
                    else { try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key-\(index)") }
                    let entries = (body[provider.apiProtocol == .responses ? "input" : "messages"] as? [[String: Any]])!
                    let content = entries.last!["content"] as! [[String: Any]]
                    try expect(content.first?["text"] as? String == original)
                    let response: String
                    switch provider.apiProtocol {
                    case .chatCompletions: response = #"{"choices":[{"message":{"content":"译文"},"finish_reason":"stop"}]}"#
                    case .responses: response = #"{"status":"completed","output":[{"content":[{"type":"output_text","text":"译文"}]}]}"#
                    case .anthropic: response = #"{"content":[{"type":"text","text":"译文"}],"stop_reason":"end_turn"}"#
                    }
                    return (200, "application/json", Data(response.utf8))
                }
                let target = TranslationTarget(service: .customAPI(provider.id), modelID: "shared")
                let result = try await engine.translate(original, target: target, onUpdate: { _ in })
                try expect(result == "译文" && calls == 1)
                var after = defaults.persistentDomain(forName: domain)!
                after.removeValue(forKey: APIConfigurationStore.thinkingHistoryStorageKey)
                try expect((after as NSDictionary).isEqual(to: before))
                try expect(store.lastThinkingStatus(for: ModelReasoningKey(provider: provider, modelID: "shared")) == .unreported)
                try expect(store.revision == revision && store.activeProviderID == providers[0].id)
                try expect(store.activeProvider?.selectedModelID == "default")
            }
            try expect(try engine.defaultChoice().target == .init(service: .customAPI(providers[0].id), modelID: "default"))
        }
        await asyncCheck("Waiting for Keychain does not block the UI and cancelled reads never start network requests") {
            let domain = "qingyi-temp-keychain-wait-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let vault = WaitingAPIKeyVault()
            let config = APIConfigurationStore(defaults: defaults, vault: vault)
            let provider = fixtureProvider(); try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
            var networkStarted = false
            FixtureAPIProtocol.handle = { _ in networkStarted = true; return (500, "application/json", Data()) }
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            var cancelled = false
            let request = Task { @MainActor in
                do { return try await engine.translate("Hello", onUpdate: { _ in }) }
                catch is CancellationError { cancelled = true; throw CancellationError() }
            }
            defer { vault.gate.signal() }
            try await Task.sleep(nanoseconds: 20_000_000)
            request.cancel()
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(cancelled && !networkStarted, "Cancellation must complete before the Keychain read returns")
            do { _ = try await request.value; throw QingyiError.message("Expected cancellation") }
            catch is CancellationError { }
            try expect(!networkStarted)
        }
        await asyncCheck("API and ChatGPT translations survive authorization beyond 15 seconds and share reads with cancelled callers") {
            let domain = "qingyi-long-authorization-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            let apiVault = AuthorizedAPIKeyVault()
            let chatVault = AuthorizedChatGPTVault()
            defer {
                apiVault.authorization.release(); chatVault.authorization.release()
                defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil
            }
            let account = Registration(id: "fixture-account", subject: "fixture", email: "fixture@example.invalid")
            defaults.set(try JSONEncoder().encode([account]), forKey: "registrations")
            defaults.set(account.id, forKey: "activeRegistration")
            let chat = ChatGPT(defaults: defaults, session: network, vault: chatVault)
            let configuration = APIConfigurationStore(defaults: defaults, vault: apiVault)
            let provider = fixtureProvider()
            try configuration.save(provider, replacementKey: "fixture"); try configuration.selectProvider(provider.id)
            let engine = TranslationEngine(chat: chat, configuration: configuration, client: CustomAPIClient(session: network))
            var networkCalls = 0
            FixtureAPIProtocol.handle = { request in
                networkCalls += 1
                if request.url?.path == "/v1/models" {
                    return (200, "application/json", Data(#"{"models":[{"slug":"fixture-model","display_name":"Fixture","visibility":"list"}]}"#.utf8))
                }
                if request.url?.path == "/v1/responses" {
                    return (200, "application/json", Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"译文"}]}]}"#.utf8))
                }
                return (200, "application/json", Data(#"{"choices":[{"message":{"content":"译文"},"finish_reason":"stop"}]}"#.utf8))
            }
            var cancelled = false
            let stale = Task { @MainActor in
                do { _ = try await configuration.keyForRequest(provider.id) }
                catch is CancellationError { cancelled = true }
            }
            var apiFinished = false; var chatFinished = false
            let apiRequest = Task { @MainActor in
                defer { apiFinished = true }
                return try await engine.translate("Hello", onUpdate: { _ in })
            }
            let chatRequest = Task { @MainActor in
                defer { chatFinished = true }
                return try await engine.translate("Hello", target: .init(service: .chatGPT(account.id), modelID: "fixture-model"), onUpdate: { _ in })
            }
            defer { stale.cancel(); apiRequest.cancel(); chatRequest.cancel() }
            for _ in 0..<100 where apiVault.authorization.reads == 0 || chatVault.authorization.reads == 0 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expect(apiVault.authorization.reads == 1 && chatVault.authorization.reads == 1)
            stale.cancel()
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(cancelled && !apiFinished && !chatFinished && networkCalls == 0)
            // Exercise the former production deadline rather than shortening a
            // test-only timeout. Both callers must still be waiting afterwards.
            try await Task.sleep(nanoseconds: 15_200_000_000)
            try expect(!apiFinished && !chatFinished && networkCalls == 0)
            apiVault.authorization.release(); chatVault.authorization.release()
            let apiText = try await apiRequest.value
            let chatText = try await chatRequest.value
            try expect(apiText == "译文" && chatText == "译文" && networkCalls == 3)
            try expect(apiVault.authorization.reads == 1 && chatVault.authorization.reads == 1)
        }
        await asyncCheck("Credential denial propagates and a cancelled caller cannot consume a completed credential") {
            let denied = Task<String, Error> { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed)) }
            do { _ = try await CredentialWait.value(denied); throw QingyiError.message("Expected access denial") }
            catch let error as NSError { try expect(error.domain == NSOSStatusErrorDomain && error.code == Int(errSecAuthFailed)) }
            let completed = Task<String, Error> { "fixture" }
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await CredentialWait.value(completed)
            }
            do { _ = try await cancelled.value; throw QingyiError.message("Expected cancellation") }
            catch is CancellationError { }
            let value = try await completed.value
            try expect(value == "fixture")
        }
        await asyncCheck("ChatGPT menu loading and explicit translation preserve saved account and default even when default is not listed") {
            let domain = "qingyi-temp-chat-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let account = Registration(id: "fixture-account", subject: "fixture", email: "fixture@example.invalid")
            defaults.set(try JSONEncoder().encode([account]), forKey: "registrations")
            defaults.set(account.id, forKey: "activeRegistration")
            defaults.set("keep-global-default", forKey: "model.\(account.id)")
            let vault = MemoryChatGPTVault()
            vault.credentials = Credentials(access: "fixture-chat-token", refresh: nil, idToken: "", scopes: ["chatgpt.tokens.use.direct"], expiry: Date().addingTimeInterval(3600))
            let chat = ChatGPT(defaults: defaults, session: network, vault: vault)
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let provider = fixtureProvider(); try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
            let engine = TranslationEngine(chat: chat, configuration: config, client: CustomAPIClient(session: network))
            let before = defaults.persistentDomain(forName: domain)!
            var requests: [String] = []
            FixtureAPIProtocol.handle = { request in
                requests.append(request.url!.path)
                try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-chat-token")
                if request.url?.path == "/v1/models" {
                    return (200, "application/json", Data(#"{"models":[{"slug":"temporary","display_name":"临时 GPT","visibility":"list"}]}"#.utf8))
                }
                let body = try bodyOfRequest(request)
                try expect(body["model"] as? String == "temporary")
                return (200, "application/json", Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"译文"}]}]}"#.utf8))
            }
            try expect(engine.modelGroups().last?.canLoadChatGPT == true)
            _ = try await chat.loadTemporaryModels()
            let choice = engine.modelGroups().last!.choices[0]
            try expect(choice.modelName == "临时 GPT")
            let translated = try await engine.translate("Hello", target: choice.target, onUpdate: { _ in })
            try expect(translated == "译文" && requests == ["/v1/models", "/v1/responses"])
            try expect(chat.activeID == account.id && chat.modelID == "keep-global-default")
            try expect(config.activeProviderID == provider.id && vault.saves == 0)
            var after = defaults.persistentDomain(forName: domain)!
            after.removeValue(forKey: APIConfigurationStore.thinkingHistoryStorageKey)
            try expect((after as NSDictionary).isEqual(to: before))
            try expect(config.lastThinkingStatus(for: ModelReasoningKey(accountID: account.id, modelID: "temporary")) == .unreported)
        }
        await asyncCheck("Temporary request errors and stale targets do not fall back to the global provider") {
            let domain = "qingyi-temp-error-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let a = fixtureProvider(); var b = fixtureProvider(); b.baseURL = "https://alternative.example/v1"
            try config.save(a, replacementKey: "a"); try config.save(b, replacementKey: "b"); try config.selectProvider(a.id)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            var calls = 0
            FixtureAPIProtocol.handle = { request in
                calls += 1; try expect(request.url?.host == "alternative.example")
                return (401, "application/json", Data())
            }
            let choice = engine.choice(for: .init(service: .customAPI(b.id), modelID: "model-a"))
            var session = TranslationSession(source: "Hello", defaultChoice: try engine.defaultChoice())
            _ = session.select(choice)
            for _ in 0..<2 {
                session.restart()
                do { _ = try await engine.translate(session.source, target: session.choice!.target, onUpdate: { _ in }); throw QingyiError.message("Expected API failure") }
                catch { try expect(error.localizedDescription.contains("401")) }
                try expect(session.choice == choice && session.temporary)
            }
            try expect(calls == 2)
            do {
                _ = try await engine.translate("Hello", target: .init(service: .customAPI("deleted"), modelID: "model-a"), onUpdate: { _ in })
                throw QingyiError.message("Expected missing target failure")
            } catch { try expect(error.localizedDescription.contains("已删除")) }
            try expect(calls == 2 && config.activeProviderID == a.id)
        }
        await asyncCheck("Late results from cancelled temporary runs and closed windows cannot overwrite newer output") {
            let a = TranslationChoice(target: .init(service: .customAPI("one"), modelID: "a"), providerName: "One", modelName: "A")
            let b = TranslationChoice(target: .init(service: .customAPI("two"), modelID: "b"), providerName: "Two", modelName: "B")
            var current: TranslationSession? = TranslationSession(source: "Hello", defaultChoice: a)
            let old = current!
            var displayed = ""
            let delayed = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000)
                if current?.accepts(sessionID: old.id, runID: old.runID) == true { displayed = "old" }
            }
            _ = current?.select(b)
            displayed = "new"
            delayed.cancel(); await delayed.value
            try expect(displayed == "new")
            let closing = current!
            current = nil
            try expect(current?.accepts(sessionID: closing.id, runID: closing.runID) != true)
        }
        check("Header dragging follows event coordinates and preserves the window size") {
            let controller = FloatingController()
            let panel = controller.resultPanel
            panel.setFrame(NSRect(x: 400, y: 400, width: 360, height: 233), display: false)
            var changes: [Bool] = []
            panel.onDragging = { changes.append($0) }
            @MainActor func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let grip = panel.frame.height - TranslationWindowLayout.headerHeight / 2
            panel.sendEvent(mouse(.leftMouseDown, NSPoint(x: 180, y: grip)))
            panel.sendEvent(mouse(.leftMouseDragged, NSPoint(x: 120, y: grip - 36)))
            panel.sendEvent(mouse(.leftMouseUp, NSPoint(x: 180, y: grip)))
            try expect(panel.frame == NSRect(x: 340, y: 364, width: 360, height: 233))
            try expect(changes == [true, false])
        }
        check("Closing the translation panel uses session cleanup, while preview model switching is disabled") {
            let controller = FloatingController()
            var closed = false; controller.onClose = { closed = true }
            controller.showResult(source: "Example", preview: true)
            try expect(!controller.state.modelSelectionEnabled)
            controller.resultPanel.cancelOperation(nil)
            try expect(closed)
            controller.hide()
            try expect(controller.state.choice == nil && !controller.state.temporaryModel)
        }
        await asyncCheck("Escape forwarded by a just-closed model menu does not close the result panel") {
            let controller = FloatingController()
            var closed = false; controller.onClose = { closed = true }
            controller.handleModelMenuTracking(true)
            controller.resultPanel.cancelOperation(nil)
            try expect(!closed)
            controller.handleModelMenuTracking(false)
            controller.resultPanel.cancelOperation(nil)
            try expect(!closed)
            try await Task.sleep(nanoseconds: 5_000_000)
            controller.resultPanel.cancelOperation(nil)
            try expect(closed)
        }
    }
}
