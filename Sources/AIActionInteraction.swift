import AppKit
import SwiftUI

enum AIActionModifier: String, CaseIterable, Identifiable, Codable {
    case option, control, shift, command
    var id: String { rawValue }
    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        case .command: return .command
        }
    }
}

enum AIActionTrigger: String, CaseIterable, Identifiable, Codable {
    case press, hold
    var id: String { rawValue }
    var title: String { self == .press ? "单次按下" : "按住显示" }
}

// Keep pending input independent of Accessibility while a drag selection is read.
struct AIActionGesture {
    enum Input { case flags, keyDown, keyUp, leftDown, leftUp, scroll, otherMouseDown }
    private(set) var deadline: TimeInterval?
    private(set) var flags: NSEvent.ModifierFlags = []
    private(set) var fired = false
    private var blocked = false
    private var dragging = false
    private var keys = Set<UInt16>()
    mutating func reconcileKeys(isDown: (UInt16) -> Bool) { keys = keys.filter(isDown) }
    mutating func cancel() {
        deadline = nil
        blocked = !flags.isEmpty
        dragging = false
    }
    mutating func input(_ kind: Input, flags raw: NSEvent.ModifierFlags, key: UInt16 = 0,
                        time: TimeInterval, modifier: AIActionModifier) {
        let previousFlags = flags
        flags = raw.intersection([.option, .control, .shift, .command, .function])
        // Mouse events also tell us the modifier has been released, even if
        // its flags-changed event went to a different window.
        if flags.isEmpty {
            deadline = nil
            blocked = false
            fired = false
        }
        switch kind {
        case .flags:
            guard !flags.isEmpty else { return }
            if flags != modifier.flag { cancel() }
            else if previousFlags.isEmpty && !blocked && keys.isEmpty {
                deadline = time; fired = false
            }
        case .keyDown: keys.insert(key); cancel()
        case .keyUp: keys.remove(key)
        case .leftDown:
            dragging = true; fired = false
            if flags == modifier.flag && !blocked && keys.isEmpty && deadline == nil { deadline = time }
        case .leftUp: dragging = false
        case .scroll, .otherMouseDown: cancel()
        }
    }
    mutating func tick(time: TimeInterval, hasSelection: Bool, mouseDown: Bool) -> Bool {
        guard let deadline, time >= deadline, hasSelection, !mouseDown, !dragging, !blocked, !fired else { return false }
        fired = true; self.deadline = nil; return true
    }
}

final class AIActionPanel: NSPanel {
    enum Presentation { case automatic, modifier }
    var presentation: Presentation = .modifier
    var onKey: ((UInt16) -> Bool)?
    var onPointer: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { presentation == .modifier }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved || event.type == .leftMouseDragged { onPointer?(event) }
        if event.type == .keyDown, onKey?(event.keyCode) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class AIActionPopupState: ObservableObject {
    @Published var operations: [TextOperation] = []
    @Published var selected = 0
    @Published var hovered: Int?
    @Published var keyboardNavigation = false
    var itemFrames: [Int: CGRect] = [:]
    var choose: (TextOperation) -> Void = { _ in }
    func hover(_ index: Int, inside: Bool) {
        if inside {
            if hovered != index { hovered = index }
            if selected != index { selected = index }
            if keyboardNavigation { keyboardNavigation = false }
        } else if hovered == index { hovered = nil }
    }
    func trackPointer(_ point: CGPoint, bounds: CGRect) {
        guard bounds.contains(point), !itemFrames.isEmpty else { hovered = nil; return }
        // Use contiguous cells, including separators and the thin outer padding.
        let visible = itemFrames.filter { $0.value.intersects(bounds) }
        let hit = visible.first { $0.value.insetBy(dx: -4.5, dy: -3).contains(point) }
        let closest = visible.min { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) }
        if let index = (hit ?? closest)?.key { hover(index, inside: true) }
        else { hovered = nil }
    }
}

@MainActor
final class AIActionPopupHostingView: NSHostingView<AIActionPopupView> {
    private var pointerArea: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area); pointerArea = area
    }
    func track(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        rootView.state.trackPointer(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y), bounds: bounds)
    }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { rootView.state.hovered = nil }
}

private struct AIActionItemFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

@MainActor
enum AIActionToolbarLayout {
    static let height: CGFloat = 32
    static let buttonHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 9
    static func buttonWidth(_ name: String) -> CGFloat {
        let text = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        return min(160, max(56, ceil(text) + 16))
    }
    static func size(operations: [TextOperation], availableWidth: CGFloat) -> NSSize {
        let content = operations.reduce(CGFloat.zero) { $0 + buttonWidth($1.action) } + CGFloat(max(0, operations.count - 1)) * 9
        return NSSize(width: min(content + 6, 900, max(1, availableWidth - 16)), height: height)
    }
}

