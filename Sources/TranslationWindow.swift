import AppKit
import SwiftUI

enum TranslationFontSize {
    static let range: ClosedRange<Double> = 12...24
    static let standard: Double = 15
    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : standard
    }
}

enum TranslationWindowPosition: String, CaseIterable, Identifiable {
    case upperRight, belowPointer
    var id: String { rawValue }
    var title: String { self == .upperRight ? "屏幕右上角" : "鼠标右下方" }
}

enum TranslationWindowLayout {
    // A notification-card-like visual width, expressed in macOS logical points.
    static let width: CGFloat = 360
    static let margin: CGFloat = 16
    static let headerHeight: CGFloat = 28
    static let footerHeight: CGFloat = 32
    static let minimumHeight: CGFloat = 128
    static let bodyPadding: CGFloat = 18
    static let paragraphGap: CGFloat = 14
    @MainActor static func contentHeight(source: String, text: String, error: Bool = false, fontSize: CGFloat = 15) -> CGFloat {
        // Measure the same SwiftUI body that is displayed, including the capped
        // source, actual line wrapping, error icon, line spacing and padding.
        let hosting = NSHostingView(rootView: TranslationBody(source: source, text: text, error: error, fontSize: fontSize))
        hosting.layoutSubtreeIfNeeded()
        let chrome = headerHeight + footerHeight + 2 // Both dividers.
        return max(minimumHeight, chrome + ceil(hosting.fittingSize.height) + 1)
    }
    static func frame(contentHeight: CGFloat, position: TranslationWindowPosition, pointer: NSPoint, screen: NSRect, manualTopLeft: NSPoint? = nil) -> NSRect {
        let flushUpperRight = position == .upperRight && manualTopLeft == nil
        var maximumHeight = max(100, screen.height - (flushUpperRight ? margin : 2 * margin))
        let spaceBelow = manualTopLeft.map { $0.y - screen.minY - margin } ??
            (position == .belowPointer ? pointer.y - 12 - screen.minY - margin : maximumHeight)
        if spaceBelow >= minimumHeight { maximumHeight = min(maximumHeight, spaceBelow) }
        let height = min(max(minimumHeight, contentHeight), maximumHeight)
        let size = NSSize(width: width, height: height)
        let origin: NSPoint
        if let manual = manualTopLeft { origin = NSPoint(x: manual.x, y: manual.y - height) }
        else if position == .upperRight { origin = NSPoint(x: screen.maxX - width, y: screen.maxY - height) }
        else { origin = FloatingController.belowPointer(pointer, size: size) }
        return NSRect(origin: FloatingController.clamped(origin, size: size, screen: screen, inset: flushUpperRight ? 0 : 10), size: size)
    }
}

struct TranslationBody: View, Equatable {
    let source: String
    let text: String
    let error: Bool
    var dark = false
    var fontSize: CGFloat = 15
    var body: some View {
        VStack(alignment: .leading, spacing: TranslationWindowLayout.paragraphGap) {
            Text(source).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if error {
                Label(text, systemImage: "exclamationmark.circle").font(.system(size: 14))
                    .foregroundStyle(.orange).textSelection(.enabled)
            } else if text.isEmpty {
                Text("正在将选中文字译成中文…").foregroundStyle(.secondary).font(.system(size: 14))
            } else {
                TranslationResultText(text: text, dark: dark, fontSize: fontSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(TranslationWindowLayout.bodyPadding)
        .frame(width: TranslationWindowLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

struct TranslationResultText: NSViewRepresentable {
    let text: String
    let dark: Bool
    var fontSize: CGFloat = 15
    func makeNSView(context: Context) -> TranslationResultTextView {
        TranslationResultTextView(text: text, dark: dark, fontSize: fontSize)
    }
    func updateNSView(_ view: TranslationResultTextView, context: Context) {
        view.updateText(text, dark: dark, fontSize: fontSize)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranslationResultTextView, context: Context) -> CGSize? {
        let width = min(proposal.width ?? TranslationWindowLayout.width - 2 * TranslationWindowLayout.bodyPadding,
                        TranslationWindowLayout.width - 2 * TranslationWindowLayout.bodyPadding)
        return NSSize(width: width, height: nsView.measuredHeight(width: width))
    }
}

final class TranslationResultTextView: NSTextView, NSMenuDelegate {
    private var currentDark: Bool?
    private var currentFontSize: CGFloat?
    private var activeMenu: NSMenu?
    private weak var menuOwner: TranslationPanel?
    private static weak var presentingTextView: TranslationResultTextView?
    static func cancelPresentedMenu() { presentingTextView?.activeMenu?.cancelTrackingWithoutAnimation() }
    init(text: String, dark: Bool, fontSize: CGFloat = 15) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let width = TranslationWindowLayout.width - 2 * TranslationWindowLayout.bodyPadding
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; container.widthTracksTextView = false
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1), textContainer: container)
        isEditable = false; isSelectable = true; isRichText = false
        drawsBackground = false; textContainerInset = .zero
        isHorizontallyResizable = false; isVerticallyResizable = true
        minSize = .zero; maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        allowsUndo = false
        setAccessibilityLabel("中文译文")
        updateText(text, dark: dark, fontSize: fontSize)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateText(_ text: String, dark: Bool, fontSize: CGFloat = 15) {
        guard string != text || currentDark != dark || currentFontSize != fontSize else { return }
        let previousSelection = selectedRange()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7 * fontSize / 15; paragraph.lineBreakMode = .byWordWrapping
        let color: NSColor = dark ? .white : .black
        let font = NSFont.systemFont(ofSize: fontSize)
        self.font = font; textColor = color; defaultParagraphStyle = paragraph
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ]))
        let length = (text as NSString).length
        let start = min(previousSelection.location, length)
        setSelectedRange(NSRange(location: start, length: min(previousSelection.length, length - start)))
        currentDark = dark; currentFontSize = fontSize
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: self)
    }
    func measuredHeight(width: CGFloat) -> CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 18 }
        let size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        if container.containerSize != size { container.containerSize = size }
        manager.ensureLayout(for: container)
        var height = manager.usedRect(for: container).maxY
        if manager.extraLineFragmentTextContainer === container { height = max(height, manager.extraLineFragmentRect.maxY) }
        return max(1, ceil(height))
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(width: bounds.width))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if !visibleRect.isEmpty { addCursorRect(visibleRect, cursor: .iBeam) }
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(); menu.delegate = self
        let copy = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: ""); copy.target = self
        let select = NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: ""); select.target = self
        menu.addItem(copy); menu.addItem(select)
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        activeMenu = menu; Self.presentingTextView = self
        menuOwner = window as? TranslationPanel
        menuOwner?.onTextMenuTracking?(true)
    }
    func menuDidClose(_ menu: NSMenu) {
        activeMenu = nil
        if Self.presentingTextView === self { Self.presentingTextView = nil }
        menuOwner?.onTextMenuTracking?(false); menuOwner = nil
    }
}

