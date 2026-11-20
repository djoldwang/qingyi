import AppKit
import SwiftUI
import ApplicationServices
import ServiceManagement
import Combine

struct ExclusionAdditionResult {
    var added = 0
    var duplicates = 0
    var invalid: [String] = []
    var message: String {
        var parts = ["已添加 \(added) 个应用。"]
        if duplicates > 0 { parts.append("\(duplicates) 个已在排除列表中。") }
        if !invalid.isEmpty { parts.append("无法识别：\(invalid.joined(separator: "、"))。请选择有效的应用程序。") }
        return parts.joined(separator: " ")
    }
}

enum ButtonPosition: String, CaseIterable, Identifiable {
    case lowerLeft, lowerRight, upperLeft, upperRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lowerLeft: return "鼠标左下方"
        case .lowerRight: return "鼠标右下方"
        case .upperLeft: return "鼠标左上方"
        case .upperRight: return "鼠标右上方"
        }
    }
    func origin(relativeTo mouse: NSPoint, size: NSSize) -> NSPoint {
        let left = self == .lowerLeft || self == .upperLeft
        let below = self == .lowerLeft || self == .lowerRight
        // AppKit coordinates start at the bottom-left. Keep the whole button
        // on the chosen side of the pointer, with a 12 pt gap on both axes.
        return NSPoint(x: left ? mouse.x - 12 - size.width : mouse.x + 12,
                       y: below ? mouse.y - 12 - size.height : mouse.y + 12)
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var buttonPosition: ButtonPosition {
        didSet { defaults.set(buttonPosition.rawValue, forKey: "selectionButtonPosition") }
    }
    @Published var hoverEnabled: Bool {
        didSet { defaults.set(hoverEnabled, forKey: "hoverTranslationEnabled") }
    }
    @Published var hoverTrigger: HoverTrigger {
        didSet { defaults.set(hoverTrigger.rawValue, forKey: "hoverTranslationTrigger") }
    }
    @Published var paused = false
    var selectionEnabled: Bool {
        get { !paused }
        set { paused = !newValue }
    }
    @Published var translationWindowPosition: TranslationWindowPosition {
        didSet { defaults.set(translationWindowPosition.rawValue, forKey: "translationWindowPosition") }
    }
    @Published var translationFontSize: Double {
        didSet { defaults.set(translationFontSize, forKey: "translationFontSize") }
    }
    @Published var trusted = AXIsProcessTrusted()
    @Published var shortcutBinding: ShortcutBinding
    let shortcutStore: ShortcutPreferences
    @Published var screenshotShortcutBinding: ShortcutBinding
    @Published var screenshotShortcutMessage = ""
    @Published var screenCaptureGranted = CGPreflightScreenCaptureAccess()
    @Published var shortcutMessage = ""
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var generalMessage = ""
    @Published var excluded: [String] = []
    private var excludedAppLocations: [String: String]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverEnabled = defaults.bool(forKey: "hoverTranslationEnabled")
        hoverTrigger = HoverTrigger(rawValue: defaults.string(forKey: "hoverTranslationTrigger") ?? "") ?? .longPress
        excludedAppLocations = defaults.dictionary(forKey: "excludedAppLocations") as? [String: String] ?? [:]
        excluded = defaults.stringArray(forKey: "excludedApps") ?? []
        buttonPosition = ButtonPosition(rawValue: defaults.string(forKey: "selectionButtonPosition") ?? "") ?? .lowerLeft
        translationWindowPosition = TranslationWindowPosition(rawValue: defaults.string(forKey: "translationWindowPosition") ?? "") ?? .upperRight
        let savedFontSize = (defaults.object(forKey: "translationFontSize") as? NSNumber)?.doubleValue ?? TranslationFontSize.standard
        translationFontSize = TranslationFontSize.normalized(savedFontSize)
        shortcutStore = ShortcutPreferences(defaults: defaults)
        shortcutBinding = shortcutStore.preferred
        screenshotShortcutBinding = shortcutStore.screenshot
    }
    @discardableResult func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        return NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            generalMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许轻译。" : ""
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { launchAtLogin = SMAppService.mainApp.status == .enabled; generalMessage = "未能更改开机启动：\(error.localizedDescription)" }
    }
    func addExcludedApplications(_ urls: [URL]) -> ExclusionAdditionResult {
        var result = ExclusionAdditionResult()
        var next = excluded
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL, url.pathExtension.lowercased() == "app",
                  let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else {
                result.invalid.append(url.lastPathComponent); continue
            }
            excludedAppLocations[id] = url.standardizedFileURL.path
            if next.contains(id) { result.duplicates += 1 }
            else { next.append(id); result.added += 1 }
        }
        excluded = next
        persistExclusions()
        return result
    }
    func removeExclusion(_ id: String) {
        excluded.removeAll { $0 == id }
        excludedAppLocations.removeValue(forKey: id)
        persistExclusions()
    }
    func toggleExclusion(_ id: String) {
        if excluded.contains(id) { removeExclusion(id) }
        else {
            excluded.append(id)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { excludedAppLocations[id] = url.path }
            persistExclusions()
        }
    }
    func excludedApplicationURL(_ id: String) -> URL? {
        if let path = excludedAppLocations[id] {
            let url = URL(fileURLWithPath: path)
            if Bundle(url: url)?.bundleIdentifier == id { return url }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }
    func clearExclusions() {
        excluded = []; excludedAppLocations = [:]; persistExclusions()
    }
    private func persistExclusions() {
        excludedAppLocations = excludedAppLocations.filter { excluded.contains($0.key) }
        if excluded.isEmpty { defaults.removeObject(forKey: "excludedApps") }
        else { defaults.set(excluded, forKey: "excludedApps") }
        if excludedAppLocations.isEmpty { defaults.removeObject(forKey: "excludedAppLocations") }
        else { defaults.set(excludedAppLocations, forKey: "excludedAppLocations") }
    }
}

