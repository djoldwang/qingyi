import AppKit
import Foundation

extension QingyiTests {
    @MainActor static func promptUndoPersistencePhase() {
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--prompt-undo-persistence"),
                  CommandLine.arguments.count > index + 2 else { throw QingyiError.message("Missing persistence fixture arguments") }
            let phase = CommandLine.arguments[index + 1], domain = CommandLine.arguments[index + 2]
            guard domain.hasPrefix("qingyi-undo-process-") else { throw QingyiError.message("Persistence fixture requires an isolated defaults domain") }
            let defaults = UserDefaults(suiteName: domain)!
            let settings = AITextSettings(defaults: defaults)
            let first = AIAction(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, name: "总结", prompt: "  原始提示词\n保留空白  ")
            let second = AIAction(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, name: "提取", prompt: "另一提示词")
            if phase == "write" {
                try settings.saveAction(first); try settings.saveAction(second)
                try settings.adoptOptimizedPrompt("翻译优化", for: .translation, replacing: settings.instructions(for: .translation))
                try settings.adoptOptimizedPrompt("总结优化", for: .custom(first), replacing: first.prompt)
                try settings.adoptOptimizedPrompt("提取优化", for: .custom(second), replacing: second.prompt)
            } else if phase == "undo" {
                try expect(settings.canUndoOptimization(for: .translation) && settings.canUndoOptimization(for: .custom(first)) && settings.canUndoOptimization(for: .custom(second)))
                try expect(try settings.undoOptimization(for: .custom(first)) == first.prompt)
                try expect(settings.instructions(for: .custom(second)) == "提取优化" && settings.prompts.translation == "翻译优化")
            } else if phase == "verify" {
                try expect(settings.instructions(for: .custom(first)) == first.prompt && !settings.canUndoOptimization(for: .custom(first)))
                try expect(settings.canUndoOptimization(for: .custom(second)) && settings.canUndoOptimization(for: .translation))
                try expect(settings.instructions(for: .custom(second)) == "提取优化" && settings.prompts.translation == "翻译优化")
            } else { throw QingyiError.message("Unknown persistence fixture phase") }
            try expect(defaults.synchronize(), "Persistence fixture could not flush preferences")
            print("PASS prompt undo persistence \(phase)")
        } catch { print("FAIL prompt undo persistence: \(error)"); exit(1) }
    }
}

