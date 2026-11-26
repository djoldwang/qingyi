import AppKit
import ApplicationServices

final class FixtureHoverElement: HoverAXElement {
    var attributes: [String: Any]
    var parameters: (String, Any) -> Any? = { _, _ in nil }
    weak var ancestor: FixtureHoverElement?
    var descendants: [FixtureHoverElement] = []
    var endpoints: (Any, Bool) -> Any? = { _, _ in nil }
    init(_ role: String, text: String? = nil, children: [FixtureHoverElement] = []) {
        attributes = [kAXRoleAttribute: role, "AXFrame": CGRect(x: 0, y: 0, width: 500, height: 500)]
        if let text = text { attributes[kAXValueAttribute] = text }
        descendants = children; children.forEach { $0.ancestor = self }
    }
    func attribute(_ name: String) -> Any? { attributes[name] }
    func parameter(_ name: String, _ value: Any) -> Any? { parameters(name, value) }
    var parent: HoverAXElement? { ancestor }
    var children: [HoverAXElement] { descendants }
    func markerEndpoint(_ range: Any, start: Bool) -> Any? { endpoints(range, start) }
    func markerRange(text: String, start: Int, end: Int, paragraphStart: Int, paragraphEnd: Int) {
        endpoints = { _, isStart in isStart ? start : end }
        parameters = { name, argument in
            switch name {
            case "AXTextMarkerRangeForUIElement": return "own"
            case "AXStringForTextMarkerRange": return text
            case "AXNextParagraphEndTextMarkerForTextMarker": return paragraphEnd
            case "AXPreviousParagraphStartTextMarkerForTextMarker": return paragraphStart
            case "AXTextMarkerRangeForUnorderedTextMarkers":
                let points = argument as! [Int]; return abs(points[1] - points[0])
            case "AXLengthForTextMarkerRange": return NSNumber(value: (argument as? Int) ?? (end - start))
            default: return nil
            }
        }
    }

}

