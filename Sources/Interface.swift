import AppKit
import SwiftUI
import ApplicationServices
import ServiceManagement

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
    @Published var paused = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var shortcutBinding: ShortcutBinding
    let shortcutStore: ShortcutPreferences
    @Published var shortcutMessage = ""
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var generalMessage = ""
    @Published var refreshing = false
    @Published var excluded: [String] = UserDefaults.standard.stringArray(forKey: "excludedApps") ?? []
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        buttonPosition = ButtonPosition(rawValue: defaults.string(forKey: "selectionButtonPosition") ?? "") ?? .lowerLeft
        shortcutStore = ShortcutPreferences(defaults: defaults)
        shortcutBinding = shortcutStore.preferred
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            generalMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许轻译。" : ""
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { launchAtLogin = SMAppService.mainApp.status == .enabled; generalMessage = "未能更改开机启动：\(error.localizedDescription)" }
    }
    func clearExclusions() { excluded = []; UserDefaults.standard.removeObject(forKey: "excludedApps") }
}

final class ShortcutRecorderButton: NSButton {
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
    var onCandidate: (ShortcutBinding) -> Bool
    var onRecording: (Bool) -> Void
    func makeNSView(context: Context) -> ShortcutRecorderButton { ShortcutRecorderButton() }
    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        view.binding = binding
        view.onCandidate = onCandidate; view.onRecording = onRecording
    }
}

@MainActor
final class FloatingState: ObservableObject {
    @Published var source = ""
    @Published var text = ""
    @Published var status = "正在翻译"
    @Published var loading = false
    @Published var error = false
    @Published var model = ""
    @Published var complete = false
}