final class ShortcutRecorderButton: NSButton {
    var actionName = "翻译已复制文字" { didSet { setAccessibilityLabel("录制\(actionName)的快捷键") } }
    var binding = ShortcutBinding.defaultClipboard { didSet { if !recording { refreshTitle() } } }
    var onCandidate: ((ShortcutBinding) -> Bool)?
    var onRecording: ((Bool) -> Void)?
    private var recording = false
    private var monitor: Any?
    private var resignation: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self; action = #selector(toggleRecording)
        setAccessibilityLabel("录制翻译已复制文字的快捷键")
        toolTip = "点击后直接按下快捷键；Esc 取消。"
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refreshTitle() { title = binding.display; setAccessibilityValue(binding.display) }
    @objc private func toggleRecording() {
        if recording { stopRecording(); return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        recording = true; title = "请按快捷键…"; setAccessibilityValue("正在录制，Esc 取消")
        window?.makeFirstResponder(self)
        onRecording?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self = self, self.recording else { return event }
            if event.type == .leftMouseDown { self.stopRecording(); return event }
            if event.type == .flagsChanged {
                self.title = ShortcutBinding.modifierLabel(ShortcutBinding.carbonModifiers(event.modifierFlags)) + "…"
                return event
            }
            let modifiers = ShortcutBinding.carbonModifiers(event.modifierFlags)
            if event.keyCode == 53 && modifiers == 0 { self.stopRecording(); return nil }
            guard let candidate = ShortcutBinding(event: event) else { return nil }
            _ = self.onCandidate?(candidate)
            self.stopRecording()
            return nil // Consume Cmd+Q/Cmd+W etc. while recording, rather than execute them.
        }
        resignation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.stopRecording() }
    }
    private func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignation = resignation { NotificationCenter.default.removeObserver(resignation) }; resignation = nil
        onRecording?(false); refreshTitle()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stopRecording() } }
    deinit {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        if let resignation = resignation { NotificationCenter.default.removeObserver(resignation) }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let binding: ShortcutBinding
    var actionName = "翻译已复制文字"
    var onCandidate: (ShortcutBinding) -> Bool
    var onRecording: (Bool) -> Void
    func makeNSView(context: Context) -> ShortcutRecorderButton { ShortcutRecorderButton() }
    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        view.actionName = actionName
        view.binding = binding
        view.onCandidate = onCandidate; view.onRecording = onRecording
    }
}

