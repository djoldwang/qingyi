import AppKit
import Vision
import Carbon

@MainActor
protocol ScreenshotCapturing: AnyObject {
    func capture() async throws -> CGImage?
    func cancel()
}

protocol ScreenshotRecognizing: AnyObject {
    func recognize(_ image: CGImage) async throws -> String
}

// Every run owns its output directory. A cancelled process cleans up only after
// exiting, so it cannot recreate a file after its owner has removed the directory.
@MainActor
final class NativeScreenshotCapture: ScreenshotCapturing {
    private final class Run {
        let id: UUID
        let process = Process()
        let directory: URL
        let output: URL
        let errors = Pipe()
        var continuation: CheckedContinuation<CGImage?, Error>?
        var cancelled = false
        init(id: UUID) throws {
            self.id = id
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingyi-screenshot-" + UUID().uuidString, isDirectory: true)
            output = directory.appendingPathComponent("capture.png")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    private var run: Run?
    private let executable: URL
    private let arguments: (URL) -> [String]
    init(executable: URL = URL(fileURLWithPath: "/usr/sbin/screencapture"),
         arguments: @escaping (URL) -> [String] = { ["-i", "-s", "-x", $0.path] }) {
        self.executable = executable; self.arguments = arguments
    }
    func capture() async throws -> CGImage? {
        try Task.checkCancellation()
        guard run == nil else { throw QingyiError.message("截图正在进行，请先完成或按 Esc 取消。") }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let current = try Run(id: id)
                    current.continuation = continuation; run = current
                    current.process.executableURL = executable
                    current.process.arguments = arguments(current.output)
                    current.process.standardError = current.errors
                    current.process.standardOutput = FileHandle.nullDevice
                    current.process.terminationHandler = { [weak self] _ in
                        Task { @MainActor in self?.finish(current) }
                    }
                    do { try current.process.run() }
                    catch { finish(current, launchError: error) }
                } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { Task { @MainActor [weak self] in if self?.run?.id == id { self?.cancel() } } })
    }
    func cancel() {
        guard let current = run else { return }
        current.cancelled = true
        if current.process.isRunning { current.process.terminate() }
    }
    private func finish(_ current: Run, launchError: Error? = nil) {
        guard let continuation = current.continuation else { return }
        current.continuation = nil
        current.process.terminationHandler = nil
        if run === current { run = nil }
        defer { try? FileManager.default.removeItem(at: current.directory) }
        if current.cancelled { continuation.resume(throwing: CancellationError()); return }
        if launchError != nil {
            continuation.resume(throwing: QingyiError.message("无法启动系统截图，请重新打开轻译后重试。")); return
        }
        let exists = FileManager.default.fileExists(atPath: current.output.path)
        if exists {
            // ImageIO normally decodes on first render. A URL-backed image would
            // lose its pixels when the defer below deletes the temporary PNG.
            // Own the bytes and decode now, before returning it to background OCR.
            guard let data = try? Data(contentsOf: current.output),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                continuation.resume(throwing: QingyiError.message("无法读取截图，请重新框选。")); return
            }
            continuation.resume(returning: image)
        } else {
            let errorData = current.errors.fileHandleForReading.readDataToEndOfFile()
            if !errorData.isEmpty {
                continuation.resume(throwing: QingyiError.message("系统截图未完成。请检查屏幕录制权限，再重新框选。"))
            } else { continuation.resume(returning: nil) } // Native Esc cancellation has no output.
        }
    }
}

struct ScreenshotOCRLine {
    let text: String
    let box: CGRect // Vision's normalized, bottom-left coordinates.
    var preserveLineBreak = false
}

