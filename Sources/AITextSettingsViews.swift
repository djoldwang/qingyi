import SwiftUI

enum AIActionPalette {
    static func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 165/255, green: 162/255, blue: 1) : Color(red: 80/255, green: 87/255, blue: 207/255)
    }
}

@MainActor
struct AIActionModelSummary {
    let text: String
    let unavailable: Bool
    init(engine: TranslationEngine, operation: TextOperation) {
        let source = engine.textSettings.model(for: operation) == nil ? "全局默认" : "独立选择"
        unavailable = (try? engine.optimizationChoice(for: operation)) == nil
        if let choice = try? engine.defaultChoice(for: operation) {
            text = "\(source) · \(choice.label)" + (unavailable ? "（不可用）" : "")
        } else {
            text = "\(source) · 未配置"
        }
    }
}

private struct AIActionEditingTarget: Identifiable {
    let operation: TextOperation
    var id: String { operation.key }
}

@MainActor
struct AIPromptEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: AITextSettings
    @ObservedObject var api: APIConfigurationStore
    @ObservedObject var chat: ChatGPT
    @StateObject private var reordering = AIActionReorderSession()
    @ViewState private var editing: AIActionEditingTarget?
    @ViewState private var creating = false
    @ViewState private var managementError = ""
    let engine: TranslationEngine

    init(api: APIConfigurationStore, chat: ChatGPT, client: CustomAPIClient = CustomAPIClient()) {
        self.api = api; self.chat = chat; settings = api.textSettings
        engine = TranslationEngine(chat: chat, configuration: api, client: client)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                actionToolbarSettings
                actionList
            }.padding(SettingsLayout.pageInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $creating) {
            AIActionCreationView(settings: settings, engine: engine, api: api, chat: chat) { creating = false }
                .interactiveDismissDisabled()
        }
        .sheet(item: $editing) { target in
            AIActionEditView(settings: settings, engine: engine, api: api, chat: chat, operation: target.operation) {
                editing = nil
            }.interactiveDismissDisabled()
        }
    }
    private var actionList: some View {
        let operations = settings.orderedOperations
        let order = operations.map(\.key)
        return VStack(alignment: .leading, spacing: 10) {
            Text("动作列表").font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if !settings.actionsLoadError.isEmpty { Text(settings.actionsLoadError).foregroundStyle(.orange) }
            if !managementError.isEmpty { Text(managementError).foregroundStyle(.orange) }
            Text("拖动动作名称可调整划词动作栏的顺序。润色和自定义动作的结果窗口也会按此顺序显示其他可用动作。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(displayOperations(operations), id: \.key) { operation in
                prompt(operation, order: order)
            }
            newActionButton
        }
    }
    private var newActionButton: some View {
        let accent = AIActionPalette.accent(for: colorScheme)
        return Button {
            creating = true
        } label: {
            Label("新建 AI 动作", systemImage: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .allowsHitTesting(false)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.actions.create")
        .disabled(!settings.actionsLoadError.isEmpty)
    }
    private var actionToolbarSettings: some View {
        SettingsGroup(title: "自定义动作栏设置") {
            SettingsRow {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 14) {
                        Text("辅助键")
                        Spacer()
                        Picker("辅助键", selection: $settings.actionModifier) {
                            ForEach(AIActionModifier.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().settingsControlColumn()
                            .accessibilityIdentifier("settings.actions.modifier")
                    }
                    toolbarSettingHint("选用“简洁按钮”时，用此辅助键打开自定义动作栏。")
                }
            }
            Divider()
            SettingsRow {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 14) {
                        Text("触发方式")
                        Spacer()
                        Picker("触发方式", selection: $settings.actionTrigger) {
                            ForEach(AIActionTrigger.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().settingsControlColumn()
                            .accessibilityIdentifier("settings.actions.trigger")
                    }
                    toolbarSettingHint(settings.actionTrigger == .hold ? "简洁按钮模式下，按住辅助键显示，松开关闭。" : "简洁按钮模式下，按一下辅助键显示，再按一下关闭。")
                }
            }
            Divider()
            SettingsRow {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 14) {
                        Text("动作栏显示上限")
                        Spacer()
                        Picker("动作栏显示上限", selection: $settings.actionDisplayLimit) {
                            ForEach(AITextSettings.actionDisplayLimitRange, id: \.self) { count in
                                Text(verbatim: String(count)).tag(count)
                            }
                        }.labelsHidden().settingsControlColumn()
                            .accessibilityIdentifier("settings.actions.displayLimit")
                    }
                    toolbarSettingHint("直接显示动作栏时，按列表顺序最多显示 \(settings.actionDisplayLimit) 个可用动作，翻译或润色也占一个名额。简洁按钮模式下，辅助键最多显示 \(settings.actionDisplayLimit) 个自定义动作。")
                }
            }
        }
    }
    private func toolbarSettingHint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func displayOperations(_ operations: [TextOperation]) -> [TextOperation] {
        guard let keys = reordering.previewIDs else { return operations }
        let byKey = Dictionary(uniqueKeysWithValues: operations.map { ($0.key, $0) })
        return keys.compactMap { byKey[$0] } + operations.filter { !keys.contains($0.key) }
    }
    private func prompt(_ operation: TextOperation, order: [String]) -> some View {
        AIActionCard(actionID: operation.key, dragging: reordering.source == operation.key) {
            SettingsGroup(title: "") {
                actionHeader(operation, order: order)
            }
        }.id(operation.key)
    }
    private func actionHeader(_ operation: TextOperation, order: [String]) -> some View {
        let model = AIActionModelSummary(engine: engine, operation: operation)
        return AIActionHeader(operation: operation, enabled: settings.enabled(operation),
                       modelSummary: model.text, modelUnavailable: model.unavailable, edit: {
            editing = AIActionEditingTarget(operation: operation)
        }, toggle: { enabled in
            manage { try settings.setEnabled(enabled, for: operation) }
        }, canMove: { source in
            source != operation.key && order.contains(source) && order.contains(operation.key)
        }, move: { source in
            commitMove(source, operation.key)
        }, reorder: reordering, actionOrder: order, commitOrder: commitMove)
        .frame(height: 50)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "上移") { manage { try settings.moveOperation(operation.key, by: -1) } }
        .accessibilityAction(named: "下移") { manage { try settings.moveOperation(operation.key, by: 1) } }
    }
    private func commitMove(_ source: String, _ target: String) -> Bool {
        do {
            try settings.moveOperation(source, to: target)
            managementError = ""
            return true
        } catch {
            managementError = error.localizedDescription
            return false
        }
    }
    private func manage(_ action: () throws -> Void) {
        do { try action(); managementError = "" }
        catch { managementError = error.localizedDescription }
    }
}

