import AppKit

// Opt-in local diagnostics contain event metadata only, never source text or credentials.
enum HoverDiagnostics {
    static var enabled: Bool { CommandLine.arguments.contains("--hover-trace") }
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "hover: \(message())\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

// Hover gestures do not register or consume system shortcuts.
enum HoverTrigger: String, CaseIterable, Identifiable, Codable {
    case control, shift, option, command, longPress
    var id: String { rawValue }
    var title: String {
        switch self {
        case .control: return "⌃ Control"
        case .shift: return "⇧ Shift"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .longPress: return "长按鼠标左键"
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .shift: return .shift
        case .option: return .option
        case .command: return .command
        case .longPress: return []
        }
    }
}

enum HoverActivation: String, CaseIterable, Identifiable {
    case release, hold, mouseHold
    var id: String { rawValue }
    var title: String {
        switch self {
        case .release: return "单次按键"
        case .hold: return "按住辅助键"
        case .mouseHold: return "长按鼠标左键"
        }
    }
    var hint: String {
        switch self {
        case .release: return "将鼠标放在段落上，单独按下并松开辅助键即可翻译；组合按键、点击或移动会取消触发。"
        case .hold: return "将鼠标放在段落上，按住辅助键 0.6 秒即可翻译；组合按键、点击或移动会取消触发。"
        case .mouseHold: return "将鼠标放在段落上，按住左键 0.6 秒即可翻译。移动超过 6 点会取消触发，正常拖选不受影响。"
        }
    }
}

struct HoverGesture {
    static let holdDuration: TimeInterval = 0.6
    static let movementTolerance: CGFloat = 6
    enum Input: Equatable { case flags, keyDown, keyUp, leftDown, leftUp, otherMouseDown, move, scroll, cancel }
    enum Action: Equatable { case none, trigger, suppressSelection }
    var trigger: HoverTrigger = .longPress
    var activation: HoverActivation = .release
    private(set) var origin: CGPoint?
    private(set) var holdDeadline: TimeInterval?
    private(set) var fired = false
    private var armedModifier = false
    private var previousFlags: NSEvent.ModifierFlags = []
    private var keysDown = Set<UInt16>()
    private var blocked = false