struct TranslationBodyScrollArea: NSViewRepresentable {
    let source: String
    let text: String
    let error: Bool
    let dark: Bool
    var fontSize: CGFloat = 15
    func makeNSView(context: Context) -> TranslationBodyScrollView { TranslationBodyScrollView() }
    func updateNSView(_ view: TranslationBodyScrollView, context: Context) {
        view.updateBody(TranslationBody(source: source, text: text, error: error, dark: dark, fontSize: fontSize))
    }
}

final class TranslationBodyScrollView: NSScrollView {
    private let hosting = NSHostingView(rootView: TranslationBody(source: "", text: "", error: false))
    private var currentBody: TranslationBody?
    private var bodyHeight: CGFloat = 0
    private var allowsScrolling = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false; borderType = .noBorder
        contentView.drawsBackground = false
        hasHorizontalScroller = false; hasVerticalScroller = false
        autohidesScrollers = true; scrollerStyle = .overlay
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        hosting.isFlipped = true
        documentView = hosting
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateBody(_ body: TranslationBody) {
        guard body != currentBody else { return }
        let reset = currentBody?.source != body.source || body.text.isEmpty ||
            !(body.text.hasPrefix(currentBody?.text ?? ""))
        currentBody = body; hosting.rootView = body
        hosting.layoutSubtreeIfNeeded()
        bodyHeight = ceil(hosting.fittingSize.height)
        layoutBody(reset: reset)
    }
    override func layout() {
        super.layout()
        layoutBody(reset: false)
    }
    private func layoutBody(reset: Bool) {
        let viewport = contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        allowsScrolling = bodyHeight > viewport.height + pixel
        if hasVerticalScroller != allowsScrolling { hasVerticalScroller = allowsScrolling }
        let height = max(bodyHeight, viewport.height)
        let documentFrame = NSRect(x: 0, y: 0, width: TranslationWindowLayout.width, height: height)
        if hosting.frame != documentFrame { hosting.frame = documentFrame }
        let y = allowsScrolling && !reset ? max(0, min(contentView.bounds.minY, height - viewport.height)) : 0
        let origin = NSPoint(x: 0, y: y)
        if contentView.bounds.origin != origin { contentView.scroll(to: origin) }
        reflectScrolledClipView(contentView)
    }
    override func scrollWheel(with event: NSEvent) {
        // Short content must not move even when the wheel has momentum phases.
        guard allowsScrolling else { return }
        super.scrollWheel(with: event)
    }
}

struct TranslationDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TranslationDragView { TranslationDragView() }
    func updateNSView(_ view: TranslationDragView, context: Context) {}
}

final class TranslationDragView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("拖动译文窗口")
        toolTip = "拖动译文窗口"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 18, y: bounds.midY - 1.5, width: 36, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
