import AppKit
import SwiftUI

// A closing window from an earlier GUI test must not give this background fixture keyboard focus.
private final class BackgroundActionEditorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension QingyiTests {
    @MainActor static func aiActionTests() async {
        await automaticSelectionToolbarTests()
        selectionToolbarFocusTests()
        @MainActor func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
        }
        check("Whole action headers open editing from blank and model areas while switches stay separate") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
            let header = AIActionHeaderView(frame: NSRect(x: 10, y: 60, width: 500, height: 50))
            root.addSubview(header); window.contentView = root
            let custom = AIAction(name: "总结", prompt: "总结资料")
            for operation in [TextOperation.translation, .polishing, .custom(custom)] {
                var clicks = 0
                @MainActor func configure() {
                    header.configure(operation: operation, enabled: true, modelSummary: "全局默认 · 测试模型")
                    header.layoutSubtreeIfNeeded()
                }
                header.onEdit = { clicks += 1; configure() }
                configure()
                let points = [NSPoint(x: 4, y: 25), NSPoint(x: 80, y: 34), NSPoint(x: 100, y: 12), NSPoint(x: 400, y: 8), NSPoint(x: 400, y: 45)]
                for _ in 0..<2 {
                    for local in points {
                        let parentPoint = header.convert(local, to: root)
                        try expect(header.hitTest(parentPoint) === header.editButton)
                        let point = header.convert(local, to: nil)
                        let time = ProcessInfo.processInfo.systemUptime
                        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.001,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
                        let previous = clicks
                        NSApp.postEvent(up, atStart: true)
                        header.editButton.mouseDown(with: down)
                        try expect(clicks == previous + 1)
                    }
                }
                try expect(clicks == 10)
                try expect(header.editButton.accessibilityLabel() == "编辑\(operation.action)")
                let switchPoint = NSPoint(x: header.toggle.frame.midX, y: header.toggle.frame.midY)
                try expect(header.hitTest(header.convert(switchPoint, to: root)) !== header.editButton)
                try expect(!header.containsActivationPoint(header.convert(switchPoint, to: nil)))
            }
        }
        await asyncCheck("Action rows present separate editors and native prompt edits autosave without changing models or order") {
            let domain = "qingyi-action-modal-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let chat = ChatGPT(defaults: defaults, vault: MemoryChatGPTVault())
            let custom = AIAction(name: "会议纪要", prompt: "记录会议决策", model: .init(service: .customAPI("missing"), modelID: "preserved"))
            try config.textSettings.saveAction(custom)
            for operation in [TextOperation.translation, .polishing, .custom(custom)] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer {
                    if let sheet = window.attachedSheet { window.endSheet(sheet) }
                    window.close()
                }
                let host = NSHostingView(rootView: SettingsView(preferences: Preferences(defaults: defaults), chat: chat, api: config,
                    navigation: SettingsNavigation(section: .prompts), updateShortcut: { _ in true }, shortcutRecording: { _ in },
                    preview: {}, verify: {}, services: BuiltinTranslationSettings(defaults: defaults), loadsAccounts: false))
                window.contentView = host; window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(120))
                host.layoutSubtreeIfNeeded()
                let label = "编辑\(operation.action)"
                guard let header = descendants(host, of: AIActionHeaderView.self).first(where: { $0.editButton.accessibilityLabel() == label }) else {
                    throw QingyiError.message("Missing action row: \(label)")
                }
                let ids = config.textSettings.actions.map(\.id)
                let model = config.textSettings.model(for: operation)
                let height = header.bounds.height
                header.editButton.performClick(nil)
                for _ in 0..<40 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(25)) }
                guard let sheet = window.attachedSheet, let content = sheet.contentView else { throw QingyiError.message("Action click did not present an editor sheet") }
                try await Task.sleep(for: .milliseconds(120))
                content.layoutSubtreeIfNeeded()
                try expect(header.bounds.height == height && height == 50, "The list row must not expand")
                let original = config.textSettings.instructions(for: operation)
                guard let editor = descendants(content, of: NSTextView.self).first(where: { $0.string == original }) else {
                    throw QingyiError.message("Editor did not load the current prompt")
                }
                let replacement = "在弹窗中修改：\(operation.action)"
                editor.string = replacement; editor.didChangeText()
                try await Task.sleep(for: .milliseconds(80))
                try expect(config.textSettings.instructions(for: operation) == replacement, "Native editor changes must autosave")
                try expect(AITextSettings(defaults: defaults).instructions(for: operation) == replacement)
                try expect(config.textSettings.actions.map(\.id) == ids && config.textSettings.model(for: operation) == model)
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                if operation.customAction != nil {
                    editor.string = ""; editor.didChangeText()
                    try await Task.sleep(for: .milliseconds(80))
                    _ = sheet.performKeyEquivalent(with: escape)
                    for _ in 0..<40 where sheet.attachedSheet == nil { try await Task.sleep(for: .milliseconds(25)) }
                    guard let alert = sheet.attachedSheet, let alertContent = alert.contentView,
                          let discard = descendants(alertContent, of: NSButton.self).first(where: { $0.title == "放弃未保存内容" }) else {
                        throw QingyiError.message("Invalid prompt must require confirmation before closing")
                    }
                    try expect(config.textSettings.instructions(for: operation) == replacement, "Invalid text must preserve the last saved prompt")
                    discard.performClick(nil)
                } else { _ = sheet.performKeyEquivalent(with: escape) }
                for _ in 0..<40 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(25)) }
                try expect(window.attachedSheet == nil, "Done must return to the action list")
            }
        }
        check("New and edit action forms have the same native size, including built-in editors") {
            let domain = "qingyi-action-form-size-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let chat = ChatGPT(defaults: defaults, vault: MemoryChatGPTVault())
            let engine = TranslationEngine(chat: chat, configuration: config)
            let action = AIAction(name: "会议纪要", prompt: "整理会议记录")
            try config.textSettings.saveAction(action)
            let creation = NSHostingView(rootView: AIActionCreationView(settings: config.textSettings, engine: engine, api: config, chat: chat, close: {}))
            let size = creation.fittingSize
            try expect(size == NSSize(width: 680, height: 600))
            for operation in [TextOperation.translation, .polishing, .custom(action)] {
                let editor = NSHostingView(rootView: AIActionEditView(settings: config.textSettings, engine: engine, api: config, chat: chat, operation: operation, close: {}))
                try expect(editor.fittingSize == size, "New and edit modal dimensions must match")
            }
        }
        check("Action model summaries distinguish global and independent choices and refresh without fallback") {
            let domain = "qingyi-action-model-summary-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config)
            let empty = AIActionModelSummary(engine: engine, operation: .translation)
            try expect(empty.text == "全局默认 · 未配置" && empty.unavailable)
            var provider = fixtureProvider()
            provider.name = "测试服务"
            provider.models = [.init(id: "a", name: "模型 A"), .init(id: "b", name: "模型 B")]
            provider.selectedModelID = "a"
            try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
            let global = AIActionModelSummary(engine: engine, operation: .translation)
            try expect(global.text == "全局默认 · 测试服务 · 模型 A" && !global.unavailable)
            let action = AIAction(name: "总结", prompt: "总结资料", model: .init(service: .customAPI(provider.id), modelID: "a"))
            try config.textSettings.saveAction(action)
            let explicit = AIActionModelSummary(engine: engine, operation: .custom(action))
            try expect(explicit.text == "独立选择 · 测试服务 · 模型 A" && !explicit.unavailable)
            try config.selectModel("b")
            try expect(AIActionModelSummary(engine: engine, operation: .translation).text.hasSuffix("模型 B"))
            try expect(AIActionModelSummary(engine: engine, operation: .custom(action)).text == explicit.text)
            let header = AIActionHeaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 50))
            header.configure(operation: .custom(action), enabled: true, modelSummary: explicit.text)
            header.layoutSubtreeIfNeeded()
            try expect(!header.modelLabel.isHidden && header.modelLabel.stringValue == explicit.text)
            try expect(header.modelLabel.frame.maxX < header.toggle.frame.minX && header.modelLabel.frame.maxY <= header.editButton.frame.minY)
            try config.remove(provider.id)
            let missing = AIActionModelSummary(engine: engine, operation: .custom(action))
            try expect(missing.unavailable && missing.text.hasPrefix("独立选择") && missing.text.contains("不可用"))
        }
        check("Legacy action order migrates with built-ins, preserves edited settings, and survives additions, deletion and restart") {
            let domain = "qingyi-action-management-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let target = TranslationTarget(service: .customAPI("provider"), modelID: "model")
            var first = AIAction(name: "第一项", prompt: "旧指令", model: target)
            let second = AIAction(name: "第二项", prompt: "第二项指令", enabled: false)
            let third = AIAction(name: "第三项", prompt: "第三项指令")
            defaults.set(try JSONEncoder().encode([first, second, third]), forKey: AITextSettings.actionsKey)
            let settings = AITextSettings(defaults: defaults)
            try expect(settings.orderedOperations == [.translation, .polishing, .custom(first), .custom(second), .custom(third)])
            var prompts = settings.prompts
            prompts.translation = "逐段翻译"; prompts.polishing = "保留语气"
            try settings.save(prompts)
            settings.selectModel(target, for: .translation)
            settings.selectModel(target, for: .polishing)
            let stale = TextOperation.custom(first)
            first.prompt = "更新后的指令"; try settings.saveAction(first)
            try settings.setEnabled(false, for: .translation)
            try settings.setEnabled(true, for: .polishing)
            try settings.setEnabled(false, for: stale)
            try expect(settings.actions[0].prompt == first.prompt && settings.actions[0].model == target)
            try settings.moveOperation(first.id.uuidString, to: third.id.uuidString)
            try expect(settings.actions.map(\.id) == [second.id, third.id, first.id])
            try settings.moveOperation(first.id.uuidString, to: second.id.uuidString)
            try expect(settings.actions.map(\.id) == [first.id, second.id, third.id])
            try settings.moveOperation(first.id.uuidString, to: first.id.uuidString)
            try settings.moveOperation(UUID().uuidString, to: first.id.uuidString)
            try settings.moveOperation(TextOperation.polishing.key, to: second.id.uuidString)
            let extra = AIAction(name: "追加项", prompt: "新指令")
            try settings.saveAction(extra)
            try settings.removeAction(second.id)
            let reopened = AITextSettings(defaults: defaults)
            try expect(reopened.actions == settings.actions && !reopened.translationEnabled && reopened.polishingEnabled)
            try expect(reopened.orderedOperations.map(\.key) == [TextOperation.translation.key, first.id.uuidString, TextOperation.polishing.key, third.id.uuidString, extra.id.uuidString])
            try expect(reopened.actions.filter(\.enabled).map(\.id) == [third.id, extra.id])
            try expect(reopened.prompts == prompts && reopened.model(for: .translation) == target && reopened.model(for: .polishing) == target)
            try expect(reopened.actions[0].prompt == first.prompt && reopened.actions[0].model == target)
            let item = AIActionPasteboard.item(for: first.id.uuidString)
            try expect(item.string(forType: AIActionPasteboard.type) == first.id.uuidString)
            try expect(item.string(forType: .string) == nil, "Action drags must not intercept ordinary text drops")
        }
        check("Native headers accept built-in and custom drag payloads and reject invalid and same-row drops") {
            let domain = "qingyi-native-action-drop-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let actions = [AIAction(name: "第一项", prompt: "第一项指令"), AIAction(name: "第二项", prompt: "第二项指令"), AIAction(name: "第三项", prompt: "第三项指令")]
            for action in actions { try settings.saveAction(action) }
            let target = TextOperation.custom(actions[2])
            let header = AIActionHeaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 50))
            var commits = 0
            @MainActor func configure(_ destination: TextOperation) {
                header.configure(operation: destination, enabled: true)
                header.canMove = { source in settings.orderedOperations.contains { $0.key == source } }
                header.onMove = { source in
                    do { try settings.moveOperation(source, to: destination.key); commits += 1; return true }
                    catch { return false }
                }
            }
            configure(target)
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.writeObjects([AIActionPasteboard.item(for: actions[0].id.uuidString)])
            try expect(header.accepts(board) && settings.actions == actions && commits == 0, "Hover/drag cancellation must not save a new order")
            try expect(header.receive(board) && commits == 1)
            try expect(settings.actions.map(\.id) == [actions[1].id, actions[2].id, actions[0].id])
            try expect(AITextSettings(defaults: defaults).actions == settings.actions)
            board.clearContents(); board.setString("Unrelated text", forType: .string)
            try expect(!header.receive(board) && commits == 1)
            board.clearContents(); board.setString("invalid-uuid", forType: AIActionPasteboard.type)
            try expect(!header.receive(board))
            board.clearContents(); board.writeObjects([AIActionPasteboard.item(for: UUID().uuidString)])
            try expect(!header.receive(board))
            board.clearContents(); board.writeObjects([AIActionPasteboard.item(for: target.key)])
            try expect(!header.receive(board))
            configure(.translation)
            board.clearContents(); board.writeObjects([AIActionPasteboard.item(for: TextOperation.polishing.key)])
            try expect(header.receive(board) && commits == 2)
            try expect(Array(settings.orderedOperations.prefix(2)) == [.polishing, .translation])
            configure(.polishing)
            board.clearContents(); board.writeObjects([AIActionPasteboard.item(for: actions[0].id.uuidString)])
            try expect(header.receive(board) && commits == 3)
            try expect(settings.orderedOperations.prefix(3).map(\.key) == [actions[0].id.uuidString, TextOperation.polishing.key, TextOperation.translation.key])
        }
        await asyncCheck("Dragging a built-in title over a custom or built-in row previews, cancels, and commits through the settings window") {
            let domain = "qingyi-drag-builtins-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let custom = AIAction(name: "总结", prompt: "概括选区")
            try config.textSettings.saveAction(custom)
            let host = NSHostingView(rootView: AIPromptEditor(api: config, chat: ChatGPT(defaults: defaults, vault: MemoryChatGPTVault()), client: CustomAPIClient()))
            let window = BackgroundActionEditorPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 680), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            @MainActor func drag(_ source: TextOperation, onto target: TextOperation, cancel: Bool) async throws {
                host.layoutSubtreeIfNeeded()
                let rows = descendants(host, of: AIActionHeaderView.self)
                guard let from = rows.first(where: { $0.editButton.actionID == source.key }),
                      let to = rows.first(where: { $0.editButton.actionID == target.key }) else { throw QingyiError.message("Missing drag source or destination") }
                let start = from.editButton.convert(NSPoint(x: 24, y: from.editButton.bounds.midY), to: nil)
                let end = to.editButton.convert(NSPoint(x: 24, y: to.editButton.bounds.midY), to: nil)
                try expect(abs(start.y - end.y) > 4, "The drag must cross two distinct rows")
                @MainActor func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                }
                var preview: [String]?, orderDuringDrag: [String]?
                var dragPanel: NSPanel?
                var previewWasKey = false
                var windowsThatBecameKey = Set<ObjectIdentifier>()
                let focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                    MainActor.assumeIsolated {
                        if let keyWindow = note.object as? NSWindow { windowsThatBecameKey.insert(ObjectIdentifier(keyWindow)) }
                    }
                }
                defer { NotificationCenter.default.removeObserver(focusObserver) }
                let observer = AIActionPasteboard.onPreview
                // End tracking even if the drag never reaches its preview callback.
                var endPosted = false
                @MainActor func finish(_ event: NSEvent) {
                    guard !endPosted else { return }
                    endPosted = true
                    NSApp.postEvent(event, atStart: true)
                }
                let timeout = Timer(fire: Date().addingTimeInterval(1), interval: 0, repeats: false) { _ in
                    MainActor.assumeIsolated { finish(mouse(.leftMouseUp, at: end)) }
                }
                RunLoop.main.add(timeout, forMode: .eventTracking)
                defer { timeout.invalidate(); AIActionPasteboard.onPreview = observer }
                AIActionPasteboard.onPreview = { panel in
                    dragPanel = panel
                    previewWasKey = previewWasKey || panel.isKeyWindow
                    preview = from.reorder?.previewIDs
                    orderDuringDrag = config.textSettings.orderedOperations.map(\.key)
                    let escape = NSEvent.keyEvent(with: .keyDown, location: end, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                    finish(cancel ? escape : mouse(.leftMouseUp, at: end))
                }
                let initial = config.textSettings.orderedOperations
                var expected = initial
                guard let sourceIndex = initial.firstIndex(of: source), let targetIndex = initial.firstIndex(of: target) else {
                    throw QingyiError.message("The settings order is missing a visible action")
                }
                expected.remove(at: sourceIndex); expected.insert(source, at: targetIndex)
                NSApp.postEvent(mouse(.leftMouseDragged, at: end), atStart: true)
                from.editButton.mouseDown(with: mouse(.leftMouseDown, at: start))
                timeout.invalidate()
                guard let dragPanel else { throw QingyiError.message("A drag should create its preview window") }
                try expect(!previewWasKey && !windowsThatBecameKey.contains(ObjectIdentifier(dragPanel)), "The drag preview must never take keyboard focus")
                try expect(window.attachedSheet == nil, "Dragging a title must not open its editor")
                try expect(preview == expected.map(\.key) && orderDuringDrag == initial.map(\.key))
                let finalOrder = cancel ? initial : expected
                try expect(config.textSettings.orderedOperations == finalOrder)
                try await waitForPolishing {
                    host.layoutSubtreeIfNeeded()
                    let cards = descendants(host, of: AIActionCardView.self).filter { !$0.isHiddenOrHasHiddenAncestor }
                    let displayed = cards.sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
                    return displayed.compactMap(\.actionID) == finalOrder.map(\.key)
                }
            }
            try await drag(.translation, onto: .custom(custom), cancel: true)
            try await drag(.polishing, onto: .translation, cancel: false)
            try await drag(.translation, onto: .custom(custom), cancel: false)
            try expect(AITextSettings(defaults: defaults).orderedOperations == [.polishing, .custom(custom), .translation])
        }
        check("Live action order previews before release, cancellation preserves storage, and a drop saves once") {
            let domain = "qingyi-live-order-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let actions = [AIAction(name: "甲", prompt: "指令甲"), AIAction(name: "乙", prompt: "指令乙"), AIAction(name: "丙", prompt: "指令丙")]
            for action in actions { try settings.saveAction(action) }
            let ids = settings.orderedOperations.map(\.key), drag = AIActionReorderSession()
            var saves = 0
            @MainActor func start() {
                drag.begin(source: ids[0], order: ids) { source, target in
                    do { try settings.moveOperation(source, to: target); saves += 1; return true }
                    catch { return false }
                }
            }
            start()
            try expect(drag.hover(over: ids[1]) && drag.previewIDs == [ids[1], ids[0], ids[2], ids[3], ids[4]])
            try expect(settings.orderedOperations.map(\.key) == ids && saves == 0, "Hover must update the preview before committing preferences")
            try expect(!drag.finish(accept: false) && drag.previewIDs == nil && AITextSettings(defaults: defaults).orderedOperations.map(\.key) == ids)
            start(); drag.hover(over: ids[2]); drag.hover(over: ids[1])
            try expect(drag.previewIDs == ids)
            drag.hover(over: ids[2]); try expect(drag.finish(accept: true) && saves == 1)
            try expect(settings.orderedOperations == [.polishing, .custom(actions[0]), .translation, .custom(actions[1]), .custom(actions[2])])
            try expect(AITextSettings(defaults: defaults).orderedOperations == settings.orderedOperations)
        }
        await asyncCheck("Optimization works with an independent model and no global model, and never substitutes an unavailable target") {
            let domain = "qingyi-optimization-choice-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            var provider = fixtureProvider(); provider.models = [APIModel(id: "chosen", name: "Chosen")]; provider.selectedModelID = "chosen"
            try config.save(provider, replacementKey: "fixture")
            try config.selectProvider(APIConfiguration.unconfiguredProviderID)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            var action = AIAction(name: "总结", prompt: "总结输入", model: .init(service: .customAPI(provider.id), modelID: "chosen"))
            try config.textSettings.saveAction(action)
            try rejects { _ = try engine.defaultChoice() }
            try expect(try engine.optimizationChoice(for: .custom(action)).target.modelID == "chosen")
            var calls = 0
            FixtureAPIProtocol.handle = { request in
                calls += 1; try expect(try bodyOfRequest(request)["model"] as? String == "chosen")
                return (200, "application/json", Data(#"{"choices":[{"message":{"content":"优化后的指令"},"finish_reason":"stop"}]}"#.utf8))
            }
            let result = try await engine.optimizePrompt(action.prompt, for: .custom(action))
            try expect(result == "优化后的指令" && calls == 1)
            action.model = .init(service: .customAPI(provider.id), modelID: "deleted")
            try rejects { _ = try engine.optimizationChoice(for: .custom(action)) }
            do { _ = try await engine.optimizePrompt(action.prompt, for: .custom(action)); throw QingyiError.message("Unexpected optimization") }
            catch { try expect(calls == 1) }
            try config.selectProvider(provider.id)
            action.model = nil
            try expect(try engine.optimizationChoice(for: .custom(action)).target.modelID == "chosen")
        }
        check("Custom actions persist order, enabled state, model and exact prompt without changing legacy settings") {
            let domain = "qingyi-actions-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            var prompts = settings.prompts; prompts.translation = "已有翻译指令"; prompts.polishing = "已有润色指令"
            try settings.save(prompts); settings.translationEnabled = false; settings.polishingEnabled = true
            let target = TranslationTarget(service: .customAPI("provider"), modelID: "model")
            settings.selectModel(target, for: .translation)
            try expect(settings.actions.isEmpty && settings.actionModifier == .option)
            let summary = AIAction(name: "  内容总结  ", prompt: "  总结用户资料。\n\n保留数字。  ", model: target)
            var explain = AIAction(name: "AI 解释", prompt: "通俗解释")
            try settings.saveAction(summary); try settings.saveAction(explain)
            try rejects { try settings.saveAction(AIAction(name: "内容总结", prompt: "重复")) }
            try rejects { try settings.saveAction(AIAction(name: "翻译", prompt: "保留内置名称")) }
            try rejects { try settings.saveAction(AIAction(name: " \n", prompt: "名称空白")) }
            try rejects { try settings.saveAction(AIAction(name: "空提示词", prompt: " \n")) }
            try settings.moveOperation(explain.id.uuidString, by: -1)
            explain.enabled = false; try settings.saveAction(explain)
            settings.actionModifier = .command
            let reopened = AITextSettings(defaults: defaults)
            try expect(reopened.actions.map(\.id) == [explain.id, summary.id])
            try expect(reopened.actions.last?.name == "内容总结" && reopened.actions.last?.prompt == summary.prompt)
            try expect(!reopened.enabled(.custom(explain)) && reopened.enabled(.custom(summary)))
            try expect(reopened.model(for: .custom(summary)) == target && reopened.actionModifier == .command)
            try expect(reopened.prompts == prompts && !reopened.translationEnabled && reopened.polishingEnabled)
            try expect(reopened.model(for: .translation) == target)
            try reopened.removeAction(summary.id)
            try expect(!reopened.enabled(.custom(summary)) && AITextSettings(defaults: defaults).actions.count == 1)
            reopened.selectModel(nil, for: .custom(summary))
            try expect(reopened.model(for: .translation) == target, "A stale deleted-action model picker must not overwrite translation settings")
            defaults.set(Data("broken".utf8), forKey: AITextSettings.actionsKey)
            let corrupt = AITextSettings(defaults: defaults)
            try expect(!corrupt.actionsLoadError.isEmpty)
            try rejects { try corrupt.saveAction(summary) }
            try expect(defaults.data(forKey: AITextSettings.actionsKey) == Data("broken".utf8))
        }
        check("Explicit custom action execution validates only nonempty input and length across languages, code and URLs") {
            let op = TextOperation.custom(AIAction(name: "解释", prompt: "解释输入"))
            for text in ["好", "a", "😀", "中文与 English", "let x = 42", "https://example.com/中文", String(repeating: "中", count: 12_000)] {
                try expect(try TextPolicy.validate(text, operation: op) == text)
            }
            try rejects { _ = try TextPolicy.validate(" \n", operation: op) }
            try rejects { _ = try TextPolicy.validate(String(repeating: "中", count: 12_001), operation: op) }
            try expect(TextPolicy.automaticSelectionOperation("中文") == .polishing)
            try expect(TextPolicy.automaticSelectionOperation("An English sentence") == .translation)
            try expect(op.serviceName(.ai) == "AI 解释" && op.resultName == "解释结果")
        }
        check("Action modifier fires immediately and waits only for drag completion and selection") {
            for modifier in AIActionModifier.allCases {
                var gesture = AIActionGesture()
                gesture.input(.flags, flags: modifier.flag, time: 10, modifier: modifier)
                try expect(gesture.tick(time: 10, hasSelection: true, mouseDown: false))
                try expect(!gesture.tick(time: 10, hasSelection: true, mouseDown: false))
                gesture.input(.leftDown, flags: modifier.flag, time: 10.1, modifier: modifier)
                try expect(!gesture.tick(time: 10.1, hasSelection: true, mouseDown: true))
                gesture.input(.leftUp, flags: modifier.flag, time: 10.2, modifier: modifier)
                try expect(!gesture.tick(time: 10.2, hasSelection: false, mouseDown: false))
                try expect(gesture.tick(time: 10.2, hasSelection: true, mouseDown: false))
                gesture.input(.flags, flags: [], time: 11, modifier: modifier)
                gesture.input(.flags, flags: modifier.flag, time: 12, modifier: modifier)
                try expect(gesture.tick(time: 12, hasSelection: true, mouseDown: false))
            }
        }
        check("Pending action input rejects typing, combinations, scroll and cancellation without suppressing ordinary hover") {
            for kind in [AIActionGesture.Input.keyDown, .scroll, .otherMouseDown] {
                var gesture = AIActionGesture()
                gesture.input(.flags, flags: .option, time: 0, modifier: .option)
                gesture.input(kind, flags: .option, key: 0, time: 0.1, modifier: .option)
                try expect(!gesture.tick(time: 1, hasSelection: true, mouseDown: false))
            }
            var gesture = AIActionGesture()
            gesture.input(.flags, flags: [.option, .command], time: 0, modifier: .option)
            gesture.input(.flags, flags: .option, time: 1, modifier: .option)
            try expect(!gesture.tick(time: 2, hasSelection: true, mouseDown: false))
            gesture.input(.flags, flags: [], time: 3, modifier: .option)
            gesture.input(.flags, flags: .option, time: 4, modifier: .option)
            gesture.input(.flags, flags: [], time: 4.1, modifier: .option)
            try expect(!gesture.tick(time: 5, hasSelection: true, mouseDown: false))
            var hover = HoverGesture(trigger: .option)
            _ = hover.input(.flags, point: .zero, time: 0, flags: .option)
            try expect(hover.input(.flags, point: .zero, time: 1, flags: []) == .trigger)
            gesture.input(.flags, flags: .option, time: 6, modifier: .option)
            gesture.cancel()
            try expect(!gesture.tick(time: 7, hasSelection: true, mouseDown: false))
            gesture.input(.leftDown, flags: .option, time: 8, modifier: .option)
            gesture.cancel()
            gesture.input(.flags, flags: [], time: 9, modifier: .option)
            gesture.input(.flags, flags: .option, time: 10, modifier: .option)
            try expect(gesture.tick(time: 10.25, hasSelection: true, mouseDown: false), "Context cancellation must clear a drag whose release was lost")
        }
        check("Context cancellation and unmodified selection input leave the first auxiliary press ready") {
            var gesture = AIActionGesture()
            gesture.cancel()
            gesture.input(.flags, flags: .command, time: 1, modifier: .command)
            try expect(gesture.tick(time: 1, hasSelection: true, mouseDown: false), "An idle context change must not block a fresh press")
            gesture.cancel()
            gesture.input(.leftDown, flags: [], time: 2, modifier: .command)
            gesture.input(.leftUp, flags: [], time: 3, modifier: .command)
            gesture.input(.flags, flags: .command, time: 4, modifier: .command)
            try expect(gesture.tick(time: 4, hasSelection: true, mouseDown: false), "A fresh selection can follow a missed modifier release")
        }
        check("Production action routing is immediate, supports press and hold, and ignores zero enabled actions") {
            let domain = "qingyi-action-events-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config)
            let app = AppDelegate(preferences: Preferences(defaults: defaults))
            app.prepareSelectionFixture(engine: engine, client: BuiltinTranslationClient(), settings: BuiltinTranslationSettings(defaults: defaults))
            defer { app.dismissHoverFixture() }
            let previous = SelectionMonitor.leftMouseDownOverride
            SelectionMonitor.leftMouseDownOverride = false
            defer { SelectionMonitor.leftMouseDownOverride = previous }
            func flags(_ value: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: value, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
            }
            app.feedSelectionFixture("当前选区")
            try expect(!app.routeActionEventFixture(flags(.option)) && !app.actionPopup.panel.isVisible)
            try expect(!app.tickActionPopupFixture())
            var action = AIAction(name: "解释", prompt: "解释资料")
            try config.textSettings.saveAction(action)
            try expect(app.routeActionEventFixture(flags(.option)) && app.actionPopup.panel.isVisible)
            _ = app.routeActionEventFixture(flags([]))
            try expect(app.actionPopup.panel.isVisible, "Single press remains visible on release")
            _ = app.routeActionEventFixture(flags(.option))
            try expect(!app.actionPopup.panel.isVisible, "A second press closes the toolbar")
            _ = app.routeActionEventFixture(flags([]))
            config.textSettings.actionTrigger = .hold
            for _ in 0..<2 {
                _ = app.routeActionEventFixture(flags(.option))
                try expect(app.actionPopup.panel.isVisible && app.monitor.modelMenuTracking)
                app.monitor.event(flags([]))
                try expect(!app.actionPopup.panel.isVisible && !app.monitor.modelMenuTracking)
            }
            var scrollCount = 0
            app.monitor.onScroll = { scrollCount += 1 }
            for mode in AIActionTrigger.allCases {
                config.textSettings.actionTrigger = mode
                let previousScrollCount = scrollCount
                let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
                wheel.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
                app.monitor.event(NSEvent(cgEvent: wheel)!)
                try expect(scrollCount == previousScrollCount + 1, "The scroll event must reach selection routing")
                let mouseUp = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0)!
                app.monitor.event(mouseUp)
                app.feedSelectionFixture("滚动后的新选区")
                _ = app.routeActionEventFixture(flags(.option))
                try expect(app.actionPopup.panel.isVisible, "The first auxiliary press after scrolling must open the toolbar in \(mode)")
                _ = app.routeActionEventFixture(flags([]))
                try expect(app.actionPopup.panel.isVisible == (mode == .press))
                _ = app.actionPopup.key(53)
            }
            action.enabled = false; try config.textSettings.saveAction(action)
            try expect(!app.routeActionEventFixture(flags(.option)) && !app.actionPopup.panel.isVisible)
            try config.textSettings.removeAction(action.id)
            try expect(!app.routeActionEventFixture(flags(.option)) && !app.tickActionPopupFixture())
            app.monitor.onSelection?(nil)
            app.hover.configure(enabled: true, trigger: .option)
            var hoverRequests = 0; app.hover.onTrigger = { _ in hoverRequests += 1 }
            var buttons = 1
            app.hover.pressedMouseButtons = { buttons }
            _ = app.monitor.onExternalEvent?(flags(.option))
            _ = app.monitor.onExternalEvent?(flags([]))
            try expect(hoverRequests == 0, "A modifier press while the mouse is held must not trigger hover")
            buttons = 0
            _ = app.monitor.onExternalEvent?(flags(.option))
            _ = app.monitor.onExternalEvent?(flags([]))
            try expect(hoverRequests == 1, "With zero custom actions the original hover gesture is unchanged")
        }
        check("Rapid pointer tracking crosses unequal cells, separators and full toolbar height without stale exit events") {
            let state = AIActionPopupState()
            state.operations = ["短", "较长的动作名称", "润色"].map { .custom(AIAction(name: $0, prompt: "处理")) }
            state.itemFrames = [0: CGRect(x: 3, y: 3, width: 56, height: 26),
                                1: CGRect(x: 68, y: 3, width: 120, height: 26),
                                2: CGRect(x: 197, y: 3, width: 56, height: 26)]
            let bounds = CGRect(x: 0, y: 0, width: 256, height: 32)
            for _ in 0..<100 {
                for (x, index) in [(255.0, 2), (61.0, 0), (190.0, 1), (72.0, 1), (0.0, 0), (200.0, 2)] {
                    for y in [0.0, 16.0, 31.0] {
                        state.trackPointer(CGPoint(x: x, y: y), bounds: bounds)
                        try expect(state.hovered == index && state.selected == index)
                    }
                }
            }
            state.keyboardNavigation = true
            state.trackPointer(CGPoint(x: 200, y: 16), bounds: bounds)
            try expect(!state.keyboardNavigation && state.hovered == 2)
            state.trackPointer(CGPoint(x: -1, y: 16), bounds: bounds)
            try expect(state.hovered == nil)
        }
        check("Shared auxiliary key belongs to selected actions for its whole cycle, otherwise hover can fire") {
            let name = "qingyi-shared-key-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let app = AppDelegate(preferences: Preferences(defaults: defaults))
            app.prepareSelectionFixture(engine: TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config),
                                        client: BuiltinTranslationClient(), settings: BuiltinTranslationSettings(defaults: defaults))
            defer { app.dismissHoverFixture() }
            try config.textSettings.saveAction(AIAction(name: "解释", prompt: "解释"))
            var hoverRequests = 0
            app.hover.configure(enabled: true, trigger: .option)
            app.hover.onTrigger = { _ in hoverRequests += 1 }
            @MainActor @discardableResult func send(_ flags: NSEvent.ModifierFlags) -> Bool {
                let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, characters: "",
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
                let claimed = app.routeActionEventFixture(event)
                if !claimed { _ = app.hover.event(event) }
                return claimed
            }
            for mode in AIActionTrigger.allCases {
                config.textSettings.actionTrigger = mode
                let beforeSelection = hoverRequests
                app.feedSelectionFixture("有效选区")
                send(.option)
                try expect(app.actionPopup.panel.isVisible)
                _ = app.actionPopup.key(53)
                send([])
                try expect(hoverRequests == beforeSelection, "Closing actions while held must not trigger hover on release")
                for text in ["https://example.org", "a", "😀", String(repeating: "x", count: 12_001)] {
                    app.feedSelectionFixture(text)
                    let beforeFiltered = hoverRequests
                    try expect(!send(.option) && !app.actionPopup.panel.isVisible && !app.tickActionPopupFixture())
                    try expect(!send([]) && hoverRequests == beforeFiltered + 1, "Filtered selection must leave hover available in \(mode)")
                }
            }
            app.monitor.onSelection?(nil)
            let beforeEmpty = hoverRequests
            send(.option); send([])
            try expect(hoverRequests == beforeEmpty + 1, "Without selection the same key must still trigger hover")
        }
        check("Action count defaults to four, limits enabled actions, and persists with trigger mode") {
            let domain = "qingyi-action-count-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            try expect(settings.actionDisplayLimit == 4 && settings.actionTrigger == .press && settings.displayedActions.isEmpty)
            let first = AIAction(name: "动作 0", prompt: "指令")
            try settings.saveAction(first)
            try expect(settings.displayedActions.map(\.id) == [first.id])
            for i in 1...11 { try settings.saveAction(AIAction(name: "动作 \(i)", prompt: "指令", enabled: i != 1)) }
            try expect(settings.displayedActions.map(\.name) == ["动作 0", "动作 2", "动作 3", "动作 4"])
            settings.actionDisplayLimit = 1; settings.actionTrigger = .hold
            let reopened = AITextSettings(defaults: defaults)
            try expect(reopened.displayedActions.map(\.id) == [first.id] && reopened.actionDisplayLimit == 1 && reopened.actionTrigger == .hold)
            settings.actionDisplayLimit = 100
            try expect(settings.actionDisplayLimit == 9 && settings.displayedActions.count == 9)
            try expect(AITextSettings(defaults: defaults).actionDisplayLimit == 9)
            defaults.set(20, forKey: AITextSettings.actionDisplayLimitKey)
            let legacy = AITextSettings(defaults: defaults)
            try expect(legacy.actionDisplayLimit == 9 && legacy.displayedActions.count == 9)
            settings.actionDisplayLimit = 0
            try expect(settings.actionDisplayLimit == 1)
        }
        await asyncCheck("Custom action snapshots and independent models reach every API protocol with full input and streaming updates") {
            let domain = "qingyi-action-wire-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            config.textSettings.translationEnabled = false; config.textSettings.polishingEnabled = false
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            let source = String(repeating: "中文资料与代码 let x = 42;\nhttps://example.com\n", count: 50) + "完整末尾"
            for proto in APIProtocol.allCases {
                var provider = fixtureProvider(proto)
                provider.models = [APIModel(id: "global", name: "Global"), APIModel(id: "independent", name: "Independent")]
                provider.selectedModelID = "global"
                try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
                var action = AIAction(name: "内容总结", prompt: "总结资料，保留数字。", model: .init(service: .customAPI(provider.id), modelID: "independent"))
                try config.textSettings.saveAction(action)
                let snapshot = TextOperation.custom(action)
                action.prompt = "新提示词，只对下一次任务生效"; try config.textSettings.saveAction(action)
                FixtureAPIProtocol.handle = { request in
                    let body = try bodyOfRequest(request)
                    try expect(body["model"] as? String == "independent")
                    let prompt = proto == .responses ? body["instructions"] : proto == .anthropic ? body["system"] : (body["messages"] as? [[String: Any]])?.first?["content"]
                    try expect(prompt as? String == snapshot.customAction?.prompt)
                    let entries = body[proto == .responses ? "input" : "messages"] as! [[String: Any]]
                    try expect((entries.last?["content"] as? [[String: Any]])?.first?["text"] as? String == source)
                    switch proto {
                    case .chatCompletions:
                        return (200, "text/event-stream", Data("data: {\"choices\":[{\"delta\":{\"content\":\"总结\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"结果\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
                    case .responses: return (200, "application/json", Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"总结结果"}]}]}"#.utf8))
                    case .anthropic: return (200, "application/json", Data(#"{"content":[{"type":"text","text":"总结结果"}],"stop_reason":"end_turn"}"#.utf8))
                    }
                }
                var updates: [String] = []
                let result = try await engine.translate(source, operation: snapshot) { updates.append($0) }
                try expect(result == "总结结果" && updates.last == result)
                action.model = nil
                try expect(try engine.defaultChoice(for: .custom(action)).target.modelID == "global")
                try config.textSettings.removeAction(action.id)
            }
        }
        await asyncCheck("ChatGPT custom actions accept Chinese and URLs with explicit instructions and immutable model routing") {
            let domain = "qingyi-action-chat-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let account = Registration(id: "action-fixture", subject: "fixture", email: "fixture@example.invalid")
            defaults.set(try JSONEncoder().encode([account]), forKey: "registrations")
            defaults.set(account.id, forKey: "activeRegistration"); defaults.set("model-a", forKey: "model.\(account.id)")
            let vault = MemoryChatGPTVault(); vault.credentials = fixtureCredentials("fixture-token")
            let chat = ChatGPT(defaults: defaults, session: network, vault: vault)
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: chat, configuration: config)
            let action = AIAction(name: "解释", prompt: "解释用户资料", model: .init(service: .chatGPT(account.id), modelID: "model-a"))
            try config.textSettings.saveAction(action)
            let source = "请解释此标记 https://example.com，不抓取网页。"
            FixtureAPIProtocol.handle = { request in
                if request.url?.path.hasSuffix("/models") == true {
                    return (200, "application/json", Data(#"{"models":[{"slug":"model-a","display_name":"Fixture","visibility":"list"}]}"#.utf8))
                }
                let body = try bodyOfRequest(request)
                try expect(body["instructions"] as? String == action.prompt)
                try expect((body["input"] as? [[String: Any]])?.first?["content"] as? String == source)
                return (200, "application/json", Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"解释结果"}]}]}"#.utf8))
            }
            let result = try await engine.translate(source, operation: .custom(action), onUpdate: { _ in })
            try expect(result == "解释结果")
        }
        await asyncCheck("Production custom action popup preserves pinned output, uses captured selection, retries snapshots and blocks deleted actions") {
            let domain = "qingyi-action-app-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            var provider = fixtureProvider(); provider.models = [APIModel(id: "first", name: "First"), APIModel(id: "second", name: "Second")]
            provider.selectedModelID = "first"
            try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
            config.textSettings.translationEnabled = false; config.textSettings.polishingEnabled = false
            var action = AIAction(name: "总结", prompt: "原提示词")
            try config.textSettings.saveAction(action)
            var disabled = AIAction(name: "隐藏动作", prompt: "不应出现在弹窗"); disabled.enabled = false
            try config.textSettings.saveAction(disabled)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            let services = BuiltinTranslationSettings(defaults: defaults); services.ai = false
            var builtinCalls = 0, prompts: [String] = [], models: [String] = []
            let app = AppDelegate(preferences: Preferences(defaults: defaults))
            app.prepareSelectionFixture(engine: engine, client: BuiltinTranslationClient(youdao: { _ in builtinCalls += 1; return .init(text: "不应请求") }), settings: services)
            defer { app.dismissHoverFixture() }
            app.floating.showResult(preview: true)
            app.floating.state.text = "钉住的结果"; app.floating.state.pinned = true
            let source = "请总结 https://example.com/ 上的说明。"
            FixtureAPIProtocol.handle = { request in
                let body = try bodyOfRequest(request)
                prompts.append((body["messages"] as! [[String: Any]]).first!["content"] as! String)
                models.append(body["model"] as! String)
                let content = (body["messages"] as! [[String: Any]]).last!["content"] as! [[String: Any]]
                try expect(content.first?["text"] as? String == source)
                return (200, "application/json", Data(#"{"choices":[{"message":{"content":"总结结果"},"finish_reason":"stop"}]}"#.utf8))
            }
            for filtered in ["https://example.com/当前选区", "a", "—", "😀"] {
                app.showActionPopupFixture(source: filtered)
                try expect(!app.actionPopup.panel.isVisible && !app.monitor.modelMenuTracking && !app.actionPopup.key(36))
                try expect(app.floating.resultPanel.isVisible && app.floating.state.text == "钉住的结果" && app.floating.state.pinned)
            }
            app.showActionPopupFixture(source: source)
            try expect(app.actionPopup.panel.isVisible && app.monitor.modelMenuTracking && app.actionPopup.operations == [.custom(action)])
            try expect(app.floating.state.text == "钉住的结果" && app.floating.state.pinned)
            try expect(app.actionPopup.key(53) && !app.actionPopup.panel.isVisible && app.floating.state.text == "钉住的结果")
            try expect(models.isEmpty && builtinCalls == 0)
            do {
                let previous = SelectionMonitor.leftMouseDownOverride
                SelectionMonitor.leftMouseDownOverride = true
                defer { SelectionMonitor.leftMouseDownOverride = previous }
                app.showActionPopupFixture(source: source)
                try expect(SelectionMonitor.isLeftMouseDown, "A synthetic completed selection must restore external mouse state")
            }
            try expect(app.actionPopup.key(36))
            try await waitForPolishing { app.floating.state.complete }
            try expect(app.floating.state.operation == .custom(action) && app.floating.state.services.map(\.id) == [.ai] && builtinCalls == 0)
            action.prompt = "改过的提示词"; action.name = "新名称"; try config.textSettings.saveAction(action)
            let id = app.floating.state.sessionID
            app.floating.onSelectModel?(engine.choice(for: .init(service: .customAPI(provider.id), modelID: "second")), id)
            try await waitForPolishing { models.count == 2 && app.floating.state.complete }
            app.floating.onRetryService?(.ai)
            try await waitForPolishing { models.count == 3 && app.floating.state.complete }
            try expect(prompts == ["原提示词", "原提示词", "原提示词"] && models == ["first", "second", "second"])
            try config.textSettings.removeAction(action.id)
            app.floating.onRetry?()
            try await Task.sleep(for: .milliseconds(30))
            try expect(models.count == 3 && !app.floating.state.modelSelectionEnabled && !app.floating.state.actionAvailable)
            try expect(app.floating.state.text == "总结结果")
        }
        await asyncCheck("Result action switches use the full original text, selected action model and prompt in the same pinned window") {
            let domain = "qingyi-result-action-switch-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let settings = config.textSettings
            var provider = fixtureProvider()
            provider.models = ["global", "temporary", "summary"].map { APIModel(id: $0, name: $0) }
            provider.selectedModelID = "global"
            try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
            let explain = AIAction(name: "解释", prompt: "解释原文")
            let summary = AIAction(name: "总结", prompt: "总结原文", model: .init(service: .customAPI(provider.id), modelID: "summary"))
            var short = AIAction(name: "简写", prompt: "简写原文")
            for action in [explain, summary, short] { try settings.saveAction(action) }
            settings.polishingEnabled = true
            settings.actionDisplayLimit = 1
            try settings.moveOperation(short.id.uuidString, to: summary.id.uuidString)
            let app = AppDelegate(preferences: Preferences(defaults: defaults))
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            app.prepareSelectionFixture(engine: engine, client: BuiltinTranslationClient(session: network), settings: BuiltinTranslationSettings(defaults: defaults, enabledByDefault: false))
            defer { app.dismissHoverFixture() }
            let source = String(repeating: "请保留这段文字的含义。", count: 70) + "原文结尾不能省略。"
            var prompts: [String] = [], models: [String] = [], sources: [String] = []
            FixtureAPIProtocol.handle = { request in
                let body = try bodyOfRequest(request)
                guard let messages = body["messages"] as? [[String: Any]], let model = body["model"] as? String,
                      let prompt = messages.first?["content"] as? String, let content = messages.last?["content"] as? [[String: Any]],
                      let original = content.first?["text"] as? String else { throw QingyiError.message("Invalid action payload") }
                prompts.append(prompt); models.append(model); sources.append(original)
                return (200, "application/json", Data(#"{"choices":[{"message":{"content":"这是模型结果，与原文不同。"},"finish_reason":"stop"}]}"#.utf8))
            }
            app.startActionFixture(explain, source: source)
            try await waitForPolishing { app.floating.state.complete }
            let state = app.floating.state
            let initial = state.sessionID
            try expect(state.resultActions == [.polishing, .custom(short), .custom(summary)])
            try settings.moveOperation(TextOperation.polishing.key, to: summary.id.uuidString)
            try await waitForPolishing { state.resultActions == [.custom(short), .custom(summary), .polishing] }
            try expect(state.sessionID == initial && models.count == 1 && state.complete)
            try expect(settings.displayedActions.map(\.id) == [explain.id])
            let temp = engine.choice(for: .init(service: .customAPI(provider.id), modelID: "temporary"))
            app.floating.onSelectModel?(temp, initial)
            try await waitForPolishing { models.count == 2 && state.complete }
            try expect(state.temporaryModel)
            state.pinned = true
            let frame = app.floating.resultPanel.frame
            app.floating.onSwitchAction?(.custom(summary), initial)
            try await waitForPolishing { state.complete && state.operation == .custom(summary) }
            try expect(source.count > 600 && sources == Array(repeating: source, count: 3))
            try expect(models == ["global", "temporary", "summary"] && prompts == [explain.prompt, explain.prompt, summary.prompt])
            try expect(state.sessionID != initial && !state.temporaryModel && state.pinned && app.floating.resultPanel.isVisible)
            try expect(abs(app.floating.resultPanel.frame.minX - frame.minX) < 1 && abs(app.floating.resultPanel.frame.maxY - frame.maxY) < 1)
            let current = state.sessionID
            app.floating.onSwitchAction?(.polishing, initial)
            app.floating.onSwitchAction?(.custom(summary), current)
            short.enabled = false
            try settings.saveAction(short)
            try await waitForPolishing { !state.resultActions.contains(where: { $0.customAction?.id == short.id }) }
            app.floating.onSwitchAction?(.custom(short), current)
            try settings.removeAction(explain.id)
            try await waitForPolishing { !state.resultActions.contains(where: { $0.customAction?.id == explain.id }) }
            app.floating.onSwitchAction?(.custom(explain), current)
            settings.polishingEnabled = false
            try await waitForPolishing { state.resultActions.isEmpty }
            app.floating.onSwitchAction?(.polishing, current)
            try expect(state.sessionID == current && state.complete && state.pinned)
            settings.polishingEnabled = true
            try await waitForPolishing { state.resultActions == [.polishing] }
            app.floating.onSwitchAction?(.polishing, current)
            try await waitForPolishing { state.operation == .polishing && state.complete }
            try expect(models.count == 4 && models.last == "global" && sources.last == source && prompts.last == settings.instructions(for: .polishing))
            try expect(state.pinned && state.resultActions == [.custom(summary)])
            app.startActionFixture(summary, source: "An English original.")
            try await waitForPolishing { state.operation == .custom(summary) && state.complete }
            let english = state.sessionID
            try expect(state.resultActions.isEmpty)
            app.floating.onSwitchAction?(.polishing, english)
            try expect(state.sessionID == english && models.count == 5)
            app.screenshotClipboardFixture("An ordinary translated sentence.")
            try await waitForPolishing { state.operation == .translation && state.complete }
            let translated = state.sessionID
            try expect(state.resultActions.isEmpty)
            app.floating.onSwitchAction?(.custom(summary), translated)
            try expect(state.sessionID == translated && models.count == 6)
        }
        await asyncCheck("Switching actions while the first request is pending keeps the newer result when the earlier reply arrives") {
            let domain = "qingyi-result-action-late-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer {
                FixtureAPIProtocol.scheduleResponse = nil; FixtureAPIProtocol.handle = nil
                network.invalidateAndCancel(); defaults.removePersistentDomain(forName: domain)
            }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let provider = fixtureProvider()
            try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
            let first = AIAction(name: "提取", prompt: "旧请求")
            let next = AIAction(name: "解释", prompt: "新请求")
            for action in [first, next] { try config.textSettings.saveAction(action) }
            let app = AppDelegate(preferences: Preferences(defaults: defaults))
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            app.prepareSelectionFixture(engine: engine, client: BuiltinTranslationClient(session: network), settings: BuiltinTranslationSettings(defaults: defaults, enabledByDefault: false))
            defer { app.dismissHoverFixture() }
            var calls = 0
            var release: (() -> Void)?
            FixtureAPIProtocol.handle = { _ in
                calls += 1
                let output = calls == 1 ? "旧结果" : "新结果"
                let body = ["choices": [["message": ["content": output], "finish_reason": "stop"]]]
                return (200, "application/json", try JSONSerialization.data(withJSONObject: body))
            }
            FixtureAPIProtocol.scheduleResponse = { _, deliver in
                if calls == 1 { DispatchQueue.main.async { release = deliver } }
                else { deliver() }
            }
            app.startActionFixture(first, source: "An original selection.")
            try await waitForPolishing { release != nil }
            let oldSession = app.floating.state.sessionID
            app.floating.onSwitchAction?(.custom(next), oldSession)
            try await waitForPolishing { app.floating.state.complete && app.floating.state.text == "新结果" }
            let current = app.floating.state.sessionID
            release?(); release = nil
            try await Task.sleep(for: .milliseconds(60))
            try expect(calls == 2 && oldSession != current && app.floating.state.sessionID == current)
            try expect(app.floating.state.complete && app.floating.state.operation == .custom(next) && app.floating.state.text == "新结果")
        }
        await asyncCheck("Cancelled custom actions waiting for credentials cannot send stale text or overwrite the next task") {
            let domain = "qingyi-action-cancel-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session(), vault = AuthorizedAPIKeyVault()
            defer { vault.authorization.release(); defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let config = APIConfigurationStore(defaults: defaults, vault: vault)
            let provider = fixtureProvider(); try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
            let action = AIAction(name: "解释", prompt: "解释输入")
            try config.textSettings.saveAction(action)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            let services = BuiltinTranslationSettings(defaults: defaults); services.youdao = false; services.google = false; services.ai = true
            let app = AppDelegate(preferences: Preferences(defaults: defaults))
            app.prepareSelectionFixture(engine: engine, client: BuiltinTranslationClient(session: network), settings: services)
            defer { app.dismissHoverFixture() }
            var sources: [String] = []
            FixtureAPIProtocol.handle = { request in
                let body = try bodyOfRequest(request)
                sources.append(((body["messages"] as! [[String: Any]]).last!["content"] as! [[String: Any]]).first!["text"] as! String)
                return (200, "application/json", Data(#"{"choices":[{"message":{"content":"当前结果"},"finish_reason":"stop"}]}"#.utf8))
            }
            app.startActionFixture(action, source: "旧选区")
            try await waitForPolishing { vault.authorization.reads == 1 }
            app.feedSelectionFixture("New selection."); app.floating.onTrigger?()
            try await Task.sleep(for: .milliseconds(30)); vault.authorization.release()
            try await waitForPolishing { app.floating.state.complete }
            try expect(sources == ["New selection."] && app.floating.state.operation == .translation)
        }
        check("Horizontal action toolbar fits the screen and supports arrow navigation and Return") {
            let actions = ["润色 1", "内容总结 1", "112233", "1111"].map { AIAction(name: $0, prompt: "处理输入") }
            let popup = AIActionPopup(); defer { popup.hide() }
            popup.show(operations: actions.map(TextOperation.custom), position: .lowerLeft, presentation: .modifier)
            try expect(popup.panel.frame.height == 32 && popup.panel.frame.width > 200)
            var chosen: UUID?
            popup.onSelect = { chosen = $0.customAction?.id }
            try expect(popup.key(123) && popup.selected == 0)
            for _ in 0..<10 { _ = popup.key(124) }
            try expect(popup.selected == actions.count - 1)
            try expect(popup.key(123) && popup.selected == actions.count - 2)
            try expect(popup.key(36) && chosen == actions[actions.count - 2].id)
            let many = (0..<30).map { AIAction(name: "长名称动作 \($0)", prompt: "处理输入") }
            let constrained = AIActionToolbarLayout.size(operations: many.map(TextOperation.custom), availableWidth: 320)
            try expect(constrained.width == 304 && constrained.height == 32)
            try expect(AIActionToolbarLayout.buttonWidth(String(repeating: "长名称", count: 40)) == 160)
            popup.show(operations: [], position: .lowerLeft, presentation: .modifier)
            try expect(popup.selected == 0 && !popup.panel.isVisible)
        }
        check("Unavailable action models stay explicit and an empty popup stays hidden") {
            let domain = "qingyi-action-unavailable-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config)
            let action = AIAction(name: "解释", prompt: "解释输入", model: .init(service: .customAPI("deleted"), modelID: "gone"))
            try config.textSettings.saveAction(action)
            try expect(try engine.defaultChoice(for: .custom(action)).providerName == "已删除的 API")
            let popup = AIActionPopup(); defer { popup.hide() }
            popup.show(operations: [], position: .lowerLeft, presentation: .modifier)
            try expect(!popup.panel.isVisible && popup.operations.isEmpty)
        }
        await asyncCheck("Custom prompt optimization previews and adopts without changing built-in prompts or executing the action") {
            let domain = "qingyi-action-opt-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let action = AIAction(name: "总结", prompt: "总结资料")
            try settings.saveAction(action)
            let draft = AIPromptDraft(settings: settings)
            draft.optimize(.custom(action), modelLabel: "全局模型") { input, operation in
                try expect(input == action.prompt && operation.action == action.name)
                return "优化后的总结指令"
            }
            try await waitForPolishing { !draft.optimizing }
            try expect(settings.actions[0].prompt == action.prompt && draft.adoptOptimization())
            try expect(settings.actions[0].prompt == "优化后的总结指令" && settings.prompts == .defaults)
        }
    }

    @MainActor static func renderAIActionUI(to directory: String) throws {
        let domain = "qingyi-action-ui-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
        var provider = fixtureProvider(); provider.name = "示例 AI 服务"; provider.models[0].name = "示例模型"
        try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
        let chat = ChatGPT(defaults: defaults)
        let engine = TranslationEngine(chat: chat, configuration: config)
        let action = AIAction(name: "内容总结", prompt: "请用简体中文总结用户提供的内容，提炼核心观点与关键信息，以简洁的要点列出。保留关键数字，不补充原文未提供的事实。")
        try config.textSettings.saveAction(action)
        try config.textSettings.adoptOptimizedPrompt(action.prompt + "\n只输出总结。", for: .custom(action), replacing: action.prompt)
        try config.textSettings.saveAction(AIAction(name: "这是一个用于验证完整名称提示与窄窗口布局的很长的自定义 AI 动作名称", prompt: "解释输入"))
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        func capture(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw QingyiError.message("Missing action bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw QingyiError.message("Missing action image") }
            try data.write(to: url.appendingPathComponent(name))
        }
        func render<V: View>(_ view: V, name: String, size: NSSize, dark: Bool) throws {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor))
                .environment(\.controlActiveState, .active).environment(\.colorScheme, dark ? .dark : .light))
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            try capture(host, name: name)
        }
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let services = BuiltinTranslationSettings(defaults: defaults)
            try render(TranslationServiceDragPreview(service: .youdao, store: services, width: 540),
                name: "service-drag-\(suffix).png", size: NSSize(width: 580, height: 110), dark: dark)
            try render(AIActionEditView(settings: config.textSettings, engine: engine, api: config, chat: chat, operation: .custom(action), close: {}), name: "action-editor-\(suffix).png", size: NSSize(width: 680, height: 600), dark: dark)
            try render(AIPromptEditor(api: config, chat: chat), name: "actions-list-\(suffix).png", size: NSSize(width: 580, height: 600), dark: dark)
            for (section, name) in [(SettingsSection.prompts, "actions"), (.selection, "selection")] {
                try render(SettingsView(preferences: Preferences(defaults: defaults), chat: chat, api: config,
                    navigation: SettingsNavigation(section: section), updateShortcut: { _ in true }, shortcutRecording: { _ in },
                    preview: {}, verify: {}, services: BuiltinTranslationSettings(defaults: defaults), loadsAccounts: false),
                    name: "\(name)-minimum-\(suffix).png", size: NSSize(width: 780, height: 600), dark: dark)
            }
            try render(AIActionEditView(settings: config.textSettings, engine: engine, api: config, chat: chat, operation: .translation, close: {}), name: "translation-editor-\(suffix).png", size: NSSize(width: 680, height: 600), dark: dark)
            try render(AIActionCreationView(settings: config.textSettings, engine: engine, api: config, chat: chat, close: {}), name: "new-action-\(suffix).png", size: NSSize(width: 680, height: 600), dark: dark)
            let popup = AIActionPopup(); defer { popup.hide() }
            popup.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let compact = ["润色 1", "内容总结 1", "112233", "1111"].map { AIAction(name: $0, prompt: "处理输入") }
            popup.show(operations: compact.map(TextOperation.custom), position: .lowerLeft, presentation: .modifier)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            try capture(popup.panel.contentView!, name: "action-toolbar-\(suffix).png")
            let many = config.textSettings.actions + (1...12).map { AIAction(name: "示例动作 \($0)", prompt: "解释输入") }
            popup.show(operations: many.map(TextOperation.custom), position: .lowerLeft, presentation: .modifier)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            try capture(popup.panel.contentView!, name: "action-toolbar-overflow-\(suffix).png")
            popup.selected = many.count - 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            try capture(popup.panel.contentView!, name: "action-popup-\(suffix).png")
            let floating = FloatingController(); defer { floating.hide() }
            let nextActions = ["解释", "会议纪要", "智能提取", "改写为工作邮件", "逐段核对专有名词"].map {
                TextOperation.custom(AIAction(name: $0, prompt: "按要求处理原文"))
            }
            floating.showResult(operation: .custom(action))
            floating.resultPanel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            floating.state.services = [.init(id: .ai, loading: false, result: .init(text: "下周二上线新版使用手册。小林负责核对截图，小周负责整理反馈，周五汇总首批问题。"))]
            floating.state.choice = try engine.defaultChoice(); floating.state.complete = true; floating.state.loading = false
            floating.state.resultActions = [.polishing] + nextActions
            floating.fitContent(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            try capture(floating.resultPanel.contentView!, name: "action-result-\(suffix).png")

            floating.showResult(operation: .polishing)
            floating.state.services = [.init(id: .ai, loading: false, result: .init(text: "新版使用手册将于下周二上线。请小林核对截图，小周整理反馈，并于周五汇总首批问题。"))]
            floating.state.choice = try engine.defaultChoice(); floating.state.complete = true; floating.state.loading = false
            floating.state.resultActions = [.custom(action)] + nextActions
            floating.fitContent(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            try capture(floating.resultPanel.contentView!, name: "polishing-result-\(suffix).png")
        }
    }
}

extension QingyiTests {
    @MainActor static func automaticSelectionToolbarTests() async {
        check("Modifier and direct selection action bars use the same placement independently of the compact button") {
            let domain = "qingyi-action-bar-placement-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let preferences = Preferences(defaults: defaults)
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let action = AIAction(name: "解释", prompt: "解释选区")
            try config.textSettings.saveAction(action)
            let app = AppDelegate(preferences: preferences)
            app.prepareSelectionFixture(engine: TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config),
                                        client: BuiltinTranslationClient(), settings: BuiltinTranslationSettings(defaults: defaults))
            defer { app.dismissHoverFixture() }
            guard let screen = NSScreen.main else { throw QingyiError.message("Missing screen for the action bar fixture") }
            let anchor = NSPoint(x: floor(screen.visibleFrame.midX), y: floor(screen.visibleFrame.midY))
            app.actionPopup.testAnchor = anchor
            let previous = SelectionMonitor.leftMouseDownOverride
            SelectionMonitor.leftMouseDownOverride = false
            defer { SelectionMonitor.leftMouseDownOverride = previous }

            app.feedSelectionFixture("Select some text.")
            try expect(app.floating.buttonPanel.isVisible && !app.actionPopup.panel.isVisible)
            config.textSettings.actionDisplayLimit = 1
            app.showActionPopupFixture(source: "Press the modifier.")
            let defaultFrame = app.actionPopup.panel.frame
            try expect(app.actionPopup.panel.isVisible && app.actionPopup.presentation == .modifier)
            try expect(abs(defaultFrame.midX - anchor.x) <= 1 && defaultFrame.maxY == anchor.y - 12)

            app.dismissHoverFixture()
            preferences.actionBarPosition = .upperRight
            preferences.buttonPosition = .lowerRight
            let upperRight = NSPoint(x: anchor.x + 12, y: anchor.y + 12)
            app.showActionPopupFixture(source: "Show custom actions.")
            try expect(app.actionPopup.operations == [.custom(action)] && app.actionPopup.panel.frame.origin == upperRight)
            preferences.selectionMode = .toolbar
            app.feedSelectionFixture("Show all available actions.")
            try expect(app.actionPopup.panel.isVisible && app.actionPopup.presentation == .automatic)
            try expect(app.actionPopup.operations == [.translation] && app.actionPopup.panel.frame.origin == upperRight)
            config.textSettings.actionDisplayLimit = 2
            app.feedSelectionFixture("Show the first two actions.")
            try expect(app.actionPopup.operations == [.translation, .custom(action)] && app.actionPopup.panel.frame.origin == upperRight)
            try expect(preferences.buttonPosition == .lowerRight)
        }
        await asyncCheck("Click-only toolbar preserves source keyboard events and translates the latest complete selection exactly once") {
            let domain = "qingyi-automatic-selection-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let preferences = Preferences(defaults: defaults)
            preferences.selectionMode = .toolbar
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config)
            let services = BuiltinTranslationSettings(defaults: defaults, enabledByDefault: false)
            services.youdao = true; services.ai = false
            var sent: [String] = []
            let client = BuiltinTranslationClient(youdao: { text in sent.append(text); return .init(text: "译文") })
            let app = AppDelegate(preferences: preferences)
            app.prepareSelectionFixture(engine: engine, client: client, settings: services)
            defer { app.dismissHoverFixture() }
            app.monitor.enabled = false // This fixture supplies the foreground app's AX events.
            let previous = SelectionMonitor.leftMouseDownOverride
            SelectionMonitor.leftMouseDownOverride = false
            defer { SelectionMonitor.leftMouseDownOverride = previous }
            func snapshot(_ text: String) -> SelectionSnapshot {
                SelectionSnapshot(text: text, anchor: nil, pid: getpid(), range: "0,\(text.count)")
            }
            func event(_ key: UInt16, _ flags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown) -> NSEvent {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!
            }
            app.monitor.onSelection?(snapshot("The initial selection"))
            try expect(app.actionPopup.operations == [.translation] && !app.floating.buttonPanel.isVisible)
            try expect(!app.actionPopup.panel.isKeyWindow && !app.monitor.modelMenuTracking && !app.actionPopup.key(36))
            app.monitor.isInternalInteraction = { _ in true }
            app.monitor.isOverAutomaticToolbar = { _ in true }
            let route = app.monitor.onExternalEvent
            var sourceKeys: [UInt16] = []
            app.monitor.onExternalEvent = { input in
                sourceKeys.append(input.keyCode)
                return route?(input) ?? false
            }
            app.monitor.event(event(8, .command))
            app.monitor.event(event(124, .shift))
            app.monitor.event(event(124, .shift, type: .keyUp))
            try expect(sourceKeys == [8, 124, 124] && sent.isEmpty && app.actionPopup.panel.isVisible)
            var verified: ((SelectionSnapshot?) -> Void)?
            var reads = 0
            app.monitor.toolbarReadFixture = { _, callback in reads += 1; verified = callback }
            app.actionPopup.choose(.translation); app.actionPopup.choose(.translation)
            let text = String(repeating: "The expanded selection has more words. ", count: 25) + "All done."
            let expanded = snapshot(text)
            // An observer read initiated before the click returns ahead of its explicit AX verification.
            app.monitor.onSelection?(expanded)
            verified?(expanded)
            try await waitForPolishing { app.floating.state.complete }
            try expect(reads == 1 && sent == [text] && app.floating.state.operation == .translation)
            try expect(!app.actionPopup.panel.isVisible)

            app.floating.state.pinned = true
            let next = snapshot("A different selection.")
            app.monitor.onSelection?(next)
            app.actionPopup.choose(.translation)
            app.monitor.onCancel?(); verified?(next)
            app.monitor.onSelection?(next)
            try expect(!app.actionPopup.panel.isVisible && app.floating.state.text == "译文" && app.floating.state.pinned)
            app.monitor.onSelection?(snapshot("Yet another selection."))
            app.actionPopup.choose(.translation)
            app.monitor.onSelectionInvalidated?()
            verified?(next)
            try expect(!app.actionPopup.panel.isVisible)
            app.monitor.onSelection?(snapshot("A selection before switching applications."))
            app.actionPopup.choose(.translation)
            app.monitor.applicationActivated(pid: nil)
            verified?(next)
            try await Task.sleep(for: .milliseconds(25))
            try expect(sent == [text] && app.floating.state.pinned && !app.actionPopup.panel.isVisible)
        }
        await asyncCheck("Direct actions respect language and saved switches, reuse polishing and custom services, and release the modifier to hover") {
            let domain = "qingyi-toolbar-routing-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let preferences = Preferences(defaults: defaults)
            preferences.selectionMode = .toolbar
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let provider = fixtureProvider()
            try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            let app = AppDelegate(preferences: preferences)
            app.prepareSelectionFixture(engine: engine, client: BuiltinTranslationClient(session: network),
                                        settings: BuiltinTranslationSettings(defaults: defaults, enabledByDefault: false))
            defer { app.dismissHoverFixture() }
            var prompts: [String] = [], sources: [String] = []
            FixtureAPIProtocol.handle = { request in
                let body = try bodyOfRequest(request)
                let messages = body["messages"] as! [[String: Any]]
                prompts.append(messages.first!["content"] as! String)
                sources.append((messages.last!["content"] as! [[String: Any]]).first!["text"] as! String)
                return (200, "application/json", Data(#"{"choices":[{"message":{"content":"处理好了"},"finish_reason":"stop"}]}"#.utf8))
            }
            app.feedSelectionFixture("这是中文。")
            try expect(app.actionPopup.panel.isVisible && app.actionPopup.operations == [.polishing])
            var action = AIAction(name: "总结", prompt: "总结所选文字")
            try config.textSettings.saveAction(action)
            app.feedSelectionFixture("请保留这个意思。")
            try expect(app.actionPopup.operations == [.polishing, .custom(action)] && !app.monitor.modelMenuTracking)
            app.actionPopup.choose(.polishing)
            try await waitForPolishing { app.floating.state.complete }
            try expect(app.floating.state.operation == .polishing && sources == ["请保留这个意思。"])
            app.floating.state.pinned = true
            let pinnedSession = app.floating.state.sessionID
            for filtered in ["https://example.com/", "example.com", "a", "---", "😀"] {
                app.feedSelectionFixture(filtered)
                try expect(!app.actionPopup.panel.isVisible && !app.floating.buttonPanel.isVisible)
                try expect(app.floating.resultPanel.isVisible && app.floating.state.pinned && app.floating.state.sessionID == pinnedSession)
            }
            app.feedSelectionFixture("A valid selection before clicking.")
            let originalRead = app.monitor.toolbarReadFixture
            var rereads = 0
            app.monitor.toolbarReadFixture = { pid, done in
                rereads += 1
                done(SelectionSnapshot(text: "https://example.com/", anchor: nil, pid: pid, range: "0,20"))
            }
            app.actionPopup.choose(.custom(action))
            app.monitor.toolbarReadFixture = originalRead
            try await Task.sleep(for: .milliseconds(30))
            try expect(rereads == 1 && !app.actionPopup.panel.isVisible && sources == ["请保留这个意思。"])
            try expect(app.floating.state.sessionID == pinnedSession && app.floating.state.text == "处理好了" && app.floating.state.pinned)
            try config.textSettings.moveOperation(action.id.uuidString, to: TextOperation.polishing.key)
            config.textSettings.actionDisplayLimit = 1
            app.feedSelectionFixture("重新选择这段文字。")
            try expect(app.actionPopup.operations == [.custom(action)])
            app.monitor.toolbarReadFixture = { pid, done in
                done(SelectionSnapshot(text: "The selection is now English.", anchor: nil, pid: pid, range: "0,29"))
            }
            app.actionPopup.choose(.custom(action))
            app.monitor.toolbarReadFixture = originalRead
            try expect(app.floating.state.sessionID == pinnedSession && !app.actionPopup.panel.isVisible,
                       "The freshly read text has translation in the only visible slot")
            config.textSettings.actionDisplayLimit = 2
            let source = "Please summarize the notes at https://example.com/ for me."
            app.feedSelectionFixture(source)
            try expect(app.actionPopup.operations == [.translation, .custom(action)])
            app.actionPopup.choose(.custom(action))
            try await waitForPolishing { app.floating.state.complete }
            try expect(prompts == [config.textSettings.instructions(for: .polishing), action.prompt])
            try expect(sources == ["请保留这个意思。", source] && app.floating.state.operation == .custom(action))
            app.feedSelectionFixture("中")
            action.enabled = false; try config.textSettings.saveAction(action)
            try expect(!app.actionPopup.panel.isVisible)
            config.textSettings.polishingEnabled = false
            app.feedSelectionFixture("中文")
            try expect(!app.actionPopup.panel.isVisible)
            app.feedSelectionFixture("English text.")
            try expect(app.actionPopup.operations == [.translation])
            app.monitor.onScroll?()
            try expect(!app.actionPopup.panel.isVisible)
            app.feedSelectionFixture("Another example.")
            preferences.paused = true
            try expect(!app.actionPopup.panel.isVisible)
            preferences.paused = false
            app.feedSelectionFixture("Yet another example.")
            preferences.selectionMode = .compact
            try expect(!app.actionPopup.panel.isVisible)
            app.feedSelectionFixture("Back to one button.")
            try expect(app.floating.buttonPanel.isVisible && !app.actionPopup.panel.isVisible)
            preferences.selectionMode = .toolbar
            app.feedSelectionFixture("Hover can still use the configured modifier.")
            app.hover.configure(enabled: true, trigger: .option)
            var hovered = 0
            app.hover.onTrigger = { _ in hovered += 1 }
            for mask: NSEvent.ModifierFlags in [.option, []] {
                let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: mask, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
                _ = app.monitor.onExternalEvent?(event)
            }
            try expect(hovered == 1)
        }
    }
}