@MainActor
final class FloatingState: ObservableObject {
    @Published var fontSize: CGFloat = 15
    @Published var source = ""
    @Published var text = ""
    @Published var status = "正在翻译"
    @Published var loading = false
    @Published var error = false
    @Published var model = ""
    @Published var complete = false
    @Published var sessionID = UUID()
    @Published var choice: TranslationChoice?
    @Published var defaultChoice: TranslationChoice?
    @Published var modelGroups: [TranslationModelGroup] = []
    @Published var modelSelectionEnabled = false
    @Published var temporaryModel = false
    @Published var loadingChatGPTModels = false
    @Published var modelMenuMessage = ""
    @Published var pinned = false
}

struct TranslationCard: View {
    @ObservedObject var state: FloatingState
    @Environment(\.colorScheme) private var colorScheme
    var close: () -> Void
    var retry: () -> Void
    var settings: () -> Void
    var modelMenuTracking: (Bool) -> Void = { _ in }
    var selectModel: (TranslationChoice, UUID) -> Void = { _, _ in }
    var restoreModel: (UUID) -> Void = { _ in }
    var loadModels: (UUID) -> Void = { _ in }
    var togglePin: () -> Void = {}
    private let accent = Color(red: 0.27, green: 0.32, blue: 0.83)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: togglePin) {
                    Image(systemName: state.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12)).foregroundStyle(state.pinned ? accent : Color.secondary)
                        .frame(width: 23, height: 22)
                }.buttonStyle(.plain)
                    .help(state.pinned ? "取消钉住" : "钉住窗口，点击外部或切换应用时保留")
                    .accessibilityLabel(state.pinned ? "取消钉住" : "钉住译文窗口")
                TranslationDragArea().frame(maxWidth: .infinity).frame(height: 22)
                if state.loading { ProgressView().controlSize(.small) }
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 23, height: 23) }.buttonStyle(.plain).help("关闭（Esc）").accessibilityLabel("关闭翻译")
            }.padding(.horizontal, 12).frame(height: TranslationWindowLayout.headerHeight)
            Divider().opacity(0.5)
            TranslationBodyScrollArea(source: state.source, text: state.text, error: state.error, dark: colorScheme == .dark, fontSize: state.fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                TemporaryModelPicker(state: state, tracking: modelMenuTracking, select: selectModel, restore: restoreModel, load: loadModels)
                    .frame(minWidth: 64).frame(height: 24)
                if state.temporaryModel {
                    Text("本次").font(.system(size: 9)).foregroundStyle(.secondary)
                        .fixedSize().help("临时模型，仅当前译文生效")
                }
                Spacer(minLength: 0)
                if state.error {
                    Button("设置", action: settings).fixedSize().frame(minHeight: 24)
                    Button("重试", action: retry).fixedSize().frame(minHeight: 24)
                }
                else {
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(state.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 24) }
                    .help("复制译文").accessibilityLabel("复制译文").disabled(!state.complete)
                }
            }.font(.system(size: 11)).buttonStyle(.borderless).tint(accent)
                .padding(.horizontal, 18).frame(height: TranslationWindowLayout.footerHeight)
        }
        .background(colorScheme == .dark ? Color(red: 0.14, green: 0.14, blue: 0.14) : Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
    }
}

