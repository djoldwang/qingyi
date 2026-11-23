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
    private let settingsReturn = SystemSettingsReturnCoordinator()
    private var returnEvents: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults = UserDefaults(suiteName: domain)!
        api = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
        preferences = Preferences(defaults: defaults)
        services = BuiltinTranslationSettings(defaults: defaults)
        preferences.trusted = false
        var provider = QingyiTests.fixtureProvider()
        provider.name = "隔离测试 API"
        provider.baseURL = "https://fixture.example/v1"
        do { try api.save(provider, replacementKey: "fixture-only"); try api.selectProvider(provider.id) }
        catch { fatalError("Fixture setup failed: \(error)") }
        FixtureAPIProtocol.handle = { [weak self] request in
            guard request.url?.host == "fixture.example", request.url?.path == "/v1/models" else {
                throw QingyiError.message("Unexpected fixture request")
            }
            DispatchQueue.main.async { self?.modelFetches += 1; self?.record() }
            return (200, "application/json", Data(#"{"data":[{"id":"model-a"},{"id":"model-imported"}]}"#.utf8))
        }
        let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: MemoryChatGPTVault())
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
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
            "modelFetches": modelFetches, "realCredentials": false, "realNetworkRequests": false,
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