extension QingyiTests {
    @MainActor static func hoverTests() {
        let p = CGPoint(x: 20, y: 20)
        check("Hover defaults off, long-press selected, preferences persist and unknown trigger migrates") {
            let name = "qingyi-hover-" + UUID().uuidString; let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let preferences = Preferences(defaults: defaults)
            try expect(!preferences.hoverEnabled && preferences.hoverTrigger == .longPress)
            preferences.hoverEnabled = true
            for value in HoverTrigger.allCases {
                preferences.hoverTrigger = value
                try expect(Preferences(defaults: defaults).hoverTrigger == value)
            }
            try expect(Preferences(defaults: defaults).hoverEnabled)
            defaults.set("unknown", forKey: "hoverTranslationTrigger")
            try expect(Preferences(defaults: defaults).hoverTrigger == .longPress)
        }
        check("Hover split settings migrate legacy choices and persist independent activation") {
            let name = "qingyi-hover-split-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            try expect(Preferences(defaults: defaults).hoverActivation == .mouseHold)
            defaults.set("shift", forKey: "hoverTranslationTrigger")
            let preferences = Preferences(defaults: defaults)
            try expect(preferences.hoverModifier == .shift && preferences.hoverActivation == .release)
            try expect(defaults.object(forKey: "hoverTranslationActivation") == nil, "Migration must not rewrite user defaults on launch")
            preferences.hoverModifier = .command; preferences.hoverActivation = .hold
            let reopened = Preferences(defaults: defaults)
            try expect(reopened.hoverModifier == .command && reopened.hoverActivation == .hold)
        }
        check("Held hover modifier fires once at deadline, never on release or after a combination") {
            for trigger in [HoverTrigger.option, .control, .shift, .command] {
                var g = HoverGesture(trigger: trigger, activation: .hold)
                _ = g.input(.flags, point: p, time: 0, flags: trigger.flag)
                try expect(g.tick(time: 0.599, point: p, buttons: 0) == .none)
                try expect(g.tick(time: 0.6, point: p, buttons: 0) == .trigger)
                try expect(g.tick(time: 1, point: p, buttons: 0) == .none)
                try expect(g.input(.flags, point: p, time: 1) == .none)
                _ = g.input(.flags, point: p, time: 2, flags: trigger.flag)
                _ = g.input(.keyDown, point: p, time: 2.1, flags: trigger.flag, key: 8)
                try expect(g.tick(time: 3, point: p, buttons: 0) == .none)
                try expect(g.input(.flags, point: p, time: 4) == .none)
            }
        }
        check("Long press fires at 0.6 seconds exactly once and owns its release") {
            var g = HoverGesture()
            _ = g.input(.leftDown, point: p, time: 1, buttons: 1)
            try expect(g.tick(time: 1.599, point: p, buttons: 1) == .none)
            try expect(g.tick(time: 1.6, point: p, buttons: 1) == .trigger)
            try expect(g.tick(time: 3, point: p, buttons: 1) == .none)
            try expect(g.input(.leftUp, point: p, time: 3) == .suppressSelection)
            _ = g.input(.leftDown, point: p, time: 4, buttons: 1)
            try expect(g.tick(time: 4.6, point: p, buttons: 1) == .trigger)
        }
        check("Short clicks, drags, scroll, context switches and combinations cancel a hold") {
            for kind in [HoverGesture.Input.leftUp, .scroll, .cancel, .keyDown, .otherMouseDown] {
                var g = HoverGesture(); _ = g.input(.leftDown, point: p, time: 0, buttons: 1)
                _ = g.input(kind, point: p, time: 0.4)
                try expect(g.tick(time: 1, point: p, buttons: 1) == .none)
            }
            var g = HoverGesture(); _ = g.input(.leftDown, point: p, time: 0, buttons: 1)
            _ = g.input(.move, point: CGPoint(x: 26.01, y: 20), time: 0.2)
            try expect(g.tick(time: 1, point: p, buttons: 1) == .none)
            g.reset(); _ = g.input(.leftDown, point: p, time: 0, flags: .shift, buttons: 1)
            try expect(g.tick(time: 1, point: p, buttons: 1) == .none)
        }
        check("Hold accepts the 6 point boundary and preserves release suppression after moving") {
            var g = HoverGesture(); _ = g.input(.leftDown, point: p, time: 0, buttons: 1)
            try expect(g.tick(time: 0.6, point: CGPoint(x: 26, y: 20), buttons: 1) == .trigger)
            _ = g.input(.move, point: CGPoint(x: 80, y: 20), time: 1, buttons: 1)
            try expect(g.input(.leftUp, point: p, time: 2) == .suppressSelection)
        }
        check("All three modifier choices fire on isolated release, including both physical sides") {
            for trigger in [HoverTrigger.control, .shift, .option] {
                for key: UInt16 in [56, 60] {
                    var g = HoverGesture(trigger: trigger)
                    try expect(g.input(.flags, point: p, time: 0, flags: trigger.flag, key: key) == .none)
                    try expect(g.input(.flags, point: p, time: 1, key: key) == .trigger)
                    try expect(g.input(.flags, point: p, time: 2, key: key) == .none)
                }
            }
        }
        check("Modifier combinations, typing, clicks, movement and scrolling never translate") {
            for kind in [HoverGesture.Input.keyDown, .leftDown, .scroll, .otherMouseDown, .cancel] {
                var g = HoverGesture(trigger: .shift)
                _ = g.input(.flags, point: p, time: 0, flags: .shift)
                _ = g.input(kind, point: p, time: 0.1, flags: .shift)
                try expect(g.input(.flags, point: p, time: 1) == .none)
            }
            var g = HoverGesture(trigger: .control)
            _ = g.input(.flags, point: p, time: 0, flags: .control)
            _ = g.input(.flags, point: p, time: 0.1, flags: [.control, .command])
            _ = g.input(.flags, point: p, time: 0.2, flags: .control)
            try expect(g.input(.flags, point: p, time: 1) == .none)
            _ = g.input(.flags, point: p, time: 2, flags: .control)
            try expect(g.input(.flags, point: p, time: 3) == .trigger)
            _ = g.input(.keyDown, point: p, time: 4, key: 0)
            _ = g.input(.flags, point: p, time: 5, flags: .control)
            try expect(g.input(.flags, point: p, time: 6) == .none)
        }
        check("Switching triggers resets a pending hold and disabling cancels its read") {
            let monitor = HoverMonitor(); var cancellations = 0
            monitor.onCancelRead = { cancellations += 1 }
            monitor.configure(enabled: true, trigger: .longPress)
            monitor.configure(enabled: true, trigger: .option)
            try expect(monitor.gesture.trigger == .option && monitor.gesture.holdDeadline == nil)
            monitor.configure(enabled: false, trigger: .option)
            try expect(!monitor.enabled && cancellations == 3)
        }
        check("Lost key releases are reconciled without allowing physically held keys") {
            var g = HoverGesture()
            _ = g.input(.keyDown, point: p, time: 0, key: 12)
            g.reconcileKeys { _ in true }
            _ = g.input(.leftDown, point: p, time: 1, buttons: 1)
            try expect(g.tick(time: 1.7, point: p, buttons: 1) == .none)
            g.reconcileKeys { _ in false }
            _ = g.input(.leftDown, point: p, time: 2, buttons: 1)
            try expect(g.tick(time: 2.7, point: p, buttons: 1) == .trigger)
            try expect(g.input(.leftUp, point: p, time: 3) == .suppressSelection)
            _ = g.input(.leftDown, point: p, time: 4, buttons: 1)
            try expect(g.tick(time: 4.7, point: p, buttons: 1) == .trigger)
        }
        check("Hover monitor recovers after internal input and application changes") {
            let monitor = HoverMonitor(); monitor.configure(enabled: true, trigger: .longPress)
            monitor.pressedMouseButtons = { 1 }
            let down = NSEvent.keyEvent(with: .keyDown, location: p, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            monitor.isKeyDown = { _ in true }
            _ = monitor.event(down)
            _ = monitor.event(click)
            try expect(monitor.gesture.holdDeadline == nil)
            monitor.cancel() // Own-window key-up / app activation uses this production path.
            _ = monitor.event(click)
            try expect(monitor.gesture.holdDeadline != nil)
            monitor.cancel()
            _ = monitor.event(down)
            monitor.isKeyDown = { _ in false } // Missed release consumed by another app.
            _ = monitor.event(click)
            try expect(monitor.gesture.holdDeadline != nil)
            monitor.cancel()
        }
        check("Hover selection ownership blocks AX notifications until the next external input") {
            let monitor = SelectionMonitor(); monitor.enabled = false
            monitor.suppressAutomaticSelectionForHover(); monitor.schedule()
            try expect(monitor.hoverOwnsSelection)
            let mouseUp = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            monitor.onExternalEvent = { $0.type == .leftMouseUp }
            monitor.event(mouseUp); try expect(monitor.hoverOwnsSelection)
            let mouseDown = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            monitor.event(mouseDown); try expect(!monitor.hoverOwnsSelection)
        }
        check("Paragraph indexing uses UTF16 and preserves emoji, combining marks and soft wraps") {
            let first = "😀 First e\u{301} paragraph with a visual wrap."
            let text = first + "\n\n第二段中文。\r\nLast paragraph."
            try expect(try ParagraphText.at(text, offset: 3) == first)
            let index = (text as NSString).range(of: "第二段").location
            try expect(try ParagraphText.at(text, offset: index) == "第二段中文。")
            try expect(try ParagraphText.at(text, offset: (text as NSString).length - 1) == "Last paragraph.")
            try rejects { _ = try ParagraphText.at(text, offset: (first as NSString).length + 1) }
            try rejects { _ = try ParagraphText.at(text, offset: -1) }
        }
        check("Paragraph length is checked without truncation and blank paragraphs are rejected") {
            try expect(try ParagraphText.clean(String(repeating: "a", count: 12000)).count == 12000)
            try rejects { _ = try ParagraphText.clean(String(repeating: "a", count: 12001)) }
            try rejects { _ = try ParagraphText.clean(" \n\t") }
        }
        check("Semantic paragraphs collect links and formatting without neighboring paragraphs") {
            let a = FixtureHoverElement("AXStaticText", text: "Please read ")
            let link = FixtureHoverElement("AXLink", children: [FixtureHoverElement("AXStaticText", text: "this link")])
            let b = FixtureHoverElement("AXStaticText", text: " and the bold words.")
            let paragraph = FixtureHoverElement("AXParagraph", children: [a, link, FixtureHoverElement("AXGroup", children: [b])])
            let page = FixtureHoverElement("AXWebArea", children: [paragraph, FixtureHoverElement("AXParagraph", children: [FixtureHoverElement("AXStaticText", text: "Other paragraph.")])])
            let result = try HoverParagraphAccess(point: p).read(hit: link.descendants[0])
            try expect(result.text == "Please read this link and the bold words.")
            withExtendedLifetime(page) {}
        }
        check("Chromium formatting groups expand to the whole paragraph and stop at multiple paragraphs") {
            let lead = FixtureHoverElement("AXStaticText", text: "Read ")
            let link = FixtureHoverElement("AXLink", children: [FixtureHoverElement("AXStaticText", text: "the link")])
            let bold = FixtureHoverElement("AXGroup", children: [FixtureHoverElement("AXStaticText", text: " and bold words.")])
            let paragraph = FixtureHoverElement("AXGroup", children: [lead, link, bold])
            let container = FixtureHoverElement("AXGroup", children: [paragraph, FixtureHoverElement("AXStaticText", text: "Other paragraph.")])
            for (node, value) in [(bold, " and bold words."), (paragraph, "Read the link and bold words."), (container, "Read the link and bold words.\nOther paragraph.")] {
                node.parameters = { name, _ in
                    switch name {
                    case "AXTextMarkerRangeForUIElement": return "range"
                    case "AXLengthForTextMarkerRange": return NSNumber(value: value.utf16.count)
                    case "AXStringForTextMarkerRange": return value
                    default: return nil
                    }
                }
            }
            try expect(try HoverParagraphAccess(point: p).read(hit: bold.descendants[0]).text == "Read the link and bold words.")
            try expect(try HoverParagraphAccess(point: p).read(hit: link.descendants[0]).text == "Read the link and bold words.")
            withExtendedLifetime(container) {}
        }
        check("Chrome paragraph markers stop before newline-free article containers and retain inline links") {
            let lead = FixtureHoverElement("AXStaticText", text: "Read ")
            let boldLeaf = FixtureHoverElement("AXStaticText", text: "bold")
            let bold = FixtureHoverElement("AXGroup", children: [boldLeaf])
            let linkLeaf = FixtureHoverElement("AXStaticText", text: " and this link.")
            let link = FixtureHoverElement("AXLink", children: [linkLeaf])
            let paragraph = FixtureHoverElement("AXGroup", children: [lead, bold, link])
            let next = FixtureHoverElement("AXGroup", children: [FixtureHoverElement("AXStaticText", text: "Other paragraph.")])
            let article = FixtureHoverElement("AXGroup", children: [paragraph, next, FixtureHoverElement("AXImage")])
            // All ranges intentionally omit newline separators, as the real news page does.
            for (node, value, start, end) in [(bold, "bold", 5, 9), (paragraph, "Readbold and this link.", 0, 24), (article, "Read bold and this link.Other paragraph.", 0, 40)] {
                node.endpoints = { _, isStart in isStart ? start : end }
                node.parameters = { name, argument in
                    switch name {
                    case "AXTextMarkerRangeForUIElement": return "own"
                    case "AXStringForTextMarkerRange": return value
                    case "AXNextParagraphEndTextMarkerForTextMarker": return 24
                    case "AXPreviousParagraphStartTextMarkerForTextMarker": return end > 24 ? 24 : 0
                    case "AXTextMarkerRangeForUnorderedTextMarkers":
                        let points = argument as! [Int]; return abs(points[1] - points[0])
                    case "AXLengthForTextMarkerRange": return NSNumber(value: (argument as? Int) ?? (end - start))
                    default: return nil
                    }
                }
            }
            for hit in [lead, boldLeaf, linkLeaf] {
                try expect(try HoverParagraphAccess(point: p).read(hit: hit).text == "Read bold and this link.")
            }
            withExtendedLifetime(article) {}
        }
        check("Paragraph navigation compares positions without requiring identical marker objects") {
            let leaf = FixtureHoverElement("AXStaticText", text: "Only this paragraph.")
            let paragraph = FixtureHoverElement("AXGroup", children: [leaf])
            let article = FixtureHoverElement("AXGroup", children: [paragraph, FixtureHoverElement("AXImage")])
            paragraph.endpoints = { _, start in start ? "start-forward-affinity" : "end-backward-affinity" }
            paragraph.parameters = { name, value in
                switch name {
                case "AXTextMarkerRangeForUIElement": return "own"
                case "AXStringForTextMarkerRange": return "Only this paragraph."
                case "AXNextParagraphEndTextMarkerForTextMarker": return "end-forward-affinity"
                case "AXPreviousParagraphStartTextMarkerForTextMarker": return "start-backward-affinity"
                case "AXTextMarkerRangeForUnorderedTextMarkers": return "gap"
                case "AXLengthForTextMarkerRange": return NSNumber(value: (value as? String) == "gap" ? 0 : 20)
                default: return nil
                }
            }
            try expect(try HoverParagraphAccess(point: p).read(hit: leaf).text == "Only this paragraph.")
            withExtendedLifetime(article) {}
        }
        check("A standalone headline link reads visible text, excluding its URL and ARIA metadata") {
            let title = "A complete headline with a link"
            let leaf = FixtureHoverElement("AXStaticText", text: title)
            let link = FixtureHoverElement("AXLink", children: [leaf])
            link.attributes[kAXTitleAttribute] = title + " - Publisher - 2 hours ago - Author"
            link.attributes[kAXValueAttribute] = "https://example.com/read/identifier"
            link.markerRange(text: "A complete headline…", start: 0, end: title.utf16.count, paragraphStart: 0, paragraphEnd: title.utf16.count)
            let card = FixtureHoverElement("AXGroup", children: [link, FixtureHoverElement("AXButton"), FixtureHoverElement("AXStaticText", text: "Publisher")])
            for hit in [link, leaf] {
                try expect(try HoverParagraphAccess(point: p).read(hit: hit).text == title)
            }
            withExtendedLifetime(card) {}
        }
        check("Inline hyperlinks still expand to the whole paragraph after headline support") {
            let lead = FixtureHoverElement("AXStaticText", text: "Read ")
            let leaf = FixtureHoverElement("AXStaticText", text: "the link")
            let link = FixtureHoverElement("AXLink", children: [leaf])
            let end = FixtureHoverElement("AXStaticText", text: " in context.")
            let paragraph = FixtureHoverElement("AXGroup", children: [lead, link, end])
            let title = "Read the link in context."
            link.markerRange(text: "the link", start: 5, end: 13, paragraphStart: 0, paragraphEnd: title.utf16.count)
            paragraph.markerRange(text: title, start: 0, end: title.utf16.count, paragraphStart: 0, paragraphEnd: title.utf16.count)
            try expect(try HoverParagraphAccess(point: p).read(hit: link).text == title)
            try expect(try HoverParagraphAccess(point: p).read(hit: leaf).text == title)
            withExtendedLifetime(paragraph) {}
        }
        check("Empty card overlays resolve only the text under the current pointer") {
            let overlay = FixtureHoverElement("AXLink")
            let overlayGroup = FixtureHoverElement("AXGroup", children: [overlay])
            let leaf = FixtureHoverElement("AXStaticText", text: "Full linked headline")
            let title = FixtureHoverElement("AXLink", children: [leaf])
            title.markerRange(text: "Full linked headline", start: 0, end: 20, paragraphStart: 0, paragraphEnd: 20)
            let author = FixtureHoverElement("AXStaticText", text: "By Someone")
            author.attributes["AXFrame"] = CGRect(x: 0, y: 100, width: 200, height: 20)
            leaf.attributes["AXFrame"] = CGRect(x: 0, y: 0, width: 200, height: 40)
            title.attributes["AXFrame"] = leaf.attributes["AXFrame"]
            let card = FixtureHoverElement("AXGroup", children: [overlayGroup, title, author])
            for _ in 0..<4 {
                try expect(try HoverParagraphAccess(point: p).read(hit: overlay).text == "Full linked headline")
                try expect(try HoverParagraphAccess(point: CGPoint(x: 20, y: 110)).read(hit: overlay).text == "By Someone")
            }
            try rejects { _ = try HoverParagraphAccess(point: CGPoint(x: 20, y: 80)).read(hit: overlay) }
            withExtendedLifetime(card) {}
        }
        check("Overlay resolution rejects ambiguous and protected text without climbing the page") {
            let overlay = FixtureHoverElement("AXLink")
            let a = FixtureHoverElement("AXStaticText", text: "First")
            let b = FixtureHoverElement("AXStaticText", text: "Second")
            let card = FixtureHoverElement("AXGroup", children: [overlay, a, b])
            try rejects { _ = try HoverParagraphAccess(point: p).read(hit: overlay) }
            b.attributes["AXProtectedContent"] = true
            do {
                _ = try HoverParagraphAccess(point: p).read(hit: overlay)
                try expect(false)
            } catch HoverReadError.protectedContent {}
            card.attributes[kAXRoleAttribute] = "AXWebArea"
            try rejects { _ = try HoverParagraphAccess(point: p).read(hit: overlay) }
            withExtendedLifetime(card) {}
        }
        check("Image-only links are not translated from their accessible labels or destination") {
            let link = FixtureHoverElement("AXLink", children: [FixtureHoverElement("AXImage")])
            link.attributes[kAXTitleAttribute] = "Misleading image label"
            link.attributes[kAXValueAttribute] = "https://example.com"
            link.markerRange(text: "\u{FFFC}", start: 0, end: 1, paragraphStart: 0, paragraphEnd: 1)
            try rejects { _ = try HoverParagraphAccess(point: p).read(hit: link) }
        }
        check("Chromium group fallback refuses protected descendants and oversized ranges") {
            let leaf = FixtureHoverElement("AXStaticText", text: "Visible")
            let secret = FixtureHoverElement("AXSecureTextField", text: "Secret")
            let group = FixtureHoverElement("AXGroup", children: [leaf, secret])
            group.parameters = { name, _ in
                switch name {
                case "AXTextMarkerRangeForUIElement": return "range"
                case "AXLengthForTextMarkerRange": return NSNumber(value: 14)
                case "AXStringForTextMarkerRange": return "Visible Secret"
                default: return nil
                }
            }
            try rejects { _ = try HoverParagraphAccess(point: p).read(hit: leaf) }
            var readValue = false
            group.parameters = { name, _ in
                if name == "AXTextMarkerRangeForUIElement" { return "range" }
                if name == "AXLengthForTextMarkerRange" { return NSNumber(value: 1000000) }
                if name == "AXStringForTextMarkerRange" { readValue = true }
                return nil
            }
            _ = try? HoverParagraphAccess(point: p).read(hit: leaf)
            try expect(!readValue)
            withExtendedLifetime(group) {}
        }
        check("Marker paragraph reads use pointer position, not selection or whole-page values") {
            let leaf = FixtureHoverElement("AXStaticText", text: "Fragment")
            let page = FixtureHoverElement("AXWebArea", children: [leaf])
            page.attributes[kAXSelectedTextAttribute] = "Wrong old selection"
            page.attributes[kAXValueAttribute] = "Wrong entire page"
            page.parameters = { name, _ in
                switch name {
                case "AXTextMarkerForPosition": return "pointer-marker"
                case "AXParagraphTextMarkerRangeForTextMarker": return "paragraph-range"
                case "AXStringForTextMarkerRange": return "Correct hovered paragraph."
                case "AXBoundsForTextMarkerRange": return CGRect(x: 0, y: 0, width: 100, height: 50)
                default: return nil
                }
            }
            try expect(try HoverParagraphAccess(point: p).read(hit: leaf).text == "Correct hovered paragraph.")
            withExtendedLifetime(page) {}
        }
        check("Whitespace, controls, a whole web area and ambiguous multi-paragraph leaves are rejected") {
            for node in [FixtureHoverElement("AXWebArea", text: "Entire page"), FixtureHoverElement("AXButton", text: "Click me"), FixtureHoverElement("AXStaticText", text: "First\nSecond"), FixtureHoverElement("AXStaticText", text: "  ")] {
                try rejects { _ = try HoverParagraphAccess(point: p).read(hit: node) }
            }
            let node = FixtureHoverElement("AXStaticText", text: "Outside pointer")
            try rejects { _ = try HoverParagraphAccess(point: CGPoint(x: 600, y: 600)).read(hit: node) }
        }
        check("Protected fields and protected ancestors never expose text") {
            let leaf = FixtureHoverElement("AXStaticText", text: "Secret")
            let parent = FixtureHoverElement("AXSecureTextField", children: [leaf])
            try rejects { _ = try HoverParagraphAccess(point: p).read(hit: leaf) }
            parent.attributes[kAXRoleAttribute] = "AXParagraph"; parent.attributes["AXProtectedContent"] = true
            try rejects { _ = try HoverParagraphAccess(point: p).read(hit: leaf) }
        }
        check("Read cancellation, deadlines and bounded traversal fail without returning fragments") {
            let node = FixtureHoverElement("AXStaticText", text: "Hello")
            try rejects { _ = try HoverParagraphAccess(point: p, isCurrent: { false }).read(hit: node) }
            try rejects { _ = try HoverParagraphAccess(point: p, deadline: .distantPast).read(hit: node) }
            let children = (0..<257).map { _ in FixtureHoverElement("AXStaticText", text: "a ") }
            let paragraph = FixtureHoverElement("AXParagraph", children: children)
            try rejects { _ = try HoverParagraphAccess(point: p).read(hit: children[0]) }
            withExtendedLifetime(paragraph) {}
            let ticket = HoverReadTicket(); try expect(ticket.isCurrent); ticket.cancel(); try expect(!ticket.isCurrent)
        }
        check("Stale Chrome hit results retry the current point with a bounded attempt count") {
            let stale = FixtureHoverElement("AXStaticText", text: "Wrong previous headline")
            stale.attributes["AXFrame"] = CGRect(x: 600, y: 600, width: 100, height: 50)
            let current = FixtureHoverElement("AXStaticText", text: "Correct current headline")
            var hits = 0; var pauses = 0
            let result = try HoverParagraphReader.read(point: p, ticket: HoverReadTicket(), hitTest: {
                hits += 1; return hits < 3 ? stale : current
            }, pause: { pauses += 1 })
            try expect(result.text == "Correct current headline" && hits == 3 && pauses == 2)
            hits = 0; pauses = 0
            try rejects { _ = try HoverParagraphReader.read(point: p, ticket: HoverReadTicket(), hitTest: { hits += 1; return nil }, pause: { pauses += 1 }) }
            try expect(hits == 3 && pauses == 2)
        }
        check("Hit retries stop on cancellation and never retry protected content") {
            let ticket = HoverReadTicket(); var hits = 0
            do {
                _ = try HoverParagraphReader.read(point: p, ticket: ticket, hitTest: { hits += 1; return nil }, pause: { ticket.cancel() })
                try expect(false)
            } catch is CancellationError {}
            try expect(hits == 1)
            let secure = FixtureHoverElement("AXSecureTextField", text: "private")
            hits = 0
            do {
                _ = try HoverParagraphReader.read(point: p, ticket: HoverReadTicket(), hitTest: { hits += 1; return secure }, pause: { hits += 100 })
                try expect(false)
            } catch HoverReadError.protectedContent {}
            try expect(hits == 1)
        }
        check("Native character-position path reads only its logical paragraph") {
            let source = "😀 Earlier paragraph.\nHovered paragraph wraps visually.\nOther paragraph."
            let node = FixtureHoverElement("AXTextArea")
            node.attributes[kAXNumberOfCharactersAttribute] = (source as NSString).length
            node.attributes[kAXSelectedTextAttribute] = "Wrong old selection"
            let index = (source as NSString).range(of: "Hovered").location
            node.parameters = { name, parameter in
                if name == kAXRangeForPositionParameterizedAttribute {
                    var range = CFRange(location: index + 2, length: 1); return AXValueCreate(.cfRange, &range)
                }
                if name == kAXBoundsForRangeParameterizedAttribute { return CGRect(x: 0, y: 0, width: 100, height: 80) }
                if name == kAXStringForRangeParameterizedAttribute {
                    var range = CFRange(); AXValueGetValue(parameter as! AXValue, .cfRange, &range)
                    return (source as NSString).substring(with: NSRange(location: range.location, length: range.length))
                }
                return nil
            }
            try expect(try HoverParagraphAccess(point: p).read(hit: node).text == "Hovered paragraph wraps visually.")
            node.parameters = { _, _ in nil }
            try rejects { _ = try HoverParagraphAccess(point: p).read(hit: node) }
        }
    }
}
