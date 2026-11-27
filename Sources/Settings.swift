import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case selection, translation, window, services, prompts, general, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .selection: return "划词"
        case .translation: return "翻译"
        case .window: return "结果窗口"
        case .services: return "AI 服务"
        case .prompts: return "AI 动作"
        case .general: return "通用"
        case .about: return "关于轻译"
        }
    }
    var icon: String {
        switch self {
        case .selection: return "cursorarrow.rays"
        case .translation: return "character.book.closed"
        case .window: return "macwindow"
        case .services: return "network"
        case .prompts: return "text.bubble"
        case .general: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

enum SettingsDetail: Equatable {
    case account
    case api(APIProvider)
}

@MainActor
final class SettingsNavigation: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var section: SettingsSection
    @Published private(set) var detail: SettingsDetail?
    @Published var editorDirty = false
    @Published var confirmDiscard = false
    @Published private(set) var discardRevision = 0
    var discardTitle: String { section == .prompts && detail == nil ? "放弃未保存的提示词修改？" : "放弃未保存的 API 修改？" }
    var discardMessage: String {
        section == .prompts && detail == nil ? "尚未保存的提示词修改将被丢弃，已保存的提示词不受影响。" : "尚未保存的配置和密钥输入将被丢弃，已保存的配置不受影响。"
    }
    private var pendingNavigation: (() -> Void)?

    init(section: SettingsSection = .selection, detail: SettingsDetail? = nil) {
        self.section = section; self.detail = detail
    }
    func open(_ section: SettingsSection, detail: SettingsDetail? = nil) {
        guard self.section != section || self.detail != detail else { return }
        requestLeave { [weak self] in
            self?.section = section; self?.detail = detail
        }
    }
    func requestLeave(_ action: @escaping () -> Void) {
        if editorDirty { pendingNavigation = action; confirmDiscard = true }
        else { action() }
    }
    func discardAndContinue() {
        guard let action = pendingNavigation else { return }
        pendingNavigation = nil; editorDirty = false; confirmDiscard = false
        discardRevision += 1
        action()
    }
    func continueEditing() { pendingNavigation = nil; confirmDiscard = false }
    func editorFinished() {
        pendingNavigation = nil; confirmDiscard = false; editorDirty = false; detail = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editorDirty else { return true }
        requestLeave { sender.close() }
        return false
    }
}

struct SettingsPermissionPresentation {
    let trusted: Bool
    var name = "辅助功能"
    var purpose = "读取选中文字及悬停段落"
    var action: String { trusted ? "管理系统权限" : "获取系统权限" }
    var status: String { "\(name) · \(trusted ? "已授权" : "未授权")" }
    var help: String { "前往系统设置 → 隐私与安全性 → \(name)，\(trusted ? "管理" : "开启")轻译\(purpose)的权限。" }
}

enum SettingsLayout {
    static let cardInset: CGFloat = 15
    static let controlWidth: CGFloat = 230
    static let pageInset: CGFloat = 30
}

extension AITextSettings {
    var selectionActionHint: String {
        guard !displayedActions.isEmpty else {
            return "要对选中文字使用自定义动作，请在“AI 动作”中新建或启用动作。"
        }
        switch actionTrigger {
        case .press:
            return "选中文字后，单独按一下 \(actionModifier.title) 打开自定义动作栏，再按一下关闭。"
        case .hold:
            return "选中文字后，单独按住 \(actionModifier.title) 显示自定义动作栏，松开即关闭。"
        }
    }
}

extension View {
    func settingsControlColumn(width: CGFloat = SettingsLayout.controlWidth) -> some View {
        self.frame(width: width, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false).layoutPriority(1)
    }
    func settingsAction() -> some View {
        self.fixedSize(horizontal: true, vertical: true).layoutPriority(1)
    }
}

struct SettingsGroup<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var emphasized = false
    @ViewBuilder var content: Content
    private var emphasis: Color { AIActionPalette.accent(for: colorScheme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !title.isEmpty { Text(title).font(.system(size: 13, weight: .semibold)) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(emphasized ? emphasis.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(emphasized ? emphasis.opacity(0.55) : Color.primary.opacity(0.09), lineWidth: emphasized ? 1.25 : 1)
                    .allowsHitTesting(false))
                .shadow(color: emphasized ? emphasis.opacity(0.10) : .clear, radius: 8, x: 0, y: 3)
        }
    }
}

struct SettingsRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsLayout.cardInset).padding(.vertical, 13)
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var chat: ChatGPT
    @ObservedObject var api: APIConfigurationStore
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var textSettings: AITextSettings
    var updateShortcut: (ShortcutBinding) -> Bool
    var shortcutRecording: (Bool) -> Void
    var preview: () -> Void
    var verify: () -> Void
    // Snapshot fixtures skip credential restoration and real model discovery.
    var services = BuiltinTranslationSettings()
    var loadsAccounts = true
    var apiClient = CustomAPIClient()
    var requestSystemPermission: (() -> Void)? = nil
    var updateScreenshotShortcut: ((ShortcutBinding) -> Bool)? = nil
    var requestScreenCapturePermission: (() -> Void)? = nil
    @ViewState<Bool> private var choosingExcludedApps = false
    @ViewState<String> private var exclusionMessage = ""
    @ViewState<Registration?> private var accountToDelete = nil
    private let accent = Color(red: 0.29, green: 0.34, blue: 0.82)

    init(preferences: Preferences, chat: ChatGPT, api: APIConfigurationStore, navigation: SettingsNavigation,
         updateShortcut: @escaping (ShortcutBinding) -> Bool, shortcutRecording: @escaping (Bool) -> Void,
         preview: @escaping () -> Void, verify: @escaping () -> Void,
         services: BuiltinTranslationSettings? = nil, loadsAccounts: Bool = true,
         apiClient: CustomAPIClient = CustomAPIClient(), requestSystemPermission: (() -> Void)? = nil,
         updateScreenshotShortcut: ((ShortcutBinding) -> Bool)? = nil, requestScreenCapturePermission: (() -> Void)? = nil) {
        self.preferences = preferences; self.chat = chat; self.api = api; self.navigation = navigation
        textSettings = api.textSettings
        self.updateShortcut = updateShortcut; self.shortcutRecording = shortcutRecording
        self.preview = preview; self.verify = verify; self.services = services ?? BuiltinTranslationSettings(); self.loadsAccounts = loadsAccounts
        self.apiClient = apiClient; self.requestSystemPermission = requestSystemPermission
        self.updateScreenshotShortcut = updateScreenshotShortcut; self.requestScreenCapturePermission = requestScreenCapturePermission
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                if case .api(let provider) = navigation.detail {
                    APIProviderEditor(api: api, provider: provider, client: apiClient, navigation: navigation)
                        .id(provider.id)
                } else if navigation.section == .prompts && navigation.detail == nil {
                    AIPromptEditor(api: api, chat: chat, client: apiClient)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if navigation.detail == .account { accountSettings }
                            else {
                                switch navigation.section {
                                case .selection: selectionSettings
                                case .translation: translationSettings
                                case .window: windowSettings
                                case .services:
                                    TranslationServiceSettings(api: api, chat: chat, services: services, client: apiClient,
                                        edit: { navigation.open(.services, detail: .api($0)) },
                                        manageAccount: { navigation.open(.services, detail: .account) })
                                case .general: generalSettings
                                case .about: aboutSettings
                                case .prompts: EmptyView()
                                }
                            }
                        }.padding(SettingsLayout.pageInset).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 13))
        .frame(minWidth: 780, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(isPresented: $choosingExcludedApps, allowedContentTypes: [.applicationBundle], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): exclusionMessage = preferences.addExcludedApplications(urls).message
            case .failure(let error): exclusionMessage = "无法添加应用：\(error.localizedDescription)"
            }
        }
        .alert(navigation.discardTitle, isPresented: $navigation.confirmDiscard) {
            Button("继续编辑", role: .cancel) { navigation.continueEditing() }
            Button("放弃修改", role: .destructive) { navigation.discardAndContinue() }
        } message: { Text(navigation.discardMessage) }
        .alert("从轻译中移除这个账号？", isPresented: Binding(get: { accountToDelete != nil }, set: { if !$0 { accountToDelete = nil } }), presenting: accountToDelete) { account in
            Button("取消", role: .cancel) { accountToDelete = nil }
            Button("移除账号", role: .destructive) { chat.removeAccount(account.id); accountToDelete = nil }
        } message: { account in
            Text("将移除 \(chat.accountLabel(account)) 及其本机登录凭据和模型偏好，再次使用需要重新授权。")
        }
        .onChange(of: api.activeProviderID) { _, id in
            if id.isEmpty { restoreAccount() }
        }
        .onChange(of: navigation.detail) { _, detail in
            if detail == .account { restoreAccount() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("译").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(accent.gradient, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("轻译").font(.system(size: 17, weight: .semibold))
                    Text("选中 · 轻触 · 读懂").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 8).padding(.top, 24).padding(.bottom, 28)
            ScrollView {
              VStack(spacing: 5) {
                ForEach(SettingsSection.allCases) { section in
                    Button { navigation.open(section) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon).frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Text(section.title).lineLimit(1)
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(navigation.section == section ? accent : Color.primary)
                    .background(navigation.section == section ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityAddTraits(navigation.section == section ? .isSelected : [])
                    .accessibilityIdentifier("settings.section.\(section.rawValue)")
                }
              }
            }.scrollIndicators(.hidden).frame(maxHeight: .infinity).padding(.bottom, 16)
            permissionButton
            Text(AppVersion.display)
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 12)
            Text("原生 macOS AI 文本工具").font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 18)
        }.padding(.horizontal, 12).frame(width: 190)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private var permissionButton: some View {
        let color: Color = preferences.trusted && preferences.screenCaptureGranted ? accent : .orange
        return VStack(alignment: .leading, spacing: 3) {
            Text("系统权限").font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                .padding(.bottom, 4)
            permissionRow(SettingsPermissionPresentation(trusted: preferences.trusted), identifier: "settings.system-permission") {
                if let requestSystemPermission = requestSystemPermission { requestSystemPermission() }
                else { preferences.requestAccessibility() }
            }
            permissionRow(SettingsPermissionPresentation(trusted: preferences.screenCaptureGranted, name: "屏幕录制", purpose: "截取屏幕文字进行翻译"), identifier: "settings.screenshot.permission") {
                requestScreenCapturePermission?()
            }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.35), lineWidth: 1))
    }

    private func permissionRow(_ presentation: SettingsPermissionPresentation, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: presentation.trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(presentation.trusted ? Color.green : .orange)
                Text(presentation.status).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.font(.system(size: 10)).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(presentation.help)
            .accessibilityLabel("\(presentation.name)，\(presentation.trusted ? "已授权，管理权限" : "未授权，获取权限")")
            .accessibilityIdentifier(identifier)
    }

    private func selectionPositionRow(_ title: String, selection: Binding<ButtonPosition>) -> some View {
        SettingsRow {
            Text(title).fixedSize(); Spacer()
            Picker(title, selection: selection) {
                ForEach(ButtonPosition.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().settingsControlColumn().help(selection.wrappedValue.title)
                .disabled(preferences.paused)
        }
    }

    private var selectionSettings: some View {
        Group {
            SettingsGroup(title: "划词") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用划词")
                        hint("在鼠标旁显示选中文字可用的动作。悬停、剪贴板和截图翻译可独立使用。")
                    }
                    Spacer()
                    Toggle("启用划词", isOn: $preferences.selectionEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small).settingsAction()
                        .accessibilityIdentifier("settings.selection.enabled")
                }
                Divider()
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 14) {
                            Text("选中文字后").fixedSize(); Spacer()
                            Picker("选中文字后", selection: $preferences.selectionMode) {
                                ForEach(SelectionMode.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                                .accessibilityIdentifier("settings.selection.mode")
                                .disabled(preferences.paused)
                        }
                        hint(preferences.selectionMode == .compact
                             ? "将鼠标移到“译”或“润”上即可翻译或润色。启用自定义动作后，可用辅助键打开动作栏。"
                             : "划词后列出适用的翻译或润色，以及已启用的自定义动作。点击动作即可执行。")
                    }
                }
                Divider()
                if preferences.selectionMode == .compact {
                    selectionPositionRow("简洁按钮位置", selection: $preferences.buttonPosition)
                    Divider()
                }
                selectionPositionRow("动作栏位置", selection: $preferences.actionBarPosition)
            }
            SelectionTrial(preferences: preferences, settings: textSettings) { navigation.open(.prompts) }
            SettingsGroup(title: "排除应用") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preferences.excluded.isEmpty ? "尚未排除应用" : "已排除 \(preferences.excluded.count) 个应用")
                        hint("排除应用后，轻译会暂停该应用内的划词和悬停翻译。剪贴板翻译和截图翻译仍可使用。")
                    }
                    Spacer()
                    Button { choosingExcludedApps = true } label: { Label("添加应用…", systemImage: "plus") }.settingsAction()
                }
                if !preferences.excluded.isEmpty {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(preferences.excluded, id: \.self) { id in
                            SettingsRow {
                                if let url = preferences.excludedApplicationURL(id) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
                                } else { Image(systemName: "app").frame(width: 22, height: 22).foregroundStyle(.secondary) }
                                Text(applicationName(id)).font(.system(size: 12)).lineLimit(1).truncationMode(.tail).help("\(applicationName(id)) · \(id)")
                                Spacer()
                                Button("移除") {
                                    preferences.removeExclusion(id); exclusionMessage = ""
                                }.settingsAction().accessibilityLabel("将 \(applicationName(id)) 移出排除列表，恢复划词及悬停翻译")
                            }
                        }
                    }
                }
            }
            if !preferences.excluded.isEmpty {
                HStack {
                    Spacer()
                    Button("清空排除列表") { preferences.clearExclusions(); exclusionMessage = "" }.buttonStyle(.link)
                }.padding(.trailing, SettingsLayout.cardInset)
            }
            if !exclusionMessage.isEmpty { hint(exclusionMessage) }
            hint("部分软件无法读取选区，可复制文字后使用快捷键翻译。")
        }
    }

    private var translationSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "翻译") {
                SettingsRow {
                    hint("在“AI 动作”中打开或关闭“翻译”。此开关同时控制划词、悬停、剪贴板和截图四种翻译方式。")
                    Spacer()
                    Button("管理 AI 动作") { navigation.open(.prompts) }.settingsAction()
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                TranslationServicesListView(store: services)
                hoverSettings
            }.disabled(!textSettings.translationEnabled).opacity(textSettings.translationEnabled ? 1 : 0.45)
        }
    }

    private var hoverSettings: some View {
        Group {
            SettingsGroup(title: "悬停翻译") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用悬停翻译")
                        hint("将鼠标放在外语段落上，按下方设置的方式查看译文。")
                    }
                    Spacer()
                    Toggle("启用悬停翻译", isOn: $preferences.hoverEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).settingsAction()
                        .accessibilityIdentifier("settings.hover.enabled")
                }
                Divider()
                SettingsRow {
                    Text("动作辅助键").fixedSize(); Spacer()
                    Picker("动作辅助键", selection: $preferences.hoverModifier) {
                        ForEach(AIActionModifier.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().settingsControlColumn()
                        .accessibilityIdentifier("settings.hover.modifier")
                        .disabled(!preferences.hoverEnabled || preferences.hoverActivation == .mouseHold)
                }
                Divider()
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 14) {
                            Text("触发方式").fixedSize(); Spacer()
                            Picker("触发方式", selection: $preferences.hoverActivation) {
                                ForEach(HoverActivation.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().settingsControlColumn()
                                .accessibilityIdentifier("settings.hover.trigger")
                                .disabled(!preferences.hoverEnabled)
                        }
                        hint(preferences.hoverActivation.hint)
                        hint("选用“简洁按钮”并设置相同辅助键时，已有选区优先显示自定义动作栏。悬停翻译默认关闭，中文自动跳过。")
                    }
                }
            }
        }
    }

    private var windowSettings: some View {
        Group {
            SettingsGroup(title: "显示位置") {
                SettingsRow {
                    Text("默认出现位置").fixedSize(); Spacer()
                    Picker("默认出现位置", selection: $preferences.translationWindowPosition) {
                        ForEach(TranslationWindowPosition.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().settingsControlColumn().help(preferences.translationWindowPosition.title)
                }
            }
            SettingsGroup(title: "文字大小") {
                SettingsRow {
                    TranslationFontSizeSlider(selection: $preferences.translationFontSize, accent: accent)
                }
            }
            SettingsWindowIllustration(position: preferences.translationWindowPosition, fontSize: CGFloat(preferences.translationFontSize))
            HStack(spacing: 12) {
                Button("预览结果窗口", action: preview)
                hint("预览使用本地示例译文。")
            }
            hint("可在窗口内滚动阅读，拖动顶部可移动窗口。在窗外单击左键并松开会收起结果。钉住后，窗外单击也会保留结果。按 Esc 或点击关闭按钮可关闭窗口。")
        }
    }

    private var generalSettings: some View {
        Group {
            SettingsGroup(title: "启动") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) { Text("登录 Mac 时启动轻译"); hint("启动后在菜单栏运行。") }
                    Spacer()
                    Toggle("登录 Mac 时启动轻译", isOn: Binding(get: { preferences.launchAtLogin }, set: { preferences.setLoginItem($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).settingsAction()
                }
            }
            if !preferences.generalMessage.isEmpty { hint(preferences.generalMessage) }
            SettingsGroup(title: "快捷键") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) { Text("翻译已复制文字"); hint("点击右侧的快捷键，再按下想用的组合键。") }
                    Spacer()
                    ShortcutRecorder(binding: preferences.shortcutBinding, onCandidate: updateShortcut, onRecording: shortcutRecording)
                        .frame(width: 185, height: 28).settingsControlColumn()
                }
                Divider()
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) { Text("截图翻译"); hint("松开快捷键，框选要翻译的外语文字。等待译文时，可以继续滚动原页面。") }
                    Spacer()
                    ShortcutRecorder(binding: preferences.screenshotShortcutBinding, actionName: "截图翻译", onCandidate: { updateScreenshotShortcut?($0) ?? false }, onRecording: shortcutRecording)
                        .frame(width: 185, height: 28).settingsControlColumn()
                        .accessibilityIdentifier("settings.screenshot.shortcut")
                }
            }
            if !preferences.screenshotShortcutMessage.isEmpty { Text(preferences.screenshotShortcutMessage).font(.caption).foregroundStyle(.orange) }
            hint("录制时按 Esc 取消。快捷键冲突时保留原组合，并在此处提示。")
            if !preferences.shortcutMessage.isEmpty { Text(preferences.shortcutMessage).font(.caption).foregroundStyle(.orange) }
        }
    }

    private var accountSettings: some View {
        Group {
            Button { navigation.open(.services) } label: { Label("AI 服务", systemImage: "chevron.left") }.buttonStyle(.link)
            SettingsGroup(title: "当前账号") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chat.activeAccount.map { chat.accountLabel($0) } ?? "尚未连接 ChatGPT").lineLimit(1).truncationMode(.tail)
                            .help(chat.activeAccount.map { chat.accountLabel($0) } ?? "尚未连接 ChatGPT").textSelection(.enabled)
                        hint(chat.message)
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                SettingsRow {
                    if chat.busy {
                        ProgressView().controlSize(.small)
                        if chat.signingOut { Text("正在退出…") }
                        else { Button("取消登录") { chat.cancelLogin() }.settingsAction() }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 14) { accountLoginActions; Spacer(minLength: 14); accountSignOutAction }
                            VStack(alignment: .leading, spacing: 12) {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 10) { accountLoginActions }
                                    VStack(alignment: .leading, spacing: 10) { accountLoginActions }
                                }
                                if chat.signedIn { HStack { Spacer(); accountSignOutAction } }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !chat.accountError.isEmpty {
                Text(chat.accountError).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !chat.registrations.isEmpty { savedAccounts }
            accountModels
            Link("管理用量 ↗", destination: URL(string: "https://chatgpt.com/#settings/Usage")!)
            hint("在“AI 服务”的“全局 AI 模型”中选择默认模型。")
        }
    }

    @ViewBuilder private var accountLoginActions: some View {
        Button(chat.signedIn ? "重新授权" : "Continue with ChatGPT") { chat.signIn() }
            .buttonStyle(.borderedProminent).tint(accent).settingsAction()
        if chat.activeAccount != nil { Button("添加账号") { chat.signIn(newAccount: true) }.settingsAction() }
        if chat.hasPendingRegistration { Button("继续上次授权") { chat.recoverPendingRegistration() }.settingsAction() }
    }
    @ViewBuilder private var accountSignOutAction: some View {
        if chat.signedIn { Button("退出登录", role: .destructive) { Task { await chat.signOut() } }.settingsAction() }
    }

    private var savedAccounts: some View {
        SettingsGroup(title: "已保存的账号") {
            ForEach(chat.registrations) { account in
                if account.id != chat.registrations.first?.id { Divider() }
                SettingsRow {
                    Text(chat.accountLabel(account)).lineLimit(1).truncationMode(.tail).help(chat.accountLabel(account)).textSelection(.enabled)
                    Spacer()
                    if account.id == chat.activeID {
                        Text("当前账号").font(.system(size: 11, weight: .medium)).foregroundStyle(accent).fixedSize()
                    } else { Button("切换") { chat.selectAccount(account.id) }.disabled(chat.busy).settingsAction() }
                    Button("移除", role: .destructive) { accountToDelete = account }.disabled(chat.busy).settingsAction()
                        .accessibilityLabel("移除账号 \(chat.accountLabel(account))")
                }
            }
        }
    }

    private var accountModels: some View {
        SettingsGroup(title: "可用模型") {
            SettingsRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前账号的模型列表")
                    hint("列表来自服务端，实际调用权限以翻译结果为准。")
                }
                Spacer()
                Button(chat.modelLoadState.isFailure ? "重试" : "刷新模型") { refreshModels() }
                    .disabled(chat.modelLoadState == .loading || chat.busy || !chat.signedIn).settingsAction()
            }
            Divider()
            SettingsRow { modelRefreshStatus; Spacer(minLength: 0) }
            ForEach(chat.models) { model in
                Divider()
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.name).lineLimit(1).truncationMode(.tail).help(model.name).textSelection(.enabled)
                        if model.id != model.name { hint(model.id).textSelection(.enabled) }
                    }
                    Spacer()
                    if model.id == chat.modelID {
                        Text("ChatGPT 默认").font(.system(size: 11)).foregroundStyle(accent).fixedSize()
                    }
                }
            }
        }
    }

    @ViewBuilder private var modelRefreshStatus: some View {
        switch chat.modelLoadState {
        case .idle: hint(chat.signedIn ? "尚未获取模型，点击“刷新模型”读取列表。" : "登录并授权后可获取模型列表。")
        case .loading:
            ProgressView().controlSize(.small)
            hint("正在刷新模型…")
        case .loaded, .empty:
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.models.isEmpty ? "当前账号未返回可用模型" : "已获取 \(chat.models.count) 个模型")
                    .font(.system(size: 12))
                if let date = chat.modelsUpdatedAt { hint("更新时间：\(date.formatted(date: .abbreviated, time: .standard))") }
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Text("刷新失败：\(error)").font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                if !chat.models.isEmpty { hint("本次未更新，下方保留上次获取的模型列表。") }
            }
        }
    }

    private var aboutSettings: some View {
        Group {
            VStack(spacing: 9) {
                Text("译").font(.system(size: 32, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56).background(accent.gradient, in: RoundedRectangle(cornerRadius: 15))
                hint("选中 · 轻触 · 读懂")
                hint(AppVersion.display)
            }.frame(maxWidth: .infinity).padding(.bottom, 4)
            SettingsGroup(title: "隐私与数据") {
                privacyRow("按需发送文字", "划词检测和截图文字识别都在本机完成。翻译时，轻译会把原文发给已开启的翻译服务。润色或执行自定义动作时，原文和提示词只发给该动作选用的 AI。")
                Divider()
                privacyRow("不保存原文与译文", "本机仅保留配置及不含正文的模型思考状态记录。")
                Divider()
                privacyRow("凭据保存在 macOS 钥匙串", "ChatGPT 凭据和 API 密钥保存在钥匙串；账号、模型与功能偏好保存在本机。")
            }
            SettingsGroup(title: "主要功能") {
                privacyRow("翻译与润色", "支持划词、悬停、剪贴板和截图翻译，以及中文划词润色。")
                Divider()
                privacyRow("自定义 AI 动作", "可为每个动作设置提示词和模型。划词后可直接显示动作栏，也可在简洁按钮模式下用辅助键打开。")
                Divider()
                privacyRow("模型与思考模式", "支持 ChatGPT 和自定义 API。动作可跟随全局或独立选模型，思考模式默认开启。")
                Divider()
                privacyRow("文字与图片", "图片及扫描件可通过截图在本机识别文字。AI 单次最多 12,000 字，有道、谷歌单次最多 5,000 字。")
            }
        }
    }
    private func privacyRow(_ title: String, _ text: String) -> some View {
        SettingsRow { VStack(alignment: .leading, spacing: 4) { Text(title); hint(text) } }
    }
    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func applicationName(_ id: String) -> String {
        preferences.excludedApplicationURL(id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
    }
    private func restoreAccount() {
        guard loadsAccounts else { return }
        chat.restoreForSettings()
        if chat.signedIn, chat.models.isEmpty { refreshModels() }
    }
    private func refreshModels() {
        Task { await chat.refreshModels() }
    }
}

struct TranslationFontSizeSlider: View {
    @Binding var selection: Double
    let accent: Color
    var body: some View {
        HStack(spacing: 12) {
            Text("A").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: $selection, in: TranslationFontSize.range) { Text("文字大小") }
                .labelsHidden().tint(accent).frame(minWidth: 160)
                .accessibilityValue("\(selection.formatted(.number.precision(.fractionLength(1)))) 点")
                .help("拖动调整文字大小，范围 12–24 pt，默认 15 pt。")
            Text("A").font(.system(size: 20)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("\(selection, specifier: "%.1f") pt").font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity).frame(minHeight: 30)
    }
}

private struct SettingsPreviewHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SettingsWindowIllustration: View {
    let position: TranslationWindowPosition
    let fontSize: CGFloat
    @StateObject private var example: FloatingState
    @ViewState<CGFloat> private var cardHeight: CGFloat = 0
    private let scale: CGFloat = 0.75
    private let menuHeight: CGFloat = 22
    private let pointer = CGPoint(x: 116, y: 84)

    init(position: TranslationWindowPosition, fontSize: CGFloat = 15) {
        self.position = position
        self.fontSize = fontSize
        _example = StateObject(wrappedValue: {
            let state = FloatingState()
            TranslationWindowExample.populate(state, fontSize: fontSize)
            return state
        }())
    }

    var body: some View {
        GeometryReader { geometry in
            // Use the same screen coordinates and edge clamping as the floating panel.
            let screen = CGRect(x: 0, y: 0, width: geometry.size.width / scale, height: (geometry.size.height - menuHeight) / scale)
            let mouse = CGPoint(x: pointer.x / scale, y: (geometry.size.height - pointer.y) / scale)
            let frame = TranslationWindowLayout.frame(contentHeight: cardHeight, position: position, pointer: mouse, screen: screen)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                Text("轻译　文件　编辑").font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).frame(height: menuHeight)
                    .background(Color(nsColor: .controlBackgroundColor))
                Text(TranslationWindowExample.source).font(.system(size: 11))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 2))
                    .frame(maxWidth: .infinity, alignment: position == .upperLeft ? .trailing : .leading)
                    .padding(.horizontal, 20).offset(y: 66)
                if position == .belowPointer {
                    Image(systemName: "cursorarrow").font(.system(size: 13))
                        .offset(x: pointer.x, y: pointer.y)
                }
                TranslationCard(state: example, close: {}, retry: {}, settings: {}, fitsServiceContent: true)
                    .frame(width: TranslationWindowLayout.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { card in
                        Color.clear.preference(key: SettingsPreviewHeight.self, value: card.size.height)
                    })
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: frame.minX * scale, y: geometry.size.height - frame.maxY * scale)
            }
        }.frame(height: max(250, cardHeight * scale + (position.isScreenCorner ? menuHeight : pointer.y + 12 * scale) + 12))
            .onPreferenceChange(SettingsPreviewHeight.self) { cardHeight = $0 }
            .onChange(of: fontSize) { _, size in example.fontSize = size }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("结果窗口位置示意：\(position.title)")
    }
}
