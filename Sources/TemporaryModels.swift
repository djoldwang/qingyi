import AppKit
import SwiftUI

struct TranslationTarget: Hashable, Codable {
    enum Service: Hashable, Codable { case customAPI(String), chatGPT(String) }
    let service: Service
    let modelID: String
    var usesChatGPT: Bool { if case .chatGPT = service { return true }; return false }
}

struct TranslationChoice: Equatable, Identifiable {
    let target: TranslationTarget
    let providerName: String
    let modelName: String
    var id: TranslationTarget { target }
    var label: String { "\(providerName) · \(modelName)" }
}

struct TranslationModelGroup {
    let name: String
    let choices: [TranslationChoice]
    var canLoadChatGPT = false
}

// Deliberately not Codable: this selection must never be persisted.
struct TranslationSession {
    enum Origin { case standard, clipboard, hover, screenshot }
    let id = UUID()
    let source: String
    let origin: Origin
    let operation: TextOperation
    let instructions: String?
    let defaultChoice: TranslationChoice?
    private(set) var choice: TranslationChoice?
    private(set) var runID = UUID()
    init(source: String, defaultChoice: TranslationChoice?, operation: TextOperation = .translation, instructions: String? = nil, origin: Origin = .standard) {
        self.source = source; self.defaultChoice = defaultChoice; choice = defaultChoice; self.operation = operation
        self.instructions = instructions; self.origin = origin
    }
    var temporary: Bool { choice?.target != defaultChoice?.target }
    @discardableResult mutating func select(_ next: TranslationChoice) -> Bool {
        guard choice?.target != next.target else { return false }
        choice = next; runID = UUID(); return true
    }
    @discardableResult mutating func restoreDefault() -> Bool {
        guard let initial = defaultChoice else { return false }
        return select(initial)
    }
    mutating func restart() { runID = UUID() }
    func accepts(sessionID: UUID, runID: UUID) -> Bool { id == sessionID && self.runID == runID }

    func alternativeActions(_ orderedOperations: [TextOperation], polishingEnabled: Bool) -> [TextOperation] {
        guard operation.aiOnly else { return [] }
        let text = TextPolicy.clean(source)
        guard !text.isEmpty, text.count <= TextPolicy.maximumLength else { return [] }
        return orderedOperations.filter { candidate in
            switch candidate {
            case .translation: return false
            case .polishing:
                return operation != .polishing && polishingEnabled && (try? TextPolicy.validate(text, operation: .polishing)) != nil
            case .custom(let action):
                return action.enabled && action.id != operation.customAction?.id
            }
        }
    }
}

struct TemporaryModelPicker: NSViewRepresentable {
    @ObservedObject var state: FloatingState
    var tracking: (Bool) -> Void
    var select: (TranslationChoice, UUID) -> Void
    var restore: (UUID) -> Void
    var load: (UUID) -> Void
    func makeNSView(context: Context) -> ModelMenuButton { ModelMenuButton() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ModelMenuButton, context: Context) -> CGSize? {
        NSSize(width: min(proposal.width ?? nsView.intrinsicContentSize.width, nsView.intrinsicContentSize.width), height: 24)
    }
    func updateNSView(_ button: ModelMenuButton, context: Context) {
        if button.sessionID != state.sessionID {
            button.cancelMenu()
            button.sessionID = state.sessionID
        }
        button.title = state.choice?.modelName ?? "选择\(state.operation.action)模型"
        button.isEnabled = state.modelSelectionEnabled
        button.toolTip = "\(state.choice?.label ?? "选择模型")\n\(state.status)\(state.temporaryModel ? " · 仅本次" : "")\n点击切换模型，仅本次生效；将完整原文发送给所选服务并重新\(state.operation.action)。"
        button.setAccessibilityLabel("临时切换\(state.operation.action)模型")
        button.operation = state.operation
        button.setAccessibilityValue(state.choice?.label ?? "未选择模型")
        button.menuContent = { [state] in
            (state.modelGroups, state.choice, state.defaultChoice, state.modelMenuMessage, state.loadingChatGPTModels)
        }
        button.onTracking = tracking; button.onSelect = select; button.onRestore = restore; button.onLoad = load
    }
}