extension QingyiTests {
    @MainActor static func aiTextSettingsTests() async {
        check("Selection toolbars limit eligible actions in saved order for each presentation") {
            let domain = "qingyi-selection-operations-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            try expect(settings.selectionToolbarOperations(for: "Hello") == [.translation])
            try expect(settings.selectionToolbarOperations(for: "中文") == [.polishing])
            let first = AIAction(name: "总结", prompt: "总结选区")
            let second = AIAction(name: "解释", prompt: "解释选区")
            try settings.saveAction(first)
            try settings.saveAction(second)
            settings.actionDisplayLimit = 1
            for text in ["Hello", "AI", "7", "42", "C++", "See https://example.org for details."] {
                try expect(settings.selectionToolbarOperations(for: text) == [.translation], text)
                try expect(settings.selectionToolbarOperations(for: text, mode: .compact) == [.custom(first)], text)
            }
            for text in [" 好\n", "這段文字需要潤色。", "请给云朵剧场的 LUMI 纸龙准备两张 MOON 舞会请柬。"] {
                try expect(settings.selectionToolbarOperations(for: text) == [.polishing], text)
                try expect(settings.selectionToolbarOperations(for: text, mode: .compact) == [.custom(first)], text)
            }
            for text in ["", " \n", "a", "e\u{301}", "!", " / - ", "👨‍👩‍👧‍👦", "example.org",
                         "https://example.org/中文", "mailto:user@example.org", String(repeating: "a", count: 12_001)] {
                try expect(settings.selectionToolbarOperations(for: text).isEmpty, "Filtered selection of \(text.count) characters")
                try expect(settings.selectionToolbarOperations(for: text, mode: .compact).isEmpty)
            }
            let atLimit = String(repeating: "中", count: 12_000)
            try expect(settings.selectionToolbarOperations(for: atLimit) == [.polishing])
            try settings.moveOperation(second.id.uuidString, to: TextOperation.translation.key)
            try expect(settings.selectionToolbarOperations(for: "Hello") == [.custom(second)])
            try expect(settings.selectionToolbarOperations(for: "中文") == [.custom(second)])
            settings.actionDisplayLimit = 2
            let reopened = AITextSettings(defaults: defaults)
            try expect(reopened.actionDisplayLimit == 2)
            try expect(reopened.selectionToolbarOperations(for: "Hello") == [.custom(second), .translation])
            try expect(reopened.selectionToolbarOperations(for: "中文") == [.custom(second), .polishing])
            try expect(reopened.selectionToolbarOperations(for: "中文", mode: .compact) == [.custom(second), .custom(first)])
            settings.translationEnabled = false
            settings.polishingEnabled = false
            try expect(settings.selectionToolbarOperations(for: "Hello") == [.custom(second), .custom(first)])
            try settings.setEnabled(false, for: .custom(first))
            try expect(settings.selectionToolbarOperations(for: "Hello") == [.custom(second)])
            try expect(settings.selectionToolbarOperations(for: "中") == [.custom(second)])
        }
        check("Two toolbar slots follow the saved order even when both built-in actions are enabled") {
            let domain = "qingyi-two-toolbar-slots-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            settings.actionDisplayLimit = 2
            let summary = AIAction(name: "总结", prompt: "总结原文")
            let explain = AIAction(name: "解释", prompt: "解释原文")
            for action in [summary, explain] {
                try settings.saveAction(action)
                try settings.moveOperation(action.id.uuidString, to: TextOperation.translation.key)
            }
            for source in ["Meeting notes", "会议记录"] {
                try expect(settings.selectionToolbarOperations(for: source) == [.custom(summary), .custom(explain)])
            }
            try settings.moveOperation(TextOperation.translation.key, to: summary.id.uuidString)
            try settings.moveOperation(TextOperation.polishing.key, to: summary.id.uuidString)
            try expect(settings.selectionToolbarOperations(for: "Meeting notes") == [.translation, .custom(summary)])
            try expect(settings.selectionToolbarOperations(for: "会议记录") == [.polishing, .custom(summary)])
            try expect(settings.selectionToolbarOperations(for: "会议记录", mode: .compact) == [.custom(summary), .custom(explain)])
        }
        await asyncCheck("Optimization adoption keeps exact independent undo records and only the latest version per action") {
            let domain = "qingyi-undo-independent-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let first = AIAction(name: "总结", prompt: "  原始总结\n保留空白。  ")
            let second = AIAction(name: "提取", prompt: "原始提取")
            try settings.saveAction(first); try settings.saveAction(second)
            let operations: [TextOperation] = [.translation, .polishing, .custom(first), .custom(second)]
            let originals = Dictionary(uniqueKeysWithValues: operations.map { ($0.key, settings.instructions(for: $0)) })
            let draft = AIPromptDraft(settings: settings)
            for operation in operations {
                draft.optimize(operation, modelLabel: "fixture") { input, _ in input + "\n优化一次" }
                try await waitForPolishing { !draft.optimizing }
                try expect(!settings.canUndoOptimization(for: operation), "Preview alone must not create history")
                try expect(draft.adoptOptimization() && settings.canUndoOptimization(for: operation))
            }
            let firstOperation = TextOperation.custom(first)
            let once = settings.instructions(for: firstOperation)
            draft.optimize(firstOperation, modelLabel: "fixture") { _, _ in "优化二次" }
            try await waitForPolishing { !draft.optimizing }
            try expect(draft.adoptOptimization())
            let reopened = AITextSettings(defaults: defaults)
            try expect(try reopened.undoOptimization(for: firstOperation) == once)
            try expect(!reopened.canUndoOptimization(for: firstOperation))
            for operation in operations.dropLast().filter({ $0.key != firstOperation.key }) + [.custom(second)] {
                try expect(reopened.canUndoOptimization(for: operation))
                try expect(try reopened.undoOptimization(for: operation) == originals[operation.key])
            }
            try expect(reopened.optimizationUndo.isEmpty && defaults.object(forKey: AITextSettings.optimizationUndoKey) == nil)
            try rejects { _ = try reopened.undoOptimization(for: firstOperation) }
            try expect(reopened.instructions(for: firstOperation) == once, "A second undo must not walk back to older history")
        }
        check("Rejected and identical adoptions preserve undo history and corrupt history is never overwritten") {
            let domain = "qingyi-undo-validation-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let original = settings.instructions(for: .translation)
            try settings.adoptOptimizedPrompt("已采用", for: .translation, replacing: original)
            let history = defaults.data(forKey: AITextSettings.optimizationUndoKey)
            try settings.adoptOptimizedPrompt("已采用", for: .translation, replacing: "已采用")
            try rejects { try settings.adoptOptimizedPrompt(" \n", for: .translation, replacing: "已采用") }
            try rejects { try settings.adoptOptimizedPrompt("过期优化", for: .translation, replacing: original) }
            try expect(defaults.data(forKey: AITextSettings.optimizationUndoKey) == history && settings.prompts.translation == "已采用")
            let deleted = AIAction(name: "已删除", prompt: "原提示词")
            try rejects { try settings.adoptOptimizedPrompt("不应保存", for: .custom(deleted), replacing: deleted.prompt) }
            try expect(defaults.data(forKey: AITextSettings.optimizationUndoKey) == history)
            let corrupt = Data("not-json".utf8)
            defaults.set(corrupt, forKey: AITextSettings.optimizationUndoKey)
            let reopened = AITextSettings(defaults: defaults)
            try expect(!reopened.optimizationUndoLoadError.isEmpty && !reopened.canUndoOptimization(for: .translation))
            try rejects { try reopened.adoptOptimizedPrompt("新优化", for: .translation, replacing: "已采用") }
            try rejects { _ = try reopened.undoOptimization(for: .translation) }
            try expect(defaults.data(forKey: AITextSettings.optimizationUndoKey) == corrupt && reopened.prompts.translation == "已采用")
            defaults.set("wrong-type", forKey: AITextSettings.optimizationUndoKey)
            let wrongType = AITextSettings(defaults: defaults)
            try expect(!wrongType.optimizationUndoLoadError.isEmpty)
            try rejects { try wrongType.adoptOptimizedPrompt("不应覆盖", for: .translation, replacing: "已采用") }
            try expect(defaults.string(forKey: AITextSettings.optimizationUndoKey) == "wrong-type")
        }
        check("Undo survives later edits, rename and reordering, preserves metadata, and is removed with its action") {
            let domain = "qingyi-undo-metadata-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            var action = AIAction(name: "总结", prompt: "原提示词", enabled: false, model: .init(service: .customAPI("fixture"), modelID: "independent"))
            let other = AIAction(name: "解释", prompt: "另一动作")
            try settings.saveAction(action); try settings.saveAction(other)
            try settings.adoptOptimizedPrompt("优化结果", for: .custom(action), replacing: action.prompt)
            action.name = "会议纪要"; action.prompt = "手动编辑的后续内容"; try settings.saveAction(action)
            try settings.moveOperation(action.id.uuidString, to: other.id.uuidString)
            let draft = AIPromptDraft(settings: settings)
            try expect(draft.undoOptimizationNeedsConfirmation(.custom(action)))
            try expect(draft.undoOptimization(.custom(action)))
            let restored = settings.actions.first { $0.id == action.id }!
            try expect(restored.prompt == "原提示词" && restored.name == action.name && restored.model == action.model && !restored.enabled)
            try expect(settings.actions.map(\.id) == [other.id, action.id] && settings.actions[0] == other)
            try settings.adoptOptimizedPrompt("再次优化", for: .custom(restored), replacing: restored.prompt)
            try settings.removeAction(action.id)
            try expect(settings.optimizationUndo[action.id.uuidString] == nil)
            let replacement = AIAction(name: "会议纪要", prompt: "新建同名动作")
            try settings.saveAction(replacement)
            try expect(!settings.canUndoOptimization(for: .custom(replacement)), "A reused name must not inherit another action's history")
        }
        await asyncCheck("Draft undo restores invalid editor contents, cancels pending optimization and refreshes save feedback") {
            let domain = "qingyi-undo-draft-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let action = AIAction(name: "总结", prompt: "原始内容")
            try settings.saveAction(action)
            let operation = TextOperation.custom(action)
            try settings.adoptOptimizedPrompt("优化结果", for: operation, replacing: action.prompt)
            let current = settings.actions[0]
            let draft = AIPromptDraft(settings: settings)
            try expect(!draft.undoOptimizationNeedsConfirmation(.custom(current)))
            draft.optimize(.custom(current), modelLabel: "fixture") { _, _ in
                try? await Task.sleep(for: .milliseconds(60)); return "延迟返回的优化"
            }
            try expect(!draft.update(operation, text: " \n") && draft.undoOptimizationNeedsConfirmation(operation))
            try expect(draft.undoOptimization(operation))
            try await Task.sleep(for: .milliseconds(90))
            try expect(settings.instructions(for: operation) == action.prompt && draft.values.instructions(for: operation) == action.prompt)
            try expect(draft.optimizationOperation == nil && draft.optimized.isEmpty && draft.error(for: operation) == nil)
            try expect(draft.receipt(for: operation) != nil && !settings.canUndoOptimization(for: operation))
        }
        check("Per-action optimization undo survives real process restarts and consumed history stays cleared") {
            let domain = "qingyi-undo-process-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            for phase in ["write", "undo", "verify"] {
                let child = Process(); let output = Pipe()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = ["--prompt-undo-persistence", phase, domain]
                child.standardOutput = output; child.standardError = output
                try child.run(); child.waitUntilExit()
                let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                try expect(child.terminationStatus == 0, "Persistence phase \(phase) failed: \(result)")
            }
        }
        check("Every successful prompt edit issues a fresh save receipt; invalid edits and failures never announce success") {
            let domain = "qingyi-save-feedback-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let action = AIAction(name: "总结", prompt: "总结输入")
            try settings.saveAction(action)
            var time = Date(timeIntervalSince1970: 1_700_000_000)
            let draft = AIPromptDraft(settings: settings, clock: { time })
            for operation in [TextOperation.translation, .polishing, .custom(action)] {
                try expect(draft.receipt(for: operation) == nil)
                try expect(draft.update(operation, text: "第一次修改"))
                let first = draft.receipt(for: operation)!
                try expect(first.savedAt == time && settings.instructions(for: operation) == "第一次修改")
                try expect(draft.update(operation, text: "同一秒内继续输入"))
                let second = draft.receipt(for: operation)!
                try expect(second.revision != first.revision && second.savedAt == first.savedAt, "The confirmation must retrigger even within the same second")
                time = time.addingTimeInterval(2)
                try expect(draft.update(operation, text: "新的保存时间"))
                let third = draft.receipt(for: operation)!
                try expect(third.time != first.time)
                try expect(!draft.update(operation, text: " \n") && draft.error(for: operation) != nil)
                try expect(draft.receipt(for: operation) == third && settings.instructions(for: operation) == "新的保存时间")
                if let current = settings.actions.first, operation.customAction != nil {
                    try expect(draft.error(for: .custom(current)) != nil, "Custom feedback must use stable identity after prompt edits")
                }
                draft.reload()
                try expect(draft.receipt(for: operation) == nil && draft.error(for: operation) == nil)
            }
            try settings.removeAction(action.id)
            try expect(!draft.update(.custom(action), text: "已删除动作不能保存"))
            try expect(draft.receipt(for: .custom(action)) == nil)
        }
        check("AI text settings retain built-in defaults, save independent overrides and preserve exact whitespace across restart") {
            let domain = "qingyi-text-settings-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            try expect(settings.polishingEnabled && settings.translationEnabled && settings.prompts == .defaults)
            try expect(defaults.object(forKey: AITextSettings.polishingEnabledKey) == nil)
            try expect(defaults.object(forKey: AITextSettings.promptsKey) == nil)
            var values = settings.prompts
            values.polishing = "  请保留原意。\n\n修正中文表达。  "
            try settings.save(values); settings.polishingEnabled = false
            let reopened = AITextSettings(defaults: defaults)
            try expect(!reopened.polishingEnabled && reopened.prompts == values)
            try expect(reopened.prompts.translation == TranslationPrompt.text)
            var invalid = values; invalid.translation = " \n\t"; invalid.polishing = "不应保存"
            try rejects { try settings.save(invalid) }
            try expect(AITextSettings(defaults: defaults).prompts == values, "Validation must precede the atomic save")
            invalid = values; invalid.polishing = "\n"
            try rejects { try settings.save(invalid) }
            try settings.save(.defaults)
            try expect(AITextSettings(defaults: defaults).prompts == .defaults && defaults.object(forKey: AITextSettings.promptsKey) == nil)
        }
        check("Existing preferences without a polishing choice get the new default and both explicit choices survive restart") {
            let domain = "qingyi-polishing-upgrade-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set(false, forKey: AITextSettings.translationEnabledKey)
            let upgraded = AITextSettings(defaults: defaults)
            try expect(upgraded.polishingEnabled && !upgraded.translationEnabled)
            try expect(defaults.object(forKey: AITextSettings.polishingEnabledKey) == nil)
            for saved in [false, true] {
                defaults.set(saved, forKey: AITextSettings.polishingEnabledKey)
                let reopened = AITextSettings(defaults: defaults)
                try expect(reopened.polishingEnabled == saved && !reopened.translationEnabled)
                try expect(defaults.object(forKey: AITextSettings.polishingEnabledKey) as? Bool == saved)
            }
        }
        check("Prompt edits autosave independently, reject blank input, restore immediately and persist models") {
            let domain = "qingyi-prompt-auto-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let draft = AIPromptDraft(settings: settings)
            try expect(draft.update(.translation, text: "  翻译自定义\n仅输出正文。  "))
            let valid = settings.prompts.translation
            try expect(!draft.update(.translation, text: " \n"))
            try expect(draft.errors[.translation] != nil && settings.prompts.translation == valid)
            try expect(draft.update(.polishing, text: "润色自定义\n保留语气。"))
            try expect(settings.prompts.translation == valid, "An invalid editor must not block the other prompt")
            draft.restore(.translation)
            try expect(settings.prompts.translation == TranslationPrompt.text && settings.prompts.polishing == "润色自定义\n保留语气。")
            let target = TranslationTarget(service: .customAPI("provider"), modelID: "model")
            settings.selectModel(target, for: .polishing)
            settings.translationEnabled = false; settings.polishingEnabled = true
            let reopened = AITextSettings(defaults: defaults)
            try expect(reopened.model(for: .translation) == nil && reopened.model(for: .polishing) == target)
            try expect(!reopened.translationEnabled && reopened.polishingEnabled)
            settings.selectModel(nil, for: .polishing)
            try expect(AITextSettings(defaults: defaults).model(for: .polishing) == nil)
        }
        await asyncCheck("Optimization previews are isolated, adoption autosaves, cancel and stale responses preserve prompts") {
            let domain = "qingyi-prompt-opt-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let draft = AIPromptDraft(settings: settings)
            draft.optimize(.polishing, modelLabel: "Global") { input, operation in
                try expect(input == TranslationPrompt.polishing && operation == .polishing)
                return "优化后的润色指令"
            }
            try await waitForPolishing { !draft.optimizing }
            try expect(settings.prompts == .defaults && draft.optimized == "优化后的润色指令")
            try expect(draft.adoptOptimization() && settings.prompts.polishing == "优化后的润色指令")
            try expect(settings.prompts.translation == TranslationPrompt.text)
            draft.optimize(.translation, modelLabel: "Global") { _, _ in
                try? await Task.sleep(for: .milliseconds(50)); return "不应覆盖"
            }
            draft.cancelOptimization()
            try await Task.sleep(for: .milliseconds(70))
            try expect(draft.optimizationOperation == nil && draft.optimized.isEmpty && settings.prompts.translation == TranslationPrompt.text)
            draft.optimize(.translation, modelLabel: "Global") { _, _ in "新建议" }
            try await waitForPolishing { !draft.optimizing }
            draft.update(.translation, text: "更新的编辑内容")
            try expect(!draft.adoptOptimization() && settings.prompts.translation == "更新的编辑内容")
        }
        check("Prompt status describes saved content across reopen, invalid edits and restore") {
            let domain = "qingyi-prompt-status-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let draft = AIPromptDraft(settings: settings)
            for operation in [TextOperation.translation, .polishing] {
                try expect(draft.status(for: operation) == "内置默认")
                draft.update(operation, text: "自定义提示词\n保留换行")
                try expect(draft.status(for: operation) == "已修改 · 自动保存")
                let reopened = AIPromptDraft(settings: AITextSettings(defaults: defaults))
                try expect(reopened.status(for: operation) == "已修改 · 自动保存")
                draft.update(operation, text: " \n")
                try expect(draft.status(for: operation) == "尚未保存")
                draft.reload()
                try expect(draft.status(for: operation) == "已修改 · 自动保存")
                draft.restore(operation)
                try expect(draft.status(for: operation) == "内置默认")
                try expect(AIPromptDraft(settings: AITextSettings(defaults: defaults)).status(for: operation) == "内置默认")
            }
        }
        await asyncCheck("Optimization candidates can be fine-tuned before adoption, reject whitespace and never autosave preview edits") {
            let domain = "qingyi-edit-optimized-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let draft = AIPromptDraft(settings: settings)
            for operation in [TextOperation.translation, .polishing] {
                let before = settings.prompts
                draft.optimize(operation, modelLabel: "Global") { _, _ in
                    try await Task.sleep(for: .milliseconds(30)); return "模型生成的提示词"
                }
                draft.updateOptimized("生成期间禁止写入")
                try expect(draft.optimized.isEmpty && !draft.canAdoptOptimization)
                try await waitForPolishing { !draft.optimizing }
                try expect(draft.canEditOptimization && draft.canAdoptOptimization)
                draft.updateOptimized(" \n\t")
                try expect(draft.optimizationEditError != nil && !draft.canAdoptOptimization && !draft.adoptOptimization())
                try expect(draft.optimizationError.isEmpty && settings.prompts == before)
                let edited = "  人工微调的\n\n完整提示词。  "
                draft.updateOptimized(edited)
                try expect(draft.optimizationEditError == nil && draft.canAdoptOptimization && settings.prompts == before)
                try expect(draft.adoptOptimization())
                try expect(settings.prompts.instructions(for: operation) == edited)
                try expect(AITextSettings(defaults: defaults).prompts.instructions(for: operation) == edited)
                draft.optimize(operation, modelLabel: "Global") { _, _ in "另一个建议" }
                try await waitForPolishing { !draft.optimizing }
                draft.updateOptimized("取消的人工微调")
                draft.cancelOptimization()
                try expect(!draft.canEditOptimization && !draft.canAdoptOptimization && settings.prompts.instructions(for: operation) == edited)
            }
        }
        await asyncCheck("Function models and prompt optimization use the selected action model on all protocols") {
            let domain = "qingyi-function-routing-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            let source = "  优化这个提示词。\n第二行，保留原有约束。  "
            for proto in APIProtocol.allCases {
                var provider = fixtureProvider(proto)
                provider.models = [APIModel(id: "global", name: "Global"), APIModel(id: "translation", name: "Translation"), APIModel(id: "polishing", name: "Polishing"), APIModel(id: "custom", name: "Custom")]
                provider.selectedModelID = "global"
                try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
                config.textSettings.selectModel(.init(service: .customAPI(provider.id), modelID: "translation"), for: .translation)
                config.textSettings.selectModel(.init(service: .customAPI(provider.id), modelID: "polishing"), for: .polishing)
                let action = AIAction(name: "总结", prompt: "总结资料", model: .init(service: .customAPI(provider.id), modelID: "custom"))
                try config.textSettings.saveAction(action)
                for operation in [TextOperation.translation, .polishing, .custom(action)] {
                    let expectedModel = operation.customAction == nil ? (operation == .polishing ? "polishing" : "translation") : "custom"
                    try expect(try engine.defaultChoice(for: operation).target.modelID == expectedModel)
                    var requests: [[String: Any]] = []
                    FixtureAPIProtocol.handle = { request in
                        requests.append(try bodyOfRequest(request))
                        switch proto {
                        case .chatCompletions: return (200, "application/json", Data(#"{"choices":[{"message":{"content":"优化结果"},"finish_reason":"stop"}]}"#.utf8))
                        case .responses: return (200, "application/json", Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"优化结果"}]}]}"#.utf8))
                        case .anthropic: return (200, "application/json", Data(#"{"content":[{"type":"text","text":"优化结果"}],"stop_reason":"end_turn"}"#.utf8))
                        }
                    }
                    let result = try await engine.optimizePrompt(source, for: operation)
                    try expect(result == "优化结果" && requests.count == 1)
                    let body = requests[0]
                    try expect(body["model"] as? String == expectedModel)
                    let entries = body[proto == .responses ? "input" : "messages"] as! [[String: Any]]
                    let instructions = proto == .responses ? body["instructions"] as? String : proto == .anthropic ? body["system"] as? String : entries.first?["content"] as? String
                    try expect(instructions == PromptOptimization.instructions(for: operation))
                    try expect((entries.last?["content"] as? [[String: Any]])?.first?["text"] as? String == source)
                    requests = []
                    _ = try await engine.translate(operation == .polishing ? "请润色这段中文。" : "Translate the original source.", operation: operation, onUpdate: { _ in })
                    try expect(requests[0]["model"] as? String == expectedModel)
                }
                try config.textSettings.removeAction(action.id)
            }
            config.textSettings.selectModel(nil, for: .translation)
            try expect(try engine.defaultChoice(for: .translation).target.modelID == "global")
            try rejects { _ = try PromptOptimization.validate(" \n") }
            try rejects { _ = try PromptOptimization.validate(String(repeating: "a", count: 12_001)) }
        }
        await asyncCheck("Translation off blocks every entry and cancels requests while polishing stays available") {
            let domain = "qingyi-function-switch-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let provider = fixtureProvider(); try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            let services = BuiltinTranslationSettings(defaults: defaults, enabledByDefault: false)
            let app = AppDelegate(preferences: Preferences(defaults: defaults))
            app.prepareSelectionFixture(engine: engine, client: BuiltinTranslationClient(session: network), settings: services)
            defer { app.dismissHoverFixture() }
            var calls = 0
            FixtureAPIProtocol.handle = { _ in calls += 1; return (200, "application/json", Data(#"{"choices":[{"message":{"content":"结果"},"finish_reason":"stop"}]}"#.utf8)) }
            config.textSettings.translationEnabled = false
            app.feedSelectionFixture("English selection.")
            try expect(!app.floating.buttonPanel.isVisible)
            app.screenshotClipboardFixture("Clipboard input."); app.feedHoverFixture("Hover input."); app.translateScreenshot()
            try expect(calls == 0 && !app.screenshotActiveFixture && !app.floating.resultPanel.isVisible)
            config.textSettings.polishingEnabled = true
            app.feedSelectionFixture("润色保持独立可用。")
            app.floating.onTrigger?()
            try await waitForPolishing { app.floating.state.complete }
            try expect(calls == 1 && app.floating.state.operation == .polishing)
            config.textSettings.translationEnabled = true; config.textSettings.translationEnabled = false
            try expect(app.floating.resultPanel.isVisible, "Translation toggle must leave polishing intact")
            config.textSettings.polishingEnabled = false
            try expect(!app.floating.resultPanel.isVisible)
            services.ai = true; config.textSettings.translationEnabled = true
            app.feedSelectionFixture("English active request."); app.floating.onTrigger?()
            config.textSettings.translationEnabled = false
            try await Task.sleep(for: .milliseconds(50))
            try expect(calls == 1 && !app.floating.resultPanel.isVisible)
        }
        await asyncCheck("Saved prompts reach both operations on every custom API protocol without changing source") {
            let domain = "qingyi-saved-prompts-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: store, client: CustomAPIClient(session: network))
            let values = AIPromptValues(translation: "翻译自定义第一行\n第二行。", polishing: "润色自定义第一行\n第二行。")
            try store.textSettings.save(values)
            for proto in APIProtocol.allCases {
                let provider = fixtureProvider(proto)
                try store.save(provider, replacementKey: "fixture"); try store.selectProvider(provider.id)
                for operation in [TextOperation.translation, .polishing] {
                    let source = operation == .polishing ? "请检查这段中文，保留原意。\n完整第二段。" : "Keep this complete source.\nSecond paragraph."
                    var calls = 0
                    FixtureAPIProtocol.handle = { request in
                        calls += 1
                        let body = try bodyOfRequest(request)
                        let entries = body[proto == .responses ? "input" : "messages"] as! [[String: Any]]
                        let instructions: String?
                        if proto == .responses { instructions = body["instructions"] as? String }
                        else if proto == .anthropic { instructions = body["system"] as? String }
                        else { instructions = entries.first?["content"] as? String }
                        try expect(instructions == values.instructions(for: operation))
                        try expect((entries.last?["content"] as? [[String: Any]])?.first?["text"] as? String == source)
                        switch proto {
                        case .chatCompletions: return (200, "application/json", Data(#"{"choices":[{"message":{"content":"正文"},"finish_reason":"stop"}]}"#.utf8))
                        case .responses: return (200, "application/json", Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"正文"}]}]}"#.utf8))
                        case .anthropic: return (200, "application/json", Data(#"{"content":[{"type":"text","text":"正文"}],"stop_reason":"end_turn"}"#.utf8))
                        }
                    }
                    let result = try await engine.translate(source, operation: operation, onUpdate: { _ in })
                    try expect(result == "正文" && calls == 1)
                }
            }
        }
        await asyncCheck("ChatGPT uses a saved prompt snapshot through model loading and automatic retry") {
            let domain = "qingyi-saved-chat-prompts-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let account = Registration(id: "prompt-fixture", subject: "fixture", email: "fixture@example.invalid")
            defaults.set(try JSONEncoder().encode([account]), forKey: "registrations")
            defaults.set(account.id, forKey: "activeRegistration")
            let vault = MemoryChatGPTVault(); vault.credentials = fixtureCredentials("fixture-token")
            let chat = ChatGPT(defaults: defaults, session: network, vault: vault)
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: chat, configuration: config)
            let original = AIPromptValues(translation: "订阅翻译提示词\n原始版本", polishing: "订阅润色提示词\n原始版本")
            let changed = AIPromptValues(translation: "新翻译提示词", polishing: "新润色提示词")
            let target = TranslationTarget(service: .chatGPT(account.id), modelID: "gpt-5.2")
            let key = ModelReasoningKey(accountID: account.id, modelID: target.modelID)
            for operation in [TextOperation.translation, .polishing] {
                let enabled = operation == .translation
                config.setThinkingMode(enabled, for: key)
                try config.textSettings.save(original)
                var bodies: [[String: Any]] = []
                FixtureAPIProtocol.handle = { request in
                    if request.url?.path.hasSuffix("/models") == true {
                        return (200, "application/json", Data(#"{"models":[{"slug":"gpt-5.2","display_name":"Fixture GPT","visibility":"list"}]}"#.utf8))
                    }
                    bodies.append(try bodyOfRequest(request))
                    if bodies.count == 1 { return (200, "application/json", Data(#"{"status":"completed","output":[]}"#.utf8)) }
                    return (200, "application/json", Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"正文"}]}]}"#.utf8))
                }
                let source = operation == .polishing ? "请润色完整的中文原文。" : "Please translate the entire source."
                var retry = 0
                let result = try await engine.translate(source, target: target, operation: operation, onEmptyRetry: {
                    retry += 1; try? config.textSettings.save(changed)
                    config.setThinkingMode(!enabled, for: key)
                }, onUpdate: { _ in })
                try expect(result == "正文" && retry == 1 && bodies.count == 2)
                try expect(bodies.allSatisfy { ($0["reasoning"] as? [String: String])?["effort"] == (enabled ? "medium" : "none") })
                try expect(bodies.allSatisfy { $0["instructions"] as? String == original.instructions(for: operation) })
                try expect(config.textSettings.prompts == changed)
                _ = try await engine.translate(source, target: target, operation: operation, onUpdate: { _ in })
                try expect(bodies.last?["instructions"] as? String == changed.instructions(for: operation))
                try expect((bodies.last?["reasoning"] as? [String: String])?["effort"] == (enabled ? "none" : "medium"))
            }
        }
        await asyncCheck("ChatGPT optimization uses each action model and retains immutable retry instructions") {
            let domain = "qingyi-chat-optimization-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let account = Registration(id: "optimization", subject: "fixture", email: "fixture@example.invalid")
            defaults.set(try JSONEncoder().encode([account]), forKey: "registrations")
            defaults.set(account.id, forKey: "activeRegistration"); defaults.set("gpt-5.2", forKey: "model." + account.id)
            let vault = MemoryChatGPTVault(); vault.credentials = fixtureCredentials("fixture-token")
            let chat = ChatGPT(defaults: defaults, session: network, vault: vault)
            let config = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            try config.selectProvider("")
            config.textSettings.selectModel(.init(service: .chatGPT(account.id), modelID: "gpt-5.1"), for: .polishing)
            let engine = TranslationEngine(chat: chat, configuration: config)
            for operation in [TextOperation.translation, .polishing] {
                let expectedModel = operation == .polishing ? "gpt-5.1" : "gpt-5.2"
                let enabled = operation == .translation
                config.setThinkingMode(enabled, for: ModelReasoningKey(accountID: account.id, modelID: expectedModel))
                var requests: [[String: Any]] = []
                FixtureAPIProtocol.handle = { request in
                    if request.url?.path.hasSuffix("/models") == true {
                        return (200, "application/json", Data(#"{"models":[{"slug":"gpt-5.2","display_name":"Global","visibility":"list"},{"slug":"gpt-5.1","display_name":"Polishing","visibility":"list"}]}"#.utf8))
                    }
                    requests.append(try bodyOfRequest(request))
                    if requests.count == 1 { return (200, "application/json", Data(#"{"status":"completed","output":[]}"#.utf8)) }
                    return (200, "application/json", Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"优化结果"}]}]}"#.utf8))
                }
                let source = "  Edit this prompt, not its task.\nPreserve output requirements.  "
                let result = try await engine.optimizePrompt(source, for: operation)
                try expect(result == "优化结果" && requests.count == 2)
                try expect(requests.allSatisfy { ($0["reasoning"] as? [String: String])?["effort"] == (enabled ? "medium" : "none") })
                for body in requests {
                    try expect(body["model"] as? String == expectedModel && body["instructions"] as? String == PromptOptimization.instructions(for: operation))
                    try expect((body["input"] as? [[String: Any]])?.first?["content"] as? String == source)
                }
            }
        }
        await asyncCheck("Custom API freezes saved prompts before credential wait and reuses the snapshot for an empty-response retry") {
            let domain = "qingyi-prompt-snapshot-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            let vault = AuthorizedAPIKeyVault()
            defer { vault.authorization.release(); defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let store = APIConfigurationStore(defaults: defaults, vault: vault)
            var provider = fixtureProvider(); provider.baseURL = "https://api.deepseek.com/v1"
            let model = APIModel(id: "deepseek-v4-flash", name: "Fixture")
            provider.models = [model]
            try store.save(provider, replacementKey: "fixture"); try store.selectProvider(provider.id)
            let key = ModelReasoningKey(provider: provider, modelID: model.id)
            store.setThinkingMode(false, for: key)
            let old = AIPromptValues(translation: "原始翻译指令", polishing: "原始润色指令\n保留换行")
            let new = AIPromptValues(translation: "修改翻译指令", polishing: "修改润色指令")
            try store.textSettings.save(old)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: store, client: CustomAPIClient(session: network))
            var bodies: [[String: Any]] = []
            FixtureAPIProtocol.handle = { request in
                bodies.append(try bodyOfRequest(request))
                if bodies.count == 1 { return (200, "application/json", Data(#"{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}"#.utf8)) }
                return (200, "application/json", Data(#"{"choices":[{"message":{"content":"正文"},"finish_reason":"stop"}]}"#.utf8))
            }
            let pending = Task { @MainActor in try await engine.translate("保留原文的一整段中文。", operation: .polishing, onUpdate: { _ in }) }
            try await waitForPolishing { vault.authorization.reads == 1 }
            try store.textSettings.save(new)
            store.setThinkingMode(true, for: key)
            vault.authorization.release()
            let result = try await pending.value
            try expect(result == "正文" && bodies.count == 2)
            try expect(bodies.allSatisfy { ($0["thinking"] as? [String: String])?["type"] == "disabled" })
            for body in bodies {
                try expect((body["messages"] as? [[String: Any]])?.first?["content"] as? String == old.polishing)
            }
            try expect(store.textSettings.prompts == new)
        }
        await asyncCheck("Polishing switch persists, respects master pause, leaves English results intact and cancels pending polishing") {
            let domain = "qingyi-polish-toggle-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let network = FixtureAPIProtocol.session()
            let vault = AuthorizedAPIKeyVault()
            defer { vault.authorization.release(); defaults.removePersistentDomain(forName: domain); network.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let config = APIConfigurationStore(defaults: defaults, vault: vault)
            let provider = fixtureProvider(); try config.save(provider, replacementKey: "fixture"); try config.selectProvider(provider.id)
            let services = BuiltinTranslationSettings(defaults: defaults, enabledByDefault: false)
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults), configuration: config, client: CustomAPIClient(session: network))
            let app = AppDelegate(preferences: Preferences(defaults: defaults))
            app.prepareSelectionFixture(engine: engine, client: BuiltinTranslationClient(session: network), settings: services)
            defer { app.dismissHoverFixture() }
            var calls = 0
            FixtureAPIProtocol.handle = { _ in calls += 1; return (200, "application/json", Data(#"{"choices":[{"message":{"content":"结果正文"},"finish_reason":"stop"}]}"#.utf8)) }
            config.textSettings.polishingEnabled = false
            app.feedSelectionFixture("润色关闭时不应出现按钮。")
            try expect(!app.floating.buttonPanel.isVisible && calls == 0)
            config.textSettings.polishingEnabled = true
            app.preferences.paused = true
            app.feedSelectionFixture("总开关暂停时也不出现按钮。")
            try expect(!app.floating.buttonPanel.isVisible)
            app.preferences.paused = false
            services.ai = false
            app.feedSelectionFixture("润色不受 AI 翻译开关影响。")
            app.floating.onTrigger?(); vault.authorization.release()
            try await waitForPolishing { app.floating.state.complete }
            app.floating.state.pinned = true
            config.textSettings.polishingEnabled = false
            try expect(!app.floating.resultPanel.isVisible && app.floating.state.services.isEmpty)
            services.ai = true
            app.feedSelectionFixture("English translation still works.")
            app.floating.onTrigger?(); vault.authorization.release()
            try await waitForPolishing { app.floating.state.complete }
            app.floating.state.pinned = true
            let id = app.floating.state.sessionID
            config.textSettings.polishingEnabled = true; config.textSettings.polishingEnabled = false
            try expect(app.floating.state.sessionID == id && app.floating.resultPanel.isVisible && app.floating.state.text == "结果正文")
            config.textSettings.polishingEnabled = true
            app.feedSelectionFixture("等待凭据时关闭润色开关。")
            app.floating.onTrigger?()
            try await waitForPolishing { vault.authorization.reads == 3 }
            config.textSettings.polishingEnabled = false
            vault.authorization.release()
            try await Task.sleep(for: .milliseconds(70))
            try expect(calls == 2 && !app.floating.resultPanel.isVisible && app.floating.state.services.isEmpty)
            try expect(!AITextSettings(defaults: defaults).polishingEnabled)
        }
    }
}