private enum AIActionEditorLayout {
    static let width: CGFloat = 680
    static let height: CGFloat = 600
    static let promptHeight: CGFloat = 240
}

private struct AIActionEditorForm<Content: View, Actions: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 17, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize)
            HStack { Spacer(); actions }
        }.padding(24)
            .frame(width: AIActionEditorLayout.width, height: AIActionEditorLayout.height)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AIActionNameField: View {
    @Binding var name: String
    var editable = true
    var error = ""
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                Text("动作名称").fixedSize()
                if editable {
                    TextField("动作名称，例如：总结", text: $name)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier(identifier)
                } else {
                    Text(name).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if editable {
                Text("动作名称会显示在浮窗按钮上，建议不超过 4 个字。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !error.isEmpty {
                Text(error + " 已保留上次有效名称。").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }
}

private struct AIActionPromptField: View {
    @Binding var text: String
    var invalid = false
    let label: String
    let identifier: String
    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12)).scrollContentBackground(.hidden)
            .frame(height: AIActionEditorLayout.promptHeight).padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(invalid ? .orange : Color.primary.opacity(0.15), lineWidth: 1))
            .accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

@MainActor
struct AIActionEditView: View {
    @ObservedObject var settings: AITextSettings
    let engine: TranslationEngine
    @ObservedObject var api: APIConfigurationStore
    @ObservedObject var chat: ChatGPT
    let initialOperation: TextOperation
    let close: () -> Void
    @StateObject private var draft: AIPromptDraft
    @ViewState private var name: String
    @ViewState private var nameError = ""
    @ViewState private var deletionError = ""
    @ViewState private var confirmingDiscard = false
    @ViewState private var confirmingDelete = false
    @ViewState private var confirmingUndo = false