final class ModelMenuButton: NSButton {
    var operation: TextOperation = .translation
    typealias MenuContent = ([TranslationModelGroup], TranslationChoice?, TranslationChoice?, String, Bool)
    var sessionID = UUID()
    var menuContent: (() -> MenuContent)?
    var onTracking: ((Bool) -> Void)?
    var onSelect: ((TranslationChoice, UUID) -> Void)?
    var onRestore: ((UUID) -> Void)?
    var onLoad: ((UUID) -> Void)?
    private var activeMenu: NSMenu?
    private var hovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private static weak var presentingButton: ModelMenuButton?
    static func cancelPresentedMenu() { presentingButton?.cancelMenu() }
    private enum Action { case select(TranslationChoice), restore, load }
    private var selectedAction: Action?
    private var actions: [Int: Action] = [:]
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = "选择翻译模型"; isBordered = false; alignment = .left
        font = .systemFont(ofSize: 11, weight: .medium); lineBreakMode = .byTruncatingMiddle
        target = self; action = #selector(openMenu)
        setAccessibilityLabel("临时切换翻译模型")
        setAccessibilityRole(.popUpButton)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium)]).width) + 30, height: 24)
    }
    // Reserve the arrow independently of the title so truncation cannot hide it.
    var titleRect: NSRect {
        NSRect(x: 8, y: (bounds.height - 14) / 2, width: max(0, min(intrinsicContentSize.width, bounds.width) - 30), height: 14)
    }
    var arrowRect: NSRect { NSRect(x: titleRect.maxX + 6, y: bounds.midY - 2, width: 6, height: 4) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted || activeMenu != nil
        let alpha: CGFloat = !isEnabled ? 0.025 : pressed ? 0.14 : hovered ? 0.09 : 0.045
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(alpha).setFill(); path.fill()
        NSColor.labelColor.withAlphaComponent(isEnabled ? 0.16 : 0.07).setStroke(); path.lineWidth = 1; path.stroke()
        let color = isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        (title as NSString).draw(in: titleRect, withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: color, .paragraphStyle: paragraph])
        let rect = arrowRect
        let arrow = NSBezierPath()
        // Work in either flipped or unflipped hosting coordinates.
        let top = isFlipped ? rect.minY : rect.maxY
        let bottom = isFlipped ? rect.maxY : rect.minY
        arrow.move(to: NSPoint(x: rect.minX, y: top)); arrow.line(to: NSPoint(x: rect.midX, y: bottom)); arrow.line(to: NSPoint(x: rect.maxX, y: top))
        color.setStroke(); arrow.lineWidth = 1.3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func cancelMenu() { selectedAction = nil; activeMenu?.cancelTrackingWithoutAnimation() }

    func buildMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        actions.removeAll(); selectedAction = nil
        guard let (groups, current, initial, message, loading) = menuContent?() else { return menu }
        let heading = NSMenuItem(title: "临时切换 · 仅当前\(operation.resultName)", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        add("恢复默认模型", action: .restore, to: menu, enabled: initial != nil && initial?.target != current?.target)
        if !message.isEmpty {
            let info = NSMenuItem(title: message, action: nil, keyEquivalent: ""); info.isEnabled = false; menu.addItem(info)
        }
        for group in groups {
            menu.addItem(.separator())
            let header = NSMenuItem(title: group.name, action: nil, keyEquivalent: ""); header.isEnabled = false; menu.addItem(header)
            for choice in group.choices {
                let item = add(choice.modelName, action: .select(choice), to: menu)
                item.indentationLevel = 1; item.state = choice.target == current?.target ? .on : .off
                item.toolTip = "\(choice.label)\n模型 ID：\(choice.target.modelID)"
            }
            if group.canLoadChatGPT {
                let item = add(loading ? "正在加载 ChatGPT 模型…" : "加载 ChatGPT 模型…", action: .load, to: menu, enabled: !loading)
                item.indentationLevel = 1
            } else if group.choices.isEmpty {
                let empty = NSMenuItem(title: "尚未添加模型", action: nil, keyEquivalent: ""); empty.isEnabled = false
                empty.indentationLevel = 1; menu.addItem(empty)
            }
        }
        if groups.isEmpty {
            let empty = NSMenuItem(title: "请先在设置中添加 API 或连接 ChatGPT", action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        return menu
    }
    @discardableResult private func add(_ title: String, action: Action, to menu: NSMenu, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chosen(_:)), keyEquivalent: "")
        item.target = self; item.tag = actions.count; item.isEnabled = enabled
        actions[item.tag] = action; menu.addItem(item); return item
    }
    @objc private func chosen(_ sender: NSMenuItem) {
        selectedAction = actions[sender.tag]
        activeMenu?.cancelTrackingWithoutAnimation()
    }
    @objc private func openMenu() {
        guard isEnabled, activeMenu == nil else { return }
        let origin = sessionID
        onTracking?(true)
        let menu = buildMenu(); activeMenu = menu; needsDisplay = true
        Self.presentingButton = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
        let selection = selectedAction
        activeMenu = nil; selectedAction = nil; needsDisplay = true
        if Self.presentingButton === self { Self.presentingButton = nil }
        onTracking?(false)
        guard origin == sessionID else { return }
        // Dispatch after native menu tracking so its closing events cannot dismiss
        // the newly started request, and never execute while SwiftUI updates a view.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.sessionID == origin else { return }
            switch selection {
            case .select(let choice): self.onSelect?(choice, origin)
            case .restore: self.onRestore?(origin)
            case .load: self.onLoad?(origin)
            case nil: break
            }
        }
    }
}
