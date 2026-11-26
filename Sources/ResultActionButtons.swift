import AppKit
import SwiftUI

struct ResultActionButtons: NSViewRepresentable {
    let actions: [TextOperation]
    let sessionID: UUID
    var tracking: (Bool) -> Void
    var select: (TextOperation, UUID) -> Void

    func makeNSView(context: Context) -> ResultActionButtonRow { ResultActionButtonRow() }
    func updateNSView(_ row: ResultActionButtonRow, context: Context) {
        row.tracking = tracking
        row.select = select
        row.update(actions, session: sessionID)
    }
    static func dismantleNSView(_ row: ResultActionButtonRow, coordinator: ()) {
        row.cancelMenu()
    }
}

final class ResultActionButtonRow: NSView {
    private(set) static weak var presentedMenu: NSMenu?
    var tracking: ((Bool) -> Void)?
    var select: ((TextOperation, UUID) -> Void)?
    private var actions: [TextOperation] = []
    private var session: UUID?
    private var buttons: [NSButton] = []
    private var directCount = 0
    private var openMenu: NSMenu?
    private var menuSelection: TextOperation?
    private lazy var more = makeButton("更多", action: #selector(showMore))

    func cancelMenu() { openMenu?.cancelTrackingWithoutAnimation() }

    func update(_ next: [TextOperation], session id: UUID) {
        guard session != id || actions != next else { return }
        cancelMenu()
        session = id
        actions = next
        buttons.forEach { $0.removeFromSuperview() }
        buttons = next.enumerated().map { index, operation in
            let button = makeButton(operation.action, action: #selector(chooseButton(_:)))
            button.tag = index
            let help = "用“\(operation.action)”处理最初选中的文字。"
            button.toolTip = help
            button.setAccessibilityHelp(help)
            button.setAccessibilityLabel("对原文执行" + operation.action)
            return button
        }
        if more.superview == nil {
            more.setAccessibilityLabel("更多 AI 动作")
            addSubview(more)
        }
        needsLayout = true
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.cell?.lineBreakMode = .byTruncatingTail
        return button
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 5
        let moreWidth = ceil(more.intrinsicContentSize.width)
        let widths = buttons.map { min(ceil($0.intrinsicContentSize.width), max(0, bounds.width)) }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
        let overflows = total > bounds.width
        let available = overflows ? max(0, bounds.width - moreWidth - gap) : bounds.width
        var x: CGFloat = 0
        directCount = 0
        for (index, button) in buttons.enumerated() {
            // Keep the first action reachable in one click even when its name is very long.
            let width = index == 0 ? min(available, widths[index]) : widths[index]
            guard index == directCount, width > 0, x + width <= available else {
                if button.superview != nil { button.removeFromSuperview() }
                continue
            }
            if button.superview == nil { addSubview(button) }
            button.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + gap
            directCount += 1
        }
        more.isHidden = directCount == actions.count
        more.frame = NSRect(x: x, y: 0, width: min(moreWidth, max(0, bounds.width - x)), height: bounds.height)
        setAccessibilityChildren(Array(buttons.prefix(directCount)) + (more.isHidden ? [] : [more]))
    }

    @objc private func chooseButton(_ sender: NSButton) {
        guard let session, sender.superview === self, actions.indices.contains(sender.tag) else { return }
        select?(actions[sender.tag], session)
    }

    @objc private func showMore() {
        guard let origin = session, directCount < actions.count, openMenu == nil else { return }
        let menu = NSMenu()
        for index in directCount..<actions.count {
            let item = NSMenuItem(title: actions[index].action, action: #selector(chooseMenuItem(_:)), keyEquivalent: "")
            item.tag = index; item.target = self
            menu.addItem(item)
        }
        menuSelection = nil
        openMenu = menu
        Self.presentedMenu = menu
        tracking?(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height), in: more)
        let chosen = menuSelection
        openMenu = nil
        Self.presentedMenu = nil
        tracking?(false)
        if let chosen {
            DispatchQueue.main.async { [weak self] in self?.select?(chosen, origin) }
        }
    }

    @objc private func chooseMenuItem(_ sender: NSMenuItem) {
        guard sender.menu === openMenu, actions.indices.contains(sender.tag) else { return }
        menuSelection = actions[sender.tag]
        openMenu?.cancelTrackingWithoutAnimation()
    }
}
