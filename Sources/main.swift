import AppKit
import SwiftUI
import Combine
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let chat = ChatGPT()
    let api = APIConfigurationStore()
    var services = BuiltinTranslationSettings()
    var builtinClient = BuiltinTranslationClient()
    private var serviceTasks: [TranslationServiceID: Task<Void, Never>] = [:]
    private lazy var engine = TranslationEngine(chat: chat, configuration: api)
    let preferences: Preferences
    let floating = FloatingController()
    let monitor = SelectionMonitor()
    let shortcut = GlobalShortcut()
    let screenshotShortcut = GlobalShortcut()
    var screenshotCapture: ScreenshotCapturing = NativeScreenshotCapture()
    var screenshotOCR: ScreenshotRecognizing = VisionScreenshotOCR()
    var screenCaptureAccess: () -> Bool = { CGPreflightScreenCaptureAccess() }
    private var screenshotTask: Task<Void, Never>?
    private var screenshotID: UUID?
    private var screenshotImage: CGImage?
    private var screenshotWasVisible = false
    private var screenshotCapturing = false
    let hover = HoverMonitor()
    let actionPopup = AIActionPopup()
    private var actionGesture = AIActionGesture()
    private var actionOwnsModifier = false
    private var toolbarReadID: UUID?
    private let hoverReadQueue = DispatchQueue(label: "com.laowang.qingyi.hover", qos: .userInitiated)
    private var hoverTicket: HoverReadTicket?
    private var hoverSessionActive = false
    private var hoverContext: (pid: pid_t, point: CGPoint)?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var settingsAccountActivation: AnyCancellable?
    private let settingsNavigation = SettingsNavigation()
    private let settingsReturn = SystemSettingsReturnCoordinator()
    private var selection: SelectionSnapshot?
    private var fingerprint = ""
    private var triggered = false
    private var translationSession: TranslationSession?
    private var modelLoadingTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var excludedCandidate: (String, String)?

    init(preferences: Preferences? = nil) {
        self.preferences = preferences ?? Preferences()
        super.init()
    }

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
        statusItem.button?.toolTip = "轻译 · 划词、悬停与截图翻译"
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        floating.onTrigger = { [weak self] in self?.trigger() }
        floating.onClose = { [weak self] in self?.dismiss() }
        floating.onRetryService = { [weak self] id in self?.performTranslation(keepPosition: true, only: id) }
        floating.onRetry = { [weak self] in self?.retryTranslation() }
        floating.onSettings = { [weak self] in self?.presentSettings(.services) }
        floating.onModelMenuTracking = { [weak self] tracking in
            guard let self = self else { return }
            if tracking { self.floating.state.modelGroups = self.engine.modelGroups() }
            self.monitor.setModelMenuTracking(tracking)
        }
        floating.onSelectModel = { [weak self] choice, id in
            self?.selectTemporaryModel(choice, sessionID: id)
        }
        floating.onRestoreModel = { [weak self] id in
            self?.restoreTemporaryModel(sessionID: id)
        }
        floating.onLoadModels = { [weak self] id in self?.loadTemporaryModels(sessionID: id) }
        configureSelectionDismissal()
        configureActionInteraction()
        monitor.onInternalEvent = { [weak self] in self?.hover.cancel() }
        hover.onCancelRead = { [weak self] in self?.hoverTicket?.cancel(); self?.hoverTicket = nil }
        hover.permitsTrigger = { [weak self] point in
            guard let self = self, self.screenshotID == nil, self.preferences.hoverEnabled, self.engine.textSettings.translationEnabled, self.preferences.trusted,
                  !self.monitor.modelMenuTracking, self.monitor.isInternalInteraction?(point) != true,
                  let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return false }
            return !self.preferences.excluded.contains(app.bundleIdentifier ?? "")
        }
        hover.onTrigger = { [weak self] point in self?.translateHoveredParagraph(at: point) }
        preferences.$hoverEnabled.combineLatest(preferences.$hoverTrigger, preferences.$hoverActivation).sink { [weak self] enabled, trigger, activation in
            self?.hover.configure(enabled: enabled, trigger: trigger, activation: activation)
        }.store(in: &subscriptions)
        monitor.isInternalInteraction = { [weak self] point in
            self?.hitsAppWindow(at: point, includeSettings: true) == true
        }
        monitor.isResultInteraction = { [weak self] point, window in
            self?.hitsAppWindow(at: point, eventWindow: window, includeSettings: false) == true
        }
        monitor.onMenuCancel = { [weak self] in
            self?.closeActionPopup()
            FloatingController.cancelResultMenus()
        }
        shortcut.onPress = { [weak self] in self?.translateClipboard() }
        screenshotShortcut.onPress = { [weak self] in self?.beginScreenshot(binding: self?.preferences.screenshotShortcutBinding) }
        registerShortcut()
        _ = applyScreenshotShortcut(preferences.screenshotShortcutBinding)
        monitor.start()
        preferences.$translationFontSize.sink { [weak self] size in
            self?.floating.state.fontSize = CGFloat(size)
        }.store(in: &subscriptions)
        preferences.$paused.sink { [weak self] value in
            self?.monitor.enabled = !value
            self?.statusItem?.button?.appearsDisabled = value
            if value, self?.screenshotID == nil, self?.floating.state.pinned == false { self?.dismiss() }
            if value {
                self?.builtinClient.cancelYoudaoPreparation()
            }
            else if self?.services.youdao == true, self?.engine.textSettings.translationEnabled == true { self?.builtinClient.prepareYoudaoConnection() }
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
        observeServiceSwitches()
        observeServicesOrder()
        observeTextSettings()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                let trusted = AXIsProcessTrusted()
                if self.preferences.trusted != trusted { self.preferences.trusted = trusted; self.hover.cancel(); self.monitor.stop(); self.monitor.start() }
                self.preferences.screenCaptureGranted = self.screenCaptureAccess()
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
        builtinClient.cancelYoudaoPreparation()
        settingsReturn.cancel(); CredentialWindowReturnCoordinator.shared.cancel(); cancelScreenshot(restore: false)
        permissionTimer?.invalidate(); cancelServiceTasks(); chat.cancelLogin(); modelLoadingTask?.cancel(); hover.cancel(); monitor.stop()
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
        let pause = menu.addItem(withTitle: preferences.paused ? "恢复划词" : "暂停划词", action: #selector(togglePaused), keyEquivalent: "")
        pause.target = self
        let clipboard = menu.addItem(withTitle: "翻译已复制文字", action: #selector(translateClipboard), keyEquivalent: ""); clipboard.target = self
        let screenshot = menu.addItem(withTitle: "截图翻译", action: #selector(translateScreenshot), keyEquivalent: ""); screenshot.target = self
        ShortcutBinding.showMenuShortcut(on: clipboard, binding: shortcut.suspended ? nil : shortcut.activeBinding)
        ShortcutBinding.showMenuShortcut(on: screenshot, binding: screenshotShortcut.suspended ? nil : screenshotShortcut.activeBinding)
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(), let id = app.bundleIdentifier {
            excludedCandidate = (id, app.localizedName ?? id)
            let excluded = preferences.excluded.contains(id)
            let item = menu.addItem(withTitle: Self.exclusionMenuTitle(for: app.localizedName ?? id, excluded: excluded), action: #selector(toggleExclusion), keyEquivalent: ""); item.target = self
        } else { excludedCandidate = nil }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        menu.addItem(.separator()); menu.addItem(withTitle: "退出轻译", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    static func exclusionMenuTitle(for name: String, excluded: Bool) -> String {
        "在 \(name) 中\(excluded ? "恢复" : "暂停")划词与悬停翻译"
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
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "轻译设置"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 780, height: 600)
            window.hidesOnDeactivate = false
            window.delegate = settingsNavigation
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, chat: chat, api: api, navigation: settingsNavigation, updateShortcut: { [weak self] binding in self?.applyShortcut(binding) ?? false }, shortcutRecording: { [weak self] recording in self?.setShortcutRecording(recording) }, preview: { [weak self] in self?.showPreview() }, verify: { [weak self] in self?.verifyTranslation() }, services: services, requestSystemPermission: { [weak self] in self?.openSystemPermissions() }, updateScreenshotShortcut: { [weak self] in self?.applyScreenshotShortcut($0) ?? false }, requestScreenCapturePermission: { [weak self] in self?.manageScreenCapturePermission() }))
            window.center(); settingsWindow = window
        }
        guard let window = settingsWindow else { return }
        settingsNavigation.open(section)
        CredentialWindowReturnCoordinator.shared.setSourceWindow(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        settingsAccountActivation?.cancel()
        guard api.activeProviderID.isEmpty else { return }
        settingsAccountActivation = whenSettingsWindowHasFocus(window) { [weak self] in
            guard let self, self.api.activeProviderID.isEmpty else { return }
            self.chat.restoreForSettings()
            if self.chat.signedIn, self.chat.models.isEmpty { Task { await self.chat.refreshModels() } }
        }
    }
    private func openSystemPermissions() {
        guard let settingsWindow = settingsWindow else { return }
        settingsReturn.begin(window: settingsWindow)
        if !preferences.requestAccessibility() { settingsReturn.cancel() }
    }
    private var registeringInitialShortcut = false
    func registerShortcut() {
        registeringInitialShortcut = true
        defer { registeringInitialShortcut = false }
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
        guard registeringInitialShortcut || !binding.sameChord(as: preferences.screenshotShortcutBinding) else {
            preferences.shortcutMessage = "该组合已用于截图翻译，原快捷键未更改。"; return false
        }
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
        hover.cancel()
        if recording { preferences.shortcutMessage = "" }
        let status = shortcut.setSuspended(recording)
        let screenshotStatus = screenshotShortcut.setSuspended(recording)
        if status != noErr { preferences.shortcutMessage = "原快捷键暂时无法恢复（\(status)），请重新录制。" }
        if screenshotStatus != noErr { preferences.screenshotShortcutMessage = "截图快捷键暂时无法恢复（\(screenshotStatus)），请重新录制。" }
    }
    @discardableResult func applyScreenshotShortcut(_ binding: ShortcutBinding) -> Bool {
        guard !binding.sameChord(as: preferences.shortcutBinding) else {
            preferences.screenshotShortcutMessage = "该组合已用于翻译已复制文字，原截图快捷键未更改。"; return false
        }
        let status = screenshotShortcut.register(binding)
        guard status == noErr else {
            preferences.screenshotShortcutMessage = "\(binding.display) 被系统保留、已被占用或无法注册（\(status)）。可重新录制，或从菜单栏截图翻译。"; return false
        }
        preferences.screenshotShortcutBinding = binding
        preferences.shortcutStore.saveScreenshot(binding)
        preferences.screenshotShortcutMessage = ""; return true
    }
    @objc func translateScreenshot() { beginScreenshot(binding: nil) }
    private func manageScreenCapturePermission() {
        if !screenCaptureAccess(), !UserDefaults.standard.bool(forKey: "screenCapturePermissionRequested") {
            UserDefaults.standard.set(true, forKey: "screenCapturePermissionRequested")
            _ = CGRequestScreenCaptureAccess()
        }
        preferences.screenCaptureGranted = screenCaptureAccess()
        if let window = settingsWindow { settingsReturn.begin(window: window) }
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) { settingsReturn.cancel() }
    }
    private func beginScreenshot(binding: ShortcutBinding?) {
        guard engine.textSettings.translationEnabled, !screenshotCapturing else { return }
        closeActionPopup(); actionGesture.cancel()
        guard screenCaptureAccess() else {
            let firstRequest = !UserDefaults.standard.bool(forKey: "screenCapturePermissionRequested")
            if firstRequest {
                UserDefaults.standard.set(true, forKey: "screenCapturePermissionRequested")
                _ = CGRequestScreenCaptureAccess()
            }
            preferences.screenCaptureGranted = screenCaptureAccess()
            let alert = NSAlert(); alert.messageText = "截图翻译需要屏幕录制权限"
            alert.informativeText = "请在系统设置 → 隐私与安全性 → 屏幕录制中允许轻译。授权后再次触发截图翻译；如系统要求，请退出并重新打开轻译。"
            alert.addButton(withTitle: "打开系统设置"); alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn { manageScreenCapturePermission() }
            return
        }
        cancelScreenshot(restore: false)
        let id = UUID(); screenshotID = id; screenshotCapturing = true
        hover.cancel(); hoverTicket?.cancel(); hoverTicket = nil
        monitor.setScreenshotSuspended(true)
        screenshotWasVisible = floating.concealForScreenshot()
        screenshotTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await ScreenshotHotkeyRelease.wait(binding: binding)
                // Let the menu close and the hidden windows leave the compositor.
                try await Task.sleep(nanoseconds: 100_000_000)
                guard self.screenshotID == id else { return }
                let image = try await self.screenshotCapture.capture()
                guard self.screenshotID == id, !Task.isCancelled else { return }
                guard let image = image else { self.cancelScreenshot(restore: true); return }
                self.screenshotCapturing = false
                self.monitor.setScreenshotSuspended(false)
                self.fingerprint = ""; self.selection = nil; self.triggered = true
                // Keep the concealed result and retry session until OCR tells us
                // whether this screenshot actually needs translation.
                self.recognizeScreenshot(image, keepPosition: false)
            } catch is CancellationError {
                if self.screenshotID == id { self.cancelScreenshot(restore: true) }
            } catch {
                guard self.screenshotID == id else { return }
                self.cancelScreenshot(restore: true)
                let alert = NSAlert(); alert.messageText = "截图未完成"; alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
    private func recognizeScreenshot(_ image: CGImage, keepPosition: Bool) {
        screenshotTask?.cancel()
        let id = UUID(); screenshotID = id; screenshotImage = image
        // First-pass OCR stays silent, so Chinese never creates a new window.
        // A retry can update the existing error window while recognizing again.
        if keepPosition { showScreenshotRecognition(id: id, keepPosition: true) }
        screenshotTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let text = try await self.screenshotOCR.recognize(image)
                try Task.checkCancellation()
                guard self.screenshotID == id else { return }
                let cleaned = TextPolicy.clean(text)
                if !cleaned.isEmpty, !TextPolicy.needsTranslation(cleaned) {
                    self.screenshotTask = nil
                    if self.screenshotWasVisible { self.cancelScreenshot(restore: true) }
                    else { self.dismiss() }
                    return
                }
                // Empty/OCR/length errors remain actionable; Chinese is skipped
                // before model selection, session creation or window display.
                let source = try ScreenshotText.validate(cleaned)
                self.screenshotTask = nil; self.screenshotWasVisible = false
                if !keepPosition { self.floating.hide() }
                self.startTranslation(source, keepPosition: true, origin: .screenshot)
            } catch is CancellationError { }
            catch {
                guard self.screenshotID == id, !Task.isCancelled else { return }
                self.screenshotTask = nil; self.screenshotWasVisible = false
                self.translationSession = nil; self.cancelServiceTasks()
                self.modelLoadingTask?.cancel(); self.modelLoadingTask = nil
                self.hoverSessionActive = false; self.hoverContext = nil
                if !keepPosition { self.floating.hide() }
                self.showScreenshotRecognition(id: id, keepPosition: keepPosition)
                self.floating.state.loading = false; self.floating.state.error = true
                self.floating.state.complete = false; self.floating.state.status = "截图文字识别未完成"
                self.floating.state.text = error.localizedDescription
            }
        }
    }
    private func showScreenshotRecognition(id: UUID, keepPosition: Bool) {
        floating.showResult(sessionID: id, keepPosition: keepPosition, position: preferences.translationWindowPosition,
                            loadingMessage: "正在识别截图中的文字…")
        floating.state.status = "正在识别截图"
        floating.state.modelSelectionEnabled = false; floating.state.choice = nil; floating.state.defaultChoice = nil
        floating.state.temporaryModel = false; floating.state.loadingChatGPTModels = false
    }
    private func cancelScreenshot(restore: Bool) {
        screenshotID = nil; screenshotTask?.cancel(); screenshotTask = nil
        screenshotCapture.cancel(); screenshotImage = nil
        let visible = screenshotWasVisible
        screenshotWasVisible = false; screenshotCapturing = false
        if monitor.screenshotSuspended { monitor.setScreenshotSuspended(false) }
        if restore { floating.restoreAfterScreenshot(wasVisible: visible) }
    }
    private func hitsAppWindow(at point: NSPoint, eventWindow: NSWindow? = nil, includeSettings: Bool) -> Bool {
        var windows: [NSWindow] = [floating.resultPanel, floating.buttonPanel, actionPopup.panel]
        if includeSettings, let settingsWindow { windows.append(settingsWindow) }
        if let eventWindow {
            return windows.contains { $0 === eventWindow || $0 === eventWindow.sheetParent || $0 === eventWindow.parent }
        }
        // A covered settings window must not intercept selections from the app in front.
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        return windows.contains { $0.isVisible && $0.windowNumber == number }
    }
    private func configureSelectionDismissal() {
        monitor.isResultVisible = { [weak self] in self?.floating.resultPanel.isVisible == true }
        monitor.resultDismissalID = { [weak self] in
            guard let self, !self.floating.state.pinned else { return nil }
            if self.floating.resultPanel.isVisible { return self.floating.state.sessionID }
            return self.screenshotID
        }
        monitor.screenshotWorkPending = { [weak self] in
            guard let self else { return false }
            return self.screenshotTask != nil || (self.translationSession?.origin == .screenshot && self.floating.state.loading && !self.floating.state.pinned)
        }
        monitor.onSelection = { [weak self] in self?.selectionChanged($0) }
        monitor.onSelectionInvalidated = { [weak self] in
            guard let self else { return }
            self.selectionChanged(nil, invalidatedByInput: true)
        }
        monitor.onContextChanged = { [weak self] in
            guard let self, !self.monitor.defersSelectionForScreenshot else { return }
            self.closeActionPopup(); self.actionGesture.cancel()
            self.hover.cancel()
        }
        monitor.onOutsideClick = { [weak self] _ in
            guard let self, !self.screenshotCapturing else { return }
            if self.floating.state.pinned { self.closeActionPopup() } else { self.dismiss() }
        }
        monitor.onScroll = { [weak self] in
            guard let self, !self.screenshotCapturing else { return }
            self.closeActionPopup()
            self.floating.hideButton()
        }
        monitor.onCancel = { [weak self] in
            guard let self else { return }
            if self.actionPopup.panel.isVisible { self.closeActionPopup() } else { self.dismiss() }
        }
    }
    private func configureActionInteraction() {
        preferences.$paused.dropFirst().filter { $0 }.sink { [weak self] _ in
            self?.actionGesture.cancel(); self?.actionOwnsModifier = false; self?.closeActionPopup(); self?.floating.hideButton()
        }.store(in: &subscriptions)
        preferences.$excluded.dropFirst().sink { [weak self] _ in
            self?.hover.cancel(); self?.actionGesture.cancel(); self?.closeActionPopup()
        }.store(in: &subscriptions)
        actionPopup.onDismiss = { [weak self] in self?.closeActionPopup() }
        monitor.isOverAutomaticToolbar = { [weak self] point in
            guard let self else { return false }
            return self.actionPopup.panel.isVisible && self.actionPopup.presentation == .automatic && self.actionPopup.panel.frame.contains(point)
        }
        monitor.onExternalEvent = { [weak self] event in
            guard let self else { return false }
            // A deliberate new drag can reselect the exact same range after Escape.
            if self.preferences.selectionMode == .toolbar && event.type == .leftMouseDragged { self.fingerprint = "" }
            if self.routeActionEvent(event) { return true }
            return self.hover.event(event)
        }
        monitor.onLocalEvent = { [weak self] event in
            guard let self, self.actionPopup.panel.isVisible == false else { return }
            // Modifier presses over the existing floating glyph are local events.
            if event.type == .flagsChanged || event.type == .keyDown || event.type == .keyUp {
                _ = self.routeActionEvent(event)
            }
        }
        monitor.onTrackedEvent = { [weak self] event in
            guard let self, self.actionPopup.panel.isVisible else { return }
            if [.flagsChanged, .keyDown, .keyUp].contains(event.type) { _ = self.routeActionEvent(event) }
            if event.type == .scrollWheel, !self.actionPopup.panel.frame.contains(NSEvent.mouseLocation) {
                self.closeActionPopup()
            } else if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
                      !self.actionPopup.panel.frame.contains(NSEvent.mouseLocation) {
                self.closeActionPopup()
            }
        }
    }
    private func routeActionEvent(_ event: NSEvent, requireFrontmost: Bool = true) -> Bool {
        guard preferences.selectionMode == .compact else { return false }
        let kind: AIActionGesture.Input
        switch event.type {
        case .flagsChanged: kind = .flags
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .leftMouseDown: kind = event.modifierFlags.contains(.control) ? .otherMouseDown : .leftDown
        case .leftMouseUp: kind = .leftUp
        case .scrollWheel: kind = .scroll
        case .rightMouseDown, .otherMouseDown: kind = .otherMouseDown
        default: return false
        }
        guard !engine.textSettings.displayedActions.isEmpty, !preferences.paused, screenshotID == nil else {
            actionGesture = AIActionGesture(); actionOwnsModifier = false; closeActionPopup()
            return false
        }
        actionGesture.reconcileKeys { CGEventSource.keyState(.combinedSessionState, key: $0) }
        let flags = event.modifierFlags.intersection([.option, .control, .shift, .command, .function])
        let modifier = engine.textSettings.actionModifier.flag
        let newPress = kind == .flags && flags == modifier && actionGesture.flags.isEmpty
        let wasVisible = actionPopup.panel.isVisible
        let key = [.keyDown, .keyUp, .flagsChanged].contains(event.type) ? event.keyCode : 0
        actionGesture.input(kind, flags: event.modifierFlags, key: key,
                            time: event.timestamp, modifier: engine.textSettings.actionModifier)
        let actions = pendingModifierActions(requireFrontmost: requireFrontmost)
        let owns = actionOwnsModifier || !actions.isEmpty
        if owns { actionOwnsModifier = true; hover.cancel() }
        if wasVisible {
            let releaseHold = kind == .flags && flags.isEmpty && engine.textSettings.actionTrigger == .hold
            let toggleOff = newPress && engine.textSettings.actionTrigger == .press
            let combination = kind == .flags && !flags.isEmpty && flags != modifier
            let typing = kind == .keyDown && ![53, 123, 124, 125, 126, 36, 76].contains(key)
            if releaseHold || toggleOff || combination || typing {
                closeActionPopup()
                if !releaseHold { actionGesture.cancel() }
            }
        } else {
            _ = showActionPopupIfReady(actions)
        }
        if flags.isEmpty { actionOwnsModifier = false }
        // Mouse-up must continue to the selection reader, even when this gesture owns the modifier.
        return owns && event.type == .flagsChanged
    }
    private func pendingModifierActions(requireFrontmost: Bool = true) -> [TextOperation] {
        // A drag may still have the previous selection while Accessibility reads the new one.
        guard actionGesture.deadline != nil, !SelectionMonitor.isLeftMouseDown, let snapshot = selection,
              !preferences.excluded.contains(NSRunningApplication(processIdentifier: snapshot.pid)?.bundleIdentifier ?? ""),
              !requireFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return [] }
        let actions = engine.textSettings.selectionToolbarOperations(for: snapshot.text, mode: .compact)
        if actions.isEmpty {
            actionGesture.cancel()
            actionOwnsModifier = false
        }
        return actions
    }
    @discardableResult private func showActionPopupIfReady(_ actions: [TextOperation]) -> Bool {
        guard preferences.selectionMode == .compact, !actions.isEmpty, !preferences.paused, screenshotID == nil, !monitor.modelMenuTracking, let snapshot = selection,
              actionGesture.tick(time: ProcessInfo.processInfo.systemUptime, hasSelection: true,
                                 mouseDown: SelectionMonitor.isLeftMouseDown) else { return false }
        hover.cancel(); actionOwnsModifier = true; floating.hideButton()
        actionPopup.onSelect = { [weak self] operation in
            guard let self else { return }
            self.closeActionPopup()
            guard self.engine.textSettings.enabled(operation) else { return }
            self.triggered = true
            self.startTranslation(snapshot.text, operation: operation)
        }
        floating.handleActionMenuTracking(true)
        actionPopup.show(operations: actions, position: preferences.actionBarPosition, presentation: .modifier)
        return true
    }
    private func showAutomaticToolbar(for snapshot: SelectionSnapshot) {
        let operations = engine.textSettings.selectionToolbarOperations(for: snapshot.text, mode: .toolbar)
        guard !operations.isEmpty else { closeActionPopup(); return }
        let mouse = CGEvent(source: nil)?.location ?? .zero
        actionPopup.onSelect = { [weak self] choice in
            guard let self, self.actionPopup.panel.isVisible, self.actionPopup.presentation == .automatic,
                  self.selection?.fingerprint == snapshot.fingerprint, self.toolbarReadID == nil else { return }
            let readID = UUID()
            self.toolbarReadID = readID
            self.monitor.readForToolbar(pid: snapshot.pid, mouse: mouse) { [weak self] latest in
                guard let self, self.toolbarReadID == readID else { return }
                self.closeActionPopup()
                guard self.preferences.selectionMode == .toolbar, !self.preferences.paused, self.screenshotID == nil,
                      let latest, latest.pid == snapshot.pid,
                      !self.preferences.excluded.contains(NSRunningApplication(processIdentifier: latest.pid)?.bundleIdentifier ?? ""),
                      let operation = self.engine.textSettings.selectionToolbarOperations(for: latest.text, mode: .toolbar).first(where: { $0.key == choice.key }) else { return }
                self.fingerprint = latest.fingerprint; self.selection = latest; self.triggered = true
                self.startTranslation(latest.text, operation: operation)
            }
        }
        actionPopup.show(operations: operations, position: preferences.actionBarPosition, presentation: .automatic)
    }
    private func closeActionPopup() {
        toolbarReadID = nil
        guard actionPopup.panel.isVisible else { return }
        let tracked = actionPopup.presentation == .modifier
        actionPopup.hide()
        if tracked { floating.handleActionMenuTracking(false) }
    }
    private func selectionChanged(_ snapshot: SelectionSnapshot?, invalidatedByInput: Bool = false) {
        guard screenshotID == nil, !preferences.paused, !monitor.modelMenuTracking else { return }
        // An older observer read can finish between a toolbar click and its queued
        // verification. Only real input/context changes cancel that explicit click.
        if toolbarReadID != nil, !invalidatedByInput, snapshot == nil || snapshot?.pid == selection?.pid {
            if let snapshot { selection = snapshot }
            return
        }
        guard let snapshot = snapshot else {
            closeActionPopup()
            if !invalidatedByInput || preferences.selectionMode == .compact { fingerprint = "" }
            selection = nil
            floating.hideButton()
            return
        }
        guard !SelectionMonitor.isLeftMouseDown else { closeActionPopup(); floating.hideButton(); return }
        if let id = NSRunningApplication(processIdentifier: snapshot.pid)?.bundleIdentifier, preferences.excluded.contains(id) {
            closeActionPopup(); selection = nil
            floating.hideButton()
            return
        }
        guard snapshot.fingerprint != fingerprint else { return }
        // A selection offers the next action. Starting that action replaces the result.
        closeActionPopup()
        floating.hideButton()
        fingerprint = snapshot.fingerprint; selection = snapshot; triggered = false
        if preferences.selectionMode == .toolbar {
            showAutomaticToolbar(for: snapshot)
            return
        }
        if showActionPopupIfReady(pendingModifierActions()) { return }
        floating.offerAutomaticTranslation(for: snapshot.text, position: preferences.buttonPosition, preserveResult: true, polishingEnabled: engine.textSettings.polishingEnabled, translationEnabled: engine.textSettings.translationEnabled)
    }
    private func trigger() {
        guard !triggered, let selection = selection, floating.buttonPanel.isVisible else { return }
        guard let operation = TextPolicy.automaticSelectionOperation(selection.text) else { floating.hideButton(); return }
        guard engine.textSettings.enabled(operation) else { floating.hideButton(); return }
        triggered = true; startTranslation(selection.text, operation: operation)
    }
    @objc func translateClipboard() {
        guard engine.textSettings.translationEnabled else { return }
        // Only this explicit shortcut/menu action reads the clipboard.
        let source = NSPasteboard.general.string(forType: .string) ?? ""
        startTranslation(source, origin: .clipboard)
    }
    private func retryTranslation() {
        if let image = screenshotImage, translationSession == nil, !screenshotCapturing {
            recognizeScreenshot(image, keepPosition: true); return
        }
        if translationSession != nil { performTranslation(keepPosition: true) }
        else if let context = hoverContext, hoverSessionActive,
                NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid {
            translateHoveredParagraph(at: context.point)
        }
    }
    private func selectTemporaryModel(_ choice: TranslationChoice, sessionID: UUID) {
        guard let session = translationSession, engine.textSettings.enabled(session.operation),
              session.id == sessionID, translationSession?.select(choice) == true else { return }
        performTranslation(keepPosition: true, only: .ai)
    }
    private func restoreTemporaryModel(sessionID: UUID) {
        guard let session = translationSession, engine.textSettings.enabled(session.operation),
              session.id == sessionID, translationSession?.restoreDefault() == true else { return }
        performTranslation(keepPosition: true, only: .ai)
    }
    private func translateHoveredParagraph(at point: CGPoint) {
        guard screenshotID == nil, engine.textSettings.translationEnabled, preferences.hoverEnabled, preferences.trusted, !monitor.modelMenuTracking,
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              !preferences.excluded.contains(app.bundleIdentifier ?? "") else { return }
        let pid = app.processIdentifier
        HoverDiagnostics.log("read started pid=\(pid)")
        hoverTicket?.cancel()
        let ticket = HoverReadTicket(); hoverTicket = ticket
        monitor.suppressAutomaticSelection()
        fingerprint = ""; selection = nil; triggered = true
        // Keep the existing session until the new paragraph needs translation.
        // A Chinese hover must not invalidate a pinned result or its retry.
        floating.hideButton()
        hoverReadQueue.async { [weak self] in
            let result = Result { try HoverParagraphReader.read(pid: pid, point: point, ticket: ticket) }
            DispatchQueue.main.async {
                guard let self = self, ticket.isCurrent, self.preferences.hoverEnabled,
                      self.preferences.trusted, self.engine.textSettings.translationEnabled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      !self.preferences.excluded.contains(app.bundleIdentifier ?? "") else { return }
                self.hoverTicket = nil
                switch result {
                case .success(let paragraph):
                    HoverDiagnostics.log("read completed characters=\(paragraph.text.count)")
                    self.acceptHoveredParagraph(paragraph.text, context: (pid, point))
                case .failure(let error):
                    HoverDiagnostics.log("read failed: \(error.localizedDescription)")
                    if error is CancellationError { return }
                    self.translationSession = nil; self.cancelServiceTasks()
                    self.modelLoadingTask?.cancel(); self.modelLoadingTask = nil
                    self.hoverContext = (pid, point); self.hoverSessionActive = true
                    self.floating.showResult(position: self.preferences.translationWindowPosition)
                    self.floating.state.text = error.localizedDescription
                    self.floating.state.loading = false; self.floating.state.error = true
                    self.floating.state.choice = nil
                    self.floating.state.defaultChoice = nil; self.floating.state.temporaryModel = false
                    self.floating.state.modelSelectionEnabled = false; self.floating.state.status = "无法读取段落"
                }
            }
        }
    }
    private func acceptHoveredParagraph(_ source: String, context: (pid: pid_t, point: CGPoint)? = nil) {
        guard engine.textSettings.translationEnabled, TextPolicy.needsTranslation(source) else {
            HoverDiagnostics.log("read skipped: no translation needed")
            return
        }
        hoverContext = context
        startTranslation(source, origin: .hover)
    }
    private func startTranslation(_ source: String, keepPosition: Bool = false, origin: TranslationSession.Origin = .standard, operation: TextOperation = .translation) {
        guard engine.textSettings.enabled(operation) else { return }
        closeActionPopup()
        cancelScreenshot(restore: false)
        hoverTicket?.cancel(); hoverTicket = nil; hoverSessionActive = origin == .hover
        if origin != .hover { hoverContext = nil }
        cancelServiceTasks(); modelLoadingTask?.cancel(); modelLoadingTask = nil
        let initial = (operation.aiOnly || services.ai) ? (try? engine.defaultChoice(for: operation)) : nil
        translationSession = TranslationSession(source: source, defaultChoice: initial, operation: operation, instructions: engine.textSettings.instructions(for: operation), origin: origin)
        floating.state.loadingChatGPTModels = false; floating.state.modelMenuMessage = ""
        let activeServices: [TranslationServiceID] = operation.aiOnly ? [.ai] : services.order.filter { services.enabled($0) && ($0 != .ai || initial != nil) }
        floating.state.services = activeServices.map { ServiceTranslationResult(id: $0) }
        performTranslation(keepPosition: keepPosition)
    }
    private func cancelServiceTasks() {
        serviceTasks.values.forEach { $0.cancel() }; serviceTasks.removeAll()
    }
    private func observeServicesOrder() {
        services.$order.dropFirst().sink { [weak self] order in
            guard let self else { return }
            let results = self.floating.state.services
            self.floating.state.services = order.compactMap { id in results.first { $0.id == id } }
        }.store(in: &subscriptions)
    }
    private func observeTextSettings() {
        preferences.$selectionMode.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.closeActionPopup(); self.floating.hideButton()
            self.selection = nil; self.fingerprint = ""; self.actionGesture = AIActionGesture(); self.actionOwnsModifier = false
        }.store(in: &subscriptions)
        floating.onSwitchAction = { [weak self] operation, origin in
            guard let self, let session = self.translationSession, session.id == origin else { return }
            let settings = self.engine.textSettings
            let available = session.alternativeActions(settings.orderedOperations, polishingEnabled: settings.polishingEnabled)
            // Resolve the current action by ID; its prompt or model may have been edited with the menu open.
            guard let target = available.first(where: { $0.key == operation.key }) else { return }
            self.startTranslation(session.source, keepPosition: true, operation: target)
        }
        engine.textSettings.$orderedOperations.dropFirst().sink { [weak self] operations in
            guard let self else { return }
            self.closeActionPopup(); self.actionGesture = AIActionGesture(); self.actionOwnsModifier = false
            self.floating.state.resultActions = self.translationSession?.alternativeActions(operations, polishingEnabled: self.engine.textSettings.polishingEnabled) ?? []
            guard let action = self.translationSession?.operation.customAction else { return }
            let available = operations.contains { $0.customAction?.id == action.id && $0.customAction?.enabled == true }
            self.floating.state.actionAvailable = available
            self.floating.state.modelSelectionEnabled = available
        }.store(in: &subscriptions)
        engine.textSettings.$actionModifier.dropFirst().sink { [weak self] _ in
            self?.actionGesture = AIActionGesture(); self?.actionOwnsModifier = false; self?.closeActionPopup()
        }.store(in: &subscriptions)
        engine.textSettings.$actionTrigger.combineLatest(engine.textSettings.$actionDisplayLimit).dropFirst().sink { [weak self] _ in
            self?.actionGesture = AIActionGesture(); self?.actionOwnsModifier = false; self?.closeActionPopup()
        }.store(in: &subscriptions)
        let switches: [(TextOperation, Published<Bool>.Publisher)] = [
            (.translation, engine.textSettings.$translationEnabled), (.polishing, engine.textSettings.$polishingEnabled)
        ]
        for (operation, publisher) in switches {
            publisher.dropFirst().sink { [weak self] enabled in
                guard let self else { return }
                // @Published sends before assigning the stored value. Use the publisher's value here.
                if operation == .polishing {
                    self.floating.state.resultActions = self.translationSession?.alternativeActions(self.engine.textSettings.orderedOperations, polishingEnabled: enabled) ?? []
                }
                self.fingerprint = ""
                if self.preferences.selectionMode == .toolbar { self.closeActionPopup() }
                guard !enabled else { return }
                if self.floating.hoverButton.operation == operation { self.floating.hideButton() }
                if operation == .translation {
                    self.hover.cancel(); self.hoverTicket?.cancel(); self.hoverTicket = nil
                    self.builtinClient.cancelYoudaoPreparation()
                    if self.screenshotID != nil { self.cancelScreenshot(restore: true) }
                }
                if self.translationSession?.operation == operation || (operation == .translation && self.hoverSessionActive) { self.dismiss() }
            }.store(in: &subscriptions)
        }
    }

    private func observeServiceSwitches() {
        let switches: [(TranslationServiceID, Published<Bool>.Publisher)] = [
            (.youdao, services.$youdao), (.google, services.$google), (.ai, services.$ai)
        ]
        for (id, enabled) in switches {
            enabled.dropFirst().sink { [weak self] isOn in
                guard let self else { return }
                if id == .youdao {
                    if isOn, self.engine.textSettings.translationEnabled, !self.preferences.paused { self.builtinClient.prepareYoudaoConnection() }
                    else { self.builtinClient.cancelYoudaoPreparation() }
                }
                guard !isOn else { return }
                guard self.translationSession?.operation.aiOnly != true else { return }
                self.serviceTasks.removeValue(forKey: id)?.cancel()
                guard self.floating.state.services.contains(where: { $0.id == id }) else { return }
                if id == .ai { ModelMenuButton.cancelPresentedMenu() }
                self.floating.state.services.removeAll { $0.id == id }
                if self.floating.state.services.isEmpty { self.dismiss() }
                else { self.updateAggregateState() }
            }.store(in: &subscriptions)
        }
    }
    private func performTranslation(keepPosition: Bool, only service: TranslationServiceID? = nil) {
        guard let context = translationSession else { return }
        guard engine.textSettings.enabled(context.operation) else { return }
        if let service {
            guard context.operation.aiOnly ? service == .ai : services.enabled(service) else { return }
        }
        if service == nil {
            cancelServiceTasks()
            let cards = floating.state.services
            floating.showResult(sessionID: context.id, keepPosition: keepPosition, position: preferences.translationWindowPosition, operation: context.operation)
            floating.state.services = cards
            floating.state.resultActions = context.alternativeActions(engine.textSettings.orderedOperations, polishingEnabled: engine.textSettings.polishingEnabled)
        }
        floating.state.choice = context.choice.map { engine.choice(for: $0.target) }
        floating.state.defaultChoice = context.defaultChoice
        floating.state.temporaryModel = context.temporary
        floating.state.modelSelectionEnabled = true; floating.state.actionAvailable = true
        floating.state.modelGroups = engine.modelGroups()
        if context.origin == .clipboard && TextPolicy.clean(context.source).isEmpty {
            floating.state.services = []
            floating.state.text = "剪贴板中没有可翻译的文字。请先复制文字，再按翻译快捷键，或从菜单栏选择“翻译已复制文字”。"
            floating.state.status = "剪贴板中没有可翻译的文字"
            floating.state.loading = false; floating.state.error = true
            floating.state.modelSelectionEnabled = false
            return
        }
        if floating.state.services.isEmpty {
            floating.state.text = "在“设置 → 翻译”中开启有道翻译或谷歌翻译。要使用 AI 翻译，请开启“AI 翻译”并选好模型。"
            floating.state.loading = false; floating.state.error = true
            floating.state.status = "尚未启用翻译服务"
            return
        }
        let requested = service.map { [$0] } ?? floating.state.services.map(\.id)
        for id in requested {
            guard let index = floating.state.services.firstIndex(where: { $0.id == id }) else { continue }
            serviceTasks[id]?.cancel()
            let pending = ServiceTranslationResult(id: id)
            floating.state.services[index] = pending
            let runID = pending.runID
            serviceTasks[id] = Task { [weak self] in
                guard let self else { return }
                do {
                    let result: BuiltinTranslationResult
                    if id == .ai {
                        guard let choice = context.choice else { throw QingyiError.message("请在设置中配置 AI 服务和模型，或临时选择已配置的模型以进行\(context.operation.action)。") }
                        let text = try await engine.execute(context.source, target: choice.target, operation: context.operation, onEmptyRetry: { [weak self] in
                            self?.updateService(id, sessionID: context.id, runID: runID) { $0.retryingEmptyResponse = true }
                        }, instructions: context.instructions) { [weak self] text in
                            self?.updateService(id, sessionID: context.id, runID: runID) { $0.result.text = text }
                        }
                        result = BuiltinTranslationResult(text: text)
                    } else {
                        result = try await builtinClient.translate(context.source, service: id) { [weak self] text in
                            self?.updateService(id, sessionID: context.id, runID: runID) { $0.result.text = text }
                        }
                    }
                    try Task.checkCancellation()
                    updateService(id, sessionID: context.id, runID: runID) { $0.result = result; $0.loading = false }
                } catch is CancellationError { }
                catch {
                    guard !Task.isCancelled else { return }
                    let message = self.readableError(error)
                    updateService(id, sessionID: context.id, runID: runID) {
                        $0.error = context.operation == .polishing ? message.replacingOccurrences(of: "翻译", with: "润色") : message
                        $0.loading = false
                    }
                }
            }
        }
        updateAggregateState()
    }
    private func updateService(_ id: TranslationServiceID, sessionID: UUID, runID: UUID, update: (inout ServiceTranslationResult) -> Void) {
        guard translationSession?.id == sessionID,
              let index = floating.state.services.firstIndex(where: { $0.id == id && $0.runID == runID }) else { return }
        var result = floating.state.services[index]; update(&result); floating.state.services[index] = result
        updateAggregateState()
    }
    private func updateAggregateState() {
        let results = floating.state.services
        floating.state.loading = results.contains { $0.loading }
        floating.state.complete = !floating.state.loading && results.contains { $0.error == nil }
        floating.state.error = !floating.state.loading && results.allSatisfy { $0.error != nil }
        floating.state.text = results.first(where: { $0.id == .ai })?.result.text ?? results.first(where: { $0.error == nil })?.result.copyText ?? ""
        let action = floating.state.operation.action
        floating.state.status = floating.state.loading ? "正在\(action)" : floating.state.error ? "\(action)未完成" : results.contains(where: { $0.error != nil }) ? "部分完成" : "已完成"
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
        closeActionPopup()
        cancelScreenshot(restore: false)
        hoverTicket?.cancel(); hoverTicket = nil; hoverSessionActive = false; hoverContext = nil
        translationSession = nil; cancelServiceTasks()
        modelLoadingTask?.cancel(); modelLoadingTask = nil; floating.hide()
    }
    @objc func showPreview() {
        dismiss(); floating.showResult(preview: true, position: preferences.translationWindowPosition)
        TranslationWindowExample.populate(floating.state, fontSize: CGFloat(preferences.translationFontSize))
        floating.fitContent()
    }
    func verifyTranslation() {
        startTranslation("Small steps make complex things easier to understand.")
        floating.resultPanel.makeKeyAndOrderFront(nil)
    }
    #if QINGYI_TESTING
    func prepareScreenshotFixture(engine: TranslationEngine, capture: ScreenshotCapturing, ocr: ScreenshotRecognizing) {
        services = BuiltinTranslationSettings(defaults: UserDefaults(suiteName: "qingyi-fixture-services")!, enabledByDefault: false)
        self.engine = engine; screenshotCapture = capture; screenshotOCR = ocr; screenCaptureAccess = { true }
        configureSelectionDismissal()
        floating.onRetry = { [weak self] in self?.retryTranslation() }
        floating.onClose = { [weak self] in self?.dismiss() }
    }
    func prepareBuiltinFixture(engine: TranslationEngine, client: BuiltinTranslationClient, settings: BuiltinTranslationSettings) {
        self.engine = engine; builtinClient = client; services = settings
        observeServiceSwitches()
        observeServicesOrder()
    }
    func retryBuiltinFixture(_ id: TranslationServiceID) { performTranslation(keepPosition: true, only: id) }
    func prepareSelectionFixture(engine: TranslationEngine, client: BuiltinTranslationClient, settings: BuiltinTranslationSettings) {
        prepareBuiltinFixture(engine: engine, client: client, settings: settings)
        // These selections and modifier events are synthetic, independent of the user's mouse.
        hover.pressedMouseButtons = { 0 }
        observeTextSettings()
        preferences.paused = false
        floating.onTrigger = { [weak self] in self?.trigger() }
        floating.onRetry = { [weak self] in self?.retryTranslation() }
        floating.onRetryService = { [weak self] in self?.performTranslation(keepPosition: true, only: $0) }
        floating.onSelectModel = { [weak self] in self?.selectTemporaryModel($0, sessionID: $1) }
        floating.onRestoreModel = { [weak self] in self?.restoreTemporaryModel(sessionID: $0) }
        floating.onClose = { [weak self] in self?.dismiss() }
        floating.onModelMenuTracking = { [weak self] in self?.monitor.setModelMenuTracking($0) }
        monitor.toolbarReadFixture = { [weak self] _, completion in completion(self?.selection) }
        configureSelectionDismissal()
        configureActionInteraction()
    }
    func feedSelectionFixture(_ text: String) {
        let previous = SelectionMonitor.leftMouseDownOverride
        SelectionMonitor.leftMouseDownOverride = false
        defer { SelectionMonitor.leftMouseDownOverride = previous }
        selectionChanged(SelectionSnapshot(text: text, anchor: nil, pid: getpid(), range: UUID().uuidString))
    }
    func startActionFixture(_ action: AIAction, source: String) { startTranslation(source, operation: .custom(action)) }
    func showActionPopupFixture(source: String) {
        // Opening this fixture represents a completed selection with the mouse released.
        let previous = SelectionMonitor.leftMouseDownOverride
        SelectionMonitor.leftMouseDownOverride = false
        defer { SelectionMonitor.leftMouseDownOverride = previous }
        feedSelectionFixture(source)
        actionGesture = AIActionGesture()
        actionGesture.input(.flags, flags: engine.textSettings.actionModifier.flag,
                            time: ProcessInfo.processInfo.systemUptime - 1, modifier: engine.textSettings.actionModifier)
        _ = showActionPopupIfReady(pendingModifierActions(requireFrontmost: false))
    }
    @discardableResult func routeActionEventFixture(_ event: NSEvent) -> Bool { routeActionEvent(event, requireFrontmost: false) }
    @discardableResult func tickActionPopupFixture() -> Bool { showActionPopupIfReady(pendingModifierActions(requireFrontmost: false)) }
    func screenshotClipboardFixture(_ text: String) { startTranslation(text, origin: .clipboard) }
    var screenshotActiveFixture: Bool { screenshotID != nil }
    func prepareHoverFixture(engine: TranslationEngine) {
        services = BuiltinTranslationSettings(defaults: UserDefaults(suiteName: "qingyi-fixture-services")!, enabledByDefault: false)
        self.engine = engine
        floating.onRetry = { [weak self] in self?.retryTranslation() }
        monitor.onSelection = { [weak self] in self?.selectionChanged($0) }
    }
    func feedHoverFixture(_ source: String) {
        monitor.suppressAutomaticSelection()
        acceptHoveredParagraph(source)
    }
    func dismissHoverFixture() { dismiss() }
    #endif
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
if CommandLine.arguments.contains("--builtin-translation-check") {
    Task { @MainActor in
        let client = BuiltinTranslationClient()
        var failed = 0
        for service in [TranslationServiceID.youdao, .google] {
            for sample in ["resilience", "Small steps make complex things easier to understand."] {
                do {
                    let result = try await client.translate(sample, service: service)
                    print("PASS \(service.name) · \(sample): \(result.copyText)")
                } catch { failed += 1; print("FAIL \(service.name): \(error.localizedDescription)") }
            }
        }
        exit(failed == 0 ? 0 : 1)
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}

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
            let sample: String
            if let index = CommandLine.arguments.firstIndex(of: "--screenshot-input"), CommandLine.arguments.count > index + 1 {
                let path = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                guard let source = CGImageSourceCreateWithURL(path as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw QingyiError.message("无法读取指定的 OCR 验证图片。") }
                sample = try ScreenshotText.validate(await VisionScreenshotOCR().recognize(image))
                print("PASS local screenshot OCR: \(sample.count) characters; only text will be sent")
            } else { sample = "Small steps make complex things easier to understand." }
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
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}

if CommandLine.arguments.contains("--default-translation-check") {
    Task { @MainActor in
        let passed = await ReleaseModelCheck.run(arguments: CommandLine.arguments)
        exit(passed ? 0 : 1)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--translation-check") {
    Task { @MainActor in
        do {
            try AppRuntime.validate()
            let chat = ChatGPT(diagnostic: { print($0) })
            let choices = try await chat.loadTemporaryModels()
            guard !chat.activeID.isEmpty, let model = choices.first(where: { $0.id == chat.modelID }) ?? choices.first else {
                throw QingyiError.message("没有可用的 ChatGPT 模型，请在设置中选择模型。")
            }
            let engine = TranslationEngine(chat: chat, configuration: APIConfigurationStore())
            let target = TranslationTarget(service: .chatGPT(chat.activeID), modelID: model.id)
            let result = try await engine.translate("Small steps make complex things easier to understand.", target: target, onUpdate: { _ in })
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
