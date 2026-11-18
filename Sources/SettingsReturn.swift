import AppKit
import CoreGraphics

// Keep the return policy independent of the workspace so races around window
// closing, activation and termination can be tested with a deterministic clock.
struct SystemSettingsReturnState {
    enum Outcome: String { case waiting, restore, cancelled }
    private(set) var isWaiting = false
    private(set) var targetPID: pid_t?
    private var ownerPID: pid_t = 0
    private var startedAt: TimeInterval = 0
    private var missingWindowSince: TimeInterval?
    private var otherApplicationSince: TimeInterval?

    mutating func begin(ownerPID: pid_t, at time: TimeInterval) {
        self = Self()
        self.ownerPID = ownerPID; startedAt = time; isWaiting = true
    }
    mutating func cancel() { self = Self() }
    mutating func update(at time: TimeInterval, systemSettingsPID: pid_t?, foregroundPID: pid_t?,
                         hasSystemSettingsWindow: Bool?, sourceAvailable: Bool) -> Outcome {
        guard isWaiting else { return .waiting }
        guard sourceAvailable else { cancel(); return .cancelled }
        guard let targetPID = targetPID else {
            if let systemSettingsPID = systemSettingsPID, foregroundPID == systemSettingsPID,
               hasSystemSettingsWindow == true {
                self.targetPID = systemSettingsPID
            } else if time - startedAt >= 10 {
                cancel(); return .cancelled
            }
            return .waiting
        }
        if systemSettingsPID != targetPID { cancel(); return .restore }
        guard let hasWindow = hasSystemSettingsWindow else {
            // Missing WindowServer data is not evidence that a window closed.
            cancel(); return .cancelled
        }
        if !hasWindow {
            if missingWindowSince == nil { missingWindowSince = time }
            if time - missingWindowSince! >= 0.35 { cancel(); return .restore }
        } else {
            missingWindowSince = nil
            // A user return while the system window still exists ends the
            // handoff. An automatic activation after it closes still needs to
            // raise the original window, even if our process is already active.
            if foregroundPID == ownerPID { cancel(); return .cancelled }
            if let foregroundPID = foregroundPID, foregroundPID != targetPID {
                // Allow closing animations/activation notifications to settle.
                // A still-visible settings window means a deliberate app switch.
                if otherApplicationSince == nil { otherApplicationSince = time }
                if time - otherApplicationSince! >= 0.35 { cancel(); return .cancelled }
            } else { otherApplicationSince = nil }
        }
        return .waiting
    }
}

@MainActor
final class SystemSettingsReturnCoordinator {
    private var state = SystemSettingsReturnState()
    private weak var sourceWindow: NSWindow?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var restorationDeadline: TimeInterval?
    private var restorationID: UUID?
    private var windowOrdered = false
    private var originalAnimationBehavior: NSWindow.AnimationBehavior?
    // Native test fixtures can record the outcome without changing production UI.
    var onOutcome: ((SystemSettingsReturnState.Outcome) -> Void)?

    func begin(window: NSWindow) {
        cancel()
        sourceWindow = window
        originalAnimationBehavior = window.animationBehavior
        window.animationBehavior = .none
        state.begin(ownerPID: getpid(), at: ProcessInfo.processInfo.systemUptime)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observe(workspace, name: name) { [weak self] in self?.sample() }
        }
        observe(workspace, name: NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.cancel() }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observe(.default, name: name, object: window) { [weak self] in self?.cancel() }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func cancel() {
        state.cancel()
        restorationDeadline = nil
        restorationID = nil
        windowOrdered = false
        stopWatching()
        if let window = sourceWindow, let animation = originalAnimationBehavior {
            window.animationBehavior = animation
        }
        originalAnimationBehavior = nil
        sourceWindow = nil
    }
    private func stopWatching() {
        timer?.invalidate(); timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
    private func observe(_ center: NotificationCenter, name: Notification.Name, object: Any? = nil, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }
    private func sample() {
        guard state.isWaiting else { return }
        let settings: NSRunningApplication?
        if let pid = state.targetPID {
            settings = NSRunningApplication(processIdentifier: pid).flatMap { $0.isTerminated ? nil : $0 }
        } else {
            settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        }
        let window = sourceWindow
        let outcome = state.update(at: ProcessInfo.processInfo.systemUptime,
            systemSettingsPID: settings?.processIdentifier,
            foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            hasSystemSettingsWindow: settings.flatMap { visibleSettingsWindow(pid: $0.processIdentifier) },
            sourceAvailable: window?.isVisible == true && window?.isMiniaturized == false)
        guard outcome != .waiting else { return }
        stopWatching()
        if outcome == .restore, let window = window, window.isVisible, !window.isMiniaturized {
            // This is a one-shot activation of the existing window: never reopen
            // settings, reset its navigation, or change its window level.
            restoreExistingWindow()
            return
        }
        cancel()
        onOutcome?(outcome)
    }
    private func restoreExistingWindow() {
        let id = UUID()
        restorationID = id
        windowOrdered = false
        restorationDeadline = ProcessInfo.processInfo.systemUptime + 1
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.cancel() }
        if let window = sourceWindow {
            for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                observe(.default, name: name, object: window) { [weak self] in self?.cancel() }
            }
        }
        observe(.default, name: NSApplication.didBecomeActiveNotification) { [weak self] in
            DispatchQueue.main.async { self?.completeRestoration(id: id) }
        }
        // A timeout only cleans up. It never repeatedly orders the window.
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.restorationID == id else { return }
                self.cancel(); self.onOutcome?(.cancelled)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        DispatchQueue.main.async { [weak self] in self?.completeRestoration(id: id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.completeRestoration(id: id) }
    }
    private func completeRestoration(id: UUID) {
        guard restorationID == id, let deadline = restorationDeadline else { return }
        guard let window = sourceWindow, window.isVisible, !window.isMiniaturized,
              ProcessInfo.processInfo.systemUptime <= deadline else {
            cancel(); onOutcome?(.cancelled); return
        }
        // Activation is asynchronous for accessory apps. Ordering the window
        // before it completes can leave the app active with no key window.
        guard NSApp.isActive else { return }
        if !windowOrdered {
            windowOrdered = true
            window.makeMain()
            window.makeKeyAndOrderFront(nil)
        } else if !window.isKeyWindow {
            // A delayed focus confirmation must not trigger another ordering
            // animation or bring the window forward a second time.
            window.makeKey()
        }
        if window.isKeyWindow {
            cancel()
            onOutcome?(.restore)
        }
    }
    private func visibleSettingsWindow(pid: pid_t) -> Bool? {
        // Only process/layer/bounds metadata is used. No screen image or window
        // contents are requested, and no screen-recording permission is needed.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.width > 80 && rect.height > 80
        }
    }
    deinit {
        timer?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
        if let window = sourceWindow, let animation = originalAnimationBehavior {
            DispatchQueue.main.async { [weak window] in window?.animationBehavior = animation }
        }
    }
}