    mutating func cancel() {
        origin = nil; holdDeadline = nil; armedModifier = false; fired = false
        blocked = true
    }
    mutating func reset() { self = HoverGesture(trigger: trigger, activation: activation) }
    mutating func reconcileKeys(isDown: (UInt16) -> Bool) {
        // Global monitors do not receive releases delivered to our own windows
        // or consumed by another app. Discard only physically released keys.
        keysDown = keysDown.filter(isDown)
    }
    mutating func input(_ kind: Input, point: CGPoint, time: TimeInterval,
                        flags rawFlags: NSEvent.ModifierFlags = [], key: UInt16 = 0, buttons: Int = 0) -> Action {
        let flags = rawFlags.intersection([.control, .shift, .option, .command, .function])
        switch kind {
        case .cancel: cancel()
        case .keyDown:
            keysDown.insert(key); cancel()
        case .keyUp: keysDown.remove(key)
        case .scroll, .otherMouseDown: cancel()
        case .leftDown:
            cancel()
            if trigger == .longPress, flags.isEmpty, keysDown.isEmpty, buttons & ~1 == 0 {
                origin = point; holdDeadline = time + Self.holdDuration; blocked = false
            }
        case .leftUp:
            let suppress = trigger == .longPress && fired
            origin = nil; holdDeadline = nil; fired = false; armedModifier = false
            return suppress ? .suppressSelection : .none
        case .move:
            if let origin = origin, hypot(point.x - origin.x, point.y - origin.y) > Self.movementTolerance {
                // Once fired, keep owning this mouse-up even if the pointer moves.
                self.origin = nil; holdDeadline = nil; armedModifier = false; blocked = true
            }
        case .flags:
            defer { previousFlags = flags }
            if trigger == .longPress {
                if !flags.isEmpty { origin = nil; holdDeadline = nil }
                return .none
            }
            if flags.isEmpty {
                let fire = activation == .release && armedModifier && !blocked && buttons == 0 && keysDown.isEmpty
                armedModifier = false; origin = nil; holdDeadline = nil; fired = false; blocked = false
                return fire ? .trigger : .none
            }
            if previousFlags.isEmpty, flags == trigger.flag, buttons == 0, keysDown.isEmpty {
                armedModifier = true; origin = point; blocked = false; fired = false
                if activation == .hold { holdDeadline = time + Self.holdDuration }
            } else if flags != trigger.flag {
                armedModifier = false; origin = nil; holdDeadline = nil; blocked = true
            }
        }
        return .none
    }
    mutating func tick(time: TimeInterval, point: CGPoint, buttons: Int) -> Action {
        guard let deadline = holdDeadline, !fired else { return .none }
        guard (trigger == .longPress ? buttons == 1 : buttons == 0 && previousFlags == trigger.flag && armedModifier && !blocked && keysDown.isEmpty), let origin = origin,
              hypot(point.x - origin.x, point.y - origin.y) <= Self.movementTolerance else { cancel(); return .none }
        guard time >= deadline else { return .none }
        fired = true; holdDeadline = nil
        return .trigger
    }
}

@MainActor
final class HoverMonitor {
    var onTrigger: ((CGPoint) -> Void)?
    var onCancelRead: (() -> Void)?
    var permitsTrigger: ((NSPoint) -> Bool)?
    private(set) var gesture = HoverGesture()
    private var timer: Timer?
    var enabled = false
    var isKeyDown: (UInt16) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: $0) }
    var pressedMouseButtons: () -> Int = { NSEvent.pressedMouseButtons }
    func configure(enabled: Bool, trigger: HoverTrigger, activation: HoverActivation? = nil) {
        cancel(); self.enabled = enabled
        let mode = activation ?? (trigger == .longPress ? .mouseHold : .release)
        gesture = HoverGesture(trigger: mode == .mouseHold ? .longPress : (trigger == .longPress ? .option : trigger), activation: mode)
        HoverDiagnostics.log("configured enabled=\(enabled) trigger=\(trigger.rawValue)")
    }
    func cancel() {
        timer?.invalidate(); timer = nil; gesture.reset(); onCancelRead?()
    }
    // Returns true only to skip Qingyi's own automatic selection processing.
    // The source app always receives the original event.
    func event(_ event: NSEvent) -> Bool {
        guard enabled else { return false }
        let kind: HoverGesture.Input
        switch event.type {
        case .flagsChanged: kind = .flags
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .leftMouseDown: kind = .leftDown
        case .leftMouseUp: kind = .leftUp
        case .rightMouseDown, .otherMouseDown: kind = .otherMouseDown
        case .mouseMoved, .leftMouseDragged: kind = .move
        case .scrollWheel: kind = .scroll
        default: return false
        }
        let point = NSEvent.mouseLocation
        let buttons = pressedMouseButtons()
        if kind == .leftDown || kind == .flags { gesture.reconcileKeys(isDown: isKeyDown) }
        if kind != .move { HoverDiagnostics.log("event=\(event.type.rawValue) flags=\(event.modifierFlags.rawValue) buttons=\(buttons)") }
        let action = gesture.input(kind, point: point, time: event.timestamp, flags: event.modifierFlags,
                                   key: [.keyDown, .keyUp, .flagsChanged].contains(event.type) ? event.keyCode : 0, buttons: buttons)
        if [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains(event.type) { onCancelRead?() }
        timer?.invalidate(); timer = nil
        if let deadline = gesture.holdDeadline {
            let next = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self, self.enabled else { return }
                    let buttons = self.pressedMouseButtons()
                    HoverDiagnostics.log("hold timer buttons=\(buttons)")
                    if self.gesture.tick(time: ProcessInfo.processInfo.systemUptime, point: NSEvent.mouseLocation,
                                         buttons: buttons) == .trigger { self.fire() }
                }
            }
            timer = next; RunLoop.main.add(next, forMode: .common)
        }
        if action == .trigger { fire() }
        return action == .suppressSelection
    }
    private func fire() {
        guard permitsTrigger?(NSEvent.mouseLocation) != false else { HoverDiagnostics.log("trigger blocked"); return }
        HoverDiagnostics.log("trigger accepted")
        onTrigger?(CGEvent(source: nil)?.location ?? .zero)
    }
}