    init(settings: AITextSettings, engine: TranslationEngine, api: APIConfigurationStore, chat: ChatGPT,
         operation: TextOperation, close: @escaping () -> Void) {
        self.settings = settings; self.engine = engine; self.api = api; self.chat = chat
        initialOperation = operation; self.close = close
        _draft = StateObject(wrappedValue: AIPromptDraft(settings: settings))
        _name = ViewState(wrappedValue: operation.action)
    }
    private var operation: TextOperation {
        guard let id = initialOperation.customAction?.id,
              let current = settings.actions.first(where: { $0.id == id }) else { return initialOperation }
        return .custom(current)
    }
    private var text: Binding<String> {
        Binding(get: { draft.values.instructions(for: operation) }, set: { draft.update(operation, text: $0) })
    }
    private var optimizationChoice: TranslationChoice? { try? engine.optimizationChoice(for: operation) }
    var body: some View {
        AIActionEditorForm(title: "编辑 AI 动作") {
            AIActionNameField(name: Binding(get: { name }, set: { updateName($0) }),
                editable: operation.customAction != nil, error: nameError, identifier: "settings.actions.editor.name")
            HStack {
                Text("提示词")
                Spacer()
                FunctionModelPicker(settings: settings, api: api, chat: chat, operation: operation, engine: engine)
            }
            AIActionPromptField(text: text, invalid: draft.error(for: operation) != nil,
                label: "\(operation.action)提示词", identifier: "settings.prompts.\(operation.key).editor")
            HStack {
                PromptSaveFeedback(draft: draft, operation: operation)
                Spacer()
                if operation.customAction == nil {
                    Button("恢复默认提示词") { draft.restore(operation) }
                        .buttonStyle(PromptActionButtonStyle())
                        .disabled(text.wrappedValue == TranslationPrompt.instructions(for: operation))
                        .accessibilityIdentifier("settings.prompts.\(operation.key).restore")
                } else {
                    Button("删除动作…", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(PromptActionButtonStyle())
                        .accessibilityIdentifier("settings.actions.\(operation.key).delete")
                }
                Button("撤销上次优化", action: requestUndo)
                    .buttonStyle(PromptActionButtonStyle())
                    .disabled(!settings.canUndoOptimization(for: operation))
                    .accessibilityIdentifier("settings.prompts.\(operation.key).undoOptimization")
                    .help("恢复采用上次优化结果之前的提示词。每个动作独立保留，重启后仍可撤销。")
                Button(action: optimize) {
                    Label("优化提示词", systemImage: "sparkles")
                }.buttonStyle(PromptActionButtonStyle(emphasized: true))
                    .disabled(optimizationChoice == nil || TextPolicy.clean(text.wrappedValue).isEmpty)
                    .accessibilityIdentifier("settings.prompts.\(operation.key).optimize")
                    .help("使用此动作选择的模型优化，预览后采用才会替换。")
            }
            Text("有效修改会自动保存，点击“完成”返回动作列表。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = draft.error(for: operation) {
                Text(error + " 已保留上次有效内容。").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if optimizationChoice == nil {
                Text("请为此动作选择可用模型，或在“AI 服务”中配置跟随的全局模型，才能优化提示词。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !deletionError.isEmpty { Text(deletionError).font(.system(size: 11)).foregroundStyle(.orange) }
        } actions: {
            Button("完成", action: requestClose).keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("settings.actions.editor.done")
        }
            .onDisappear { draft.cancelOptimization() }
            .sheet(isPresented: Binding(get: { draft.optimizationOperation != nil }, set: { if !$0 { draft.cancelOptimization() } })) {
                optimizationPreview.interactiveDismissDisabled()
            }
            .alert("放弃未保存的修改？", isPresented: $confirmingDiscard) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃未保存内容", role: .destructive, action: close)
            } message: {
                Text("当前有尚未保存的名称或提示词。已自动保存的修改会保留。")
            }
            .alert("撤销上次优化？", isPresented: $confirmingUndo) {
                Button("继续编辑", role: .cancel) {}
                Button("撤销优化", role: .destructive) { draft.undoOptimization(operation) }
            } message: {
                Text("采用优化后，提示词又有改动。撤销将以优化前的版本替换当前内容。")
            }
            .alert("删除此 AI 动作？", isPresented: $confirmingDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive, action: deleteAction)
            } message: {
                Text("删除后将无法再次调用此动作，已显示的结果仍可复制。")
            }
    }
    private func updateName(_ text: String) {
        name = text
        guard var current = operation.customAction else { return }
        current.name = text
        do { try settings.saveAction(current); nameError = "" }
        catch { nameError = error.localizedDescription }
    }
    private func requestClose() {
        if !nameError.isEmpty || draft.error(for: operation) != nil { confirmingDiscard = true }
        else { close() }
    }
    private func requestUndo() {
        guard settings.canUndoOptimization(for: operation) else { return }
        if draft.undoOptimizationNeedsConfirmation(operation) { confirmingUndo = true }
        else { draft.undoOptimization(operation) }
    }
    private func deleteAction() {
        guard let id = operation.customAction?.id else { return }
        do { try settings.removeAction(id); close() }
        catch { deletionError = error.localizedDescription }
    }
    private func optimize() {
        guard let selected = optimizationChoice else { return }
        draft.optimize(operation, modelLabel: selected.label) { prompt, operation in
            try await engine.optimizePrompt(prompt, for: operation, target: selected.target)
        }
    }
    private var optimizationPreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("优化\(draft.optimizationOperation?.action ?? "")提示词").font(.system(size: 15, weight: .semibold))
            Text("使用模型：\(draft.modelLabel)").font(.system(size: 11)).foregroundStyle(.secondary)
            if draft.optimizing { HStack { ProgressView().controlSize(.small); Text("正在优化…") } }
            HStack(alignment: .top, spacing: 16) {
                previewText("当前", value: draft.original)
                VStack(alignment: .leading, spacing: 7) {
                    Text("优化后的提示词").font(.system(size: 12, weight: .medium))
                    TextEditor(text: Binding(get: { draft.optimized }, set: { draft.updateOptimized($0) }))
                        .font(.system(size: 12)).scrollContentBackground(.hidden)
                        .frame(height: 220).padding(10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(draft.optimizationEditError == nil ? Color.primary.opacity(0.15) : .orange, lineWidth: 1))
                        .disabled(!draft.canEditOptimization)
                        .accessibilityLabel("优化后的提示词")
                        .accessibilityIdentifier("settings.prompts.optimization.editor")
                }.frame(maxWidth: .infinity)
            }
            Text("可以先修改优化结果。点击“采用”后，新提示词会替换原内容并自动保存。").font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = draft.optimizationEditError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            if !draft.optimizationError.isEmpty { Text(draft.optimizationError).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { draft.cancelOptimization() }.keyboardShortcut(.cancelAction)
                Button("采用") { draft.adoptOptimization() }.keyboardShortcut(.defaultAction)
                    .disabled(!draft.canAdoptOptimization)
                    .accessibilityIdentifier("settings.prompts.optimization.adopt")
            }
        }.padding(24).frame(width: 680)
    }
    private func previewText(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            ScrollView { Text(value).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                .frame(height: 240).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }.frame(maxWidth: .infinity)
    }
}