final class TranslationPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onDragging: ((Bool) -> Void)?
    var onTextMenuTracking: ((Bool) -> Void)?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func sendEvent(_ event: NSEvent) {
        // Handle the header before NSHostingView hit testing: SwiftUI material
        // layers can otherwise receive the click instead of the native grip.
        let p = event.locationInWindow
        if event.type == .leftMouseDown, p.x >= 43, p.x <= frame.width - 60,
           p.y >= frame.height - TranslationWindowLayout.headerHeight, p.y <= frame.height {
            dragStart = convertPoint(toScreen: event.locationInWindow); windowStart = frame.origin
            onDragging?(true); NSCursor.closedHand.push(); return
        }
        if let start = dragStart, let origin = windowStart {
            if event.type == .leftMouseDragged {
                let pointer = convertPoint(toScreen: event.locationInWindow)
                setFrameOrigin(NSPoint(x: origin.x + pointer.x - start.x, y: origin.y + pointer.y - start.y)); return
            }
            if event.type == .leftMouseUp {
                dragStart = nil; windowStart = nil; NSCursor.pop(); onDragging?(false); return
            }
        }
        super.sendEvent(event)
    }
}

final class HoverButton: NSView {
    var trigger: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovering = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("翻译选中文字，移入即翻译，也可点击")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        NSColor(calibratedRed: hovering ? 0.25 : 0.29, green: hovering ? 0.29 : 0.34, blue: 0.86, alpha: 1).setFill(); path.fill()
        let text: NSString = "译"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true; needsDisplay = true
        guard !SelectionMonitor.isLeftMouseDown else { return }
        trigger?()
    }
    override func mouseExited(with event: NSEvent) { cancelHover() }
    override func mouseDown(with event: NSEvent) { trigger?() }
    override func accessibilityPerformPress() -> Bool { trigger?(); return true }
    func cancelHover() { hovering = false; needsDisplay = true }
}

