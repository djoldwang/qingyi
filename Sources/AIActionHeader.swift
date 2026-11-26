import AppKit
import SwiftUI
import QuartzCore

// Preview order changes while tracking; only an accepted drop saves it.
enum AIActionPasteboard {
    static let type = NSPasteboard.PasteboardType("com.laowang.qingyi.custom-action")
    static func item(for id: String) -> NSPasteboardItem {
        let item = NSPasteboardItem(); item.setString(id, forType: type); return item
    }
    static func source(in pasteboard: NSPasteboard) -> String? {
        guard let key = pasteboard.string(forType: type) else { return nil }
        if key == TextOperation.translation.key || key == TextOperation.polishing.key { return key }
        return UUID(uuidString: key)?.uuidString
    }
    #if QINGYI_TESTING
    @MainActor static var dragEvents: [String: Int] = [:]
    @MainActor static var onPreview: ((NSPanel) -> Void)?
    @MainActor static var onEvent: (() -> Void)?
    #endif
    @MainActor static func trace(_ event: String) {
        #if QINGYI_TESTING
        dragEvents[event, default: 0] += 1; onEvent?()
        #endif
    }
}

@MainActor
final class AIActionReorderSession: ObservableObject {
    @Published private(set) var previewIDs: [String]?
    private(set) var source: String?
    private var initialIDs: [String] = []
    private var save: ((String, String) -> Bool)?
    func begin(source: String, order: [String], save: @escaping (String, String) -> Bool) {
        guard order.contains(source) else { return }
        self.source = source; initialIDs = order; self.save = save; previewIDs = order
    }
    @discardableResult func hover(over target: String) -> Bool {
        guard let source, var ids = previewIDs, source != target,
              let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: target) else { return false }
        ids.insert(ids.remove(at: from), at: to); previewIDs = ids; return true
    }
    @discardableResult func finish(accept: Bool) -> Bool {
        defer { source = nil; save = nil; initialIDs = []; previewIDs = nil }
        guard accept, let source, let index = previewIDs?.firstIndex(of: source),
              initialIDs.indices.contains(index) else { return false }
        if initialIDs[index] == source { return true }
        return save?(source, initialIDs[index]) == true
    }
}

// A native host gives dragging the bounds and rendered contents of the complete
// SwiftUI action row.
@MainActor
struct AIActionCard<Content: View>: NSViewRepresentable {
    var actionID: String?
    var dragging = false
    @ViewBuilder let content: Content
    func makeNSView(context: Context) -> AIActionCardView {
        let view = AIActionCardView(rootView: AnyView(content))
        view.actionID = actionID; view.alphaValue = dragging ? 0.18 : 1
        view.update(content: AnyView(content)); return view
    }
    func updateNSView(_ view: AIActionCardView, context: Context) {
        view.actionID = actionID; view.alphaValue = dragging ? 0.18 : 1
        view.update(content: AnyView(content))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AIActionCardView, context: Context) -> CGSize? {
        let width = proposal.width ?? 500
        nsView.render(width: width)
        return NSSize(width: width, height: ceil(nsView.fittingSize.height))
    }
}

@MainActor
final class AIActionCardView: NSHostingView<AnyView> {
    var actionID: String?
    private var content = AnyView(EmptyView())
    private var renderedWidth: CGFloat = 0
    func update(content: AnyView) {
        self.content = content; renderedWidth = 0
        render(width: bounds.width > 0 ? bounds.width : 500)
    }
    func render(width: CGFloat) {
        guard width > 0, width != renderedWidth else { return }
        renderedWidth = width; rootView = AnyView(content.frame(width: width))
    }
    override func layout() {
        // SwiftUI may measure at its ideal width before assigning the real
        // available width. Render the card edge to edge at the assigned width.
        render(width: bounds.width); super.layout()
    }
    func snapshot() -> NSImage? {
        layoutSubtreeIfNeeded(); displayIfNeeded(); CATransaction.flush()
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size); image.addRepresentation(bitmap)
        return image
    }
}