private struct PromptActionButtonStyle: ButtonStyle {
    var emphasized = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovered = false
    private var accent: Color { AIActionPalette.accent(for: colorScheme) }
    private var fill: Color {
        if emphasized { return colorScheme == .dark ? Color(red: 55/255, green: 52/255, blue: 79/255) : Color(red: 238/255, green: 237/255, blue: 252/255) }
        if hovered && isEnabled { return Color(nsColor: .controlColor) }
        return colorScheme == .dark ? Color(red: 42/255, green: 43/255, blue: 47/255) : Color(nsColor: .textBackgroundColor)
    }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12)).labelStyle(.titleAndIcon)
            .foregroundStyle(emphasized ? accent : Color.primary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(emphasized ? accent.opacity(0.24) : Color.primary.opacity(0.13), lineWidth: 1))
            .brightness(isEnabled && (configuration.isPressed || hovered && emphasized) ? -0.035 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}

@MainActor
private struct FunctionModelPicker: View {
    @ObservedObject var settings: AITextSettings
    @ObservedObject var api: APIConfigurationStore
    @ObservedObject var chat: ChatGPT
    let operation: TextOperation
    let engine: TranslationEngine
    var body: some View {
        ActionModelPicker(selection: Binding(get: { settings.model(for: operation) }, set: { settings.selectModel($0, for: operation) }), engine: engine)
            .accessibilityLabel("\(operation.action)使用的 AI 模型")
            .accessibilityIdentifier("settings.prompts.\(operation.key).model")
    }
}

