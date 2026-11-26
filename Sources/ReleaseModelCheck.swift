import Foundation
import ImageIO

/// Signed-app diagnostics. All requests use one captured global target and public sample prompts.
@MainActor
enum ReleaseModelCheck {
    static let screenshotSample = "The green bag contains 36 apples."

    static func run(arguments: [String]) async -> Bool {
        do { try AppRuntime.validate() }
        catch { print("FAIL app bundle or signature validation"); return false }

        let domain = "qingyi-default-model-check-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: domain), let bundleID = Bundle.main.bundleIdentifier else {
            print("FAIL opening diagnostic settings"); return false
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        // Use saved settings as an in-memory fallback. Test results and migrations write to the disposable suite.
        defaults.register(defaults: UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:])
        let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: APIConfigurationStore(defaults: defaults))
        let target: TranslationTarget
        do { target = try engine.defaultChoice().target }
        catch { print("FAIL resolving global service and model"); return false }

        if !arguments.contains("--actions") && !arguments.contains("--screenshot-input") {
            do {
                let result = try await engine.translate("Small steps make complex things easier to understand.",
                                                        target: target, instructions: TranslationPrompt.text, onUpdate: { _ in })
                print("PASS real translation using the saved default service and model")
                print("Example translation: \(result)")
                return true
            } catch {
                print("FAIL real translation using the saved default service and model")
                return false
            }
        }

        var checks = 0, passed = 0
        func check(_ name: String, request: () async throws -> String, accepts: (String) -> Bool) async {
            checks += 1
            do {
                let result = TextPolicy.clean(try await request())
                guard accepts(result) else { print("FAIL \(name): sample content check"); return }
                passed += 1
                print("PASS \(name) (\(result.count) characters)")
            } catch {
                // Some providers include request details in their error body. Keep diagnostic logs content-free.
                if let network = error as? URLError { print("FAIL \(name): network error \(network.code.rawValue)") }
                else { print("FAIL \(name): request or input could not be processed") }
            }
        }
        func execute(_ source: String, _ operation: TextOperation) async throws -> String {
            try await engine.execute(source, target: target, operation: operation,
                                     instructions: TranslationPrompt.instructions(for: operation), onUpdate: { _ in })
        }
        func hasJuly18(_ text: String) -> Bool {
            text.range(of: #"(?:7|七)\s*月\s*(?:18|十八)"#, options: .regularExpression) != nil
        }

        await check("real translation using the saved default service and model", request: {
            try await execute("The blue box contains 24 pencils.", .translation)
        }, accepts: { text in
            (text.contains("蓝") || text.contains("藍")) && (text.contains("铅笔") || text.contains("鉛筆"))
                && (text.contains("24") || text.contains("二十四"))
        })

        if arguments.contains("--actions") {
            await check("Chinese polishing", request: {
                try await execute("我们我们会在7月18日发布Atlas。", .polishing)
            }, accepts: { text in
                text.contains("Atlas") && hasJuly18(text) && !text.contains("我们我们")
            })
            let summary = AIAction(name: "总结", prompt: "用一句简体中文只总结最终决定，保留项目英文名和日期，无需复述讨论过程。")
            await check("custom summary", request: {
                try await execute("会上讨论了场地和文具颜色。最终决定：项目 Maple 将于 7 月 18 日上线。", .custom(summary))
            }, accepts: { text in
                text.contains("Maple") && hasJuly18(text) && !text.contains("文具")
            })
            let extraction = AIAction(name: "智能提取", prompt: "提取订单编号和数量。只返回 JSON 对象，键名为 id 和 quantity，数量用数字。不要 Markdown 代码围栏。")
            await check("custom field extraction", request: {
                try await execute("示例订单 QY-204 中有 18 本笔记本。", .custom(extraction))
            }, accepts: { text in
                let fields = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                return fields?["id"] as? String == "QY-204" && fields?["quantity"] as? Int == 18
            })
            let prompt = "用中文整理资料，记得保留 QY-ID 字段名，别改字段名。"
            await check("prompt optimization", request: {
                try await engine.optimizePrompt(prompt, for: .custom(summary), target: target)
            }, accepts: { text in
                text != prompt && text.contains("QY-ID") && (text.contains("中文") || text.contains("汉语") || text.contains("漢語"))
            })
        }

        if let index = arguments.firstIndex(of: "--screenshot-input") {
            guard index + 1 < arguments.count else { print("FAIL missing screenshot path"); return false }
            let url = URL(fileURLWithPath: arguments[index + 1])
            await check("Vision OCR to Chinese translation", request: {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw QingyiError.message("Unreadable OCR sample.")
                }
                let original = try ScreenshotText.validate(await VisionScreenshotOCR().recognize(image))
                let words = original.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard words == screenshotSample else {
                    print("FAIL local OCR did not match the public test sentence")
                    throw QingyiError.message("Unexpected OCR sample.")
                }
                print("PASS local Vision OCR matched the public sample (\(original.count) characters)")
                return try await execute(original, .translation)
            }, accepts: { text in
                (text.contains("绿") || text.contains("綠")) && (text.contains("苹果") || text.contains("蘋果"))
                    && (text.contains("36") || text.contains("三十六"))
            })
        }
        print("Global model checks: \(passed) passed, \(checks - passed) failed")
        return passed == checks
    }
}