enum ScreenshotText {
    static func merge(_ observations: [ScreenshotOCRLine]) -> String {
        let ordered = observations.filter { !TextPolicy.clean($0.text).isEmpty }.sorted { $0.box.midY > $1.box.midY }
        var rows: [[ScreenshotOCRLine]] = []
        for line in ordered {
            if let first = rows.last?.first,
               abs(first.box.midY - line.box.midY) < min(first.box.height, line.box.height) * 0.45 {
                rows[rows.count - 1].append(line)
            } else { rows.append([line]) }
        }
        let lines = rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
        var result = ""
        var previous: ScreenshotOCRLine?
        for line in lines {
            let text = TextPolicy.clean(line.text)
            if let before = previous {
                let height = max(0.001, min(before.box.height, line.box.height))
                let sameRow = abs(before.box.midY - line.box.midY) < height * 0.45
                let gap = before.box.minY - line.box.maxY
                let aligned = abs(before.box.minX - line.box.minX) < height
                let list = text.range(of: #"^(?:[-*•●▪‣]|\d+[.)、]|[A-Za-z][.)])\s"#, options: .regularExpression) != nil
                if sameRow {
                    result += line.box.minX - before.box.maxX > height * 2 ? "\n" : " "
                } else if gap > height * 0.8 { result += "\n\n" }
                else if list || line.preserveLineBreak || !aligned { result += "\n" }
                else if result.hasSuffix("-"), text.first?.isLowercase == true { result.removeLast() }
                else if !isCJK(result.last) || !isCJK(text.first) { result += " " }
            }
            result += text; previous = line
        }
        return TextPolicy.clean(result)
    }
    private static func isCJK(_ character: Character?) -> Bool {
        guard let value = character?.unicodeScalars.first?.value else { return false }
        return (0x2e80...0x9fff).contains(value) || (0xac00...0xd7af).contains(value) || (0x20000...0x3134f).contains(value)
    }
    static func validate(_ text: String) throws -> String {
        let text = TextPolicy.clean(text)
        guard !text.isEmpty else { throw QingyiError.message("截图中没有识别到文字，请重新框选清晰的文字区域。") }
        return try TextPolicy.validate(text)
    }
    static func languages(preferred: [String], supported: [String]) -> [String] {
        var result: [String] = []
        for language in preferred + ["en-US", "zh-Hans", "zh-Hant", "ja-JP"] {
            let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
            let match = supported.first { $0.lowercased() == normalized }
                ?? supported.first { $0.lowercased().hasPrefix(normalized + "-") }
                ?? supported.first { $0.split(separator: "-").first?.lowercased() == normalized.split(separator: "-").first.map(String.init) }
            if let match = match, !result.contains(match) { result.append(match) }
        }
        return result
    }
}

// Cancellation/timeout finishes the caller once. The single underlying Vision
// slot stays occupied until perform() actually exits, even if cancel is slow.
private final class ScreenshotRecognitionOperation: @unchecked Sendable {
    let request = VNRecognizeTextRequest()
    private let lock = NSLock()
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    func install(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        if let result = result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation; self.continuation = nil
        lock.unlock()
        if case .failure = result { request.cancel() }
        continuation?.resume(with: result)
    }
}

// Accurate recognition can discard a whole line when a decorative symbol is
// mixed with text. Use the character detector to find uncovered lines, then
// recognize their text bounds separately, without replacing good full-page OCR.
enum ScreenshotOCRRecognition {
    static func covers(_ candidate: ScreenshotOCRLine, with lines: [ScreenshotOCRLine]) -> Bool {
        lines.contains { line in
            let intersection = line.box.intersection(candidate.box)
            return !intersection.isNull && intersection.height >= candidate.box.height * 0.5 &&
                intersection.width >= candidate.box.width * 0.5
        }
    }
    static func lines(_ image: CGImage, request: VNRecognizeTextRequest,
                      cancelled: () -> Bool,
                      perform: (CGImage, VNRecognizeTextRequest) throws -> [ScreenshotOCRLine] = read) throws -> [ScreenshotOCRLine] {
        func checkCancellation() throws { if cancelled() { throw CancellationError() } }
        try checkCancellation()
        var result = try perform(image, request)
        let languages = request.recognitionLanguages
        let autoLanguage = request.automaticallyDetectsLanguage
        let correction = request.usesLanguageCorrection
        func restore() {
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.automaticallyDetectsLanguage = autoLanguage
            request.usesLanguageCorrection = correction
        }
        defer { restore() }
        try checkCancellation()
        request.recognitionLevel = .fast
        guard let supported = try? request.supportedRecognitionLanguages() else { return result }
        let fastLanguages = languages.filter { supported.contains($0) }
        guard !fastLanguages.isEmpty else { return result }
        request.recognitionLanguages = fastLanguages
        request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = false
        let detected: [ScreenshotOCRLine]
        do { detected = try perform(image, request) }
        catch { try checkCancellation(); return result } // Supplemental OCR is best effort.
        restore()
        for candidate in detected {
            try checkCancellation()
            guard candidate.text.filter({ $0.isLetter || $0.isNumber }).count >= 2,
                  !covers(candidate, with: result) else { continue }
            // CGImage crops use top-left pixel coordinates; Vision uses bottom-left.
            let box = candidate.box
            let crop = CGRect(x: box.minX * CGFloat(image.width),
                              y: (1 - box.maxY) * CGFloat(image.height),
                              width: box.width * CGFloat(image.width),
                              height: box.height * CGFloat(image.height))
                .insetBy(dx: -2, dy: -box.height * CGFloat(image.height) * 0.2)
                .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let cropped = image.cropping(to: crop) else { continue }
            let refined: [ScreenshotOCRLine]
            do { refined = try perform(cropped, request) }
            catch {
                try checkCancellation()
                var fallback = candidate; fallback.preserveLineBreak = true
                result.append(fallback); continue
            }
            if refined.isEmpty {
                var fallback = candidate; fallback.preserveLineBreak = true
                result.append(fallback); continue
            }
            for line in refined {
                let mapped = ScreenshotOCRLine(text: line.text, box: CGRect(
                    x: (crop.minX + line.box.minX * crop.width) / CGFloat(image.width),
                    y: (CGFloat(image.height) - crop.maxY + line.box.minY * crop.height) / CGFloat(image.height),
                    width: line.box.width * crop.width / CGFloat(image.width),
                    height: line.box.height * crop.height / CGFloat(image.height)), preserveLineBreak: true)
                if !covers(mapped, with: result) { result.append(mapped) }
            }
        }
        try checkCancellation()
        return result
    }
    private static func read(_ image: CGImage, _ request: VNRecognizeTextRequest) throws -> [ScreenshotOCRLine] {
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ScreenshotOCRLine(text: $0.string, box: observation.boundingBox) }
        }
    }
}

