import AppKit
import Combine

// Runs the production panel, native menu and selection monitor with fixture
// results only. No defaults, real credentials or network requests are used.
@MainActor
final class NativeModelMenuFixture: NSObject, NSApplicationDelegate {
    let floating = FloatingController()
    let monitor = SelectionMonitor()
    var session: TranslationSession
    let first: TranslationChoice
    let second: TranslationChoice
    private var outsideCloseRequests = 0
    private var escapeCloseRequests = 0
    private var explicitCloseRequests = 0
    private var settingsRequests = 0
    private var retryRequests = 0
    private var lastMenuEnd: TimeInterval = 0
    private var closeDiagnostic: [String: Any] = [:]
    private var observers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    override init() {
        first = TranslationChoice(target: .init(service: .customAPI("fixture-a"), modelID: "default"), providerName: "测试 API A", modelName: "默认模型 A")
        second = TranslationChoice(target: .init(service: .customAPI("fixture-b"), modelID: "alternate"), providerName: "测试 API B", modelName: "临时模型 B")
        session = TranslationSession(source: "Small steps make complex things easier to understand.", defaultChoice: first)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        floating.onSettings = { [weak self] in self?.settingsRequests += 1; self?.record() }
        floating.onRetry = { [weak self] in self?.retryRequests += 1; self?.record() }
        floating.onClose = { [weak self] in
            guard let self = self else { return }
            self.explicitCloseRequests += 1
            let event = NSApp.currentEvent
            self.closeDiagnostic = [
                "currentEventType": event.map { Int($0.type.rawValue) } ?? -1,
                "eventTimestamp": event?.timestamp ?? -1,
                "systemUptime": ProcessInfo.processInfo.systemUptime,
                "modelMenuTracking": self.floating.modelMenuTracking,
                "lastMenuEnd": self.lastMenuEnd
            ]
            self.render()
        }
        floating.onModelMenuTracking = { [weak self] tracking in
            if !tracking { self?.lastMenuEnd = ProcessInfo.processInfo.systemUptime }
            self?.monitor.setModelMenuTracking(tracking)
        }
        monitor.isInternalInteraction = { [weak self] point in
            guard let self = self else { return false }
            return NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == self.floating.resultPanel.windowNumber
        }
        monitor.onOutsideClick = { [weak self] point in
            guard let self = self, !self.floating.contains(point) else { return }
            if !self.floating.state.pinned { self.outsideCloseRequests += 1; self.render() }
        }
        monitor.onScroll = { [weak self] in
            if self?.floating.state.pinned == false { self?.escapeCloseRequests += 1; self?.render() }
        }
        monitor.onCancel = { [weak self] in self?.escapeCloseRequests += 1; self?.render() }
        monitor.onMenuCancel = { ModelMenuButton.cancelPresentedMenu() }
        floating.onSelectModel = { [weak self] choice, id in
            guard let self = self, self.session.id == id, self.session.select(choice) else { return }
            self.render()
        }
        floating.onRestoreModel = { [weak self] id in
            guard let self = self, self.session.id == id, self.session.restoreDefault() else { return }
            self.render()
        }
        floating.onLoadModels = { [weak self] id in
            guard let self = self, self.session.id == id else { return }
            let chat = TranslationChoice(target: .init(service: .chatGPT("fixture-account"), modelID: "fixture-chat"), providerName: "测试 ChatGPT", modelName: "测试 GPT 模型")
            self.floating.state.modelGroups[self.floating.state.modelGroups.count - 1] = .init(name: "测试 ChatGPT", choices: [chat])
            self.floating.state.modelMenuMessage = "模型已加载（测试数据）"
        }
        floating.showResult(source: session.source, preview: true)
        floating.state.modelGroups = [
            .init(name: first.providerName, choices: [first]),
            .init(name: second.providerName, choices: [second,
                TranslationChoice(target: .init(service: .customAPI("fixture-b"), modelID: "long"), providerName: "测试 API B", modelName: "长译文测试模型"),
                TranslationChoice(target: .init(service: .customAPI("fixture-b"), modelID: "error"), providerName: "测试 API B", modelName: "一个用于验证错误工具栏截断行为的很长模型显示名称")
            ] + (1...30).map {
                TranslationChoice(target: .init(service: .customAPI("fixture-b"), modelID: "extra-\($0)"), providerName: "测试 API B", modelName: "测试模型 \($0)")
            }),
            .init(name: "测试 ChatGPT", choices: [], canLoadChatGPT: true)
        ]
        render()
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: floating.resultPanel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record() }
            })
        }
        subscription = floating.state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.record() }
        }
        floating.resultPanel.makeKeyAndOrderFront(nil)
        monitor.start(); NSApp.activate(ignoringOtherApps: true)
        record()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floating.state.source = session.source; render()
        floating.resultPanel.makeKeyAndOrderFront(nil); return true
    }
    private func render() {
        floating.state.sessionID = session.id; floating.state.choice = session.choice; floating.state.defaultChoice = session.defaultChoice
        floating.state.modelSelectionEnabled = true; floating.state.temporaryModel = session.temporary
        // Keep this fixture visible and count close callbacks instead. The AX
        // driver may activate Dock/other windows while targeting a utility panel.
        floating.state.status = "测试 · 外部 \(outsideCloseRequests) · Esc \(escapeCloseRequests) · 关闭 \(explicitCloseRequests)"
        floating.state.error = session.choice?.target.modelID == "error"
        floating.state.complete = !floating.state.error
        floating.state.text = session.choice?.target.modelID == "long" ? String(repeating: "这是一段用于验证长译文自适应高度与内部滚动的模拟文本。", count: 200) : "一步一步来，复杂的事情也能变得容易理解。\n\n当前：\(session.choice!.label)"
        if floating.state.error { floating.state.text = "API 密钥无效或已过期，请编辑提供商配置。（HTTP 401）" }
    }
    private func record() {
        let frame = floating.resultPanel.frame
        let screen = floating.resultPanel.screen?.visibleFrame ?? .zero
        let value: [String: Any] = [
            "model": session.choice?.target.modelID ?? "", "temporary": session.temporary,
            "pinned": floating.state.pinned, "frame": [frame.minX, frame.minY, frame.width, frame.height],
            "visibleScreen": [screen.minX, screen.minY, screen.width, screen.height],
            "outsideCloseRequests": outsideCloseRequests, "escapeCloseRequests": escapeCloseRequests,
            "explicitCloseRequests": explicitCloseRequests, "closeDiagnostic": closeDiagnostic,
            "settingsRequests": settingsRequests, "retryRequests": retryRequests,
            "realCredentials": false, "realNetworkRequests": false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("state.json"), options: .atomic)
        }
    }
}

extension QingyiTests {
    @MainActor static func runNativeModelMenuFixture() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = NativeModelMenuFixture()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
