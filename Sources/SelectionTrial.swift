import AppKit
import SwiftUI

enum SelectionTrialSample: String, CaseIterable {
    case english = "英文", chinese = "中文"

    var text: String {
        self == .english ? TranslationWindowExample.source : "我们今天一起共同完成了任务。"
    }
    func feedback(for operation: TextOperation) -> String {
        switch operation {
        case .translation: return "示例译文　" + TranslationWindowExample.translation
        case .polishing: return "示例润色　我们今天一起完成了任务。"
        case .custom(let action): return "已选“\(action.name)”。实际使用时，此动作会处理你选中的原文。"
        }
    }
}

struct SelectionTrialModifiers {
    var toolbarOpen = false
    private var previous: NSEvent.ModifierFlags = []

    mutating func update(_ flags: NSEvent.ModifierFlags, modifier: AIActionModifier, trigger: AIActionTrigger) {
        let current = flags.intersection([.control, .option, .command, .shift, .function])
        if current == modifier.flag, previous.isEmpty {
            if trigger == .hold { toolbarOpen = true } else { toolbarOpen.toggle() }
        } else if current != modifier.flag, trigger == .hold || !current.isEmpty {
            toolbarOpen = false
        }
        previous = current
    }
}

@MainActor
struct SelectionTrial: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var settings: AITextSettings
    var manageActions: () -> Void
    @ViewState private var sample = SelectionTrialSample.english
    @ViewState private var modifiers = SelectionTrialModifiers()
    @ViewState private var feedback: String?

    private var builtin: TextOperation? {
        guard let operation = TextPolicy.automaticSelectionOperation(sample.text), settings.enabled(operation) else { return nil }
        return operation
    }
    private var toolbarOperations: [TextOperation] {
        settings.selectionToolbarOperations(for: sample.text, mode: preferences.selectionMode)
    }
    private var showsToolbar: Bool { preferences.selectionMode == .toolbar || modifiers.toolbarOpen }
    private var guidance: String {
        if preferences.paused { return "划词已暂停。打开“启用划词”后即可试用。" }
        if builtin == nil && toolbarOperations.isEmpty {
            return (sample == .english ? "翻译已关闭" : "中文润色已关闭") + "，也没有已启用的自定义动作。"
        }
        if preferences.selectionMode == .toolbar { return "点击示例动作栏中的动作，查看本地演示。" }
        if modifiers.toolbarOpen { return "点击自定义动作，试用当前选区。" }
        let buttonHint = builtin.map { "移入或点击“" + $0.selectionMark + "”试用" + $0.action + "。" }
        if settings.displayedActions.isEmpty { return (buttonHint ?? "") + settings.selectionActionHint }
        return (buttonHint ?? (sample == .english ? "翻译已关闭。" : "中文润色已关闭。")) + settings.selectionActionHint
    }

    var body: some View {
        SettingsGroup(title: "划词试用") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("本地示例")
                    Spacer()
                    Picker("示例语言", selection: $sample) {
                        ForEach(SelectionTrialSample.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                canvas
                if let feedback {
                    Text(feedback).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(guidance).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if preferences.selectionEnabled && settings.displayedActions.isEmpty {
                        Spacer(minLength: 0)
                        Button("前往 AI 动作", action: manageActions).buttonStyle(.link).fixedSize()
                    }
                }
            }.padding(SettingsLayout.cardInset)
        }
        .onChange(of: sample) { reset() }
        .onChange(of: preferences.selectionMode) { reset() }
        .onChange(of: preferences.paused) { reset() }
        .onChange(of: builtin) { reset() }
        .onChange(of: toolbarOperations) { reset() }
        .onChange(of: settings.actionModifier) { reset() }
        .onChange(of: settings.actionTrigger) { reset() }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            // AppKit uses a bottom-left origin for both the real popup and this example.
            let pointer = CGPoint(x: bounds.midX, y: bounds.midY)
            let position = showsToolbar ? preferences.actionBarPosition : preferences.buttonPosition
            let entryAbove = [.upperLeft, .upperRight, .above].contains(position)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                Text(sample.text).font(.system(size: 13)).padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 2))
                    .frame(width: pointer.x, alignment: .trailing)
                    .offset(y: entryAbove ? bounds.midY + 4 : bounds.midY - 23)
                Image(systemName: "cursorarrow").font(.system(size: 14))
                    .offset(x: pointer.x, y: bounds.midY - 2).accessibilityHidden(true)
                if preferences.selectionEnabled {
                    if showsToolbar && !toolbarOperations.isEmpty {
                        let size = AIActionToolbarLayout.size(operations: toolbarOperations, availableWidth: bounds.width - 4)
                        let origin = position.placedOrigin(relativeTo: pointer, size: size, screen: bounds)
                        TrialToolbar(operations: toolbarOperations, choose: choose)
                            .id(sample).frame(width: size.width, height: size.height)
                            .offset(x: origin.x, y: bounds.height - origin.y - size.height)
                    } else if !showsToolbar, let builtin {
                        let size = CGSize(width: 38, height: 38)
                        let origin = position.placedOrigin(relativeTo: pointer, size: size, screen: bounds)
                        TrialGlyph(operation: builtin) { choose(builtin) }
                            .frame(width: size.width, height: size.height)
                            .offset(x: origin.x, y: bounds.height - origin.y - size.height)
                    }
                }
            }.background {
                if preferences.selectionEnabled && preferences.selectionMode == .compact && !toolbarOperations.isEmpty {
                    TrialModifierListener { event in
                        if event.type == .flagsChanged {
                            modifiers.update(event.modifierFlags, modifier: settings.actionModifier, trigger: settings.actionTrigger)
                        } else {
                            modifiers.toolbarOpen = false
                        }
                    }.onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in reset() }
                }
            }
        }.frame(height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func choose(_ operation: TextOperation) {
        guard preferences.selectionEnabled,
              showsToolbar ? toolbarOperations.contains(operation) : builtin == operation else { return }
        feedback = sample.feedback(for: operation)
        modifiers.toolbarOpen = false
    }
    private func reset() {
        modifiers = SelectionTrialModifiers()
        feedback = nil
    }
}

private struct TrialGlyph: NSViewRepresentable {
    let operation: TextOperation
    var choose: () -> Void
    func makeNSView(context: Context) -> HoverButton { HoverButton(frame: .zero) }
    func updateNSView(_ view: HoverButton, context: Context) {
        view.operation = operation
        view.trigger = choose
    }
}

private struct TrialToolbar: View {
    let operations: [TextOperation]
    var choose: (TextOperation) -> Void
    @StateObject private var state = AIActionPopupState()

    var body: some View {
        AIActionPopupView(state: state, embedded: true)
            .onChange(of: operations, initial: true) {
                state.operations = operations
                state.selected = 0
                state.hovered = nil
                state.choose = choose
            }
    }
}

// Keep practice gestures local to this settings window, including on macOS 14.
private struct TrialModifierListener: NSViewRepresentable {
    var handle: (NSEvent) -> Void

    final class Listener: NSView {
        var handle: ((NSEvent) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                if let self, let window = self.window, window.isKeyWindow,
                   (event.window ?? NSApp.keyWindow) === window, !self.visibleRect.isEmpty {
                    self.handle?(event)
                }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> Listener { Listener() }
    func updateNSView(_ view: Listener, context: Context) { view.handle = handle }
}
