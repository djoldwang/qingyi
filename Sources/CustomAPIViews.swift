import SwiftUI

// Disambiguate the property wrapper from the newer SDK State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

struct TranslationServiceSettings: View {
    @ObservedObject var api: APIConfigurationStore
    @ObservedObject var chat: ChatGPT
    var verify: () -> Void
    var edit: (APIProvider) -> Void
    var manageAccount: () -> Void
    @ViewState<String> private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "默认翻译") {
                SettingsRow {
                    Text("翻译服务").fixedSize(); Spacer()
                    Picker("翻译服务", selection: Binding(get: { api.activeProviderID }, set: { id in perform { try api.selectProvider(id) } })) {
                        Text("ChatGPT 账号").tag("")
                        ForEach(api.providers) { Text($0.name).tag($0.id) }
                        if !api.activeProviderID.isEmpty, api.activeProvider == nil { Text("服务已删除，请重新选择").tag(api.activeProviderID) }
                    }.labelsHidden().lineLimit(1).truncationMode(.tail).settingsControlColumn()
                        .help(api.activeProviderID.isEmpty ? "ChatGPT 账号" : (api.activeProvider?.name ?? "服务已删除，请重新选择"))
                        .disabled(chat.busy || !api.loadError.isEmpty)
                }
                Divider()
                SettingsRow {
                    Text("翻译模型").fixedSize(); Spacer()
                    if let provider = api.activeProvider {
                        Picker("翻译模型", selection: Binding(get: { api.activeProvider?.selectedModelID ?? "" }, set: { id in perform { try api.selectModel(id) } })) {
                            Text(provider.models.isEmpty ? "请先添加模型" : "请选择模型").tag("")
                            ForEach(provider.models) { Text($0.name).tag($0.id) }
                        }.labelsHidden().lineLimit(1).truncationMode(.tail).settingsControlColumn()
                            .help(provider.selectedModel?.name ?? "请选择模型").disabled(!api.loadError.isEmpty)
                    } else if api.activeProviderID.isEmpty {
                        Picker("翻译模型", selection: $chat.modelID) {
                            if chat.models.isEmpty { Text(chat.modelID.isEmpty ? "请连接账号并刷新模型" : chat.modelID).tag(chat.modelID) }
                            ForEach(chat.models) { Text($0.name).tag($0.id) }
                        }.labelsHidden().lineLimit(1).truncationMode(.tail).settingsControlColumn()
                            .help(chat.modelName.isEmpty ? "请连接账号并刷新模型" : chat.modelName).disabled(chat.busy || !chat.signedIn)
                    } else { Text("请重新选择服务").foregroundStyle(.secondary).settingsControlColumn() }
                }
                Divider()
                SettingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(api.activeProviderID.isEmpty ? "使用当前授权账号的订阅额度" : "使用所选服务商的 API 额度")
                        Text("验证会发送一句固定英文。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("验证一次翻译", action: verify)
                        .settingsAction()
                        .disabled(api.activeProviderID.isEmpty ? (!chat.signedIn || chat.modelID.isEmpty || chat.busy) : api.activeProvider?.selectedModel == nil)
                }
            }
            Text("应用于新翻译任务。译文窗口中的临时换模型仅影响本次翻译。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("账号与 API").font(.system(size: 13, weight: .semibold))
                    Spacer(); Button { edit(APIProvider()) } label: { Label("添加 API", systemImage: "plus") }
                        .disabled(!api.loadError.isEmpty).settingsAction()
                        .padding(.trailing, SettingsLayout.cardInset)
                }
                SettingsGroup(title: "") {
                    SettingsRow {
                        Image(systemName: "sparkles").foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text("ChatGPT").lineLimit(1); if api.activeProviderID.isEmpty { defaultBadge } }
                            Text(chat.activeAccount?.email ?? "尚未连接账号").font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail).help(chat.activeAccount?.email ?? "尚未连接账号")
                        }
                        Spacer(); Button("管理账号 ›", action: manageAccount).buttonStyle(.link).settingsAction()
                    }
                    ForEach(api.providers) { provider in
                        Divider()
                        SettingsRow {
                            Image(systemName: "network").foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(provider.name).lineLimit(1).truncationMode(.tail).help(provider.name); if api.activeProviderID == provider.id { defaultBadge } }
                                Text("\(provider.apiProtocol.name) · \(provider.models.count) 个模型").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(); Button("编辑配置 ›") { edit(provider) }.buttonStyle(.link).disabled(!api.loadError.isEmpty).settingsAction()
                        }
                    }
                }
            }
            Text("模型列表不代表已验证访问权限。请求失败时不会自动切换服务。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !api.loadError.isEmpty { Text(api.loadError).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
    private var defaultBadge: some View {
        Text("默认服务").font(.system(size: 10)).foregroundStyle(Color.accentColor).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); message = "" } catch { message = error.localizedDescription }
    }
}