final class VisionScreenshotOCR: ScreenshotRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private let timeout: TimeInterval
    private let perform: ((CGImage, VNRecognizeTextRequest) throws -> [ScreenshotOCRLine])?
    init(timeout: TimeInterval = 15, perform: ((CGImage, VNRecognizeTextRequest) throws -> [ScreenshotOCRLine])? = nil) {
        self.timeout = timeout; self.perform = perform
    }
    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }; busy = true; return true
    }
    private func release() { lock.lock(); busy = false; lock.unlock() }
    func recognize(_ image: CGImage) async throws -> String {
        try Task.checkCancellation()
        let operation = ScreenshotRecognitionOperation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                guard !operation.finished else { return }
                guard claim() else {
                    operation.finish(.failure(QingyiError.message("上一次文字识别仍在结束，请稍后重试。"))); return
                }
                let timer = Task<Void, Never> { [timeout] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        operation.finish(.failure(QingyiError.message("截图文字识别超时，请缩小区域后重试。")))
                    } catch { }
                }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { timer.cancel(); release() }
                    guard !operation.finished else { return }
                    do {
                        let request = operation.request
                        request.recognitionLevel = .accurate
                        request.usesLanguageCorrection = true
                        request.automaticallyDetectsLanguage = true
                        request.recognitionLanguages = ScreenshotText.languages(preferred: Locale.preferredLanguages, supported: try request.supportedRecognitionLanguages())
                        let lines: [ScreenshotOCRLine]
                        if let perform = perform { lines = try perform(image, request) }
                        else { lines = try ScreenshotOCRRecognition.lines(image, request: request, cancelled: { operation.finished }) }
                        operation.finish(.success(ScreenshotText.merge(lines)))
                    } catch { operation.finish(.failure(error)) }
                }
            }
        }, onCancel: { operation.finish(.failure(CancellationError())) })
    }
}

enum ScreenshotHotkeyRelease {
    static func wait(binding: ShortcutBinding?, isDown: (() -> Bool)? = nil) async throws {
        let pressed = isDown ?? {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let modifiers: CGEventFlags = [.maskControl, .maskCommand, .maskShift, .maskAlternate]
            return !flags.intersection(modifiers).isEmpty || binding.map {
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0.key))
            } == true
        }
        while pressed() { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation()
    }
}
