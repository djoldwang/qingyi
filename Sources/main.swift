import AppKit
import SwiftUI
import Combine
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let chat = ChatGPT()
    let api = APIConfigurationStore()
    private lazy var engine = TranslationEngine(chat: chat, configuration: api)
    let preferences = Preferences()
    let floating = FloatingController()
    let monitor = SelectionMonitor()
    let shortcut = GlobalShortcut()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    private let settingsReturn = SystemSettingsReturnCoordinator()
    private var selection: SelectionSnapshot?
    private var fingerprint = ""
    private var triggered = false
    private var translation: Task<Void, Never>?
    private var translationSession: TranslationSession?
    private var modelLoadingTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var excludedCandidate: (String, String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: "com.laowang.qingyi").filter { $0.processIdentifier != getpid() }
        if let peer = peers.first {
            if AppRuntime.filesPresent(bundle: peer.bundleURL, executable: peer.executableURL) {
                if let url = peer.bundleURL { NSWorkspace.shared.open(url) }
                else { peer.activate(options: []) }
                NSApp.terminate(nil); return
            }
            // A stale process must not intercept launches of a healthy installed copy.
            peer.terminate()
            Task { [weak self] in
                for _ in 0..<30 {
                    if peer.isTerminated { self?.initializeInterface(); return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let alert = NSAlert()
                alert.messageText = "请先退出旧版轻译"
                alert.informativeText = "旧进程的程序文件已不存在。请从菜单栏退出旧版，再重新打开已安装的轻译。"
                alert.runModal(); NSApp.terminate(nil)
            }
            return
        }
        initializeInterface()
    }
    private func initializeInterface() {
        configureMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "译"
        statusItem.button?.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        statusItem.button?.setAccessibilityLabel("轻译菜单")
        statusItem.button?.toolTip = "轻译 · 划词翻译"
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        floating.onTrigger = { [weak self] in self?.trigger() }
        floating.onClose = { [weak self] in self?.dismiss() }
        floating.onRetry = { [weak self] in self?.performTranslation(keepPosition: true) }
        floating.onSettings = { [weak self] in self?.dismiss(); self?.showSettings() }
        floating.onModelMenuTracking = { [weak self] tracking in
            guard let self = self else { return }
            if tracking { self.floating.state.modelGroups = self.engine.modelGroups() }
            self.monitor.setModelMenuTracking(tracking)
        }
        floating.onSelectModel = { [weak self] choice, id in
            guard let self = self, self.translationSession?.id == id,
                  self.translationSession?.select(choice) == true else { return }
            self.performTranslation(keepPosition: true)
        }
        floating.onRestoreModel = { [weak self] id in
            guard let self = self, self.translationSession?.id == id,
                  self.translationSession?.restoreDefault() == true else { return }
            self.performTranslation(keepPosition: true)
        }
        floating.onLoadModels = { [weak self] id in self?.loadTemporaryModels(sessionID: id) }
        monitor.onSelection = { [weak self] in self?.selectionChanged($0) }
        monitor.isInternalInteraction = { [weak self] point in
            guard let self = self else { return false }
            // Hit-test the frontmost window rather than its frame: a settings
            // window behind another app must not suppress that app's selections.
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            let windows: [NSWindow?] = [self.floating.buttonPanel, self.floating.resultPanel, self.settingsWindow]
            return windows.contains { $0?.isVisible == true && $0?.windowNumber == number }
        }
        monitor.onOutsideClick = { [weak self] point in
            guard let self = self else { return }
            if !self.floating.state.pinned, !self.floating.contains(point) { self.dismiss() }
        }
        monitor.onScroll = { [weak self] in if self?.floating.state.pinned == false { self?.dismiss() } }
        monitor.onCancel = { [weak self] in self?.dismiss() }
        monitor.onMenuCancel = { ModelMenuButton.cancelPresentedMenu(); TranslationResultTextView.cancelPresentedMenu() }
        shortcut.onPress = { [weak self] in self?.translateClipboard() }
        registerShortcut()
        monitor.start()
        preferences.$translationFontSize.sink { [weak self] size in
            self?.floating.state.fontSize = CGFloat(size)
        }.store(in: &subscriptions)
        preferences.$paused.sink { [weak self] value in
            self?.monitor.enabled = !value
            self?.statusItem?.button?.appearsDisabled = value
            if value, self?.floating.state.pinned == false { self?.dismiss() }
        }.store(in: &subscriptions)
        chat.$activeID.dropFirst().sink { [weak self] _ in self?.dismiss() }.store(in: &subscriptions)
        var previouslySignedIn = chat.signedIn
        chat.$signedIn.dropFirst().sink { [weak self] value in
            if previouslySignedIn, !value, self?.translationSession?.choice?.target.usesChatGPT == true { self?.dismiss() }
            previouslySignedIn = value
        }.store(in: &subscriptions)
        var previousModelID = chat.modelID
        chat.$modelID.dropFirst().sink { [weak self] id in
            if !previousModelID.isEmpty { self?.dismiss() }
            previousModelID = id
        }.store(in: &subscriptions)
        api.$revision.dropFirst().sink { [weak self] _ in self?.dismiss() }.store(in: &subscriptions)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                let trusted = AXIsProcessTrusted()
                if self.preferences.trusted != trusted { self.preferences.trusted = trusted; self.monitor.stop(); self.monitor.start() }
                if !trusted { self.monitor.enabled = false }
                else { self.monitor.enabled = !self.preferences.paused }
            }
        }
        if CommandLine.arguments.contains("--preview") { showSettings(); showPreview() }
        else if !UserDefaults.standard.bool(forKey: "onboardingShown") || !UserDefaults.standard.bool(forKey: "runtimeFixOnboardingShown") {
            UserDefaults.standard.set(true, forKey: "onboardingShown")
            UserDefaults.standard.set(true, forKey: "runtimeFixOnboardingShown")
            showSettings()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        settingsReturn.cancel()
        permissionTimer?.invalidate(); chat.cancelLogin(); translation?.cancel(); modelLoadingTask?.cancel(); monitor.stop()
    }
    private func configureMainMenu() {
        let menu = NSMenu()
        let root = NSMenuItem(); let application = NSMenu()
        application.addItem(withTitle: "关于轻译", action: #selector(showAbout), keyEquivalent: "")
        application.addItem(.separator()); application.addItem(withTitle: "退出轻译", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = application; menu.addItem(root)
        let editRoot = NSMenuItem(); let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editRoot.submenu = edit; menu.addItem(editRoot); NSApp.mainMenu = menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: AppVersion.menuTitle, action: #selector(showAbout), keyEquivalent: "")
        title.target = self
        menu.addItem(title)
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: preferences.paused ? "恢复自动划词" : "暂停自动划词", action: #selector(togglePaused), keyEquivalent: "")
        pause.target = self
        let clipboard = menu.addItem(withTitle: "翻译已复制文字", action: #selector(translateClipboard), keyEquivalent: ""); clipboard.target = self
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(), let id = app.bundleIdentifier {
            excludedCandidate = (id, app.localizedName ?? id)
            let excluded = preferences.excluded.contains(id)
            let item = menu.addItem(withTitle: "\(excluded ? "恢复" : "暂停")在 \(app.localizedName ?? id) 中自动划词", action: #selector(toggleExclusion), keyEquivalent: ""); item.target = self
        } else { excludedCandidate = nil }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        menu.addItem(.separator()); menu.addItem(withTitle: "退出轻译", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    @objc func togglePaused() { preferences.paused.toggle(); if !preferences.paused { monitor.schedule() } }
    @objc func toggleExclusion() {
        guard let (id, _) = excludedCandidate else { return }
        preferences.toggleExclusion(id); dismiss(); fingerprint = ""
    }
    @objc func showSettings() {
        presentSettings(.selection)
    }
    @objc func showAbout() {
        presentSettings(.about)
    }
    private func presentSettings(_ section: SettingsSection) {
        if api.activeProviderID.isEmpty { chat.restore() }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "轻译设置"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 780, height: 600)
            window.hidesOnDeactivate = false
            window.delegate = settingsNavigation
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, chat: chat, api: api, navigation: settingsNavigation, updateShortcut: { [weak self] binding in self?.applyShortcut(binding) ?? false }, shortcutRecording: { [weak self] recording in self?.setShortcutRecording(recording) }, preview: { [weak self] in self?.showPreview() }, verify: { [weak self] in self?.verifyTranslation() }, requestSystemPermission: { [weak self] in self?.openSystemPermissions() }))
            window.center(); settingsWindow = window
        }
        settingsNavigation.open(section)
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
        if api.activeProviderID.isEmpty, chat.signedIn, chat.models.isEmpty { Task { await chat.refreshModels() } }
    }
    private func openSystemPermissions() {
        guard let settingsWindow = settingsWindow else { return }
        settingsReturn.begin(window: settingsWindow)
        if !preferences.requestAccessibility() { settingsReturn.cancel() }
    }
    func registerShortcut() {
        let preferred = preferences.shortcutBinding
        // Keep the existing default alive until its replacement has registered.
        if let fallback = preferences.shortcutStore.migrationFallback { _ = shortcut.register(fallback) }
        if !applyShortcut(preferred), let fallback = shortcut.activeBinding {
            preferences.shortcutBinding = fallback
            preferences.shortcutStore.save(fallback)
            preferences.shortcutMessage = "新默认组合已被占用，已保留原快捷键 \(fallback.display)。可点击上方重新录制。"
        }
    }
    @discardableResult func applyShortcut(_ binding: ShortcutBinding) -> Bool {
        let status = shortcut.register(binding)
        if status == noErr {
            preferences.shortcutBinding = binding
            preferences.shortcutStore.save(binding)
            preferences.shortcutMessage = ""
            return true
        }
        preferences.shortcutMessage = "\(binding.display) 被系统保留、已被占用或无法注册（\(status)），原快捷键未更改。"
        return false
    }
    func setShortcutRecording(_ recording: Bool) {
        if recording { preferences.shortcutMessage = "" }
        let status = shortcut.setSuspended(recording)
        if status != noErr { preferences.shortcutMessage = "原快捷键暂时无法恢复（\(status)），请重新录制。" }
    }
    private func selectionChanged(_ snapshot: SelectionSnapshot?) {
        guard !preferences.paused, !monitor.modelMenuTracking else { return }
        guard let snapshot = snapshot else {
            fingerprint = ""; selection = nil
            if floating.state.pinned { floating.hideButton() } else { dismiss() }
            return
        }
        guard !SelectionMonitor.isLeftMouseDown else { floating.hideButton(); return }
        if let id = NSRunningApplication(processIdentifier: snapshot.pid)?.bundleIdentifier, preferences.excluded.contains(id) {
            if floating.state.pinned { floating.hideButton() } else { dismiss() }
            return
        }
        guard snapshot.fingerprint != fingerprint else { return }
        if !floating.state.pinned { dismiss() } else { floating.hideButton() }
        fingerprint = snapshot.fingerprint; selection = snapshot; triggered = false
        floating.offerAutomaticTranslation(for: snapshot.text, position: preferences.buttonPosition, preserveResult: floating.state.pinned)
    }
    private func trigger() {
        guard !triggered, let selection = selection, floating.buttonPanel.isVisible else { return }
        guard TextPolicy.shouldOfferAutomaticTranslation(selection.text) else { floating.hideButton(); return }
        triggered = true; startTranslation(selection.text)
    }
    @objc func translateClipboard() {
        // Only this explicit shortcut/menu action reads the clipboard.
        let source = NSPasteboard.general.string(forType: .string) ?? ""
        startTranslation(source)
    }
    private func startTranslation(_ source: String, keepPosition: Bool = false) {
        translation?.cancel(); modelLoadingTask?.cancel(); modelLoadingTask = nil
        let initial = try? engine.defaultChoice()
        translationSession = TranslationSession(source: source, defaultChoice: initial)
        floating.state.loadingChatGPTModels = false; floating.state.modelMenuMessage = ""
        performTranslation(keepPosition: keepPosition)
    }
    private func performTranslation(keepPosition: Bool) {
        guard translationSession != nil else { return }
        translation?.cancel(); translationSession?.restart()
        let context = translationSession!
        floating.showResult(source: String(context.source.prefix(600)), keepPosition: keepPosition, position: preferences.translationWindowPosition)
        floating.state.sessionID = context.id
        floating.state.choice = context.choice.map { engine.choice(for: $0.target) }; floating.state.defaultChoice = context.defaultChoice
        floating.state.temporaryModel = context.temporary; floating.state.modelSelectionEnabled = true
        floating.state.modelGroups = engine.modelGroups()
        floating.state.status = "正在翻译"
        translation = Task { [self] in
            do {
                guard let choice = context.choice else { _ = try engine.defaultChoice(); throw QingyiError.message("请选择翻译模型。") }
                let result = try await engine.translate(context.source, target: choice.target) { [weak self] text in
                    guard let self = self, self.translationSession?.accepts(sessionID: context.id, runID: context.runID) == true else { return }
                    self.floating.state.text = text
                }
                guard translationSession?.accepts(sessionID: context.id, runID: context.runID) == true else { return }
                floating.state.choice = engine.choice(for: choice.target)
                floating.state.text = result; floating.state.loading = false; floating.state.complete = true
                floating.state.status = "已完成"
            } catch is CancellationError { }
            catch {
                guard translationSession?.accepts(sessionID: context.id, runID: context.runID) == true else { return }
                floating.state.text = readableError(error); floating.state.loading = false; floating.state.error = true; floating.state.complete = false
                floating.state.status = "翻译未完成"
            }
        }
    }
    private func loadTemporaryModels(sessionID: UUID) {
        guard translationSession?.id == sessionID, modelLoadingTask == nil else { return }
        floating.state.loadingChatGPTModels = true; floating.state.modelMenuMessage = ""
        modelLoadingTask = Task { [self] in
            defer {
                if translationSession?.id == sessionID {
                    floating.state.loadingChatGPTModels = false; modelLoadingTask = nil
                }
            }
            do {
                _ = try await chat.loadTemporaryModels()
                try Task.checkCancellation()
                guard translationSession?.id == sessionID else { return }
                floating.state.modelGroups = engine.modelGroups()
                floating.state.modelMenuMessage = "ChatGPT 模型已加载，请选择模型"
            } catch is CancellationError { }
            catch {
                guard translationSession?.id == sessionID else { return }
                floating.state.modelMenuMessage = error is URLError ? "ChatGPT 模型加载失败，请检查网络；其他 API 仍可选择" : error.localizedDescription
            }
        }
    }
    private func readableError(_ error: Error) -> String {
        if let error = error as? URLError {
            if error.code == .cancelled { return "翻译已取消。" }
            return "网络连接失败，请检查网络或代理后重试。（\(error.code.rawValue)）"
        }
        return error.localizedDescription
    }
    private func dismiss() {
        translationSession = nil; translation?.cancel(); translation = nil
        modelLoadingTask?.cancel(); modelLoadingTask = nil; floating.hide()
    }
    @objc func showPreview() {
        dismiss(); floating.showResult(source: "Small steps make complex things easier to understand.", preview: true, position: preferences.translationWindowPosition)
        floating.state.text = "一步一步来，复杂的事情也能变得容易理解。"
        floating.state.complete = true; floating.state.loading = false; floating.state.status = "界面预览 · 未调用模型"
    }
    func verifyTranslation() {
        startTranslation("Small steps make complex things easier to understand.")
        floating.resultPanel.makeKeyAndOrderFront(nil)
    }
}

if CommandLine.arguments.contains("--credential-check") {
    do {
        try AppRuntime.validate()
        try CredentialStore.probe()
        print("PASS running app identity and real keychain create/read/delete (diagnostic data only)")
        exit(0)
    } catch {
        fputs("FAIL \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--api-credential-check") {
    do {
        try AppRuntime.validate()
        let id = "__qingyi_diagnostic_" + UUID().uuidString
        let vault = KeychainAPIKeyVault()
        let value = try secureRandom()
        try vault.save(value, id: id)
        defer { try? vault.remove(id) }
        guard try vault.read(id) == value else { throw QingyiError.message("API 密钥钥匙串读写检查失败。") }
        try vault.remove(id)
        print("PASS custom API keychain create/read/delete (random diagnostic data only)")
        exit(0)
    } catch {
        fputs("FAIL \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// Release smoke test: real requests use disposable preference copies so that
// checking another account/provider never changes the user's global defaults.
if CommandLine.arguments.contains("--services-translation-check") {
    Task { @MainActor in
        do {
            try AppRuntime.validate()
            let domain = "qingyi-service-check-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let snapshot = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!) ?? [:]
            defaults.setPersistentDomain(snapshot, forName: domain)
            let api = APIConfigurationStore(defaults: defaults)
            let accounts = ChatGPT(defaults: defaults).registrations
            let sample = "Small steps make complex things easier to understand."
            var passed = 0, failed = 0
            func verify(_ engine: TranslationEngine, target: TranslationTarget, label: String) async {
                do {
                    var updates = 0
                    let result = try await engine.translate(sample, target: target) { _ in updates += 1 }
                    guard result.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }) else {
                        throw QingyiError.message("没有返回中文译文。")
                    }
                    print("PASS \(label): completed, updates=\(updates)")
                    print("Example translation: \(result)")
                    passed += 1
                } catch {
                    print("FAIL \(label): \(error.localizedDescription)")
                    failed += 1
                }
            }
            if accounts.isEmpty { print("FAIL ChatGPT: 没有已保存账号，需要登录授权。"); failed += 1 }
            for (index, account) in accounts.enumerated() {
                defaults.set(account.id, forKey: "activeRegistration")
                let chat = ChatGPT(defaults: defaults)
                do {
                    let models = try await chat.loadTemporaryModels()
                    guard let model = models.first(where: { $0.id == chat.modelID }) ?? models.first else {
                        throw QingyiError.message("没有可用的 ChatGPT 模型。")
                    }
                    await verify(TranslationEngine(chat: chat, configuration: api), target: .init(service: .chatGPT(account.id), modelID: model.id), label: "ChatGPT account \(index + 1) / \(model.name)")
                } catch { print("FAIL ChatGPT account \(index + 1): \(error.localizedDescription)"); failed += 1 }
            }
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: api)
            for provider in api.providers {
                guard let model = provider.models.first(where: { $0.id == provider.selectedModelID }) ?? provider.models.first else {
                    print("FAIL \(provider.name): 没有已配置模型。"); failed += 1; continue
                }
                await verify(engine, target: .init(service: .customAPI(provider.id), modelID: model.id), label: "\(provider.name) / \(model.name)")
            }
            print("Real service checks: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        } catch { fputs("FAIL \(error.localizedDescription)\n", stderr); exit(1) }
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--default-translation-check") {
    Task { @MainActor in
        do {
            try AppRuntime.validate()
            let engine = TranslationEngine(chat: ChatGPT(), configuration: APIConfigurationStore())
            let result = try await engine.translate("Small steps make complex things easier to understand.", onUpdate: { _ in })
            print("PASS real translation using the saved default service and model")
            print("Example translation: \(result)")
            exit(0)
        } catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--translation-check") {
    Task { @MainActor in
        do {
            try AppRuntime.validate()
            let chat = ChatGPT()
            let result = try await chat.translate("Small steps make complex things easier to understand.", diagnostic: { print($0) }, onUpdate: { _ in })
            print("PASS real ChatGPT translation")
            print("Example translation: \(result)")
            exit(0)
        } catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--selection-check") {
    print("Accessibility granted: \(AXIsProcessTrusted())")
    var source = NSWorkspace.shared.frontmostApplication
    if let index = CommandLine.arguments.firstIndex(of: "--selection-app"), CommandLine.arguments.count > index + 1 {
        source = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[index + 1]).first
    }
    if let app = source {
        print("Selection source app: \(app.bundleIdentifier ?? "unknown")")
        let mouse = CGEvent(source: nil)?.location ?? .zero
        if let selected = SelectionReader.read(pid: app.processIdentifier, mouse: mouse) {
            print("Selection characters: \(selected.text.count)")
            print("Selection path: \(selected.range.hasPrefix("marker:") ? "WebKit text marker" : "standard text")")
            print("Bounds available: \(selected.anchor != nil)")
        } else { print("Selection unavailable or empty") }
    } else { print("Selection source application unavailable") }
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