@MainActor
final class AIActionPopup {
    let panel = AIActionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let state = AIActionPopupState()
    var operations: [TextOperation] { state.operations }
    var presentation: AIActionPanel.Presentation { panel.presentation }
    var selected: Int { get { state.selected } set { state.selected = newValue } }
    var onSelect: ((TextOperation) -> Void)?
    var onDismiss: (() -> Void)?
    #if QINGYI_TESTING
    var testAnchor: NSPoint?
    #endif
    init() {
        panel.isFloatingPanel = true; panel.level = .screenSaver; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        state.choose = { [weak self] in self?.choose($0) }
        let hosting = AIActionPopupHostingView(rootView: AIActionPopupView(state: state))
        panel.contentView = hosting
        panel.onPointer = { [weak hosting] in hosting?.track($0) }
        panel.onKey = { [weak self] key in self?.key(key) ?? false }
    }
    func show(operations: [TextOperation], position: ButtonPosition, presentation: AIActionPanel.Presentation, point: NSPoint = NSEvent.mouseLocation) {
        guard !operations.isEmpty else { hide(); return }
        #if QINGYI_TESTING
        let point = testAnchor ?? point
        #endif
        if presentation == .automatic && panel.isKeyWindow { panel.orderOut(nil) }
        panel.presentation = presentation
        panel.title = presentation == .automatic ? "划词动作栏" : "自定义 AI 动作"
        panel.setAccessibilityTitle(panel.title)
        state.operations = operations; selected = 0; state.hovered = nil; state.keyboardNavigation = false
        let screen = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = AIActionToolbarLayout.size(operations: operations, availableWidth: screen.width)
        let origin = position.placedOrigin(relativeTo: point, size: size, screen: screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        switch presentation {
        case .automatic: panel.orderFrontRegardless()
        case .modifier: panel.makeKeyAndOrderFront(nil)
        }
    }
    func hide() {
        panel.orderOut(nil); onSelect = nil
        state.operations = []; selected = 0; state.hovered = nil; state.keyboardNavigation = false
    }
    func choose(_ operation: TextOperation) {
        guard panel.isVisible, let current = operations.first(where: { $0.key == operation.key }) else { return }
        onSelect?(current)
    }
    func key(_ key: UInt16) -> Bool {
        guard presentation == .modifier, panel.isVisible else { return false }
        switch key {
        case 53: onDismiss?()
        case 124, 125:
            state.hovered = nil; state.keyboardNavigation = true
            selected = min(selected + 1, max(0, operations.count - 1))
        case 123, 126:
            state.hovered = nil; state.keyboardNavigation = true
            selected = max(0, selected - 1)
        case 36, 76:
            if operations.indices.contains(selected) { choose(operations[selected]) }
        default: return false
        }
        return true
    }
}

@MainActor
struct AIActionPopupView: View {
    @ObservedObject var state: AIActionPopupState
    var embedded = false
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(state.operations.enumerated()), id: \.element.key) { index, operation in
                            if index > 0 { separator }
                            let button = Button { state.choose(operation) } label: {
                                Text(operation.action).lineLimit(1).truncationMode(.tail)
                                    .padding(.horizontal, 8)
                                    .frame(width: AIActionToolbarLayout.buttonWidth(operation.action), height: AIActionToolbarLayout.buttonHeight)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(state.hovered == index ? Color.white : Color.primary)
                                .background(state.hovered == index ? Color(nsColor: SelectionEntryAppearance.background(hovered: false)) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(state.keyboardNavigation && state.selected == index ? Color.primary.opacity(0.25) : .clear, lineWidth: 1)
                                    .allowsHitTesting(false))
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: AIActionItemFrames.self, value: [index: geometry.frame(in: .named("actionToolbar"))])
                                })
                                .accessibilityLabel(operation.action)
                                .accessibilityAddTraits(state.selected == index ? .isSelected : [])
                                .help(operation.action).id(operation.key)
                            if embedded {
                                button.onHover { inside in state.hover(index, inside: inside) }
                            } else {
                                button
                            }
                        }
                    }
                }.frame(height: AIActionToolbarLayout.buttonHeight).clipped()
                    .onChange(of: state.selected) { _, index in
                    if state.keyboardNavigation, state.operations.indices.contains(index) { reader.scrollTo(state.operations[index].key, anchor: .center) }
                }
            }
        }.padding(3).frame(height: AIActionToolbarLayout.height)
            .coordinateSpace(name: "actionToolbar")
            .onPreferenceChange(AIActionItemFrames.self) { state.itemFrames = $0 }
            .transaction { $0.animation = nil }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: AIActionToolbarLayout.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: AIActionToolbarLayout.cornerRadius)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
    }
    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 12).padding(.horizontal, 4)
    }
}
