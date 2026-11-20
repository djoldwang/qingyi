import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case selection, window, services, general, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .selection: return "翻译触发"
        case .window: return "译文窗口"
        case .services: return "翻译服务"
        case .general: return "通用"
        case .about: return "关于轻译"
        }
    }
    var icon: String {
        switch self {
        case .selection: return "cursorarrow.rays"
        case .window: return "macwindow"
        case .services: return "network"
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
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !title.isEmpty { Text(title).font(.system(size: 13, weight: .semibold)) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09), lineWidth: 1))
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

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var chat: ChatGPT
    @ObservedObject var api: APIConfigurationStore
    @ObservedObject var navigation: SettingsNavigation
    var updateShortcut: (ShortcutBinding) -> Bool
    var shortcutRecording: (Bool) -> Void
    var preview: () -> Void
    var verify: () -> Void
    // Snapshot fixtures skip credential restoration and real model discovery.
    var loadsAccounts = true
    var apiClient = CustomAPIClient()
    var requestSystemPermission: (() -> Void)? = nil
    var updateScreenshotShortcut: ((ShortcutBinding) -> Bool)? = nil
    var requestScreenCapturePermission: (() -> Void)? = nil
    @ViewState<Bool> private var choosingExcludedApps = false
    @ViewState<String> private var exclusionMessage = ""
    @ViewState<Registration?> private var accountToDelete = nil
    private let accent = Color(red: 0.29, green: 0.34, blue: 0.82)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                if case .api(let provider) = navigation.detail {
                    APIProviderEditor(api: api, provider: provider, client: apiClient, navigation: navigation)
                        .id(provider.id)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if navigation.detail == .account { accountSettings }
                            else {
                                switch navigation.section {
                                case .selection: selectionSettings
                                case .window: windowSettings
                                case .services:
                                    TranslationServiceSettings(api: api, chat: chat, verify: verify,
                                        edit: { navigation.open(.services, detail: .api($0)) },
                                        manageAccount: { navigation.open(.services, detail: .account) })
                                case .general: generalSettings
                                case .about: aboutSettings
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
        .alert("放弃未保存的 API 修改？", isPresented: $navigation.confirmDiscard) {
            Button("继续编辑", role: .cancel) { navigation.continueEditing() }
            Button("放弃修改", role: .destructive) { navigation.discardAndContinue() }
        } message: { Text("尚未保存的配置和密钥输入将被丢弃，已保存的配置不受影响。") }
        .alert("从轻译删除此账号？", isPresented: Binding(get: { accountToDelete != nil }, set: { if !$0 { accountToDelete = nil } }), presenting: accountToDelete) { account in
            Button("取消", role: .cancel) { accountToDelete = nil }
            Button("删除账号", role: .destructive) { chat.removeAccount(account.id); accountToDelete = nil }
        } message: { account in
            Text("将移除 \(account.email) 及其本机登录凭据和模型偏好，再次使用需要重新授权。")
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
            VStack(spacing: 5) {
                ForEach(SettingsSection.allCases) { section in
                    Button { navigation.open(section) } label: {
                        Label(section.title, systemImage: section.icon)
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
            Spacer(minLength: 30)
            permissionButton
            Text(AppVersion.display)
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 12)
            Text("原生 macOS 翻译工具").font(.system(size: 10)).foregroundStyle(.secondary)
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

    private var selectionSettings: some View {
        Group {
            SettingsGroup(title: "划词翻译") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用划词翻译")
                        hint("关闭后不显示“译”按钮，悬停翻译和剪贴板翻译独立控制。")
                    }
                    Spacer()
                    Toggle("启用划词翻译", isOn: $preferences.selectionEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small).settingsAction()
                        .accessibilityIdentifier("settings.selection.enabled")
                }
                Divider()
                SettingsRow {
                    Text("划词按钮位置").fixedSize(); Spacer()
                    Picker("划词按钮位置", selection: $preferences.buttonPosition) {
                        ForEach(ButtonPosition.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().settingsControlColumn().help(preferences.buttonPosition.title)
                        .disabled(preferences.paused)
                }
                SettingsRow { hint("松手后读取选区，显示“译”按钮。鼠标移入或点击按钮即可翻译。") }
            }
            hoverSettings
            SettingsGroup(title: "排除应用") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preferences.excluded.isEmpty ? "未排除任何软件" : "已排除 \(preferences.excluded.count) 个软件")
                        hint("添加应用后，将暂停这些应用的自动划词和悬停翻译，不影响剪贴板翻译。")
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
                                }.settingsAction().accessibilityLabel("将 \(applicationName(id)) 移出排除列表，恢复自动划词及悬停翻译")
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

    private var hoverSettings: some View {
        Group {
            SettingsGroup(title: "悬停翻译") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用悬停翻译")
                        hint("无需选中文字，触发后直接显示当前段落的译文。")
                    }
                    Spacer()
                    Toggle("启用悬停翻译", isOn: $preferences.hoverEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).settingsAction()
                        .accessibilityIdentifier("settings.hover.enabled")
                }
                Divider()
                SettingsRow {
                    Text("触发方式").fixedSize(); Spacer()
                    Picker("触发方式", selection: $preferences.hoverTrigger) {
                        ForEach(HoverTrigger.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().settingsControlColumn()
                        .accessibilityIdentifier("settings.hover.trigger")
                        .disabled(!preferences.hoverEnabled)
                }
                SettingsRow {
                    VStack(alignment: .leading, spacing: 6) {
                        hint(preferences.hoverTrigger == .longPress
                             ? "将鼠标放在段落上，按住左键 0.6 秒即可翻译。移动超过 6 点会取消触发，正常拖选不受影响。"
                             : "将鼠标放在段落上，单独按下并松开所选按键即可翻译；组合按键、鼠标点击或移动会取消触发。")
                        hint("默认关闭，开启后与自动划词独立工作。中文自动跳过，不显示译文窗口。")
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
            SettingsGroup(title: "译文字号") {
                SettingsRow {
                    TranslationFontSizeSlider(selection: $preferences.translationFontSize, accent: accent)
                }
            }
            SettingsWindowIllustration(position: preferences.translationWindowPosition, fontSize: CGFloat(preferences.translationFontSize))
            HStack(spacing: 12) {
                Button("预览翻译浮窗", action: preview)
                hint("预览不调用模型。")
            }
            hint("窗口高度随内容调整，长内容内部滚动。拖动顶部可移动窗口，钉住后持续显示；关闭后下次使用默认位置。")
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
                    VStack(alignment: .leading, spacing: 3) { Text("翻译已复制文字"); hint("点击右侧录制新的快捷键。") }
                    Spacer()
                    ShortcutRecorder(binding: preferences.shortcutBinding, onCandidate: updateShortcut, onRecording: shortcutRecording)
                        .frame(width: 185, height: 28).settingsControlColumn()
                }
                Divider()
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) { Text("截图翻译"); hint("松开快捷键后框选，自动识别并翻译。") }
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
            Button { navigation.open(.services) } label: { Label("翻译服务", systemImage: "chevron.left") }.buttonStyle(.link)
            SettingsGroup(title: "当前账号") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chat.activeAccount?.email ?? "尚未连接 ChatGPT").lineLimit(1).truncationMode(.tail)
                            .help(chat.activeAccount?.email ?? "尚未连接 ChatGPT").textSelection(.enabled)
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
            hint("默认翻译模型统一在“翻译服务”首页选择。")
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
                    Text(account.email).lineLimit(1).truncationMode(.tail).help(account.email).textSelection(.enabled)
                    Spacer()
                    if account.id == chat.activeID {
                        Text("当前账号").font(.system(size: 11, weight: .medium)).foregroundStyle(accent).fixedSize()
                    } else { Button("切换") { chat.selectAccount(account.id) }.disabled(chat.busy).settingsAction() }
                    Button("删除", role: .destructive) { accountToDelete = account }.disabled(chat.busy).settingsAction()
                        .accessibilityLabel("删除账号 \(account.email)")
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
                privacyRow("主动触发，才发送待翻译文字", "文字发送给你选择的翻译服务，划词检测与截图文字识别在本机完成。")
                Divider()
                privacyRow("默认不保存翻译历史", "默认不保存原文、译文或翻译历史。")
                Divider()
                privacyRow("凭据保存在 macOS 钥匙串", "账号及模型配置保存在本机。")
            }
            SettingsGroup(title: "当前能力") {
                SettingsRow { hint("支持划词、悬停、剪贴板及截图翻译。外语译为简体中文，单次最多 12,000 字。") }
                Divider()
                SettingsRow { hint("图片及扫描件可通过截图识别后翻译。文字在本机识别，仅将识别出的文字发送给当前翻译服务。") }
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
            Slider(value: $selection, in: TranslationFontSize.range) { Text("译文字号") }
                .labelsHidden().tint(accent).frame(minWidth: 160)
                .accessibilityValue("\(selection.formatted(.number.precision(.fractionLength(1)))) 点")
                .help("拖动调整译文字号，范围 12–24 pt，默认 15 pt。")
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
    var fontSize: CGFloat = 15
    @ViewState<CGFloat> private var cardHeight: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                Text("轻译　文件　编辑").font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).frame(height: 22)
                    .background(Color(nsColor: .controlBackgroundColor))
                Text("Small steps make things easier.").font(.system(size: 11)).foregroundStyle(.secondary).offset(x: 24, y: 85)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Image(systemName: "pin"); Spacer(); Text("—"); Spacer(); Image(systemName: "xmark") }.font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Small steps make things easier.").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("小小的进步，让事情变得更简单。").font(.system(size: fontSize * 0.8)).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    HStack { Text("默认模型 ⌄"); Spacer(); Image(systemName: "doc.on.doc") }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(12).frame(width: 220).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    .background(GeometryReader { card in
                        Color.clear.preference(key: SettingsPreviewHeight.self, value: card.size.height)
                    })
                    .offset(x: position == .upperRight ? max(0, geometry.size.width - 232) : min(95, max(0, geometry.size.width - 232)), y: position == .upperRight ? 28 : 93)
            }
        }.frame(height: max(250, cardHeight + (position == .upperRight ? 28 : 93) + 12))
            .onPreferenceChange(SettingsPreviewHeight.self) { cardHeight = $0 }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityLabel("译文窗口位置示意：\(position.title)")
    }
}