@MainActor
private struct ActionModelPicker: View {
    @Binding var selection: TranslationTarget?
    let engine: TranslationEngine
    var body: some View {
        let groups = engine.modelGroups()
        return Picker("模型", selection: $selection) {
            Text("跟随全局 · \((try? engine.defaultChoice().label) ?? "未配置")").tag(nil as TranslationTarget?)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Section(group.name) {
                    ForEach(group.choices) { choice in Text(choice.label).tag(Optional(choice.target)) }
                }
            }
            if let selected = selection, !groups.flatMap(\.choices).contains(where: { $0.target == selected }) {
                Text("原模型不可用，请重新选择").tag(Optional(selected))
            }
        }.frame(maxWidth: 290).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
struct AIActionCreationView: View {
    @ObservedObject var settings: AITextSettings
    let engine: TranslationEngine
    @ObservedObject var api: APIConfigurationStore
    @ObservedObject var chat: ChatGPT
    let close: () -> Void
    @ViewState private var name = ""
    @ViewState private var prompt = ""
    @ViewState private var model: TranslationTarget? = nil
    @ViewState private var error = ""
    private var action: AIAction { AIAction(name: name, prompt: prompt, model: model) }
    private var validationMessage: String? {
        do { try settings.validateAction(action); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        AIActionEditorForm(title: "新建 AI 动作") {
            AIActionNameField(name: $name, identifier: "settings.actions.new.name")
            HStack { Text("提示词"); Spacer(); ActionModelPicker(selection: $model, engine: engine) }
            AIActionPromptField(text: $prompt, label: "提示词", identifier: "settings.actions.new.prompt")
            Text("在提示词中写明希望 AI 做什么。轻译会自动附上选中的原文，每次最多 12,000 字。可以选中含网址的句子。若只选中网址、单个外文字母、空白、符号或表情，轻译会跳过。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            examples
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            if !name.isEmpty || !prompt.isEmpty, let message = validationMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange)
            }
        } actions: {
            Button("取消", role: .cancel, action: close).keyboardShortcut(.cancelAction)
            Button("创建") {
                do { try settings.saveAction(action); close() }
                catch { self.error = error.localizedDescription }
            }.keyboardShortcut(.defaultAction)
                .disabled((try? settings.validateAction(action)) == nil)
                .accessibilityIdentifier("settings.actions.new.save")
        }
    }
    private var examples: some View {
            HStack {
                Text(prompt.isEmpty ? "填入示例" : "选择示例会替换当前提示词。").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("总结") {
                    fillExample(name: "总结", prompt: """
                    请用简体中文总结所选内容。先用一句话概括主题或结论，再按重要性列出关键要点。原文较短时，直接用一两句话概括。
                    保留影响理解的数字、条件、限制和例外。原文如有明确的决定或待办，可单独列出。区分已确认、推测和待核实的信息，不自行补充事实或把推测写成结论。只输出总结。
                    """)
                }
                Button("解释") {
                    fillExample(name: "解释", prompt: """
                    请用通俗的简体中文解释所选内容。先说它在当前语境中是什么意思，再按需要解释关键术语、前因后果或运行过程。遇到代码时，说明它做了什么、关键步骤和效果。
                    如果例子能帮助理解，补一个简短例子并标明是举例。区分原文信息、合理推断和未知之处。上下文不足时，说明缺少什么，不猜测具体事实。只输出解释。
                    """)
                }
                Button("会议纪要") {
                    fillExample(name: "会议纪要", prompt: """
                    请将所选的会议转写、聊天记录或会议笔记整理为简体中文会议纪要。按“会议概况”“讨论要点”“已确认决策”“待办事项”“待确认问题”组织，没有相关信息的部分可省略。会议主题、时间和参会人仅在原文明确提供时填写。
                    合并重复和口语表达，保留关键事实、数字、条件、分歧及尚未解决的问题。严格区分讨论建议、个人观点和已确认决策，不把建议或推测写成结论。
                    待办事项按“任务｜负责人｜截止时间”列出。负责人或截止时间未明确时标注“未明确”，不把发言人自动当作负责人；相对时间在缺少日期依据时保留原文表述，不自行换算。不要补充原文没有的背景、承诺或行动项。只输出会议纪要。
                    """)
                }
                Button("智能提取") {
                    fillExample(name: "智能提取", prompt: """
                    请从所选内容中提取可直接使用的关键信息，用简体中文组织结果，并根据内容选择合适的字段，例如人物或组织、事项、时间、地点、金额、数量、联系方式、状态、条件和限制；不要机械列出无关字段。
                    涉及多个同类对象时使用表格，每个对象一行，保持字段与对象的对应关系；单个对象或内容较短时使用“字段：内容”的简洁列表。原文使用特定字段名或已有结构时优先沿用，名称、编号、网址、联系方式、金额、币种、单位和日期保留原始值。
                    只提取原文明确提供的信息，不推断、不计算、不补全，也不访问链接。必需字段缺失时标注“未明确”；存在歧义、冲突或多个候选值时保留各项并标注“待核实”，不要擅自选择。只输出提取结果；没有可提取的信息时简要说明。
                    """)
                }
            }.buttonStyle(.link)
    }
    private func fillExample(name exampleName: String, prompt examplePrompt: String) {
        if name.isEmpty || ["总结", "解释", "会议纪要", "智能提取"].contains(name) { name = exampleName }
        prompt = examplePrompt
    }
}

@MainActor
private struct PromptSaveFeedback: View {
    @ObservedObject var draft: AIPromptDraft
    let operation: TextOperation
    var body: some View {
        Group {
            if draft.error(for: operation) != nil {
                Label("尚未保存", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            } else if let receipt = draft.receipt(for: operation) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").symbolEffect(.bounce, value: receipt.revision).accessibilityHidden(true)
                    Text("已保存 \(receipt.time)").monospacedDigit().contentTransition(.numericText())
                }.foregroundStyle(.green)
                    .animation(.easeOut(duration: 0.2), value: receipt.revision)
                    .help("提示词已自动保存到本机。")
            } else {
                Text(draft.status(for: operation)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 11))
            .accessibilityIdentifier("settings.prompts.\(operation.key).status")
    }
}
