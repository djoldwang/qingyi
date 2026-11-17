import AppKit
import ApplicationServices
import Carbon

struct SelectionSnapshot {
    let text: String
    let anchor: NSRect?
    let pid: pid_t
    let range: String
    var fingerprint: String { "\(pid):\(range):\(text)" }
}

struct AXSelectionPayload {
    let text: String
    let bounds: CGRect?
    let range: String
}

// Injectable AX calls allow a Mail/WebKit fixture to exercise the marker path
// without opening real mail or needing Accessibility authorization in unit tests.
struct AXSelectionAccess {
    var attribute: (String) -> CFTypeRef?
    var parameter: (String, CFTypeRef) -> CFTypeRef?

    func selected() -> AXSelectionPayload? {
        let role = attribute(kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(kAXSubroleAttribute) as? String ?? ""
        guard role != "AXSecureTextField", subrole != "AXSecureTextField", attribute("AXProtectedContent") as? Bool != true else { return nil }
        if let direct = attribute(kAXSelectedTextAttribute) as? String, !TextPolicy.clean(direct).isEmpty {
            var bounds: CGRect?; var description = ""
            if let range = attribute(kAXSelectedTextRangeAttribute) {
                if CFGetTypeID(range) == AXValueGetTypeID() {
                    let value = range as! AXValue
                    var location = CFRange()
                    if AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &location) { description = "\(location.location),\(location.length)" }
                }
                bounds = Self.rect(parameter(kAXBoundsForRangeParameterizedAttribute, range))
            }
            return AXSelectionPayload(text: direct, bounds: bounds, range: description)
        }
        // WKWebView (including Mail's reading pane) exposes document selections as
        // opaque text-marker ranges instead of AXSelectedText/AXSelectedTextRange.
        if let marker = attribute("AXSelectedTextMarkerRange"),
           let selected = parameter("AXStringForTextMarkerRange", marker) as? String,
           !TextPolicy.clean(selected).isEmpty {
            let bounds = Self.rect(parameter("AXBoundsForTextMarkerRange", marker))
            let location = bounds.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? "unknown"
            return AXSelectionPayload(text: selected, bounds: bounds, range: "marker:" + location)
        }
        return nil
    }
    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value = value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(ax) == .cgRect, AXValueGetValue(ax, .cgRect, &rect), !rect.isEmpty,
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }
}

enum SelectionReader {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func read(pid: pid_t, mouse: CGPoint) -> SelectionSnapshot? {
        guard AXIsProcessTrusted(), pid != getpid() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        var candidates: [AXUIElement] = []
        if let focused = element(value(app, kAXFocusedUIElementAttribute)) { candidates.append(focused) }
        var hit: AXUIElement?
        // Search within the foreground app's tree. Its remote WebKit descendants
        // may belong to another PID; rejecting every different PID loses Mail text.
        if AXUIElementCopyElementAtPosition(app, Float(mouse.x), Float(mouse.y), &hit) == .success, let hit = hit { candidates.append(hit) }
        var visited: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(0.8)
        func inspect(_ node: AXUIElement) -> SelectionSnapshot? {
            AXUIElementSetMessagingTimeout(node, 0.08)
            let access = AXSelectionAccess(attribute: { value(node, $0) }, parameter: { name, parameter in
                var result: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(node, name as CFString, parameter, &result) == .success else { return nil }
                return result
            })
            guard let selected = access.selected() else { return nil }
            return SelectionSnapshot(text: selected.text, anchor: selected.bounds, pid: pid, range: selected.range)
        }
        for initial in candidates {
            var current: AXUIElement? = initial
            for _ in 0..<16 {
                guard let node = current, Date() < deadline, !visited.contains(where: { CFEqual($0, node) }) else { break }
                visited.append(node)
                if let snapshot = inspect(node) { return snapshot }
                let role = value(node, kAXRoleAttribute) as? String ?? ""
                let subrole = value(node, kAXSubroleAttribute) as? String ?? ""
                if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return nil }
                current = self.element(value(node, kAXParentAttribute))
            }
        }
        // Mail can leave focus on the message list while the selection lives in
        // its reading pane. Visit only container nodes of the focused window,
        // skipping mailbox/message tables, never reading their full text values.
        if let window = element(value(app, kAXFocusedWindowAttribute)) {
            var queue = [window]; var index = 0
            let containers: Set<String> = ["AXWindow", "AXSplitGroup", "AXScrollArea", "AXGroup", "AXUnknown", "AXLayoutArea", "AXWebArea"]
            while index < queue.count, index < 100, Date() < deadline {
                let node = queue[index]; index += 1
                AXUIElementSetMessagingTimeout(node, 0.05)
                let role = value(node, kAXRoleAttribute) as? String ?? ""
                guard containers.contains(role) else { continue }
                if role == "AXWebArea", let selected = inspect(node) { return selected }
                if role != "AXWebArea", let children = value(node, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.prefix(100 - min(queue.count, 100))) }
            }
        }
        return nil
    }
}