struct APIModelForm: Identifiable, Equatable {
    let id = UUID()
    var modelID = ""
    var name = ""
    var supportsImages = false
    var maximumOutputTokens = ""
    init(model: APIModel? = nil) {
        if let model = model {
            modelID = model.id; name = model.name; supportsImages = model.supportsImages
            maximumOutputTokens = model.maximumOutputTokens.map(String.init) ?? ""
        }
    }
    func model() throws -> APIModel {
        let rawLimit = TextPolicy.clean(maximumOutputTokens)
        var limit: Int?
        if !rawLimit.isEmpty {
            guard let value = Int(rawLimit), value > 0 else { throw QingyiError.message("最大输出 token 数必须是正整数，留空则使用默认值。") }
            limit = value
        }
        return APIModel(id: modelID, name: name, supportsImages: supportsImages, maximumOutputTokens: limit)
    }
}

struct APIProviderEditor: View {
    @ObservedObject var api: APIConfigurationStore
    @Environment(\.dismiss) private var dismiss
    var navigation: SettingsNavigation?
    @ViewState<APIProvider> private var provider: APIProvider
    @ViewState<[APIModelForm]> private var models: [APIModelForm]
    @ViewState<String> private var key = ""
    @ViewState<Bool> private var showKey = false
    @ViewState<String> private var message = ""
    @ViewState<Bool> private var fetching = false
    @ViewState<[APIModel]> private var candidates = []
    @ViewState<Set<String>> private var selected = []
    @ViewState<Task<Void, Never>?> private var fetchTask = nil
    @ViewState<UUID> private var fetchID = UUID()
    @ViewState<UUID?> private var expandedModel = nil
    @ViewState<Bool> private var deleting = false
    private let existing: Bool
    private let client: CustomAPIClient
    private let originalProvider: APIProvider
    private let originalModels: [APIModelForm]
    init(api: APIConfigurationStore, provider: APIProvider, client: CustomAPIClient = CustomAPIClient(), navigation: SettingsNavigation? = nil) {
        self.api = api; self.client = client; self.navigation = navigation
        originalProvider = provider
        let forms = provider.models.map { APIModelForm(model: $0) }
        originalModels = forms
        _provider = ViewState(initialValue: provider)
        _models = ViewState(initialValue: forms)
        existing = api.providers.contains { $0.id == provider.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { leave() } label: { Label("翻译服务", systemImage: "chevron.left") }.buttonStyle(.link)
                Spacer()
                Button("取消") { finish() }.keyboardShortcut(.cancelAction).settingsAction()
                Button("保存") { save() }.buttonStyle(.borderedProminent).disabled(fetching).settingsAction()
            }.padding(.horizontal, SettingsLayout.pageInset).padding(.vertical, 20)
            Divider()
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(message.hasPrefix("已") ? Color.secondary : Color.orange)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsLayout.pageInset).padding(.top, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Text("连接配置").font(.system(size: 13, weight: .semibold))
                    HStack(alignment: .top, spacing: 16) {
                        field("显示名称") { TextField("例如：我的 API", text: $provider.name) }
                        field("API 协议") {
                            Picker("API 协议", selection: $provider.apiProtocol) {
                                ForEach(APIProtocol.allCases) { Text($0.name).tag($0) }
                            }.labelsHidden().lineLimit(1).truncationMode(.tail).settingsControlColumn().help(provider.apiProtocol.name)
                        }
                    }
                    field("API 基础地址") { TextField("https://gateway.example/v1", text: $provider.baseURL) }
                    Text("仅填写域名时补 /v1；网关前缀会保留。不要包含 /chat/completions、/responses 或 /messages。")
                        .font(.caption).foregroundStyle(.secondary)
                    field("API 密钥") {
                        HStack {
                            Group {
                                if showKey { TextField(existing ? "留空保留已保存的密钥" : "输入 API 密钥", text: $key) }
                                else { SecureField(existing ? "留空保留已保存的密钥" : "输入 API 密钥", text: $key) }
                            }
                            Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                                .help(showKey ? "隐藏输入的密钥" : "显示输入的密钥")
                                .accessibilityLabel(showKey ? "隐藏输入的密钥" : "显示输入的密钥")
                        }
                    }
                    Text("密钥保存在 macOS 钥匙串。其他配置保存在本机；取消编辑不会保存。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Text("模型目录").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if fetching {
                            ProgressView().controlSize(.small)
                            Button("取消获取") { invalidateFetch() }
                        } else {
                            Button("获取可用模型") { fetchModels() }
                        }
                    }
                    Text("获取操作会把密钥发送到上方 API 地址。导入模型后仍可修改显示名称；也可以直接手动添加。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("选择要导入的模型").font(.subheadline.bold())
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 9) {
                                    ForEach(candidates) { model in
                                        Toggle(isOn: Binding(get: { selected.contains(model.id) }, set: { value in
                                            if value { selected.insert(model.id) } else { selected.remove(model.id) }
                                        })) {
                                            VStack(alignment: .leading) {
                                                Text(model.name)
                                                if model.name != model.id { Text(model.id).font(.caption).foregroundStyle(.secondary) }
                                            }
                                        }
                                    }
                                }
                            }.frame(height: min(210, CGFloat(candidates.count * 45)))
                            HStack {
                                Button("全选") { selected = Set(candidates.map(\.id)) }
                                Button("导入选中模型（\(selected.count)）") { importModels() }.disabled(selected.isEmpty)
                                Button("收起列表") { candidates = []; selected = [] }
                            }
                        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach($models) { $model in
                        let rowID = model.id
                        VStack(spacing: 0) {
                            Button {
                                expandedModel = expandedModel == rowID ? nil : rowID
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.name.isEmpty ? (model.modelID.isEmpty ? "新模型" : model.modelID) : model.name)
                                            .foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                                            .help(model.name.isEmpty ? model.modelID : model.name)
                                        Text(model.modelID.isEmpty ? "请填写模型 ID" : model.modelID).font(.system(size: 11)).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.tail).help(model.modelID)
                                    }
                                    Spacer()
                                    Label(expandedModel == rowID ? "收起" : "编辑", systemImage: expandedModel == rowID ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 11)).foregroundStyle(Color.accentColor).fixedSize()
                                }.padding(13).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if expandedModel == rowID {
                                Divider()
                                APIModelEditorRow(model: $model) { models.removeAll { $0.id == rowID } }
                            }
                        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.09), lineWidth: 1))
                    }
                    Button {
                        let form = APIModelForm(); models.append(form); expandedModel = form.id
                    } label: { Label("手动添加模型", systemImage: "plus") }
                    if models.isEmpty { Text("可以先保存提供商，再编辑配置获取或添加模型。").font(.caption).foregroundStyle(.secondary) }
                    if existing {
                        Divider()
                        Button("删除此 API…", role: .destructive) { deleting = true }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(SettingsLayout.pageInset).textFieldStyle(.roundedBorder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { navigation?.editorDirty = hasUnsavedChanges }
        .onChange(of: hasUnsavedChanges) { _, dirty in navigation?.editorDirty = dirty }
        .onChange(of: provider.baseURL) { _, _ in invalidateFetch() }
        .onChange(of: provider.apiProtocol) { _, _ in invalidateFetch() }
        .onChange(of: key) { _, _ in invalidateFetch() }
        .onDisappear { invalidateFetch(); navigation?.editorDirty = false }
        .alert("删除此 API 提供商？", isPresented: $deleting) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                do { try api.remove(provider.id); finish() }
                catch { message = apiEditorError(error) }
            }
        } message: { Text("将删除配置、模型列表及钥匙串中的对应密钥。删除正在使用的服务后需重新选择。") }
    }
    private var hasUnsavedChanges: Bool { provider != originalProvider || models != originalModels || !key.isEmpty }
    private func finish() {
        invalidateFetch()
        if let navigation = navigation { navigation.editorFinished() } else { dismiss() }
    }
    private func leave() {
        if let navigation = navigation { navigation.requestLeave { navigation.editorFinished() } }
        else { dismiss() }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.subheadline.bold()); content() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func invalidateFetch() {
        fetchID = UUID(); fetchTask?.cancel(); fetchTask = nil; fetching = false; candidates = []; selected = []
    }
    private func fetchModels() {
        invalidateFetch(); message = ""
        do {
            var snapshot = provider
            snapshot.baseURL = try APIEndpoint.base(provider.baseURL).absoluteString
            let secret = try api.key(for: provider.id, replacement: key)
            let run = fetchID
            fetching = true
            fetchTask = Task { @MainActor in
                defer { if fetchID == run { fetching = false; fetchTask = nil } }
                do {
                    let result = try await client.models(provider: snapshot, key: secret)
                    try Task.checkCancellation()
                    guard fetchID == run else { return }
                    candidates = result
                    let existing = Set(models.map { TextPolicy.clean($0.modelID) })
                    selected = Set(result.map(\.id).filter { !existing.contains($0) })
                    message = "已获取 \(result.count) 个模型。选择后点击导入；已有模型设置会保留。"
                } catch is CancellationError { }
                catch {
                    if fetchID == run { message = apiEditorError(error) }
                }
            }
        } catch { message = apiEditorError(error) }
    }
    private func importModels() {
        var known = Set(models.map { TextPolicy.clean($0.modelID) }); var added = 0
        for candidate in candidates where selected.contains(candidate.id) {
            if known.insert(candidate.id).inserted { models.append(APIModelForm(model: candidate)); added += 1 }
        }
        message = "已导入 \(added) 个新模型；已有模型的名称、图片能力和输出上限保持原设置。"
        candidates = []; selected = []
    }
    private func save() {
        do {
            var saved = provider
            saved.models = try models.map { try $0.model() }
            try api.save(saved, replacementKey: key)
            finish()
        } catch { message = apiEditorError(error) }
    }
    private func apiEditorError(_ error: Error) -> String {
        if error is URLError { return "网络连接失败，请检查 API 地址、网络或代理，也可手动添加模型。" }
        return error.localizedDescription
    }
}

struct APIModelEditorRow: View {
    @Binding var model: APIModelForm
    var remove: () -> Void
    @ViewState<Bool> private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) { Text("模型 ID").font(.caption); TextField("例如：deepseek-chat", text: $model.modelID) }
                VStack(alignment: .leading) { Text("显示名称").font(.caption); TextField("例如：DeepSeek", text: $model.name) }
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }.help("删除模型").padding(.top, 20)
            }
            DisclosureGroup("高级设置", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最大输出 token 数").font(.caption)
                        TextField("默认", text: $model.maximumOutputTokens).frame(width: 105)
                    }
                    Toggle("支持图片输入", isOn: $model.supportsImages).toggleStyle(.checkbox)
                    Text("图片开关仅记录模型能力，尚未验证；当前不提供图片翻译。输出上限留空：OpenAI 不额外设置，Anthropic 使用 8192。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }.font(.system(size: 12))
        }
        .padding(13)
    }
}
