import AppKit
import ApplicationServices

struct HoverParagraph {
    let text: String
    let bounds: CGRect?
}

enum HoverReadError: LocalizedError {
    case unavailable, protectedContent, tooLong, timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法读取鼠标所在段落，请改用划词或复制文字后翻译。"
        case .protectedContent: return "此处为受保护内容，无法读取。"
        case .tooLong: return "这段文字超过可读取范围或 12,000 字，请缩小选区后翻译。"
        case .timedOut: return "读取段落超时，请重试，或改用划词翻译。"
        }
    }
}

// Both real AX elements and deterministic test trees use the same extraction path.
protocol HoverAXElement {
    func attribute(_ name: String) -> Any?
    func parameter(_ name: String, _ value: Any) -> Any?
    var reference: Any { get }
    var parent: HoverAXElement? { get }
    var children: [HoverAXElement] { get }
    func markerEndpoint(_ range: Any, start: Bool) -> Any?
}

extension HoverAXElement {
    var reference: Any { self }
    func markerEndpoint(_ range: Any, start: Bool) -> Any? {
        guard CFGetTypeID(range as CFTypeRef) == AXTextMarkerRangeGetTypeID() else { return nil }
        let range = range as! AXTextMarkerRange
        return start ? AXTextMarkerRangeCopyStartMarker(range) : AXTextMarkerRangeCopyEndMarker(range)
    }
}

final class SystemHoverElement: HoverAXElement {
    var reference: Any { element }
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element; AXUIElementSetMessagingTimeout(element, 0.06) }
    func attribute(_ name: String) -> Any? { SelectionReader.value(element, name) }
    func parameter(_ name: String, _ value: Any) -> Any? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value as CFTypeRef, &result) == .success else { return nil }
        return result
    }
    var parent: HoverAXElement? { SelectionReader.element(SelectionReader.value(element, kAXParentAttribute)).map(SystemHoverElement.init) }
    var children: [HoverAXElement] {
        // Never copy an unbounded list from a whole web document.
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success, count <= 256 else { return [] }
        var result: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &result) == .success,
              let elements = result as? [AXUIElement] else { return [] }
        return elements.map(SystemHoverElement.init)
    }
}

enum ParagraphText {
    static let maximumUTF16 = 60_000
    static func clean(_ text: String) throws -> String {
        let text = TextPolicy.clean(text)
        guard !text.isEmpty else { throw HoverReadError.unavailable }
        guard text.count <= TextPolicy.maximumLength, text.utf16.count <= maximumUTF16 else { throw HoverReadError.tooLong }
        return text
    }
    static func range(in text: String, at offset: Int) throws -> NSRange {
        let value = text as NSString
        guard offset >= 0, offset < value.length else { throw HoverReadError.unavailable }
        // A blank line must not silently resolve to the previous paragraph.
        let unit = value.character(at: offset)
        guard ![10, 13, 0x2028, 0x2029].contains(Int(unit)) else { throw HoverReadError.unavailable }
        return value.paragraphRange(for: NSRange(location: offset, length: 0))
    }
    static func at(_ text: String, offset: Int) throws -> String {
        try clean((text as NSString).substring(with: range(in: text, at: offset)))
    }
}