final class SelectionMonitor {
    var onSelection: ((SelectionSnapshot?) -> Void)?
    var onOutsideClick: ((NSPoint) -> Void)?
    var onScroll: (() -> Void)?
    var enabled = true
    private var global: Any?
    private var local: Any?
    private var activation: NSObjectProtocol?
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var pending: DispatchWorkItem?
    private var readInFlight = false
    private var revision = 0
    private let readQueue = DispatchQueue(label: "com.laowang.qingyi.selection", qos: .userInitiated)

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .keyUp, .keyDown, .scrollWheel]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] in self?.event($0) }
        local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 { self?.onScroll?() }
            return event
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
            self?.onSelection?(nil)
            self?.attachObserver()
        }
        attachObserver()
    }
    func attachObserver() {
        if let observer = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; observedApp = nil
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context = context else { return }
            Unmanaged<SelectionMonitor>.fromOpaque(context).takeUnretainedValue().schedule()
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created = created else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, element, kAXSelectedTextChangedNotification as CFString, context)
        AXObserverAddNotification(created, element, kAXFocusedUIElementChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created; observedApp = element
    }
    private func event(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            revision += 1; pending?.cancel(); onOutsideClick?(NSEvent.mouseLocation)
        case .leftMouseUp: schedule()
        case .keyUp:
            if event.modifierFlags.contains(.shift) || (event.modifierFlags.contains(.command) && event.keyCode == 0) { schedule() }
        case .keyDown:
            if event.keyCode == 53 { onScroll?() }
            else if !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.command) { revision += 1; onSelection?(nil) }
        case .scrollWheel: revision += 1; pending?.cancel(); onScroll?()
        default: break
        }
    }
    func schedule() {
        revision += 1; pending?.cancel()
        guard enabled, AXIsProcessTrusted() else { return }
        let work = DispatchWorkItem { [weak self] in self?.read() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }
    private func read() {
        guard enabled, !readInFlight, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        readInFlight = true
        let ticket = revision; let pid = app.processIdentifier
        let mouse = CGEvent(source: nil)?.location ?? .zero
        readQueue.async { [weak self] in
            let snapshot = SelectionReader.read(pid: pid, mouse: mouse)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.readInFlight = false
                guard self.enabled, self.revision == ticket, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    if self.enabled, self.revision != ticket { self.schedule() }
                    return
                }
                self.onSelection?(snapshot)
            }
        }
    }
    func stop() {
        revision += 1
        pending?.cancel()
        if let global = global { NSEvent.removeMonitor(global) }; global = nil
        if let local = local { NSEvent.removeMonitor(local) }; local = nil
        if let activation = activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }; activation = nil
        if let observer = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }; observer = nil
    }
    deinit { stop() }
}