@MainActor
struct AIActionHeader: NSViewRepresentable {
    let operation: TextOperation
    let enabled: Bool
    let modelSummary: String
    let modelUnavailable: Bool
    let edit: () -> Void
    let toggle: (Bool) -> Void
    let canMove: (String) -> Bool
    let move: (String) -> Bool
    let reorder: AIActionReorderSession
    let actionOrder: [String]
    let commitOrder: (String, String) -> Bool

    func makeNSView(context: Context) -> AIActionHeaderView { AIActionHeaderView() }
    func updateNSView(_ view: AIActionHeaderView, context: Context) {
        view.configure(operation: operation, enabled: enabled,
                       modelSummary: modelSummary, modelUnavailable: modelUnavailable)
        view.onEdit = edit; view.onToggle = toggle; view.canMove = canMove; view.onMove = move
        view.reorder = reorder; view.actionOrder = actionOrder; view.commitOrder = commitOrder
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AIActionHeaderView, context: Context) -> CGSize? {
        NSSize(width: proposal.width ?? 500, height: 50)
    }
}

@MainActor
final class AIActionHeaderView: NSView {
    let editButton = AIActionTitleButton()
    let modelLabel = NSTextField(labelWithString: "")
    let toggle = NSSwitch()
    var onEdit: (() -> Void)?
    var onToggle: ((Bool) -> Void)?
    var canMove: ((String) -> Bool)?
    var onMove: ((String) -> Bool)?
    var reorder: AIActionReorderSession?
    var actionOrder: [String] = []
    var commitOrder: ((String, String) -> Bool)?
    private var dropHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        editButton.isBordered = false; editButton.alignment = .left
        editButton.imagePosition = .imageLeading; editButton.imageHugsTitle = true
        editButton.font = .systemFont(ofSize: 13, weight: .semibold)
        editButton.lineBreakMode = .byTruncatingTail
        editButton.target = self; editButton.action = #selector(editClicked)
        toggle.controlSize = .small; toggle.target = self; toggle.action = #selector(toggleClicked)
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.maximumNumberOfLines = 1
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(editButton); addSubview(modelLabel); addSubview(toggle)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(operation: TextOperation, enabled: Bool,
                   modelSummary: String = "", modelUnavailable: Bool = false) {
        editButton.attributedTitle = NSAttributedString(string: "  " + operation.action,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        editButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        let titleHelp = "点击编辑\(operation.action) · 拖动标题调整顺序"
        editButton.toolTip = modelSummary.isEmpty ? titleHelp : "\(titleHelp)\n\(modelSummary)"
        editButton.actionID = operation.key
        editButton.setAccessibilityLabel("编辑\(operation.action)")
        editButton.setAccessibilityIdentifier("settings.prompts.\(operation.key).edit")
        modelLabel.stringValue = modelSummary
        modelLabel.toolTip = modelSummary
        modelLabel.textColor = modelUnavailable ? .systemOrange : .secondaryLabelColor
        modelLabel.isHidden = modelSummary.isEmpty
        modelLabel.setAccessibilityIdentifier("settings.prompts.\(operation.key).modelSummary")
        toggle.state = enabled ? .on : .off
        toggle.setAccessibilityLabel("启用\(operation.action)")
        toggle.setAccessibilityIdentifier(operation.customAction == nil ? "settings.\(operation.key).enabled" : "settings.actions.\(operation.key).enabled")
        registerForDraggedTypes([AIActionPasteboard.type])
        editButton.registerForDraggedTypes([AIActionPasteboard.type])
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let inset: CGFloat = 15, width: CGFloat = 44
        toggle.frame = NSRect(x: max(inset, bounds.width - inset - width), y: (bounds.height - 24) / 2, width: width, height: 24)
        let titleWidth = max(0, toggle.frame.minX - inset - 14)
        editButton.frame = NSRect(x: inset, y: modelLabel.isHidden ? (bounds.height - 28) / 2 : bounds.height - 26,
                                  width: titleWidth, height: modelLabel.isHidden ? 28 : 20)
        modelLabel.frame = NSRect(x: inset + 15, y: 7, width: max(0, titleWidth - 15), height: 14)
    }
    private var activationRect: NSRect {
        NSRect(x: 0, y: 0, width: max(0, toggle.frame.minX - 8), height: bounds.height)
    }
    func containsActivationPoint(_ pointInWindow: NSPoint) -> Bool {
        activationRect.contains(convert(pointInWindow, from: nil))
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(convert(point, from: superview)) else { return nil }
        // Borderless NSButton cells can ignore their blank area. Keep the
        // title, model caption, margins and empty header space on one target.
        if activationRect.contains(convert(point, from: superview)) { return editButton }
        return super.hitTest(point)
    }
    func setDropHighlight(_ highlighted: Bool) { dropHighlighted = highlighted }
    static func header(in root: NSView, at pointInWindow: NSPoint) -> AIActionHeaderView? {
        if let header = root as? AIActionHeaderView, !header.isHiddenOrHasHiddenAncestor {
            var surface: NSView = header
            var ancestor = header.superview
            while let view = ancestor {
                if view is AIActionCardView { surface = view; break }
                ancestor = view.superview
            }
            let point = surface.convert(pointInWindow, from: nil)
            if surface.bounds.contains(point), surface.visibleRect.contains(point) { return header }
        }
        for child in root.subviews.reversed() {
            if let found = header(in: child, at: pointInWindow) { return found }
        }
        return nil
    }
    @objc private func editClicked() { onEdit?() }
    @objc private func toggleClicked() { onToggle?(toggle.state == .on) }
    func accepts(_ pasteboard: NSPasteboard) -> Bool {
        guard let target = editButton.actionID, let source = AIActionPasteboard.source(in: pasteboard), source != target else { return false }
        return canMove?(source) == true
    }
    @discardableResult func receive(_ pasteboard: NSPasteboard) -> Bool {
        defer { dropHighlighted = false }
        guard accepts(pasteboard), let source = AIActionPasteboard.source(in: pasteboard) else { return false }
        return onMove?(source) == true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        AIActionPasteboard.trace("destinationEntered")
        dropHighlighted = accepts(sender.draggingPasteboard)
        #if QINGYI_TESTING
        AIActionPasteboard.trace(dropHighlighted ? "destinationAccepted" : "destinationRefused")
        if AIActionPasteboard.source(in: sender.draggingPasteboard) == nil { AIActionPasteboard.trace("missingPayload") }
        else if AIActionPasteboard.source(in: sender.draggingPasteboard) == editButton.actionID { AIActionPasteboard.trace("sameRow") }
        #endif
        return dropHighlighted ? .move : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender.draggingPasteboard) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = receive(sender.draggingPasteboard)
        AIActionPasteboard.trace(accepted ? "dropCommitted" : "dropRejected")
        return accepted
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dropHighlighted = false }
}

