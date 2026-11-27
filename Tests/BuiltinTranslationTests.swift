import AppKit
import SwiftUI
import WebKit

extension QingyiTests {
    @MainActor static func waitForClickSequence() async throws {
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
    }
    @MainActor static func resultInteractionTests() async {
        await asyncCheck("Multi-service streaming growth updates the native scroll extent and can reach the bottom") {
            let controller = FloatingController()
            controller.showResult()
            controller.state.services = [ServiceTranslationResult(id: .ai)]
            defer { controller.hide() }
            try await Task.sleep(nanoseconds: 100_000_000)
            @MainActor func findScroll(_ view: NSView) -> TranslationBodyScrollView? {
                if let scroll = view as? TranslationBodyScrollView { return scroll }
                for child in view.subviews { if let scroll = findScroll(child) { return scroll } }
                return nil
            }
            guard let root = controller.resultPanel.contentView, let scroll = findScroll(root) else { throw QingyiError.message("Missing native translation scroll view") }
            controller.state.services[0].result.text = String(repeating: "这是用于检查长译文滚动的一整段中文内容。\n", count: 160) + "译文结束标记"
            controller.state.services[0].loading = false
            try await Task.sleep(nanoseconds: 200_000_000)
            let viewport = scroll.contentView.bounds.height
            let document = scroll.documentView!.frame.height
            try expect(document > viewport + 100 && scroll.hasVerticalScroller, "Document=\(document), viewport=\(viewport), verticalScroller=\(scroll.hasVerticalScroller)")
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -500, wheel2: 0, wheel3: 0)!
            guard let event = NSEvent(cgEvent: wheel) else { throw QingyiError.message("Missing wheel event") }
            scroll.scrollWheel(with: event)
            try await Task.sleep(nanoseconds: 100_000_000)
            try expect(scroll.contentView.bounds.minY > 0, "Wheel must move the long translation, delta=\(event.scrollingDeltaY)")
            scroll.documentView!.scroll(NSPoint(x: 0, y: document - viewport))
            try expect(scroll.contentView.bounds.maxY >= document - 2, "Last service and its copy button must be reachable")
            let previousOffset = scroll.contentView.bounds.minY
            controller.state.services[0].result.text += "\n继续追加的译文"
            try await Task.sleep(nanoseconds: 100_000_000)
            try expect(abs(scroll.contentView.bounds.minY - previousOffset) < 2, "Streaming must preserve the reading position")
            let longResults = controller.state.services
            controller.showResult(operation: .custom(AIAction(name: "总结", prompt: "总结原文")))
            controller.state.services = longResults
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let switched = findScroll(root) else { throw QingyiError.message("Missing switched action scroll view") }
            try expect(switched.hasVerticalScroller && switched.contentView.bounds.minY == 0,
                       "Switching actions on the same source must start the new long result at the top")
            controller.showResult()
            controller.state.services = [ServiceTranslationResult(id: .youdao, loading: false, result: .init(text: "简短译文"))]
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let nextScroll = findScroll(root) else { throw QingyiError.message("Missing replacement scroll view") }
            try expect(!nextScroll.hasVerticalScroller && nextScroll.contentView.bounds.minY == 0, "Short results must reset scrolling")
        }
        await asyncCheck("Only a completed outside primary click dismisses an unpinned selection result") {
            let domain = "qingyi-selection-reader-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = BuiltinTranslationSettings(defaults: defaults)
            settings.google = false
            settings.ai = false
            let api = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: api)
            let client = BuiltinTranslationClient { source in BuiltinTranslationResult(text: "译文 " + source) }
            let app = AppDelegate(preferences: Preferences(defaults: defaults))
            app.prepareSelectionFixture(engine: engine, client: client, settings: settings)
            defer { app.dismissHoverFixture() }
            // Drive selection changes explicitly without reading the user's foreground application.
            app.monitor.enabled = false
            var inside = false
            app.monitor.isInternalInteraction = { _ in inside }
            app.monitor.isResultInteraction = { _, _ in inside }
            let outside = NSPoint(x: 30, y: 30)
            func mouse(_ type: NSEvent.EventType, at point: NSPoint? = nil, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point ?? outside, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0)!
            }
            func key(_ code: UInt16) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            }
            let state = app.floating.state
            let panel = app.floating.resultPanel
            let source = "Read this passage."
            app.feedSelectionFixture("Offer a translation.")
            app.monitor.event(screenshotScrollEvent())
            try expect(!app.floating.buttonPanel.isVisible, "Scrolling should clear the compact selection button")
            app.feedSelectionFixture(source)
            app.floating.onTrigger?()
            let initial = state.sessionID
            for loading in [true, false] {
                if !loading { try await waitForPolishing { state.complete } }
                try expect(state.loading == loading && !state.pinned)
                for event in [mouse(.rightMouseDown), mouse(.leftMouseDown, flags: .control), mouse(.leftMouseUp),
                              screenshotScrollEvent(), screenshotScrollEvent(phase: .began), screenshotScrollEvent(momentum: .continuous),
                              key(125), key(0)] {
                    app.monitor.event(event)
                    try expect(panel.isVisible && state.sessionID == initial && state.loading == loading)
                }
                app.monitor.applicationActivated(pid: getpid() + 1)
                app.monitor.onSelection?(nil)
                try expect(panel.isVisible && state.sessionID == initial && state.loading == loading)
            }
            try expect(state.services.first?.result.text == "译文 " + source)

            // Dragging the selection, including an excursion back to its origin, is not a click.
            app.monitor.event(mouse(.leftMouseDown))
            try expect(panel.isVisible && state.sessionID == initial)
            app.monitor.event(mouse(.leftMouseDragged, at: NSPoint(x: 90, y: 30)))
            app.monitor.event(mouse(.leftMouseUp))
            try await waitForClickSequence()
            try expect(panel.isVisible && state.sessionID == initial)
            // Releasing outside after starting inside, or releasing inside after starting outside, must also preserve the result.
            for startsInside in [true, false] {
                inside = startsInside
                app.monitor.event(mouse(.leftMouseDown))
                inside = !startsInside
                app.monitor.event(mouse(.leftMouseUp))
                try await waitForClickSequence()
                try expect(panel.isVisible && state.sessionID == initial)
            }
            inside = false
            for count in [2, 3] {
                for click in 1...count {
                    app.monitor.event(mouse(.leftMouseDown, clicks: click))
                    app.monitor.event(mouse(.leftMouseUp, clicks: click))
                    try expect(panel.isVisible && state.sessionID == initial, "Selecting a word or line must preserve the result")
                }
                try await waitForClickSequence()
                try expect(panel.isVisible && state.sessionID == initial, "The first release in a multi-click must never dismiss later")
            }
            app.monitor.event(mouse(.leftMouseDown))
            app.monitor.event(mouse(.leftMouseUp))
            try expect(panel.isVisible, "A first release may still be followed by a second click")
            let nextSource = "Translate the next passage."
            app.feedSelectionFixture(nextSource)
            try expect(app.floating.buttonPanel.isVisible && panel.isVisible && state.sessionID == initial,
                       "A new selection should offer an action alongside the current translation")
            app.floating.onTrigger?()
            try await waitForPolishing { state.complete }
            try await waitForClickSequence()
            try expect(panel.isVisible && state.sessionID != initial && state.services.first?.result.text == "译文 " + nextSource)
            @MainActor func resultText(in view: NSView) -> TranslationResultTextView? {
                if let text = view as? TranslationResultTextView { return text }
                return view.subviews.lazy.compactMap { resultText(in: $0) }.first
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            guard let root = panel.contentView, let text = resultText(in: root),
                  let menu = text.menu(for: mouse(.rightMouseDown)) else { throw QingyiError.message("Missing result text menu") }
            let session = state.sessionID
            text.menuWillOpen(menu)
            try expect(app.monitor.modelMenuTracking && menu.item(withTitle: "复制")?.target === text)
            text.menuDidClose(menu)
            try expect(!app.monitor.modelMenuTracking && panel.isVisible && state.sessionID == session)
            state.pinned = true
            app.monitor.event(mouse(.leftMouseDown))
            app.monitor.event(mouse(.leftMouseUp))
            try await waitForClickSequence()
            try expect(panel.isVisible && state.sessionID == session, "Pinning must protect a result from outside clicks")
            state.pinned = false
            app.monitor.event(mouse(.leftMouseUp))
            try await waitForClickSequence()
            try expect(panel.isVisible, "An unmatched release must not dismiss a result")
            app.monitor.event(mouse(.leftMouseDown))
            try expect(panel.isVisible && state.sessionID == session, "Wait for release before dismissing")
            app.monitor.event(mouse(.leftMouseUp))
            try await waitForClickSequence()
            try expect(!panel.isVisible, "A confirmed single click should dismiss the unpinned result")

            app.feedSelectionFixture("Dismiss this with Escape.")
            app.floating.onTrigger?()
            app.monitor.event(key(53))
            try expect(!panel.isVisible, "Escape should still close the result")
            app.feedSelectionFixture("Dismiss this with the close button.")
            app.floating.onTrigger?()
            try expect(panel.isVisible)
            app.floating.onClose?()
            try expect(!panel.isVisible, "The close control should still dismiss an active translation")
        }
    }
    @MainActor static func builtinTranslationTests() async {
        await resultInteractionTests()
        check("Built-in services default on, preserve explicit off, and normalize display order") {
            let domain = "qingyi-builtin-tests-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = BuiltinTranslationSettings(defaults: defaults)
            try expect(settings.youdao && settings.google && settings.ai)
            settings.ai = false
            settings.google = false
            settings.move(.ai, before: .youdao)
            let reloaded = BuiltinTranslationSettings(defaults: defaults)
            try expect(!reloaded.google && reloaded.youdao && reloaded.order == [.ai, .youdao, .google])
            try expect(!reloaded.ai)
            settings.move(.ai, to: .google)
            try expect(settings.order == [.youdao, .google, .ai])
            try expect(BuiltinTranslationSettings.normalized(["google", "invalid", "google"]) == [.google, .youdao, .ai])
        }
        check("Fresh AI selection is empty, explicit clearing persists, and legacy ChatGPT selection survives") {
            let domain = "qingyi-ai-default-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let vault = MemoryAPIKeyVault()
            let store = APIConfigurationStore(defaults: defaults, vault: vault)
            try expect(store.isUnconfigured && store.activeProvider == nil)
            defaults.set("newly-added-account", forKey: "activeRegistration")
            try expect(APIConfigurationStore(defaults: defaults, vault: vault).isUnconfigured)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: store)
            try rejects { _ = try engine.defaultChoice() }
            try store.selectProvider("")
            try expect(!APIConfigurationStore(defaults: defaults, vault: vault).isUnconfigured)
            try store.selectProvider(APIConfiguration.unconfiguredProviderID)
            defaults.set("saved-account", forKey: "activeRegistration")
            try expect(APIConfigurationStore(defaults: defaults, vault: vault).isUnconfigured)
            defaults.removeObject(forKey: APIConfigurationStore.storageKey)
            try expect(APIConfigurationStore(defaults: defaults, vault: vault).activeProviderID.isEmpty)
        }
        check("Google parsing handles nullable phonetics and missing dictionary fields") {
            let data = Data(#"{"sentences":[{"trans":"恢复力"},{"src_translit":"rɪˈzɪliəns"}],"dict":[{"pos":"noun","terms":["韧性","恢复力"]}]}"#.utf8)
            let result = try GoogleWebTranslation.parseGoogleGTX(data)
            try expect(result.text == "恢复力" && result.phonetics == ["/rɪˈzɪliəns/"])
            try expect(result.meanings == [DictionaryMeaning(part: "noun", text: "韧性；恢复力")])
            try rejects { _ = try GoogleWebTranslation.parseGoogleGTX(Data("[]".utf8)) }
            let sentence = try GoogleWebTranslation.parseGoogleGTX(Data(#"{"sentences":[{"trans":"你好"},{"trans":"。"}]}"#.utf8))
            try expect(sentence.text == "你好。")
        }
        await asyncCheck("Youdao short sentences use one native JSON request and verify its matching translation") {
            let source = "Tom & Amy saved 3 + 2 = 5."
            let html = """
                <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"></head><body>
                <form><textarea id="inputText">Tom &amp; Amy saved 3 + 2 = 5.</textarea></form>
                <ul id="translateResult"><li>汤姆与艾米省了五元。</li></ul></body></html>
                """
            var requests = 0
            FixtureAPIProtocol.handle = { request in
                requests += 1
                try expect(request.url?.path == "/jsonapi_s" && request.httpMethod == "POST")
                let body = try dataOfRequest(request)
                let fields = URLComponents(string: "https://fixture.invalid/?" + String(decoding: body, as: UTF8.self))?.queryItems ?? []
                try expect(fields.contains { $0.name == "q" && $0.value == source })
                return (200, "application/json", try JSONSerialization.data(withJSONObject:
                    ["input": source, "fanyi": ["input": source, "type": "en2zh-CHS", "tran": "汤姆与艾米省了五元。"]]))
            }
            defer { FixtureAPIProtocol.handle = nil }
            let client = BuiltinTranslationClient(session: FixtureAPIProtocol.session())
            let result = try await client.translate(source, service: .youdao)
            try expect(result.text == "汤姆与艾米省了五元。" && requests == 1)
            try expect(YoudaoTranslation.parseHTML(Data(html.utf8), source: "A different sentence.") == nil)
            try expect(YoudaoTranslation.parseHTML(Data("<html>正在翻译</html>".utf8), source: source) == nil)
        }
        await asyncCheck("Technical and multiline inputs keep one bounded native request and restore protected literals") {
            let sources = [
                "This installs `easytier-core` and `easytier-cli` using the repository's metadata, independently of crates.io publication. On Windows, also copy the DLL and driver files from the matching release ZIP beside the installed binaries; binstall only installs executables.",
                "The package contains two tools.\r\n\r\nCopy the DLL files beside them.\r\nKeep the final line.",
                String(repeating: "😀", count: 299) + "!x"
            ]
            let session = FixtureAPIProtocol.session()
            defer { session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let client = BuiltinTranslationClient(session: session)
            var submitted: [String] = []
            FixtureAPIProtocol.handle = { request in
                try expect(request.url?.path == "/jsonapi_s")
                let fields = URLComponents(string: "https://fixture.invalid/?" + String(decoding: try dataOfRequest(request), as: UTF8.self))?.queryItems ?? []
                let input = fields.first { $0.name == "q" }!.value!
                submitted.append(input)
                try expect(input.utf16.count <= 600)
                return (200, "application/json", try JSONSerialization.data(withJSONObject:
                    ["input": input, "fanyi": ["input": input, "type": "en2zh-CHS", "tran": input]]))
            }
            for source in sources {
                let result = try await client.translate(source, service: .youdao)
                try expect(result.text == source.replacingOccurrences(of: "\r\n", with: "\n"), "Unexpected translation: \(result.text)")
            }
            try expect(submitted.count == sources.count)
            let truncated = "<form><textarea id='inputText'>First part.</textarea></form><ul id='translateResult'><li>第一部分。</li></ul>"
            try expect(YoudaoTranslation.parseHTML(Data(truncated.utf8), source: "First part. Missing last part.") == nil)
        }
        check("Youdao page results use completed text or dictionary rows only") {
            let result = YoudaoWebTranslation.result(from: ["phonetics": ["英 /test/", "美 /tɛst/"],
                "meanings": [["part": "n.", "text": "测试"], ["part": "v.", "text": "检验"]]])
            try expect(result?.phonetics == ["英 /test/", "美 /tɛst/"])
            try expect(result?.copyText == "n. 测试\nv. 检验")
            try expect(YoudaoWebTranslation.result(from: ["text": "  "]) == nil)
            try expect(YoudaoWebTranslation.result(from: NSNull()) == nil)
        }
        await asyncCheck("Youdao accepts the current language pair’s completed result, not a partial stream") {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: .zero, configuration: config)
            let source = "Une pomme verte."
            web.loadHTMLString("""
                <div id="js_fanyi_input" contenteditable="true"></div>
                <div class="lang-text-ai">检测到法语 - 中文</div>
                <div class="target"><div id="js_fanyi_output"><div class="current-translation"><div class="resultOutput">
                <p class="tgt un-step-trans"><span class="tgt">一个</span><span class="tgt"></span></p>
                </div></div></div><div class="targetAction"></div></div>
                """, baseURL: URL(string: "https://fanyi.youdao.com/"))
            for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(10)) }
            @MainActor func result() async throws -> BuiltinTranslationResult? {
                let raw = try await web.callAsyncJavaScript(YoudaoWebTranslation.translation, arguments: ["source": source], in: nil, contentWorld: .defaultClient)
                return YoudaoWebTranslation.result(from: raw)
            }
            let pending = try await result(); try expect(pending == nil)
            let incomplete = try await result(); try expect(incomplete == nil)
            _ = try await web.evaluateJavaScript("document.querySelectorAll('span.tgt')[1].textContent='青苹果。'")
            let changing = try await result(); try expect(changing == nil)
            _ = try await web.evaluateJavaScript("document.querySelector('.targetAction').innerHTML = '<a class=ic_translate_copy>复制</a>'")

            let complete = try await result(); try expect(complete?.text == "一个青苹果。")
            _ = try await web.evaluateJavaScript("document.querySelector('.lang-text-ai').innerText='检测到英语 - 中文'")
            let streaming = try await result(); try expect(streaming == nil)
        }
        check("Built-in request encoding preserves punctuation and Unicode") {
            let encoded = GoogleWebTranslation.form([("q", "中 +&=?"), ("dt", "t"), ("dt", "bd")])
            try expect(encoded.contains("%2B") && encoded.contains("%26") && encoded.contains("dt=t&dt=bd"))
            try expect(BuiltinTranslationClient.isEnglishWord("well-being") && !BuiltinTranslationClient.isEnglishWord("two words"))
        }
        await asyncCheck("AI switch gates production requests, preserves configuration, and removes only AI results") {
            let domain = "qingyi-ai-switch-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain); FixtureAPIProtocol.handle = nil }
            let vault = MemoryAPIKeyVault()
            let api = APIConfigurationStore(defaults: defaults, vault: vault)
            let provider = fixtureProvider()
            try api.save(provider, replacementKey: "fixture-only")
            try api.selectProvider(provider.id)
            let settings = BuiltinTranslationSettings(defaults: defaults)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: api, client: CustomAPIClient(session: FixtureAPIProtocol.session()))
            let app = AppDelegate()
            var allRequests = 0
            let client = BuiltinTranslationClient(session: FixtureAPIProtocol.session()) { _ in
                allRequests += 1
                return BuiltinTranslationResult(text: "有道释义")
            }
            app.prepareBuiltinFixture(engine: engine, client: client, settings: settings)
            defer { app.dismissHoverFixture() }
            var aiRequests = 0
            FixtureAPIProtocol.handle = { request in
                allRequests += 1
                if request.url?.host == URL(string: provider.baseURL)?.host {
                    aiRequests += 1
                    return (200, "application/json", Data(#"{"choices":[{"message":{"content":"AI 译文"},"finish_reason":"stop"}]}"#.utf8))
                }
                if request.url?.host == "translate.google.com" {
                    return (200, "application/json", Data(#"{"sentences":[{"trans":"谷歌译文"}]}"#.utf8))
                }
                throw QingyiError.message("Unexpected request")
            }
            app.screenshotClipboardFixture("  \n")
            try expect(app.floating.state.error && app.floating.state.services.isEmpty && allRequests == 0)
            try expect(app.floating.state.text == "剪贴板中没有可翻译的文字。请先复制文字，再按翻译快捷键，或从菜单栏选择“翻译已复制文字”。")
            app.screenshotClipboardFixture("resilience")
            for _ in 0..<150 where app.floating.state.loading { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(aiRequests == 1 && app.floating.state.services.count == 3)
            let completed = Dictionary(uniqueKeysWithValues: app.floating.state.services.map { ($0.id, $0.runID) })
            let requestCount = allRequests
            settings.move(.ai, to: .youdao)
            try expect(app.floating.state.services.map(\.id) == [.ai, .youdao, .google])
            try expect(app.floating.state.services.allSatisfy { completed[$0.id] == $0.runID })
            try await Task.sleep(nanoseconds: 30_000_000)
            try expect(allRequests == requestCount, "Reordering must not request new translations")
            let builtinRuns = app.floating.state.services.filter { $0.id != .ai }.map(\.runID)
            settings.ai = false
            try expect(app.floating.state.services.count == 2 && app.floating.state.services.map(\.runID) == builtinRuns)
            app.retryBuiltinFixture(.ai)
            app.screenshotClipboardFixture("test")
            for _ in 0..<150 where app.floating.state.loading { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(aiRequests == 1 && api.activeProviderID == provider.id)
            settings.ai = true
            try api.selectProvider(APIConfiguration.unconfiguredProviderID)
            app.screenshotClipboardFixture("word")
            for _ in 0..<150 where app.floating.state.loading { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(aiRequests == 1 && app.floating.state.services.count == 2)
            settings.youdao = false; settings.google = false
            app.screenshotClipboardFixture("No usable services")
            try expect(app.floating.state.error && app.floating.state.services.isEmpty)
            try expect(app.floating.state.text == "在“设置 → 翻译”中开启有道翻译或谷歌翻译。要使用 AI 翻译，请开启“AI 翻译”并选好模型。")
        }
        await asyncCheck("New selection and disable cancel the old provider task; copy uses the selected result") {
            let domain = "qingyi-service-cancel-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let store = BuiltinTranslationSettings(defaults: defaults)
            store.google = false
            let api = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let app = AppDelegate()
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: api)
            var started: [String] = []
            var cancelled: [String] = []
            let client = BuiltinTranslationClient { source in
                started.append(source)
                if source != "New selection" {
                    do { try await Task.sleep(for: .seconds(4)) }
                    catch { cancelled.append(source) }
                }
                // Simulate a provider returning a stale result after its cancellation.
                return BuiltinTranslationResult(text: source)
            }
            app.prepareBuiltinFixture(engine: engine, client: client, settings: store)
            defer { app.dismissHoverFixture() }
            app.screenshotClipboardFixture("Old selection")
            for _ in 0..<100 where started.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            app.screenshotClipboardFixture("New selection")
            for _ in 0..<100 where app.floating.state.loading || cancelled.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            app.floating.state.services.first?.copy(to: pasteboard)
            try expect(pasteboard.string(forType: .string) == "New selection" && cancelled == ["Old selection"])
            app.screenshotClipboardFixture("Pending result")
            for _ in 0..<100 where !started.contains("Pending result") { try await Task.sleep(for: .milliseconds(10)) }
            store.youdao = false
            for _ in 0..<100 where !cancelled.contains("Pending result") { try await Task.sleep(for: .milliseconds(10)) }
            try expect(cancelled.contains("Pending result") && app.floating.state.services.isEmpty)
        }
        await asyncCheck("Production translation entry runs built-ins without an AI account and isolates failures and retries") {
            let domain = "qingyi-builtin-app-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain); FixtureAPIProtocol.handle = nil }
            let store = BuiltinTranslationSettings(defaults: defaults)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault()))
            let app = AppDelegate()
            let client = BuiltinTranslationClient(session: FixtureAPIProtocol.session()) { _ in
                BuiltinTranslationResult(text: "", meanings: [.init(part: "n.", text: "有道成功")])
            }
            app.prepareBuiltinFixture(engine: engine, client: client, settings: store)
            defer { app.dismissHoverFixture() }
            var googleFails = true
            FixtureAPIProtocol.handle = { request in
                if request.url?.host == "translate.google.com" {
                    return googleFails ? (429, "text/plain", Data()) : (200, "application/json", Data(#"{"sentences":[{"trans":"谷歌成功"}]}"#.utf8))
                }
                throw QingyiError.message("Unexpected request")
            }
            app.screenshotClipboardFixture("resilience")
            for _ in 0..<150 where app.floating.state.loading { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(app.floating.state.services.count == 2)
            try expect(app.floating.state.services[0].result.copyText == "n. 有道成功")
            try expect(app.floating.state.services[1].error != nil && app.floating.state.complete)
            let youdaoRun = app.floating.state.services[0].runID
            googleFails = false
            app.retryBuiltinFixture(.google)
            for _ in 0..<150 where app.floating.state.loading { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(app.floating.state.services[1].result.text == "谷歌成功")
            try expect(app.floating.state.services[0].runID == youdaoRun)
            store.youdao = false
            try expect(app.floating.state.services.map(\.id) == [.google])
            app.retryBuiltinFixture(.youdao)
            try expect(app.floating.state.services.count == 1)
            store.google = false
            app.screenshotClipboardFixture("resilience")
            try expect(app.floating.state.services.isEmpty && app.floating.state.error)
        }
    }
}

extension QingyiTests {
    @MainActor static func renderBuiltinUI(to directory: String) throws {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in ["services-light", "services-dark", "screenshot-ocr"] {
            let dark = name == "services-dark"
            let ocr = name == "screenshot-ocr"
            let state = FloatingState()
            state.loading = false; state.complete = true
            state.services = [
                ServiceTranslationResult(id: .youdao, loading: false, result: .init(text: "一小步一小步地走，会让复杂的事情更容易理解。")),
                ServiceTranslationResult(id: .google, loading: false, result: .init(text: "小小的步骤使复杂的事情更容易理解。")),
                ServiceTranslationResult(id: .ai, loading: false, result: .init(text: "循序渐进，复杂的事情也会变得更容易理解。"))
            ]
            if dark {
                state.services = [
                    ServiceTranslationResult(id: .youdao, loading: false, result: .init(text: "恢复力", phonetics: ["英 /rɪˈzɪliəns/"], meanings: [.init(part: "n.", text: "恢复力，复原力；（橡胶等的）弹性")])),
                    ServiceTranslationResult(id: .google, loading: false, result: .init(text: "弹性", meanings: [.init(part: "noun", text: "弹性；弹力")]))
                ]
            }
            if ocr {
                state.services.removeAll { $0.id == .ai }
            }
            let target = TranslationTarget(service: .customAPI("fixture"), modelID: "fixture-model")
            state.choice = TranslationChoice(target: target, providerName: "示例 API", modelName: "示例模型")
            let body = ServiceResultsBody(state: state, retry: { _ in }, modelMenuTracking: { _ in }, selectModel: { _, _ in }, restoreModel: { _ in }, loadModels: { _ in })
            let measure = NSHostingView(rootView: body)
            measure.layoutSubtreeIfNeeded()
            let height = ceil(measure.fittingSize.height) + TranslationWindowLayout.headerHeight + TranslationWindowLayout.footerHeight + 2
            let view = TranslationCard(state: state, close: {}, retry: {}, settings: {}).environment(\.colorScheme, dark ? .dark : .light)
            let frameWidth: CGFloat = ocr ? 460 : 360
            let preview = VStack(spacing: 16) {
                if ocr {
                    Image(decorative: screenshotImage(), scale: 1)
                        .resizable().scaledToFit().frame(width: 428)
                        .accessibilityLabel("截图原图")
                }
                view.frame(width: 360, height: height)
            }
            .padding(ocr ? 16 : 0)
            .background(ocr ? Color(nsColor: .windowBackgroundColor) : .clear)
            let host = NSHostingView(rootView: preview)
            host.frame = NSRect(x: 0, y: 0, width: frameWidth, height: ocr ? height + 119 : height)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw QingyiError.message("Unable to render service cards") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: url.appendingPathComponent(name + ".png"))
            window.close()
        }
    }
}

@MainActor
final class NativeServiceScrollFixture: NSObject, NSApplicationDelegate {
    private let controller = FloatingController()
    private var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onClose = { NSApp.terminate(nil) }
        controller.showResult()
        controller.state.pinned = true
        controller.state.services = TranslationServiceID.allCases.map { ServiceTranslationResult(id: $0) }
        controller.resultPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.controller.state.services = TranslationServiceID.allCases.map { id in
                let text = (1...60).map { "\(id.name)第 \($0) 段：这是一段用于验证长译文滚动和文字选择的固定中文内容。" }.joined(separator: "\n")
                return ServiceTranslationResult(id: id, loading: false, result: .init(text: text + "\n\(id.name)结束标记"))
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.record() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.resultPanel.makeKeyAndOrderFront(nil); return true
    }
    private func findScroll(_ view: NSView) -> TranslationBodyScrollView? {
        if let scroll = view as? TranslationBodyScrollView { return scroll }
        return view.subviews.compactMap(findScroll).first
    }
    private func record() {
        guard let root = controller.resultPanel.contentView, let scroll = findScroll(root) else { return }
        let value: [String: Any] = ["documentHeight": scroll.documentView?.frame.height ?? 0,
            "viewportHeight": scroll.contentView.bounds.height, "scrollY": scroll.contentView.bounds.minY,
            "verticalScroller": scroll.hasVerticalScroller, "realNetworkRequests": false]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("scroll-state.json"), options: .atomic)
        }
    }
}
