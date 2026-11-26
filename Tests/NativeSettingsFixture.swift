import AppKit
import SwiftUI
import Combine

// Exercises the production settings UI with disposable defaults, in-memory
// credentials and URLProtocol responses. It never accesses real accounts.
@MainActor
final class NativeSettingsFixture: NSObject, NSApplicationDelegate {
    private let domain = "qingyi-native-settings-" + UUID().uuidString
    private var defaults: UserDefaults!
    private var api: APIConfigurationStore!
    private var preferences: Preferences!
    private var services: BuiltinTranslationSettings!
    private var window: NSWindow!
    private let navigation = SettingsNavigation(section: .services)
    private var subscription: AnyCancellable?
    private var serviceSubscription: AnyCancellable?
    private var modelFetches = 0
    private var optimizationRequests = 0
    private var optimizationModels: [String] = []
    private var textSubscription: AnyCancellable?
    private let settingsReturn = SystemSettingsReturnCoordinator()
    private var returnEvents: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--settings-dark") || Bundle.main.object(forInfoDictionaryKey: "QingyiFixtureDark") as? Bool == true { NSApp.appearance = NSAppearance(named: .darkAqua) }
        defaults = UserDefaults(suiteName: domain)!
        api = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
        preferences = Preferences(defaults: defaults)
        services = BuiltinTranslationSettings(defaults: defaults)
        preferences.trusted = false
        var provider = QingyiTests.fixtureProvider()
        let actionsMode = CommandLine.arguments.contains("--settings-actions") || Bundle.main.object(forInfoDictionaryKey: "QingyiFixtureMode") as? String == "actions"
        if actionsMode { provider.models.append(APIModel(id: "action-model", name: "动作专用模型")) }
        provider.name = "隔离测试 API"
        provider.baseURL = "https://fixture.example/v1"
        do {
            try api.save(provider, replacementKey: "fixture-only"); try api.selectProvider(provider.id)
            if actionsMode {
                let target = TranslationTarget(service: .customAPI(provider.id), modelID: "action-model")
                try api.textSettings.saveAction(AIAction(name: "内容总结", prompt: "总结用户提供的内容。", model: target))
                try api.textSettings.saveAction(AIAction(name: "AI 解释", prompt: "通俗解释用户提供的内容。"))
                try api.textSettings.saveAction(AIAction(name: "待启用动作", prompt: "分析输入。", enabled: false))
                api.textSettings.selectModel(target, for: .translation)
                navigation.open(.prompts)
            }
        }
        catch { fatalError("Fixture setup failed: \(error)") }
        FixtureAPIProtocol.handle = { [weak self] request in
            if request.url?.host == "fixture.example", request.url?.path == "/v1/chat/completions" {
                let model = try QingyiTests.bodyOfRequest(request)["model"] as? String ?? ""
                DispatchQueue.main.async { self?.optimizationRequests += 1; self?.optimizationModels.append(model); self?.record() }
                return (200, "application/json", Data(#"{"choices":[{"message":{"content":"隔离测试优化结果：保持原意，只输出正文。"},"finish_reason":"stop"}]}"#.utf8))
            }
            guard request.url?.host == "fixture.example", request.url?.path == "/v1/models" else {
                throw QingyiError.message("Unexpected fixture request")
            }
            DispatchQueue.main.async { self?.modelFetches += 1; self?.record() }
            return (200, "application/json", Data(#"{"data":[{"id":"model-a"},{"id":"model-imported"}]}"#.utf8))
        }
        let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: MemoryChatGPTVault())
        let minimum = CommandLine.arguments.contains("--settings-minimum")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: minimum ? 780 : 900, height: minimum ? 600 : 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "轻译设置 · 隔离验证"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 780, height: 600); window.delegate = navigation
        window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, chat: chat, api: api,
            navigation: navigation, updateShortcut: { _ in true }, shortcutRecording: { _ in }, preview: {}, verify: {},
            services: services, loadsAccounts: false, apiClient: CustomAPIClient(session: FixtureAPIProtocol.session()),
            requestSystemPermission: { [weak self] in
                guard let self = self else { return }
                self.settingsReturn.begin(window: self.window)
                if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) {
                    self.settingsReturn.cancel()
                }
            }))
        settingsReturn.onOutcome = { [weak self] outcome in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self = self else { return }
                self.returnEvents.append(["outcome": outcome.rawValue, "appActive": NSApp.isActive,
                    "windowKey": self.window.isKeyWindow, "section": self.navigation.section.rawValue,
                    "editorDirty": self.navigation.editorDirty, "windowMain": self.window.isMainWindow,
                    "canBecomeKey": self.window.canBecomeKey,
                    "frontmostOwn": NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()])
                self.record()
            }
        }
        let menu = NSMenu(); let item = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出隔离验证", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
        serviceSubscription = services.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.record() } }
        subscription = api.$revision.sink { [weak self] _ in DispatchQueue.main.async { self?.record() } }
        textSubscription = api.textSettings.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.record() } }
        AIActionPasteboard.onEvent = { [weak self] in self?.record() }
        var capturedDrags = Set<Int>()
        AIActionPasteboard.onPreview = { [weak self] panel in
            let index = AIActionPasteboard.dragEvents["sourceDragStarted", default: 0]
            if let self, let root = self.window.contentView {
                @MainActor func cards(_ view: NSView) -> [AIActionCardView] {
                    if let card = view as? AIActionCardView, card.actionID != nil { return [card] }
                    return view.subviews.flatMap { cards($0) }
                }
                let order = cards(root).sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }.compactMap(\.actionID)
                let persisted = self.api.textSettings.orderedOperations.map(\.key)
                if order != persisted {
                    let value: [String: Any] = ["visibleOrder": order, "persistedOrder": persisted,
                        "mouseStillDown": NSEvent.pressedMouseButtons & 1 != 0, "beforeMouseUp": true]
                    let folder = Bundle.main.bundleURL.deletingLastPathComponent()
                    if let json = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                        try? json.write(to: folder.appendingPathComponent("live-reorder-\(index).json"))
                    }
                }
            }
            guard capturedDrags.insert(index).inserted, let view = panel.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let folder = Bundle.main.bundleURL.deletingLastPathComponent()
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("drag-preview-\(index).png"))
            }
            let state: [String: Any] = ["width": panel.frame.width, "height": panel.frame.height,
                "visibleDuringTracking": panel.isVisible, "hasShadow": panel.hasShadow,
                "ignoresMouseEvents": panel.ignoresMouseEvents]
            if let json = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: folder.appendingPathComponent("drag-preview-\(index).json"))
            }
        }

        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        record()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        settingsReturn.cancel()
        record(); defaults.removePersistentDomain(forName: domain)
    }
    private func record() {
        let value: [String: Any] = [
            "providers": api.providers.map { provider in
                ["name": provider.name, "models": provider.models.map { ["id": $0.id, "name": $0.name] }] as [String: Any]
            },
            "serviceOrder": services.order.map(\.rawValue),
            "enabledServices": ["youdao": services.youdao, "google": services.google, "ai": services.ai],
            "modelFetches": modelFetches, "optimizationRequests": optimizationRequests,
            "optimizationModels": optimizationModels,
            "dragEvents": AIActionPasteboard.dragEvents,
            "actionOrder": api.textSettings.orderedOperations.map(\.key),
            "customActions": api.textSettings.actions.map { ["id": $0.id.uuidString, "name": $0.name, "enabled": $0.enabled] as [String: Any] },
            "translationEnabled": api.textSettings.translationEnabled, "polishingEnabled": api.textSettings.polishingEnabled,
            "translationPrompt": api.textSettings.prompts.translation, "polishingPrompt": api.textSettings.prompts.polishing, "realCredentials": false, "realNetworkRequests": false,
            "returnEvents": returnEvents
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("settings-state.json"), options: .atomic)
        }
    }
}

extension QingyiTests {
    @MainActor static func runNativeSettingsFixture() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = NativeSettingsFixture()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