@MainActor
final class AIActionDragPreview {
    let panel: NSPanel
    let sourceFrame: NSRect
    init(image: NSImage, sourceFrame: NSRect, parent: NSWindow) {
        self.sourceFrame = sourceFrame
        panel = NSPanel(contentRect: sourceFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let view = NSImageView(frame: NSRect(origin: .zero, size: sourceFrame.size))
        view.image = image; view.imageScaling = .scaleNone
        panel.contentView = view
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }
    func move(by delta: NSSize) {
        panel.setFrameOrigin(NSPoint(x: sourceFrame.minX + delta.width, y: sourceFrame.minY + delta.height))
        // The mouse tracking loop does not return to the normal display pass.
        // Flush the native preview on every move, including the very first one.
        panel.displayIfNeeded(); CATransaction.flush()
    }
    func close() { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
}

@MainActor
final class AIActionTitleButton: NSButton {
    var actionID: String?
    private var destination: AIActionHeaderView? { superview as? AIActionHeaderView }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { destination?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { destination?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { destination?.draggingExited(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { destination?.prepareForDragOperation(sender) ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { destination?.performDragOperation(sender) ?? false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { destination?.concludeDragOperation(sender) }

    // Track within this settings window rather than relying on the hosting
    // view to forward a drag session's mouse-up to a SwiftUI drop delegate.
    override func mouseDown(with event: NSEvent) {
        guard let window, let content = window.contentView else { super.mouseDown(with: event); return }
        let sourceID = actionID
        AIActionPasteboard.trace("sourceMouseDown")
        highlight(true)
        var board: NSPasteboard?
        var preview: AIActionDragPreview?
        var target: AIActionHeaderView?
        var dragging = false
        var card: AIActionCardView?
        var ancestor: NSView? = self
        while let view = ancestor {
            if let host = view as? AIActionCardView { card = host; break }
            ancestor = view.superview
        }
        let reorder = destination?.reorder
        let order = destination?.actionOrder ?? []
        let commitOrder = destination?.commitOrder
        let start = window.convertPoint(toScreen: event.locationInWindow)
        @MainActor func refreshLayout() {
            // Allow SwiftUI's pending order update to render inside mouse tracking.
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            content.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        }
        defer {
            target?.setDropHighlight(false); preview?.close()
            if reorder?.source != nil { _ = reorder?.finish(accept: false) }
            refreshLayout()
            card?.alphaValue = 1; card?.displayIfNeeded(); CATransaction.flush()
            board?.releaseGlobally(); highlight(false)
            if dragging { NSCursor.pop() }
        }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .keyDown {
                if next.keyCode == 53 { AIActionPasteboard.trace("sourceEndedCancelled"); return }
                continue
            }
            if next.type == .leftMouseUp {
                if dragging, let board, let id = sourceID {
                    let destination = AIActionHeaderView.header(in: content, at: next.locationInWindow)
                    let valid = destination?.editButton.actionID == id || destination?.accepts(board) == true
                    let committed = reorder?.finish(accept: valid) ?? (destination?.receive(board) == true)
                    AIActionPasteboard.trace(committed ? "dropCommitted" : "dropRejected")
                    AIActionPasteboard.trace(committed ? "sourceEndedMove" : "sourceEndedCancelled")
                } else if destination?.containsActivationPoint(next.locationInWindow) == true { performClick(nil) }
                return
            }
            let distance = hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y)
            if !dragging {
                guard distance >= 4, let id = sourceID else { continue }
                highlight(false)
                guard let card, let image = card.snapshot() else { return }
                dragging = true; NSCursor.closedHand.push(); AIActionPasteboard.trace("sourceDragStarted")
                let pasteboard = NSPasteboard.withUniqueName()
                pasteboard.writeObjects([AIActionPasteboard.item(for: id)]); board = pasteboard
                let rect = window.convertToScreen(card.convert(card.bounds, to: nil))
                preview = AIActionDragPreview(image: image, sourceFrame: rect, parent: window)
                if let commitOrder { reorder?.begin(source: id, order: order, save: commitOrder) }
                card.alphaValue = 0.18
                refreshLayout()
            }

            if let board {
                let candidate = AIActionHeaderView.header(in: content, at: next.locationInWindow)
                let accepted = candidate?.accepts(board) == true ? candidate : nil
                if target !== accepted {
                    target?.setDropHighlight(false); target = accepted; target?.setDropHighlight(true)
                    if accepted != nil { AIActionPasteboard.trace("destinationAccepted") }
                }
                if let targetID = accepted?.editButton.actionID, reorder?.hover(over: targetID) == true {
                    refreshLayout(); AIActionPasteboard.trace("hoverReordered")
                }
            }
            if let preview {
                let point = window.convertPoint(toScreen: next.locationInWindow)
                preview.move(by: NSSize(width: point.x - start.x, height: point.y - start.y))
                window.displayIfNeeded(); CATransaction.flush()
                #if QINGYI_TESTING
                AIActionPasteboard.onPreview?(preview.panel)
                #endif
            }
        }
    }
}
