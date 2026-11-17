import AppKit
import SwiftUI
import Combine
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let chat = ChatGPT()
    let preferences = Preferences()
    let floating = FloatingController()
    let monitor = SelectionMonitor()
    let shortcut = GlobalShortcut()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var selection: SelectionSnapshot?
    private var fingerprint = ""
    private var triggered = false
    private var translation: Task<Void, Never>?
    private var translationID = UUID()
    private var permissionTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var excludedCandidate: (String, String)?
    private var lastSource = ""

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
        floating.onRetry = { [weak self] in guard let self = self else { return }; self.startTranslation(self.lastSource, keepPosition: true) }
        floating.onSettings = { [weak self] in self?.dismiss(); self?.showSettings() }
        monitor.onSelection = { [weak self] in self?.selectionChanged($0) }
        monitor.onOutsideClick = { [weak self] point in
            guard let self = self else { return }
            if !self.floating.contains(point) { self.dismiss() }
        }
        monitor.onScroll = { [weak self] in self?.dismiss() }
        shortcut.onPress = { [weak self] in self?.translateClipboard() }
        registerShortcut()
        monitor.start()
        preferences.$paused.sink { [weak self] value in
            self?.monitor.enabled = !value
            self?.statusItem?.button?.appearsDisabled = value
            if value { self?.dismiss() }
        }.store(in: &subscriptions)
        chat.$activeID.dropFirst().sink { [weak self] _ in self?.dismiss() }.store(in: &subscriptions)
        chat.$signedIn.dropFirst().sink { [weak self] value in if !value { self?.dismiss() } }.store(in: &subscriptions)
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
        permissionTimer?.invalidate(); chat.cancelLogin(); translation?.cancel(); monitor.stop()
    }
    private func configureMainMenu() {
        let menu = NSMenu()
        let root = NSMenuItem(); let application = NSMenu()
        application.addItem(withTitle: "关于轻译", action: #selector(showSettings), keyEquivalent: "")
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
        menu.addItem(withTitle: "轻译 · 外语 → 简体中文", action: nil, keyEquivalent: "")
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
        let preview = menu.addItem(withTitle: "预览翻译浮窗", action: #selector(showPreview), keyEquivalent: ""); preview.target = self
        menu.addItem(.separator()); menu.addItem(withTitle: "退出轻译", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    @objc func togglePaused() { preferences.paused.toggle(); if !preferences.paused { monitor.schedule() } }
    @objc func toggleExclusion() {
        guard let (id, _) = excludedCandidate else { return }
        if preferences.excluded.contains(id) { preferences.excluded.removeAll { $0 == id } } else { preferences.excluded.append(id) }
        UserDefaults.standard.set(preferences.excluded, forKey: "excludedApps"); dismiss(); fingerprint = ""
    }
    @objc func showSettings() {
        chat.restore()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "轻译设置"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 600, height: 600)
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, chat: chat, updateShortcut: { [weak self] binding in self?.applyShortcut(binding) ?? false }, shortcutRecording: { [weak self] recording in self?.setShortcutRecording(recording) }, preview: { [weak self] in self?.showPreview() }, verify: { [weak self] in self?.verifyTranslation() }))
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
        if chat.signedIn, chat.models.isEmpty { Task { await chat.refreshModels() } }
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
        guard !preferences.paused else { return }
        guard let snapshot = snapshot else { fingerprint = ""; selection = nil; dismiss(); return }
        if let id = NSRunningApplication(processIdentifier: snapshot.pid)?.bundleIdentifier, preferences.excluded.contains(id) { dismiss(); return }
        guard snapshot.fingerprint != fingerprint else { return }
        dismiss(); fingerprint = snapshot.fingerprint; selection = snapshot; triggered = false
        guard TextPolicy.needsTranslation(snapshot.text) else { return }
        floating.showButton(position: preferences.buttonPosition)
    }
    private func trigger() {
        guard !triggered, let selection = selection, floating.buttonPanel.isVisible else { return }
        triggered = true; startTranslation(selection.text)
    }
    @objc func translateClipboard() {
        // Only this explicit shortcut/menu action reads the clipboard.
        let source = NSPasteboard.general.string(forType: .string) ?? ""
        startTranslation(source)
    }
    private func startTranslation(_ source: String, keepPosition: Bool = false) {
        translation?.cancel(); let run = UUID(); translationID = run; lastSource = source
        floating.showResult(source: String(source.prefix(600)), keepPosition: keepPosition)
        translation = Task { [self] in
            do {
                let result = try await chat.translate(source) { [weak self] text in
                    guard let self = self, self.translationID == run else { return }
                    self.floating.state.text = text
                }
                guard translationID == run else { return }
                floating.state.text = result; floating.state.loading = false; floating.state.complete = true
                floating.state.status = "\(chat.modelName) · 已完成"
            } catch is CancellationError { }
            catch {
                guard translationID == run else { return }
                floating.state.text = readableError(error); floating.state.loading = false; floating.state.error = true; floating.state.complete = false
                floating.state.status = "翻译未完成"
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
        translationID = UUID(); translation?.cancel(); translation = nil; floating.hide(); lastSource = ""
    }
    @objc func showPreview() {
        dismiss(); floating.showResult(source: "Small steps make complex things easier to understand.", preview: true)
        floating.state.text = "一步一步来，复杂的事情也能变得容易理解。"
        floating.state.complete = true; floating.state.loading = false; floating.state.status = "界面预览 · 未调用模型"
    }
    func verifyTranslation() { startTranslation("Small steps make complex things easier to understand.") }
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
    if let app = NSWorkspace.shared.frontmostApplication {
        print("Foreground app: \(app.bundleIdentifier ?? "unknown")")
        let mouse = CGEvent(source: nil)?.location ?? .zero
        if let selected = SelectionReader.read(pid: app.processIdentifier, mouse: mouse) {
            print("Selection characters: \(selected.text.count)")
            print("Selection path: \(selected.range.hasPrefix("marker:") ? "WebKit text marker" : "standard text")")
            print("Bounds available: \(selected.anchor != nil)")
        } else { print("Selection unavailable or empty") }
    }
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