struct ShortcutBinding: Codable, Equatable {
    let key: UInt32
    let modifiers: UInt32
    let keyName: String
    static let defaultClipboard = ShortcutBinding(key: 17, modifiers: UInt32(controlKey | cmdKey | shiftKey), keyName: "T")
    static let legacyDefault = ShortcutBinding(key: 17, modifiers: UInt32(optionKey | shiftKey), keyName: "T")
    func sameChord(as other: ShortcutBinding) -> Bool { key == other.key && modifiers == other.modifiers }
    var display: String { Self.modifierLabel(modifiers) + keyName }
    static func modifierLabel(_ modifiers: UInt32) -> String {
        [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(cmdKey), "⌘"), (UInt32(shiftKey), "⇧")].filter { modifiers & $0.0 != 0 }.map(\.1).joined()
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
    static func isModifierKey(_ key: UInt32) -> Bool { [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(key) }
    static func name(for key: UInt32, characters: String? = nil) -> String {
        let special: [UInt32: String] = [36:"↩", 48:"⇥", 49:"空格", 51:"⌫", 53:"Esc", 71:"Clear", 76:"⌅", 117:"⌦", 115:"Home", 119:"End", 116:"Page Up", 121:"Page Down", 123:"←", 124:"→", 125:"↓", 126:"↑", 122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5", 97:"F6", 98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12", 105:"F13", 107:"F14", 113:"F15", 106:"F16", 64:"F17", 79:"F18", 80:"F19", 90:"F20"]
        if let name = special[key] { return name }
        if let characters = characters, !characters.isEmpty, characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { return characters.uppercased() }
        let standard: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",50:"`",65:"小键盘 .",67:"小键盘 *",69:"小键盘 +",75:"小键盘 /",78:"小键盘 -",81:"小键盘 =",82:"小键盘 0",83:"小键盘 1",84:"小键盘 2",85:"小键盘 3",86:"小键盘 4",87:"小键盘 5",88:"小键盘 6",89:"小键盘 7",91:"小键盘 8",92:"小键盘 9"]
        return standard[key] ?? "键码 \(key)"
    }
    init(key: UInt32, modifiers: UInt32, keyName: String? = nil) {
        self.key = key; self.modifiers = modifiers; self.keyName = keyName ?? Self.name(for: key)
    }
    init?(event: NSEvent) {
        guard event.type == .keyDown, !event.isARepeat, !Self.isModifierKey(UInt32(event.keyCode)) else { return nil }
        self.init(key: UInt32(event.keyCode), modifiers: Self.carbonModifiers(event.modifierFlags), keyName: Self.name(for: UInt32(event.keyCode), characters: event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers))
    }
}

struct ShortcutPreferences {
    let defaults: UserDefaults
    static let storageKey = "clipboardShortcutBinding"
    var saved: ShortcutBinding? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(ShortcutBinding.self, from: data)
    }
    var legacy: ShortcutBinding? {
        guard let key = defaults.object(forKey: "shortcutKey") as? NSNumber,
              let modifiers = defaults.object(forKey: "shortcutModifiers") as? NSNumber else { return nil }
        return ShortcutBinding(key: key.uint32Value, modifiers: modifiers.uint32Value)
    }
    var preferred: ShortcutBinding {
        if let saved = saved { return saved }
        if let legacy = legacy, !legacy.sameChord(as: .legacyDefault) { return legacy }
        return .defaultClipboard
    }
    var migrationFallback: ShortcutBinding? {
        guard saved == nil, let legacy = legacy, legacy.sameChord(as: .legacyDefault) else { return nil }
        return legacy
    }
    func save(_ binding: ShortcutBinding) {
        // One encoded value is the source of truth; legacy fields are read only for migration.
        defaults.set(try? JSONEncoder().encode(binding), forKey: Self.storageKey)
    }
}

final class GlobalShortcut {
    var onPress: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var activeBinding: ShortcutBinding?
    private var activeID: UInt32 = 0
    private static var nextID: UInt32 = 1
    private(set) var suspended = false
    static let signature: OSType = 0x51494e47 // QING
    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context = context, let event = event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == GlobalShortcut.signature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            guard id.id == owner.activeID, !owner.suspended else { return OSStatus(eventNotHandledErr) }
            owner.onPress?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    static func isSystemReserved(_ binding: ShortcutBinding, hotKeys: [[String: Any]]) -> Bool {
        hotKeys.contains { item in
            (item[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true &&
            (item[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == binding.key &&
            (item[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == binding.modifiers
        }
    }
    @discardableResult func register(_ binding: ShortcutBinding) -> OSStatus {
        if reference != nil, activeBinding?.sameChord(as: binding) == true { return noErr }
        guard !ShortcutBinding.isModifierKey(binding.key) else { return OSStatus(paramErr) }
        var symbolic: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&symbolic) == noErr, let list = symbolic?.takeRetainedValue() as? [[String: Any]], Self.isSystemReserved(binding, hotKeys: list) { return OSStatus(eventHotKeyExistsErr) }
        let id = Self.nextID; Self.nextID &+= 1
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.key, binding.modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr, let replacement = replacement else { return status == noErr ? OSStatus(paramErr) : status }
        // Register first. An occupied new combination must never remove the old binding.
        let previous = reference
        reference = replacement; activeBinding = binding; activeID = id; suspended = false
        if let previous = previous { UnregisterEventHotKey(previous) }
        return noErr
    }
    @discardableResult func setSuspended(_ value: Bool) -> OSStatus {
        if value {
            suspended = true
            if let reference = reference { UnregisterEventHotKey(reference); self.reference = nil }
            return noErr
        }
        guard suspended else { return noErr }
        guard let binding = activeBinding else { suspended = false; return noErr }
        return register(binding)
    }
    deinit { if let reference = reference { UnregisterEventHotKey(reference) }; if let handler = handler { RemoveEventHandler(handler) } }
}