struct TranslationCard: View {
    @ObservedObject var state: FloatingState
    var close: () -> Void
    var retry: () -> Void
    var settings: () -> Void
    private let accent = Color(red: 0.27, green: 0.32, blue: 0.83)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text("译").font(.system(size: 16, weight: .semibold)).foregroundStyle(accent)
                Text("轻译").font(.system(size: 13, weight: .semibold))
                Text("/ 简体中文").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if state.loading { ProgressView().controlSize(.small) }
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 23, height: 23) }.buttonStyle(.plain).help("关闭（Esc）").accessibilityLabel("关闭翻译")
            }.padding(.horizontal, 18).padding(.vertical, 14)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(state.source).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    if state.error {
                        Label(state.text, systemImage: "exclamationmark.circle").font(.system(size: 14)).foregroundStyle(.orange).textSelection(.enabled)
                    } else if state.text.isEmpty {
                        Text("正在将选中文字译成中文…").foregroundStyle(.secondary).font(.system(size: 14))
                    } else {
                        Text(state.text).font(.system(size: 15)).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }.padding(18)
            }
            Divider().opacity(0.5)
            HStack {
                Text(state.status).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if state.error { Button("设置", action: settings); Button("重试", action: retry) }
                else {
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(state.text, forType: .string)
                    } label: { Label("复制译文", systemImage: "doc.on.doc") }.disabled(!state.complete)
                }
            }.font(.system(size: 11)).buttonStyle(.borderless).tint(accent).padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class HoverButton: NSView {
    var trigger: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var pending: DispatchWorkItem?
    private var hovering = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("翻译选中文字，悬停或点击")
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
        hovering = true; needsDisplay = true; pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.trigger?() }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    override func mouseExited(with event: NSEvent) { cancelHover() }
    override func mouseDown(with event: NSEvent) { pending?.cancel(); trigger?() }
    override func accessibilityPerformPress() -> Bool { trigger?(); return true }
    func cancelHover() { hovering = false; needsDisplay = true; pending?.cancel(); pending = nil }
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
    init() {
        buttonPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 38, height: 38), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        resultPanel = TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        resultPanel.title = "轻译译文"
        resultPanel.setAccessibilityTitle("轻译译文")
        for panel in [buttonPanel, resultPanel] {
            panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        }
        buttonPanel.contentView = hoverButton
        hoverButton.trigger = { [weak self] in self?.onTrigger?() }
        resultPanel.contentView = NSHostingView(rootView: TranslationCard(state: state, close: { [weak self] in self?.onClose?() }, retry: { [weak self] in self?.onRetry?() }, settings: { [weak self] in self?.onSettings?() }))
    }
    func showButton(position: ButtonPosition) {
        hide()
        let point = clamp(position.origin(relativeTo: NSEvent.mouseLocation, size: buttonPanel.frame.size), size: buttonPanel.frame.size)
        buttonPanel.setFrameOrigin(point); buttonPanel.orderFrontRegardless()
    }
    func showResult(source: String, preview: Bool = false, keepPosition: Bool = false) {
        let reposition = !keepPosition || !resultPanel.isVisible
        hoverButton.cancelHover(); buttonPanel.orderOut(nil)
        state.source = source; state.text = ""; state.error = false; state.loading = !preview; state.complete = false
        state.status = preview ? "界面预览 · 未调用模型" : "正在翻译 · ChatGPT"
        if reposition {
            let point = clamp(Self.belowPointer(NSEvent.mouseLocation, size: resultPanel.frame.size), size: resultPanel.frame.size)
            resultPanel.setFrameOrigin(point)
        }
        resultPanel.orderFrontRegardless()
        if preview { resultPanel.makeKeyAndOrderFront(nil) }
    }
    func hide() { hoverButton.cancelHover(); buttonPanel.orderOut(nil); resultPanel.orderOut(nil); state.source = ""; state.text = ""; state.complete = false }
    func contains(_ point: NSPoint) -> Bool { (buttonPanel.isVisible && buttonPanel.frame.insetBy(dx: -4, dy: -4).contains(point)) || (resultPanel.isVisible && resultPanel.frame.contains(point)) }
    static func belowPointer(_ mouse: NSPoint, size: NSSize) -> NSPoint {
        // AppKit's origin is bottom-left; this puts the panel's top-left 12 pt
        // to the right and 12 pt below the pointer, independent of drag direction.
        NSPoint(x: mouse.x + 12, y: mouse.y - 12 - size.height)
    }
    static func clamped(_ point: NSPoint, size: NSSize, screen: NSRect) -> NSPoint {
        NSPoint(x: max(screen.minX + 10, min(point.x, screen.maxX - size.width - 10)), y: max(screen.minY + 10, min(point.y, screen.maxY - size.height - 10)))
    }
    private func clamp(_ point: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first!
        return Self.clamped(point, size: size, screen: screen.visibleFrame)
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var chat: ChatGPT
    var updateShortcut: (ShortcutBinding) -> Bool
    var shortcutRecording: (Bool) -> Void
    var preview: () -> Void
    var verify: () -> Void
    private let accent = Color(red: 0.29, green: 0.34, blue: 0.86)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Text("译").font(.system(size: 33, weight: .semibold)).foregroundStyle(.white).frame(width: 64, height: 64).background(accent.gradient, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("轻译").font(.system(size: 25, weight: .bold))
                        Text("选中 · 轻触 · 读懂").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0").font(.caption).foregroundStyle(.tertiary)
                }.padding(.bottom, 3)
                accountSection
                permissionSection
                behaviorSection
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lock.shield").foregroundStyle(accent)
                    Text("只有悬停或点击“译”后，才将选中文字发送给 OpenAI。默认不保存原文、译文或翻译历史。图片和扫描件暂不支持。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 3)
            }.padding(26)
        }.frame(minWidth: 590, minHeight: 690).background(Color(nsColor: .windowBackgroundColor))
    }
    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
            content()
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
    }
    private var accountSection: some View {
        section("ChatGPT 账号", icon: "sparkles") {
            Text(chat.activeAccount?.email ?? "尚未连接").font(.system(size: 14, weight: .medium))
            Text(chat.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if chat.registrations.count > 1 {
                Picker("已保存的账号", selection: Binding(get: { chat.activeID }, set: { chat.selectAccount($0) })) {
                    ForEach(chat.registrations) { Text("\($0.email) · \($0.id.suffix(6))").tag($0.id) }
                }.disabled(chat.busy)
            }
            HStack(spacing: 10) {
                if chat.busy {
                    ProgressView().controlSize(.small)
                    if chat.signingOut { Text("正在退出…").font(.caption).foregroundStyle(.secondary) }
                    else { Button("取消登录") { chat.cancelLogin() } }
                }
                else {
                    Button(chat.signedIn ? "重新授权" : "Continue with ChatGPT") { chat.signIn() }.buttonStyle(.borderedProminent).tint(accent)
                    if chat.activeAccount != nil { Button("添加账号") { chat.signIn(newAccount: true) } }
                    if chat.signedIn { Button("退出登录") { Task { await chat.signOut() } } }
                    if chat.hasPendingRegistration { Button("继续上次授权") { chat.recoverPendingRegistration() } }
                }
                Spacer()
                Link("管理用量 ↗", destination: URL(string: "https://chatgpt.com/#settings/Usage")!).font(.system(size: 11))
            }
            if chat.signedIn {
                Divider()
                HStack {
                    Picker("翻译模型", selection: $chat.modelID) {
                        if chat.models.isEmpty { Text("请刷新模型列表").tag(chat.modelID) }
                        ForEach(chat.models) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: .infinity)
                    Button { preferences.refreshing = true; Task { await chat.refreshModels(); preferences.refreshing = false } } label: { Image(systemName: "arrow.clockwise") }.disabled(preferences.refreshing || chat.busy).help("刷新模型列表")
                }
                Button("验证一次翻译", action: verify).disabled(chat.modelID.isEmpty || chat.busy)
                Text("使用你授权的订阅额度；可用模型以当前账号为准。验证会发送一句示例英文。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
    private var permissionSection: some View {
        section("全电脑划词", icon: "cursorarrow.rays") {
            HStack {
                Label(preferences.trusted ? "辅助功能权限已开启" : "需要辅助功能权限", systemImage: preferences.trusted ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 12)).foregroundStyle(preferences.trusted ? Color.green : Color.secondary)
                Spacer()
                Button(preferences.trusted ? "打开系统设置" : "开启权限") { preferences.requestAccessibility() }
            }
            Text("划词后，将鼠标移到“译”上停留 0.3 秒，即可看到中文译文。部分软件不提供选区，请复制文字后使用快捷键。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("划词按钮位置", selection: $preferences.buttonPosition) {
                ForEach(ButtonPosition.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            HStack {
                Toggle("暂停自动划词", isOn: $preferences.paused).toggleStyle(.switch).controlSize(.small)
                Spacer(); Button("预览翻译浮窗", action: preview)
            }
            if !preferences.excluded.isEmpty {
                HStack { Text("已排除 \(preferences.excluded.count) 个软件").font(.caption).foregroundStyle(.secondary); Spacer(); Button("清除排除列表") { preferences.clearExclusions() } }
            }
        }
    }
    private var behaviorSection: some View {
        section("快捷键与启动", icon: "keyboard") {
            HStack {
                Text("翻译已复制文字").font(.system(size: 12)); Spacer()
                ShortcutRecorder(binding: preferences.shortcutBinding, onCandidate: updateShortcut, onRecording: shortcutRecording)
                    .frame(width: 205, height: 28)
            }
            Text("点击快捷键框后直接按下组合，Esc 取消。默认：Control + Command + Shift + T。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !preferences.shortcutMessage.isEmpty { Text(preferences.shortcutMessage).font(.caption).foregroundStyle(.orange) }
            Toggle("登录 Mac 时启动轻译", isOn: Binding(get: { preferences.launchAtLogin }, set: { preferences.setLoginItem($0) })).toggleStyle(.switch).controlSize(.small)
            if !preferences.generalMessage.isEmpty { Text(preferences.generalMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
