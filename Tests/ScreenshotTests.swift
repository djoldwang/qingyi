import AppKit
import Vision

@MainActor
final class FixtureScreenshotCapture: ScreenshotCapturing {
    var image: CGImage?
    var error: Error?
    private(set) var captures = 0
    var cancelled = false
    var delay: UInt64 = 0
    func capture() async throws -> CGImage? {
        captures += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let error = error { throw error }; return image
    }
    func cancel() { cancelled = true }
}
final class FixtureScreenshotOCR: ScreenshotRecognizing {
    var text = "A screenshot contains useful text for translation."
    var delay: UInt64 = 0
    var calls = 0
    var error: Error?
    func recognize(_ image: CGImage) async throws -> String {
        calls += 1
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) } // Deliberately late result.
        if let error = error { throw error }; return text
    }
}

extension QingyiTests {
    @MainActor static func screenshotEmojiTests(path: String) async {
        await asyncCheck("Emoji screenshot: real Vision preserves all eight feature lines without duplicates") {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
            let labels = ["Decentralized", "Easy to Use", "Cross-Platform", "Secure:", "Efficient NAT Traversal", "Subnet Proxy", "Intelligent Routing", "High Performance"]
            func verify(_ text: String) throws {
                for label in labels { try expect(text.components(separatedBy: label).count == 2, "Missing or duplicated: \(label)\n\(text)") }
                for continuation in ["required", "architectures", "attacks", "NAT4 networks", "network experience", "protocols"] {
                    try expect(text.contains(continuation), "Missing continuation: \(continuation)")
                }
            }
            let full = try await VisionScreenshotOCR().recognize(image)
            try verify(full)
            // Reproduce the reported loss of all emoji-bearing rows at the first
            // recognition boundary, while keeping detection/crop OCR real.
            let recovering = VisionScreenshotOCR(perform: { input, request in
                var initial = true
                return try ScreenshotOCRRecognition.lines(input, request: request, cancelled: { false }) { pixels, pass in
                    try VNImageRequestHandler(cgImage: pixels).perform([pass])
                    let lines = (pass.results ?? []).compactMap { observation in
                        observation.topCandidates(1).first.map { ScreenshotOCRLine(text: $0.string, box: observation.boundingBox) }
                    }
                    defer { initial = false }
                    return initial ? lines.filter { line in !labels.contains { line.text.contains($0) } } : lines
                }
            })
            let recovered = try await recovering.recognize(image)
            try verify(recovered)
            print("Recovered original sample:\n" + recovered)
        }
        check("Supplemental OCR cancellation stops before another region starts") {
            let image = screenshotImage()
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
            var calls = 0; var cancelled = false
            do {
                _ = try ScreenshotOCRRecognition.lines(image, request: request, cancelled: { cancelled }) { _, _ in
                    calls += 1
                    if calls == 2 { cancelled = true }
                    return calls == 1 ? [] : [ScreenshotOCRLine(text: "Missing text", box: CGRect(x: 0.1, y: 0.3, width: 0.7, height: 0.2))]
                }
                throw QingyiError.message("Expected cancellation")
            } catch is CancellationError { }
            try expect(calls == 2 && request.recognitionLevel == .accurate)
        }
    }
    @MainActor static func screenshotImage(text: String = "Small steps make complex things easier to understand.") -> CGImage {
        let image = NSImage(size: NSSize(width: 1100, height: 180))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1100, height: 180).fill()
        (text as NSString).draw(at: NSPoint(x: 30, y: 75), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
    static func screenshotScrollEvent(phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none) -> NSEvent {
        let unit: CGScrollEventUnit = phase == nil && momentum == .none ? .line : .pixel
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: unit, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0)!
        if let phase { wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        wheel.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        wheel.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        return NSEvent(cgEvent: wheel)!
    }
    @MainActor static func screenshotTests() async {
        check("Screenshot OCR preserves paragraphs and list boundaries, joins prose and CJK") {
            let lines = [
                ScreenshotOCRLine(text: "Continued sentence.", box: CGRect(x: 0.1, y: 0.78, width: 0.5, height: 0.05)),
                ScreenshotOCRLine(text: "First sentence.", box: CGRect(x: 0.1, y: 0.85, width: 0.5, height: 0.05)),
                ScreenshotOCRLine(text: "New paragraph.", box: CGRect(x: 0.1, y: 0.60, width: 0.5, height: 0.05)),
                ScreenshotOCRLine(text: "• First item", box: CGRect(x: 0.1, y: 0.53, width: 0.5, height: 0.05)),
                ScreenshotOCRLine(text: "• Second item", box: CGRect(x: 0.1, y: 0.46, width: 0.5, height: 0.05))]
            try expect(ScreenshotText.merge(lines) == "First sentence. Continued sentence.\n\nNew paragraph.\n• First item\n• Second item")
            let cjk = [ScreenshotOCRLine(text: "这是第一行", box: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05)), ScreenshotOCRLine(text: "接着第二行。", box: CGRect(x: 0.1, y: 0.73, width: 0.5, height: 0.05))]
            try expect(ScreenshotText.merge(cjk) == "这是第一行接着第二行。")
        }
        check("Screenshot validation rejects no text, Chinese and oversized input without truncation") {
            for text in ["  \n", "这段文字已经是中文。", String(repeating: "a", count: 12_001)] { try rejects { _ = try ScreenshotText.validate(text) } }
            try expect(try ScreenshotText.validate(String(repeating: "a", count: 12_000)).count == 12_000)
            try expect(ScreenshotText.languages(preferred: ["fr-CA", "unsupported"], supported: ["en-US", "zh-Hans", "ja-JP", "fr-FR"]) == ["fr-FR", "en-US", "zh-Hans", "ja-JP"])
        }
        check("Screenshot shortcut persists separately and recorder labels identify both actions") {
            let name = "qingyi-screenshot-shortcuts-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let store = ShortcutPreferences(defaults: defaults)
            try expect(store.screenshot == .defaultScreenshot && store.preferred == .defaultClipboard)
            store.saveScreenshot(.legacyDefault)
            try expect(store.screenshot == .legacyDefault && store.preferred == .defaultClipboard)
            let button = ShortcutRecorderButton(); button.actionName = "截图翻译"
            try expect(button.accessibilityLabel() == "录制截图翻译的快捷键")
        }
        check("Screenshot suspension ignores native mouse-up and AX work, then accepts a fresh modifier gesture") {
            let monitor = SelectionMonitor()
            var forwarded = 0; var cleared = 0
            monitor.onExternalEvent = { _ in forwarded += 1; return false }
            monitor.onSelection = { _ in cleared += 1 }
            let release = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            monitor.setScreenshotSuspended(true); monitor.event(release); monitor.schedule()
            try expect(forwarded == 0 && cleared == 0 && monitor.screenshotSuspended)
            monitor.setScreenshotSuspended(false); monitor.event(release); monitor.schedule()
            try expect(forwarded == 0 && cleared == 0 && monitor.screenshotAwaitingFreshInput)
            let shiftRelease = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.command, .control], timestamp: ProcessInfo.processInfo.systemUptime + 1,
                                                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
            monitor.event(shiftRelease)
            try expect(forwarded == 0 && monitor.screenshotAwaitingFreshInput, "Releasing Shift while other shortcut modifiers are down is still capture cleanup")
            let option = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime + 1, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
            monitor.event(option)
            try expect(forwarded == 1 && !monitor.screenshotAwaitingFreshInput)
        }
        check("Screenshot suspension ignores ongoing scrolling and resumes on the first traditional mouse-wheel tick") {
            let monitor = SelectionMonitor()
            var scrolls = 0
            monitor.onScroll = { scrolls += 1 }
            monitor.setScreenshotSuspended(true)
            monitor.setScreenshotSuspended(false)
            let continued = screenshotScrollEvent(phase: .changed)
            let momentum = screenshotScrollEvent(momentum: .continuous)
            try expect(continued.phase == .changed && !momentum.momentumPhase.isEmpty, "Fixture must represent an ongoing gesture and its inertia")
            for event in [continued, momentum] {
                monitor.event(event)
                try expect(monitor.screenshotAwaitingFreshInput && scrolls == 0, "Only a new scroll gesture should resume external input")
            }
            let wheel = screenshotScrollEvent()
            try expect(wheel.phase.isEmpty && wheel.momentumPhase.isEmpty)
            monitor.event(wheel)
            try expect(!monitor.screenshotAwaitingFreshInput && scrolls == 1, "A traditional mouse emits individual ticks without phases")
        }
        let image = screenshotImage()
        await asyncCheck("Native capture reads output, deletes its directory, handles cancel, bad image and launch failure") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingyi-screenshot-fixture-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let png = directory.appendingPathComponent("fixture.png")
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(to: png)
            var output: URL?
            let capture = NativeScreenshotCapture(executable: URL(fileURLWithPath: "/bin/cp"), arguments: { output = $0; return [png.path, $0.path] })
            let result = try await capture.capture()
            try expect(result?.width == image.width && !FileManager.default.fileExists(atPath: output!.deletingLastPathComponent().path))
            let reread = NSBitmapImageRep(cgImage: result!).representation(using: .png, properties: [:])
            try expect(reread != nil, "Captured pixels must remain readable after the native temporary PNG is deleted")
            let realText = try await VisionScreenshotOCR().recognize(result!)
            try expect(realText.contains("Small steps"), "Deleted capture file must not invalidate OCR")
            let cancelled = NativeScreenshotCapture(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: { output = $0; return [] })
            let noImage = try await cancelled.capture()
            try expect(noImage == nil)
            try expect(!FileManager.default.fileExists(atPath: output!.deletingLastPathComponent().path))
            let invalid = NativeScreenshotCapture(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: { output = $0; return [$0.path] })
            do { _ = try await invalid.capture(); throw QingyiError.message("Expected invalid image error") } catch { try expect(error.localizedDescription.contains("读取截图")) }
            try expect(!FileManager.default.fileExists(atPath: output!.deletingLastPathComponent().path))
            let missing = NativeScreenshotCapture(executable: directory.appendingPathComponent("missing"), arguments: { output = $0; return [] })
            do { _ = try await missing.capture(); throw QingyiError.message("Expected launch error") } catch { try expect(error.localizedDescription.contains("启动系统截图")) }
            try expect(!FileManager.default.fileExists(atPath: output!.deletingLastPathComponent().path))
            let sleeping = NativeScreenshotCapture(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: { output = $0; return ["3"] })
            let task = Task { try await sleeping.capture() }
            try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
            do { _ = try await task.value; throw QingyiError.message("Expected cancellation") } catch is CancellationError { }
            try expect(!FileManager.default.fileExists(atPath: output!.deletingLastPathComponent().path))
        }
        await asyncCheck("Screenshot release waits for modifiers and key, cancellation stops waiting") {
            var polls = 0
            try await ScreenshotHotkeyRelease.wait(binding: .defaultScreenshot, isDown: { polls += 1; return polls < 4 })
            try expect(polls == 4)
            let waiting = Task { try await ScreenshotHotkeyRelease.wait(binding: nil, isDown: { true }) }
            try await Task.sleep(nanoseconds: 30_000_000); waiting.cancel()
            do { try await waiting.value; throw QingyiError.message("Expected release cancellation") } catch is CancellationError { }
        }
        await asyncCheck("Real Vision recognizes a generated English screenshot offline") {
            let text = try await VisionScreenshotOCR().recognize(image)
            try expect(text.contains("Small steps") && text.contains("understand"), text)
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            let source = CGImageSourceCreateWithData(png as CFData, nil)!
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let decodedText = try await VisionScreenshotOCR().recognize(decoded)
            try expect(decodedText.contains("Small steps") && decodedText.contains("understand"), decodedText)
        }
        await asyncCheck("OCR timeout and cancellation discard late output and bound underlying concurrency") {
            let ocr = VisionScreenshotOCR(timeout: 0.03, perform: { _, _ in
                Thread.sleep(forTimeInterval: 0.18)
                return [ScreenshotOCRLine(text: "Late text", box: .zero)]
            })
            do { _ = try await ocr.recognize(image); throw QingyiError.message("Expected timeout") }
            catch { try expect(error.localizedDescription == "文字识别超时。点击“重试”可重新识别这张截图。如需缩小范围，请再次使用“截图翻译”并重新框选。") }
            do { _ = try await ocr.recognize(image); throw QingyiError.message("Expected busy rejection") } catch { try expect(error.localizedDescription.contains("仍在结束")) }
            try await Task.sleep(nanoseconds: 200_000_000)
            let task = Task { try await ocr.recognize(image) }
            try await Task.sleep(nanoseconds: 5_000_000); task.cancel()
            do { _ = try await task.value; throw QingyiError.message("Expected OCR cancellation") } catch is CancellationError { }
        }
        await screenshotAppTests(image: image)
    }
    @MainActor static func screenshotAppTests(image: CGImage) async {
        await asyncCheck("An unpinned screenshot survives focus and scrolling until every service finishes and still supports explicit dismissal") {
            let domain = "qingyi-screenshot-window-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain); FixtureAPIProtocol.handle = nil }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            var provider = APIProvider()
            provider.name = "Window fixture"; provider.baseURL = "https://fixture.example/v1"
            provider.models = [APIModel(id: "fixture", name: "fixture")]
            try store.save(provider, replacementKey: "fixture-only")
            try store.selectProvider(provider.id)
            let translation = "截图译文"
            FixtureAPIProtocol.handle = { _ in
                let body = "data: {\"choices\":[{\"delta\":{\"content\":\"截图译文\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
                return (200, "text/event-stream", Data(body.utf8))
            }
            let capture = FixtureScreenshotCapture()
            capture.image = image
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: store, client: CustomAPIClient(session: FixtureAPIProtocol.session()))
            let app = AppDelegate(preferences: Preferences(defaults: defaults))
            app.prepareScreenshotFixture(engine: engine, capture: capture, ocr: VisionScreenshotOCR())
            app.services = BuiltinTranslationSettings(defaults: defaults, enabledByDefault: false)
            app.services.youdao = true
            var releaseSlowService: CheckedContinuation<Void, Never>?
            app.builtinClient = BuiltinTranslationClient(youdao: { _ in
                await withCheckedContinuation { releaseSlowService = $0 }
                return BuiltinTranslationResult(text: "较慢服务的译文")
            })
            // Inject external events independently of where the real pointer happens to be.
            app.monitor.isInternalInteraction = { _ in false }
            defer { app.floating.onClose?(); releaseSlowService?.resume() }
            func mouse(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            }
            func key(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            }
            // Place the panel away from the pointer used by the synthetic outside click.
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
                app.preferences.translationWindowPosition = NSEvent.mouseLocation.x < screen.frame.midX ? .upperRight : .upperLeft
            }
            for cancelWhileLoading in [false, true] {
                app.translateScreenshot()
                for _ in 0..<700 where releaseSlowService == nil || app.floating.state.text != translation { try await Task.sleep(for: .milliseconds(10)) }
                try expect(releaseSlowService != nil && app.floating.state.text == translation && app.floating.state.loading)
                try expect(app.floating.resultPanel.isVisible && !app.floating.state.pinned)
                let session = app.floating.state.sessionID
                app.monitor.event(mouse(.leftMouseUp))
                app.monitor.event(mouse(.mouseMoved))
                app.monitor.event(key(.flagsChanged, code: 56, flags: .shift))
                app.monitor.applicationActivated(pid: 1)
                app.monitor.schedule()  // The AX observer may report the restored selection.
                app.monitor.event(key(.keyDown, code: 0))
                app.monitor.event(screenshotScrollEvent(phase: .began))
                app.monitor.event(screenshotScrollEvent())
                app.monitor.event(screenshotScrollEvent(momentum: .continuous))
                await Task.yield()
                try expect(app.floating.resultPanel.isVisible && app.floating.state.sessionID == session && app.floating.state.loading,
                           "Focus restoration, selection updates and scrolling must preserve the in-flight screenshot")
                if cancelWhileLoading { app.monitor.event(key(.keyDown, code: 53)) }
                releaseSlowService?.resume(); releaseSlowService = nil
                if cancelWhileLoading {
                    try await Task.sleep(for: .milliseconds(50))
                    try expect(!app.floating.resultPanel.isVisible && app.floating.state.services.isEmpty, "Late service replies must not reopen the panel")
                } else {
                    for _ in 0..<200 where !app.floating.state.complete { try await Task.sleep(for: .milliseconds(10)) }
                    app.monitor.event(mouse(.mouseMoved))
                    app.monitor.applicationActivated(pid: 1)
                    app.monitor.event(screenshotScrollEvent(momentum: .continuous))
                    try expect(app.floating.resultPanel.isVisible && app.floating.state.sessionID == session && app.floating.state.complete)
                    try expect(app.floating.state.services.first { $0.id == .youdao }?.result.text == "较慢服务的译文")
                    app.monitor.event(mouse(.leftMouseDown))
                }
                try expect(!app.floating.resultPanel.isVisible, "The next outside click or Escape should still close the screenshot result")
            }
        }
        await asyncCheck("Screenshot entry skips Chinese silently, preserves pinned session, and retains error retry and English requests") {
            let domain = "qingyi-screenshot-app-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain); FixtureAPIProtocol.handle = nil }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            var provider = APIProvider(); provider.name = "screenshot fixture"; provider.baseURL = "https://fixture.example/v1"
            provider.models = [APIModel(id: "fixture", name: "fixture")]
            try store.save(provider, replacementKey: "fixture-only"); try store.selectProvider(provider.id)
            var bodies: [Data] = []
            FixtureAPIProtocol.handle = { request in
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                    }
                }
                bodies.append(data)
                return (200, "application/json", Data(#"{"choices":[{"message":{"content":"截图翻译测试完成"},"finish_reason":"stop"}]}"#.utf8))
            }
            let app = AppDelegate(); let capture = FixtureScreenshotCapture(); let ocr = FixtureScreenshotOCR()
            app.prepareScreenshotFixture(engine: TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: store, client: CustomAPIClient(session: FixtureAPIProtocol.session())), capture: capture, ocr: ocr)
            defer { app.floating.onClose?() }
            app.floating.showResult(); app.floating.state.text = "Existing translation"
            app.floating.state.loading = false; app.floating.state.pinned = true
            let previousID = app.floating.state.sessionID; let frame = app.floating.resultPanel.frame
            app.translateScreenshot()
            try expect(app.monitor.screenshotSuspended && !app.floating.resultPanel.isVisible)
            for _ in 0..<100 where app.screenshotActiveFixture { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(capture.captures == 1 && app.floating.resultPanel.isVisible && app.floating.state.pinned)
            try expect(app.floating.state.text == "Existing translation" && app.floating.state.sessionID == previousID && app.floating.resultPanel.frame == frame)
            try expect(!app.monitor.screenshotSuspended && bodies.isEmpty)
            capture.image = image
            let chinese = ["这段文字已经是中文。", "這段文字已經是中文。", "请给云朵剧场的 LUMI 纸龙准备两张 MOON 舞会请柬。"]
            for text in chinese {
                ocr.text = text; app.translateScreenshot()
                for _ in 0..<100 where app.screenshotActiveFixture { try await Task.sleep(nanoseconds: 10_000_000) }
                try expect(app.floating.resultPanel.isVisible && app.floating.state.pinned && !app.floating.state.error)
                try expect(app.floating.state.text == "Existing translation" && app.floating.state.sessionID == previousID && app.floating.resultPanel.frame == frame)
                try expect(bodies.isEmpty && !app.screenshotActiveFixture)
            }
            app.floating.onClose?()
            ocr.delay = 120_000_000; ocr.text = chinese[0]
            let callsBefore = ocr.calls; app.translateScreenshot()
            for _ in 0..<100 where ocr.calls == callsBefore { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(!app.floating.resultPanel.isVisible, "Chinese OCR must not flash a loading window")
            for _ in 0..<100 where app.screenshotActiveFixture { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(!app.floating.resultPanel.isVisible && !app.floating.state.error && bodies.isEmpty)
            ocr.delay = 0; ocr.calls = 0
            app.preferences.paused = true; app.preferences.trusted = false // Manual action is independent.
            ocr.error = QingyiError.message("fixture OCR failure")
            app.translateScreenshot()
            for _ in 0..<100 where !app.floating.state.error { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(app.floating.state.error && ocr.calls == 1 && bodies.isEmpty)
            ocr.error = nil; ocr.text = String(repeating: "A complete screenshot sentence. ", count: 40)
            let capturesBeforeRetry = capture.captures
            app.floating.onRetry?()
            try expect(app.floating.state.loading && app.floating.state.loadingMessage == "正在识别截图中的文字…")
            for _ in 0..<150 where !app.floating.state.complete { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(app.floating.state.complete && ocr.calls == 2 && bodies.count == 1)
            try expect(capture.captures == capturesBeforeRetry && app.floating.state.loadingMessage == nil)
            try expect(String(data: bodies[0], encoding: .utf8)?.contains(TextPolicy.clean(ocr.text)) == true, "Full OCR source must reach the provider")
            app.floating.state.pinned = true
            let translatedID = app.floating.state.sessionID; let translatedText = app.floating.state.text
            let translatedFrame = app.floating.resultPanel.frame; let originalEnglish = TextPolicy.clean(ocr.text)
            ocr.text = chinese[1]; app.translateScreenshot()
            for _ in 0..<100 where app.screenshotActiveFixture { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(capture.captures == capturesBeforeRetry + 1)
            try expect(app.floating.resultPanel.isVisible && app.floating.state.pinned && app.floating.state.complete && !app.floating.state.error)
            try expect(app.floating.state.sessionID == translatedID && app.floating.state.text == translatedText && app.floating.resultPanel.frame == translatedFrame && bodies.count == 1)
            app.floating.onRetry?()
            for _ in 0..<150 where !app.floating.state.complete { try await Task.sleep(nanoseconds: 10_000_000) }
            try expect(bodies.count == 2 && ocr.calls == 3)
            try expect(String(data: bodies.last!, encoding: .utf8)?.contains(originalEnglish) == true, "Chinese screenshot must preserve the previous retry source")
            for invalid in ["", String(repeating: "a", count: 12_001)] {
                let oldErrorID = app.floating.state.sessionID
                ocr.text = invalid; app.translateScreenshot()
                for _ in 0..<100 where app.floating.state.sessionID == oldErrorID { try await Task.sleep(nanoseconds: 10_000_000) }
                try expect(app.floating.state.sessionID != oldErrorID && app.floating.state.error && bodies.count == 2)
            }
            ocr.delay = 180_000_000; ocr.text = "A late screenshot must never replace the new task."
            app.translateScreenshot()
            try await Task.sleep(nanoseconds: 140_000_000)
            app.floating.onClose?()
            try await Task.sleep(nanoseconds: 200_000_000)
            try expect(!app.floating.resultPanel.isVisible && bodies.count == 2 && !app.screenshotActiveFixture)
            app.translateScreenshot()
            try await Task.sleep(nanoseconds: 140_000_000)
            app.screenshotClipboardFixture("A newer manual translation wins.")
            for _ in 0..<150 where !app.floating.state.complete { try await Task.sleep(nanoseconds: 10_000_000) }
            try await Task.sleep(nanoseconds: 200_000_000)
            try expect(bodies.count == 3 && !app.screenshotActiveFixture)
            try expect(String(data: bodies.last!, encoding: .utf8)?.contains("A newer manual translation wins.") == true)
            let originalClipboard = app.preferences.shortcutBinding
            try expect(!app.applyScreenshotShortcut(originalClipboard))
            try expect(!app.applyShortcut(app.preferences.screenshotShortcutBinding))
        }
    }
}

// Opt-in native diagnostic uses the exact production delegate and capture path.
// Only this test harness saves the explicitly selected sample for visual QA.
@MainActor
final class RecordingScreenshotCapture: ScreenshotCapturing {
    private let native = NativeScreenshotCapture()
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    func cancel() { native.cancel() }
    func capture() async throws -> CGImage? {
        let image = try await native.capture()
        guard let image = image else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw QingyiError.message("诊断：截图像素在临时文件清理后不可读取。")
        }
        try png.write(to: directory.appendingPathComponent("selected-sample.png"), options: .atomic)
        let details: [String: Any] = ["width": image.width, "height": image.height, "bitsPerComponent": image.bitsPerComponent,
            "bitsPerPixel": image.bitsPerPixel, "colorSpace": image.colorSpace?.name as String? ?? "unknown", "permission": CGPreflightScreenCaptureAccess()]
        try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("capture.json"))
        return image
    }
}

extension QingyiTests {
    @MainActor static func runNativeScreenshotFixture() {
        guard let index = CommandLine.arguments.firstIndex(of: "--screenshot-evidence"), CommandLine.arguments.count > index + 1 else { exit(2) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.screenshotCapture = RecordingScreenshotCapture(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        app.delegate = delegate
        // The user/agent chooses the crop with the native UI. No synthetic input.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            delegate.translateScreenshot()
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