@MainActor
final class FloatingController {
    let state = FloatingState()
    let buttonPanel: NSPanel
    let resultPanel: TranslationPanel
    let hoverButton = HoverButton(frame: NSRect(x: 0, y: 0, width: 38, height: 38))
    var onTrigger: (() -> Void)?
    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?
    var onSettings: (() -> Void)?
    var onModelMenuTracking: ((Bool) -> Void)?
    var onSelectModel: ((TranslationChoice, UUID) -> Void)?
    var onRestoreModel: ((UUID) -> Void)?
    var onLoadModels: ((UUID) -> Void)?
    private(set) var modelMenuTracking = false
    private var modelPickerTracking = false
    private var textMenuTracking = false
    private var menuClosingThisTurn = false
    private var lastMenuClosedAt: TimeInterval = 0
    private var stateSubscription: AnyCancellable?
    private var resizeScheduled = false
    private var draggingWindow = false
    private var placement: TranslationWindowPosition = .upperRight
    private var anchorPointer = NSPoint.zero
    private var placementScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private var manualTopLeft: NSPoint?
    private var settingFrame = false
    private var moveObservers: [NSObjectProtocol] = []
    init() {
        buttonPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 38, height: 38), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        resultPanel = TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: TranslationWindowLayout.width, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        resultPanel.title = "轻译译文"
        resultPanel.isMovable = true
        resultPanel.isMovableByWindowBackground = false
        resultPanel.setAccessibilityTitle("轻译译文")
        for panel in [buttonPanel, resultPanel] {
            panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        }
        resultPanel.level = .screenSaver
        resultPanel.onTextMenuTracking = { [weak self] in self?.handleTextMenuTracking($0) }
        buttonPanel.contentView = hoverButton
        hoverButton.trigger = { [weak self] in self?.onTrigger?() }
        resultPanel.onCancel = { [weak self] in
            guard let self = self else { return }
            if self.modelMenuTracking {
                ModelMenuButton.cancelPresentedMenu(); TranslationResultTextView.cancelPresentedMenu()
            }
            else {
                let forwardedEscape = NSApp.currentEvent.map { $0.type == .keyDown && $0.keyCode == 53 && $0.timestamp <= self.lastMenuClosedAt } ?? false
                if !self.menuClosingThisTurn && !forwardedEscape { self.onClose?() }
            }
        }
        resultPanel.onDragging = { [weak self] active in
            guard let self = self else { return }
            self.draggingWindow = active
            if !active {
                self.manualTopLeft = NSPoint(x: self.resultPanel.frame.minX, y: self.resultPanel.frame.maxY)
                self.placementScreen = self.resultPanel.screen?.visibleFrame ?? self.placementScreen
                self.fitContent()
            }
        }
        resultPanel.contentView = NSHostingView(rootView: TranslationCard(state: state, close: { [weak self] in self?.onClose?() }, retry: { [weak self] in self?.onRetry?() }, settings: { [weak self] in self?.onSettings?() }, modelMenuTracking: { [weak self] tracking in
            self?.handleModelMenuTracking(tracking)
        }, selectModel: { [weak self] choice, id in self?.onSelectModel?(choice, id) }, restoreModel: { [weak self] id in self?.onRestoreModel?(id) }, loadModels: { [weak self] id in self?.onLoadModels?(id) }, togglePin: { [weak self] in self?.state.pinned.toggle() }))
        stateSubscription = state.objectWillChange.sink { [weak self] _ in
            guard let self = self, !self.resizeScheduled else { return }
            self.resizeScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.resizeScheduled = false; self?.fitContent()
            }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            moveObservers.append(NotificationCenter.default.addObserver(forName: name, object: resultPanel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self, !self.settingFrame, self.resultPanel.isVisible else { return }
                    self.manualTopLeft = NSPoint(x: self.resultPanel.frame.minX, y: self.resultPanel.frame.maxY)
                    self.placementScreen = self.resultPanel.screen?.visibleFrame ?? self.placementScreen
                }
            })
        }
    }
    deinit { for observer in moveObservers { NotificationCenter.default.removeObserver(observer) } }
    func handleModelMenuTracking(_ tracking: Bool) {
        modelPickerTracking = tracking
        updateMenuTracking()
    }
    private func handleTextMenuTracking(_ tracking: Bool) {
        textMenuTracking = tracking
        updateMenuTracking()
    }
    private func updateMenuTracking() {
        let tracking = modelPickerTracking || textMenuTracking
        guard modelMenuTracking != tracking else { return }
        modelMenuTracking = tracking
        // Native menus use the pop-up menu level. Let them cover the card only
        // during tracking, then restore the high window level immediately.
        resultPanel.level = tracking ? NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1) : .screenSaver
        if !tracking {
            if resultPanel.isVisible { resultPanel.orderFrontRegardless() }
            lastMenuClosedAt = ProcessInfo.processInfo.systemUptime
            menuClosingThisTurn = true
            DispatchQueue.main.async { [weak self] in self?.menuClosingThisTurn = false }
        }
        onModelMenuTracking?(tracking)
    }
    func offerAutomaticTranslation(for text: String, position: ButtonPosition, preserveResult: Bool = false) {
        guard TextPolicy.shouldOfferAutomaticTranslation(text) else {
            if preserveResult { hideButton() } else { hide() }
            return
        }
        showButton(position: position, preserveResult: preserveResult)
    }
    func showButton(position: ButtonPosition, preserveResult: Bool = false) {
        guard !SelectionMonitor.isLeftMouseDown else { hideButton(); return }
        if !preserveResult { hide() }
        let point = clamp(position.origin(relativeTo: NSEvent.mouseLocation, size: buttonPanel.frame.size), size: buttonPanel.frame.size)
        buttonPanel.setFrameOrigin(point); buttonPanel.orderFrontRegardless()
    }
    func showResult(source: String, preview: Bool = false, keepPosition: Bool = false, position: TranslationWindowPosition = .upperRight) {
        let reposition = (!keepPosition && !state.pinned) || !resultPanel.isVisible
        hoverButton.cancelHover(); buttonPanel.orderOut(nil)
        state.source = source; state.text = ""; state.error = false; state.loading = !preview; state.complete = false
        if preview { state.modelSelectionEnabled = false; state.choice = nil; state.defaultChoice = nil; state.temporaryModel = false }
        state.status = preview ? "界面预览 · 未调用模型" : "正在翻译 · ChatGPT"
        if reposition {
            placement = position; anchorPointer = NSEvent.mouseLocation; manualTopLeft = nil
            placementScreen = (NSScreen.screens.first { $0.frame.contains(anchorPointer) } ?? NSScreen.main)?.visibleFrame ?? placementScreen
        }
        fitContent(requireVisible: false)
        resultPanel.orderFrontRegardless()
        if preview { resultPanel.makeKeyAndOrderFront(nil) }
    }
    func hide() {
        ModelMenuButton.cancelPresentedMenu(); TranslationResultTextView.cancelPresentedMenu()
        hoverButton.cancelHover(); buttonPanel.orderOut(nil); resultPanel.orderOut(nil)
        state.source = ""; state.text = ""; state.complete = false
        state.sessionID = UUID(); state.modelSelectionEnabled = false; state.choice = nil; state.defaultChoice = nil
        state.temporaryModel = false; state.modelMenuMessage = ""; state.loadingChatGPTModels = false
        state.pinned = false; manualTopLeft = nil
    }
    // Hiding for capture must retain the session, pin, geometry and retry source.
    func concealForScreenshot() -> Bool {
        ModelMenuButton.cancelPresentedMenu(); TranslationResultTextView.cancelPresentedMenu()
        let visible = resultPanel.isVisible
        hoverButton.cancelHover(); buttonPanel.orderOut(nil); resultPanel.orderOut(nil)
        return visible
    }
    func restoreAfterScreenshot(wasVisible: Bool) {
        if wasVisible { resultPanel.orderFrontRegardless() }
    }
    func hideButton() { hoverButton.cancelHover(); buttonPanel.orderOut(nil) }
    func fitContent(requireVisible: Bool = true) {
        guard (!requireVisible || resultPanel.isVisible), !draggingWindow else { return }
        let height = TranslationWindowLayout.contentHeight(source: state.source, text: state.text, error: state.error, fontSize: state.fontSize)
        let frame = TranslationWindowLayout.frame(contentHeight: height, position: placement, pointer: anchorPointer, screen: placementScreen, manualTopLeft: manualTopLeft)
        if resultPanel.frame != frame {
            settingFrame = true; resultPanel.setFrame(frame, display: true); settingFrame = false
        }
    }
    func contains(_ point: NSPoint) -> Bool { (buttonPanel.isVisible && buttonPanel.frame.insetBy(dx: -4, dy: -4).contains(point)) || (resultPanel.isVisible && resultPanel.frame.contains(point)) }
    nonisolated static func belowPointer(_ mouse: NSPoint, size: NSSize) -> NSPoint {
        // AppKit's origin is bottom-left; this puts the panel's top-left 12 pt
        // to the right and 12 pt below the pointer, independent of drag direction.
        NSPoint(x: mouse.x + 12, y: mouse.y - 12 - size.height)
    }
    nonisolated static func clamped(_ point: NSPoint, size: NSSize, screen: NSRect, inset: CGFloat = 10) -> NSPoint {
        NSPoint(x: max(screen.minX + inset, min(point.x, screen.maxX - size.width - inset)), y: max(screen.minY + inset, min(point.y, screen.maxY - size.height - inset)))
    }
    private func clamp(_ point: NSPoint, size: NSSize) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first else { return point }
        return Self.clamped(point, size: size, screen: screen.visibleFrame)
    }
}