struct HoverParagraphAccess {
    let point: CGPoint
    var isCurrent: () -> Bool = { true }
    var deadline = Date().addingTimeInterval(0.9)
    private func check() throws {
        guard isCurrent() else { throw CancellationError() }
        guard Date() < deadline else { throw HoverReadError.timedOut }
    }
    private func role(_ node: HoverAXElement) -> String { node.attribute(kAXRoleAttribute) as? String ?? "" }
    private func rect(_ value: Any?) -> CGRect? {
        guard let value = value else { return nil }
        if let value = value as? CGRect { return value.isEmpty ? nil : value }
        return AXSelectionAccess.rect(value as CFTypeRef)
    }
    private func frame(_ node: HoverAXElement) -> CGRect? {
        if let frame = node.attribute("AXFrame") as? CGRect { return frame }
        guard let position = node.attribute(kAXPositionAttribute), let size = node.attribute(kAXSizeAttribute),
              CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; var s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
    private func cfRange(_ range: CFRange) -> AXValue {
        var range = range
        return AXValueCreate(.cfRange, &range)!
    }
    private func text(_ raw: Any?) -> String? {
        if let value = raw as? String { return value }
        return (raw as? NSAttributedString)?.string
    }
    // Chromium may concatenate several HTML paragraphs without any newline in
    // AXStringForTextMarkerRange. Navigation markers retain the actual block
    // boundaries. Query forward from the start and backward from the end: doing
    // the reverse at a boundary would jump into the adjacent paragraph.
    private func isParagraphRange(_ range: Any, on node: HoverAXElement) throws -> Bool? {
        try check()
        guard let start = node.markerEndpoint(range, start: true),
              let end = node.markerEndpoint(range, start: false),
              let paragraphEnd = node.parameter("AXNextParagraphEndTextMarkerForTextMarker", start),
              let paragraphStart = node.parameter("AXPreviousParagraphStartTextMarkerForTextMarker", end) else { return nil }
        func samePosition(_ a: Any, _ b: Any) throws -> Bool? {
            try check()
            guard let gap = node.parameter("AXTextMarkerRangeForUnorderedTextMarkers", [a, b]),
                  let length = node.parameter("AXLengthForTextMarkerRange", gap) as? NSNumber else { return nil }
            return length.intValue == 0
        }
        guard let sameStart = try samePosition(start, paragraphStart),
              let sameEnd = try samePosition(end, paragraphEnd) else { return nil }
        return sameStart && sameEnd
    }
    func read(hit: HoverAXElement, resolveOverlay: Bool = true) throws -> HoverParagraph {
        try check()
        var ancestry: [HoverAXElement] = []; var current: HoverAXElement? = hit
        for _ in 0..<20 {
            try check()
            guard let node = current else { break }
            let r = role(node)
            let subrole = node.attribute(kAXSubroleAttribute) as? String ?? ""
            guard r != "AXSecureTextField", subrole != "AXSecureTextField",
                  node.attribute("AXProtectedContent") as? Bool != true else { throw HoverReadError.protectedContent }
            ancestry.append(node)
            if r == "AXWindow" || r == "AXApplication" { break }
            current = node.parent
        }
        let hitRole = role(hit)
        let textRoles: Set<String> = ["AXStaticText", "AXLink", "AXParagraph", "AXHeading", "AXTextArea", "AXTextField", "AXInlineTextBox"]
        guard textRoles.contains(hitRole) || ancestry.contains(where: { role($0) == "AXParagraph" }) else { throw HoverReadError.unavailable }
        if let bounds = frame(hit), !bounds.insetBy(dx: -1, dy: -1).contains(point) { throw HoverReadError.unavailable }

        // News cards can contain an empty, absolutely positioned link above
        // their text. Chromium's hit test alternates between that overlay and
        // the text beneath it. Resolve only a unique text leaf at this point,
        // within at most three nearby groups, never by label, URL or whole page.
        if resolveOverlay, hitRole == "AXLink", hit.children.isEmpty,
           (text(hit.attribute(kAXValueAttribute)) ?? "").isEmpty {
            var visited = 0
            for container in ancestry.dropFirst().prefix(3) {
                guard role(container) == "AXGroup" else { break }
                var matches: [HoverAXElement] = []
                func locate(_ node: HoverAXElement, depth: Int) throws {
                    try check(); visited += 1
                    guard visited <= 96, depth <= 6 else { throw HoverReadError.unavailable }
                    guard let bounds = frame(node), bounds.contains(point) else { return }
                    let r = role(node)
                    guard r != "AXSecureTextField", node.attribute(kAXSubroleAttribute) as? String != "AXSecureTextField",
                          node.attribute("AXProtectedContent") as? Bool != true else { throw HoverReadError.protectedContent }
                    if ["AXStaticText", "AXInlineTextBox"].contains(r) {
                        if let value = text(node.attribute(kAXValueAttribute)), !TextPolicy.clean(value).isEmpty { matches.append(node) }
                        return
                    }
                    guard ["AXGroup", "AXLink", "AXParagraph", "AXHeading"].contains(r) else { return }
                    for child in node.children { try locate(child, depth: depth + 1) }
                }
                try locate(container, depth: 0)
                guard matches.count <= 1 else { throw HoverReadError.unavailable }
                if let leaf = matches.first {
                    HoverDiagnostics.log("resolved empty link overlay")
                    return try read(hit: leaf, resolveOverlay: false)
                }
            }
        }

        // Native editors expose a character index at the pointer. Read only a
        // bounded window around that index and resolve logical paragraph breaks.
        for node in ancestry where ["AXTextArea", "AXTextField"].contains(role(node)) {
            try check()
            var p = point
            let parameter = AXValueCreate(.cgPoint, &p)!
            guard let raw = node.parameter(kAXRangeForPositionParameterizedAttribute, parameter),
                  CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID() else { continue }
            var index = CFRange()
            let ax = raw as! AXValue
            guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &index), index.location >= 0 else { continue }
            guard let count = (node.attribute(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue,
                  count > 0, index.location < count else { continue }
            // Reject clicks in an editor's empty trailing area (AX hit testing
            // often supplies the nearest character there).
            guard let characterBounds = rect(node.parameter(kAXBoundsForRangeParameterizedAttribute, cfRange(CFRange(location: index.location, length: 1)))),
                  characterBounds.insetBy(dx: -2, dy: -2).contains(point) else { continue }
            let start = max(0, index.location - ParagraphText.maximumUTF16)
            let end = min(count, index.location + ParagraphText.maximumUTF16)
            guard let value = text(node.parameter(kAXStringForRangeParameterizedAttribute, cfRange(CFRange(location: start, length: end - start)))) else { continue }
            let range = try ParagraphText.range(in: value, at: index.location - start)
            if (start > 0 && range.location == 0) || (end < count && NSMaxRange(range) >= (value as NSString).length) { throw HoverReadError.tooLong }
            let result = try ParagraphText.clean((value as NSString).substring(with: range))
            let bounds = rect(node.parameter(kAXBoundsForRangeParameterizedAttribute, cfRange(CFRange(location: start + range.location, length: range.length))))
            return HoverParagraph(text: result, bounds: bounds)
        }

        // Chromium represents both paragraphs and inline formatting as AXGroup.
        // Prefer marker navigation to prove a group's paragraph boundaries.
        // Missing newlines alone are not proof that it contains one paragraph.
        var block: HoverAXElement?
        var blockText: String?
        for candidate in ancestry {
            try check()
            let r = role(candidate)
            if ["AXWebArea", "AXWindow", "AXApplication"].contains(r) { break }
            if ["AXParagraph", "AXHeading"].contains(r) { block = candidate; break }
            if ["AXGroup", "AXLink"].contains(r),
               let range = candidate.parameter("AXTextMarkerRangeForUIElement", candidate.reference),
               let length = candidate.parameter("AXLengthForTextMarkerRange", range) as? NSNumber,
               length.intValue > 0, length.intValue <= ParagraphText.maximumUTF16,
               let raw = text(candidate.parameter("AXStringForTextMarkerRange", range)) {
                let value = TextPolicy.clean(raw)
                if let isParagraph = try isParagraphRange(range, on: candidate) {
                    if isParagraph && !value.isEmpty {
                        block = candidate; blockText = value; break
                    }
                    continue
                }
                // A headline can itself be a complete paragraph-sized link.
                // Inline links still expand to their enclosing paragraph; do
                // not accept a link without proof of both paragraph boundaries.
                if r == "AXLink" { continue }
                if value.contains(where: { $0.isNewline }) { break }
                if !value.isEmpty { block = candidate; blockText = value }
            }
        }

        // WebKit/Chromium marker support differs by version. A supported marker
        // path is used when there is no proven single-paragraph container.
        var markerPoint = point
        let markerPosition = AXValueCreate(.cgPoint, &markerPoint)!
        for node in (block == nil ? ancestry : []) {
            try check()
            guard let marker = node.parameter("AXTextMarkerForPosition", markerPosition),
                  let range = node.parameter("AXParagraphTextMarkerRangeForTextMarker", marker),
                  let value = text(node.parameter("AXStringForTextMarkerRange", range)) else { continue }
            let bounds = rect(node.parameter("AXBoundsForTextMarkerRange", range))
            if let bounds = bounds, !bounds.insetBy(dx: -2, dy: -2).contains(point) { continue }
            return HoverParagraph(text: try ParagraphText.clean(value), bounds: bounds)
        }

        // Reassemble inline fragments only inside the nearest semantic block.
        // Document roots and groups spanning logical paragraphs are excluded.
        if let block = block {
            var nodes = 0; var length = 0
            var usedContainerValue = false
            func collect(_ node: HoverAXElement, depth: Int) throws -> String {
                try check(); nodes += 1
                guard nodes <= 256, depth <= 16 else { throw HoverReadError.unavailable }
                let r = role(node)
                guard r != "AXSecureTextField", node.attribute(kAXSubroleAttribute) as? String != "AXSecureTextField",
                      node.attribute("AXProtectedContent") as? Bool != true else { throw HoverReadError.protectedContent }
                if r == "AXStaticText" || r == "AXInlineTextBox" {
                    let value = text(node.attribute(kAXValueAttribute)) ?? ""
                    length += value.utf16.count
                    guard length <= ParagraphText.maximumUTF16 else { throw HoverReadError.tooLong }
                    return value
                }
                guard ["AXParagraph", "AXHeading", "AXLink", "AXGroup", "AXUnknown"].contains(r) else { throw HoverReadError.unavailable }
                let children = node.children
                if children.isEmpty, let value = text(node.attribute(kAXValueAttribute)), !value.isEmpty {
                    usedContainerValue = true
                    length += value.utf16.count
                    guard length <= ParagraphText.maximumUTF16 else { throw HoverReadError.tooLong }
                    return value
                }
                return try children.map { try collect($0, depth: depth + 1) }.joined()
            }
            let collected = try collect(block, depth: 0)
            // Chrome's marker string can drop a space at an inline-link edge.
            // Prefer leaf text only when it contains exactly the same non-space
            // characters, so URLs, duplicate children or omitted text cannot leak in.
            let value: String
            if let markerText = blockText {
                // A line-clamped headline's marker range can include an ellipsis
                // and lose trailing characters. Its verified link block's text
                // leaves retain the full headline; never use AXTitle/AXDescription
                // (Google News adds publisher/time there) or the URL value.
                let completeLinkText = role(block) == "AXLink" && !usedContainerValue && !collected.isEmpty
                value = completeLinkText || collected.filter { !$0.isWhitespace } == markerText.filter { !$0.isWhitespace }
                    ? collected : markerText
            } else { value = collected }
            return HoverParagraph(text: try ParagraphText.clean(value), bounds: frame(block))
        }
        // Some applications expose a complete standalone paragraph as one leaf.
        if hitRole == "AXStaticText", let value = text(hit.attribute(kAXValueAttribute)),
           !value.contains(where: { $0.isNewline }) {
            return HoverParagraph(text: try ParagraphText.clean(value), bounds: frame(hit))
        }
        throw HoverReadError.unavailable
    }
}

// Cancellation is checked between AX calls, not just after the whole traversal.
final class HoverReadTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
}

enum HoverParagraphReader {
    // Retry transient unavailable AX results briefly on the background queue;
    // all attempts share one deadline and the same cancellation ticket.
    static func read(point: CGPoint, ticket: HoverReadTicket,
                     hitTest: () -> HoverAXElement?,
                     pause: () -> Void = { Thread.sleep(forTimeInterval: 0.025) }) throws -> HoverParagraph {
        let deadline = Date().addingTimeInterval(0.9)
        for attempt in 0..<3 {
            guard ticket.isCurrent else { throw CancellationError() }
            guard Date() < deadline else { throw HoverReadError.timedOut }
            do {
                guard let hit = hitTest() else { throw HoverReadError.unavailable }
                HoverDiagnostics.log("hit attempt=\(attempt + 1) role=\(hit.attribute(kAXRoleAttribute) as? String ?? "unknown")")
                return try HoverParagraphAccess(point: point, isCurrent: { ticket.isCurrent }, deadline: deadline).read(hit: hit)
            } catch HoverReadError.unavailable {
                guard attempt < 2 else { throw HoverReadError.unavailable }
                guard ticket.isCurrent else { throw CancellationError() }
                pause()
            }
        }
        throw HoverReadError.unavailable
    }
    static func read(pid: pid_t, point: CGPoint, ticket: HoverReadTicket) throws -> HoverParagraph {
        guard AXIsProcessTrusted(), pid != getpid(), ticket.isCurrent else { throw HoverReadError.unavailable }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        return try read(point: point, ticket: ticket, hitTest: {
            var hit: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
            guard status == .success, let hit = hit else {
                HoverDiagnostics.log("hit error=\(status.rawValue)"); return nil
            }
            var owner: pid_t = 0
            AXUIElementGetPid(hit, &owner)
            guard owner == pid, owner != getpid() else { HoverDiagnostics.log("hit owner mismatch"); return nil }
            return SystemHoverElement(hit)
        })
    }
}
