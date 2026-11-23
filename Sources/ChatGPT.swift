import AppKit
import Foundation

struct Registration: Codable, Identifiable, Equatable {
    let id: String
    let subject: String
    let email: String
}
struct Credentials: Codable {
    var access: String
    var refresh: String?
    var idToken: String
    var scopes: [String]
    var expiry: Date
}

protocol ChatGPTCredentialVault {
    func read(_ id: String) throws -> Credentials?
    func save(_ credentials: Credentials, id: String) throws
    func remove(_ id: String) throws
}
struct KeychainChatGPTCredentialVault: ChatGPTCredentialVault {
    func read(_ id: String) throws -> Credentials? { try CredentialStore.read(Credentials.self, account: id) }
    func save(_ credentials: Credentials, id: String) throws { try CredentialStore.save(credentials, account: id) }
    func remove(_ id: String) throws { try CredentialStore.remove(account: id) }
}

enum ChatGPTModelLoadState: Equatable {
    case idle, loading, loaded, empty, failed(String)
    var isFailure: Bool { if case .failed = self { return true }; return false }
}

@MainActor
final class ChatGPT: ObservableObject {
    @Published private(set) var registrations: [Registration] = []
    @Published private(set) var activeID: String = ""
    @Published private(set) var models: [ModelChoice] = []
    @Published private(set) var signedIn = false
    @Published private(set) var busy = false
    @Published private(set) var signingOut = false
    @Published private(set) var modelLoadState: ChatGPTModelLoadState = .idle
    @Published private(set) var modelsUpdatedAt: Date?
    @Published private(set) var accountError = ""
    @Published var message = "登录 ChatGPT，授权轻译使用你的订阅额度。"
    @Published var modelID: String = "" { didSet { if !activeID.isEmpty { defaults.set(modelID, forKey: "model.\(activeID)") } } }
    private let defaults: UserDefaults
    private let session: URLSession
    private let vault: ChatGPTCredentialVault
    private var temporaryModels: [ModelChoice] = []
    private var temporaryModelsAccountID = ""
    private var credentialRead: (UUID, Task<Credentials?, Error>)?
    private var receiver: LoopbackReceiver?
    private var authTask: Task<Void, Never>?
    private var refreshTask: Task<Credentials, Error>?
    private var modelTask: Task<Void, Never>?
    private var modelRequestID: UUID?
    private var generation = UUID()
    private var settingsRestoreTask: Task<Void, Never>?
    private var loadedCredentials = false
    private var credentials: Credentials?
    private let issuer = "https://auth.openai.com"
    private let resource = "https://api.openai.com/v1"

    init(defaults: UserDefaults = .standard, session: URLSession = HTTP.session(), vault: ChatGPTCredentialVault = KeychainChatGPTCredentialVault()) {
        self.defaults = defaults; self.session = session; self.vault = vault
        if let data = defaults.data(forKey: "registrations"), let values = try? JSONDecoder().decode([Registration].self, from: data) { registrations = values }
        activeID = defaults.string(forKey: "activeRegistration") ?? ""
        modelID = defaults.string(forKey: "model.\(activeID)") ?? ""
        // Older builds queued other registrations for deletion by email. Those
        // entries may belong to another workspace: cancel the queue, never the keys.
        defaults.removeObject(forKey: "obsoleteChatGPTCredentials")
        // Keychain access is deferred until the user opens settings or requests translation.
    }
    var activeAccount: Registration? { registrations.first { $0.id == activeID } }
    var activeAccountLabel: String { activeAccount.map { accountLabel($0) } ?? "ChatGPT" }
    func accountLabel(_ account: Registration) -> String {
        let matches = registrations.filter { Self.emailKey($0.email) == Self.emailKey(account.email) }
        guard matches.count > 1, let index = matches.firstIndex(where: { $0.id == account.id }) else { return account.email }
        return "\(account.email) · 连接 \(index + 1)"
    }
    var modelName: String { models.first(where: { $0.id == modelID })?.name ?? modelID }
    var temporaryModelChoices: [ModelChoice] {
        temporaryModelsAccountID == activeID ? temporaryModels : models
    }
    var hostID: String {
        if let value = defaults.string(forKey: "hostID") { return value }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(value, forKey: "hostID"); return value
    }
    // Opening settings must never wait for SecurityAgent on the UI thread.
    // Reuse the coalesced, cancellable request credential path, including while
    // the user is still responding to the system authorization prompt.
    func restoreForSettings() {
        guard !loadedCredentials, settingsRestoreTask == nil else { return }
        let client = activeID; let run = generation
        message = "正在读取 ChatGPT 登录信息…"
        settingsRestoreTask = Task { [weak self] in
            guard let self = self else { return }
            defer { if activeID == client, generation == run { settingsRestoreTask = nil } }
            do {
                try await restoreForRequest()
                try Task.checkCancellation()
                guard activeID == client, generation == run else { return }
                message = signedIn ? "已连接 \(activeAccountLabel)。使用量计入账号获准的订阅额度。" : "请重新登录，并允许使用 ChatGPT 订阅额度。"
                if signedIn, models.isEmpty { await refreshModels() }
            } catch is CancellationError { }
            catch { if activeID == client, generation == run { message = error.localizedDescription } }
        }
    }
    func restore() {
        guard !loadedCredentials else { return }
        loadedCredentials = true
        guard !activeID.isEmpty else { return }
        do {
            credentials = try vault.read(activeID)
            signedIn = credentials?.scopes.contains("chatgpt.tokens.use.direct") == true
            message = signedIn ? "已连接 \(activeAccountLabel)。使用量计入账号获准的订阅额度。" : "请重新登录，并允许使用 ChatGPT 订阅额度。"
        } catch { message = error.localizedDescription }
    }
    func selectAccount(_ id: String) {
        guard !busy, id.isEmpty || registrations.contains(where: { $0.id == id }) else { return }
        cancelLogin(); refreshTask?.cancel(); refreshTask = nil; generation = UUID()
        activeID = id; defaults.set(id, forKey: "activeRegistration")
        credentials = nil; signedIn = false; loadedCredentials = false; models = []
        temporaryModels = []; temporaryModelsAccountID = ""
        credentialRead = nil
        modelID = defaults.string(forKey: "model.\(id)") ?? ""
        message = "登录 ChatGPT，授权轻译使用你的订阅额度。"
        restore()
        if signedIn {
            let run = generation
            Task { if activeID == id, generation == run { await refreshModels() } }
        }
    }
    func signIn(newAccount: Bool = false) {
        guard !busy else { return }
        do { try AppRuntime.validate(); try CredentialStore.probe() }
        catch { message = error.localizedDescription; return }
        if !newAccount, activeAccount == nil, hasPendingRegistration {
            recoverPendingRegistration()
            return
        }
        restore()
        let registration = newAccount ? nil : activeAccount
        let oldCredentials = newAccount ? nil : credentials
        cancelLogin(); accountError = ""
        busy = true; message = "请在浏览器中登录，并允许轻译使用 ChatGPT 订阅额度。"
        let run = generation
        authTask = Task {
            defer { if self.generation == run { self.busy = false; self.receiver = nil; self.authTask = nil } }
            do {
                let verifier = try secureRandom(); let state = try secureRandom(); let nonce = try secureRandom()
                let receiver = LoopbackReceiver(state: state, existingClient: registration?.id)
                self.receiver = receiver
                let redirect = try await receiver.start()
                try Task.checkCancellation()
                var components = URLComponents(string: issuer + "/api/accounts/authorize")!
                var fields: [String: String] = ["client_id": registration?.id ?? "dynamic_agent_client", "ext_agent_host_id": hostID, "response_type": "code", "redirect_uri": redirect.absoluteString, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", "resource": resource, "state": state, "nonce": nonce, "code_challenge_method": "S256", "code_challenge": pkceChallenge(verifier)]
                if registration == nil { fields["agent_name_hint"] = "轻译 Qingyi" }
                else if let token = oldCredentials?.idToken, !token.isEmpty { fields["id_token_hint"] = token }
                else { fields["login_hint"] = registration?.email }
                components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let url = components.url, NSWorkspace.shared.open(url) else { throw QingyiError.message("无法打开登录页面，请检查默认浏览器。") }
                let (code, client) = try await receiver.wait()
                try Task.checkCancellation()
                guard self.generation == run else { return }
                // Retain the issued client before token exchange, including interrupted exchanges.
                defaults.set(client, forKey: "pendingClient")
                try Task.checkCancellation()
                let tokens = try await tokenRequest(["grant_type": "authorization_code", "client_id": client, "code": code, "code_verifier": verifier, "redirect_uri": redirect.absoluteString, "resource": resource])
                guard let idToken = tokens["id_token"] as? String else { throw QingyiError.message("登录服务未返回可验证的身份信息。") }
                let (jwks, response) = try await session.data(from: URL(string: issuer + "/.well-known/jwks.json")!)
                try HTTP.check(response, data: jwks)
                let identity = try IdentityValidator.verify(idToken, clientID: client, nonce: nonce, jwks: jwks)
                let saved = try Self.decodeCredentials(tokens)
                try Task.checkCancellation()
                guard self.generation == run else { return }
                try saveVerifiedRegistration(client: client, identity: identity, saved: saved, replacing: registration)
                message = "已连接 \(identity.email)，正在读取可用模型…"
                await refreshModels()
            } catch is CancellationError { }
            catch { if generation == run { message = error.localizedDescription } }
        }
    }
    func cancelLogin() {
        guard !signingOut else { return }
        settingsRestoreTask?.cancel(); settingsRestoreTask = nil
        generation = UUID(); authTask?.cancel(); receiver?.cancel(); receiver = nil; authTask = nil; busy = false
        refreshTask?.cancel(); refreshTask = nil; credentialRead = nil
        resetModelLoading()
    }
    func removeAccount(_ id: String) {
        guard !busy, registrations.contains(where: { $0.id == id }) else { return }
        accountError = ""
        if activeID == id { cancelLogin() }
        do { try vault.remove(id) }
        catch { accountError = "无法删除账号：\(error.localizedDescription)"; return }
        registrations.removeAll { $0.id == id }; persistRegistrations()
        defaults.removeObject(forKey: "model.\(id)")
        if defaults.string(forKey: "pendingClient") == id { defaults.removeObject(forKey: "pendingClient") }
        if activeID == id { selectAccount(registrations.first?.id ?? "") }
    }
    func recoverPendingRegistration() {
        guard let client = defaults.string(forKey: "pendingClient"), !client.isEmpty, !busy else { return }
        // A failed exchange still has a registration. Reuse it for a fresh OAuth attempt.
        let provisional = Registration(id: client, subject: "", email: "上次未完成的授权")
        if !registrations.contains(where: { $0.id == client }) { registrations.append(provisional); persistRegistrations() }
        selectAccount(client)
        signIn()
    }
    var hasPendingRegistration: Bool { defaults.string(forKey: "pendingClient") != nil }
    func signOut() async {
        guard !busy else { return }
        restore(); cancelLogin(); refreshTask?.cancel(); refreshTask = nil
        let id = activeID; let saved = credentials
        let run = generation
        credentials = nil; signedIn = false; models = []; loadedCredentials = true
        temporaryModels = []; temporaryModelsAccountID = ""
        credentialRead = nil
        busy = true; signingOut = true
        defer { busy = false; signingOut = false }
        var revoked = saved?.refresh == nil
        if let refresh = saved?.refresh {
            for attempt in 0..<2 {
                do {
                    var request = URLRequest(url: URL(string: issuer + "/api/accounts/oauth/revoke")!)
                    request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.httpBody = formBody(["token": refresh, "token_type_hint": "refresh_token", "client_id": id])
                    let (data, response) = try await session.data(for: request)
                    try HTTP.check(response, data: data); revoked = true; break
                } catch { if attempt == 0 { try? await Task.sleep(nanoseconds: 500_000_000) } }
            }
        }
        do { if !id.isEmpty { try vault.remove(id) } }
        catch { message = error.localizedDescription; return }
        guard generation == run else { return }
        message = revoked ? "已退出登录，已清除本地凭据。" : "已清除本地凭据，但未确认远程撤销。请到 ChatGPT 设置中断开轻译。"
    }
    func accessToken() async throws -> String {
        try await restoreForRequest()
        guard let saved = credentials, saved.scopes.contains("chatgpt.tokens.use.direct") else { throw QingyiError.message("请先打开轻译设置，登录 ChatGPT 并授权使用订阅额度。") }
        if saved.expiry > Date().addingTimeInterval(90) { return saved.access }
        if let task = refreshTask { return try await task.value.access }
        guard let refresh = saved.refresh else { throw QingyiError.message("登录已过期，请在设置中重新登录。") }
        let client = activeID; let run = generation
        let task = Task<Credentials, Error> {
            let object = try await self.tokenRequest(["grant_type": "refresh_token", "client_id": client, "refresh_token": refresh, "resource": self.resource])
            let refreshed = try Self.decodeCredentials(object, previous: saved)
            try Task.checkCancellation()
            guard self.generation == run, self.activeID == client else { throw CancellationError() }
            try self.vault.save(refreshed, id: client)
            self.credentials = refreshed
            self.signedIn = refreshed.scopes.contains("chatgpt.tokens.use.direct")
            guard self.signedIn else { throw QingyiError.message("订阅额度授权已失效，请重新登录。") }
            return refreshed
        }
        refreshTask = task
        defer { if generation == run { refreshTask = nil } }
        return try await task.value.access
    }
    private func restoreForRequest() async throws {
        guard !loadedCredentials else { return }
        guard !activeID.isEmpty else { loadedCredentials = true; return }
        let client = activeID; let run = generation
        let pending: (UUID, Task<Credentials?, Error>)
        if let existing = credentialRead { pending = existing }
        else {
            let vault = self.vault
            let focus = CredentialWindowReturnCoordinator.shared.begin()
            pending = (UUID(), Task.detached { try vault.read(client) })
            credentialRead = pending
            Task { @MainActor [weak self] in
                _ = try? await pending.1.value
                CredentialWindowReturnCoordinator.shared.end(focus)
                if self?.credentialRead?.0 == pending.0 { self?.credentialRead = nil }
            }
        }
        let saved = try await CredentialWait.value(pending.1)
        try Task.checkCancellation()
        guard activeID == client, generation == run else { throw CancellationError() }
        credentials = saved; loadedCredentials = true
        signedIn = saved?.scopes.contains("chatgpt.tokens.use.direct") == true
    }
    static func decodeCredentials(_ object: [String: Any], previous: Credentials? = nil) throws -> Credentials {
        guard let access = object["access_token"] as? String, !access.isEmpty,
              let expiry = object["expires_in"] as? Double, expiry > 0,
              (object["token_type"] as? String)?.lowercased() == "bearer" else { throw QingyiError.message("登录凭据格式无效，请重新登录。") }
        let scopes = (object["scope"] as? String)?.split(separator: " ").map(String.init) ?? previous?.scopes ?? []
        return Credentials(access: access, refresh: object["refresh_token"] as? String ?? previous?.refresh, idToken: object["id_token"] as? String ?? previous?.idToken ?? "", scopes: scopes, expiry: Date().addingTimeInterval(expiry))
    }
    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 400 {
            throw QingyiError.message("授权码或登录会话已失效，请重新登录。若上次授权未完成，使用“继续上次授权”。")
        }
        try HTTP.check(response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QingyiError.message("登录服务返回格式错误。") }
        return object
    }
    func refreshModels() async {
        if let task = modelTask { await task.value; return }
        guard !activeID.isEmpty else { return }
        let client = activeID; let run = generation
        let requestID = UUID()
        modelRequestID = requestID; modelLoadState = .loading
        let task = Task { await self.fetchModels(client: client, run: run, requestID: requestID) }
        modelTask = task
        await task.value
        if modelRequestID == requestID { modelTask = nil; modelRequestID = nil }
    }
    private func fetchModels(client: String, run: UUID, requestID: UUID) async {
        do {
            let token = try await accessToken()
            try Task.checkCancellation()
            guard activeID == client, generation == run, modelRequestID == requestID else { return }
            var request = URLRequest(url: URL(string: resource + "/models")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            try HTTP.check(response, data: data)
            let choices = try ModelChoice.parse(data)
            try Task.checkCancellation()
            guard activeID == client, generation == run, modelRequestID == requestID else { return }
            models = choices
            temporaryModels = []; temporaryModelsAccountID = ""
            modelsUpdatedAt = Date()
            guard !choices.isEmpty else { modelLoadState = .empty; return }
            if !choices.contains(where: { $0.id == modelID }) { modelID = choices[0].id }
            modelLoadState = .loaded
            message = "已连接 \(activeAccountLabel) · 可选择 \(choices.count) 个模型。首次翻译成功后即可确认模型访问权限。"
        } catch is CancellationError {
            if modelRequestID == requestID { modelLoadState = .idle }
        } catch {
            if activeID == client, generation == run, modelRequestID == requestID { modelLoadState = .failed(error.localizedDescription) }
        }
    }
    private func resetModelLoading() {
        modelTask?.cancel(); modelTask = nil; modelRequestID = nil
        modelLoadState = .idle; modelsUpdatedAt = nil
    }
    // Unlike refreshModels, loading the temporary menu must not repair or persist
    // the settings page's default model.
    func loadTemporaryModels() async throws -> [ModelChoice] {
        let client = activeID; let run = generation
        let token = try await accessToken()
        var request = URLRequest(url: URL(string: resource + "/models")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try HTTP.check(response, data: data)
        let choices = try ModelChoice.parse(data)
        try Task.checkCancellation()
        guard activeID == client, generation == run else { throw CancellationError() }
        guard !choices.isEmpty else { throw QingyiError.message("当前 ChatGPT 账号没有可用模型。") }
        temporaryModels = choices; temporaryModelsAccountID = client
        return choices
    }
    static func translationBody(text: String, model: String, fastTranslation: Bool = false) throws -> Data {
        var body: [String: Any] = ["model": model, "store": false, "stream": true,
            "instructions": TranslationPrompt.text,
            "input": [["role": "user", "content": text]]]
        if fastTranslation && FastTranslationCapability.supportsChatGPT(modelID: model) {
            body["reasoning"] = ["effort": "none"]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
    func translate(_ raw: String, using requestedModel: String? = nil, accountID: String? = nil, diagnostic: ((String) -> Void)? = nil,
                   fastTranslation: Bool = false, onThinking: @escaping @MainActor (TranslationThinkingEvidence) -> Void = { _ in },
                   onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        let text = try TextPolicy.validate(raw)
        let client = activeID; let run = generation
        guard accountID == nil || accountID == client else { throw QingyiError.message("ChatGPT 账号已切换，请重新选择当前账号的模型。") }
        let token = try await accessToken()
        if let requestedModel = requestedModel {
            if !temporaryModelChoices.contains(where: { $0.id == requestedModel }) { _ = try await loadTemporaryModels() }
        } else if models.isEmpty { await refreshModels() }
        try Task.checkCancellation()
        guard activeID == client, generation == run else { throw CancellationError() }
        let selectedModel = requestedModel ?? modelID
        let choices = requestedModel == nil ? models : temporaryModelChoices
        guard !selectedModel.isEmpty, choices.contains(where: { $0.id == selectedModel }) else { throw QingyiError.message("没有可用模型，请在设置中刷新模型列表。") }
        var request = URLRequest(url: URL(string: resource + "/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.translationBody(text: text, model: selectedModel, fastTranslation: fastTranslation)
        let parameter: FastTranslationParameter? = fastTranslation && FastTranslationCapability.supportsChatGPT(modelID: selectedModel) ? .reasoning : nil
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse {
            diagnostic?("HTTP status: \(http.statusCode)")
            diagnostic?("Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "missing")")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                body.append(byte)
                if body.count == 16_384 { break }
            }
            if let http = response as? HTTPURLResponse, [400, 422].contains(http.statusCode) { try parameter?.checkRejection(body: body) }
            try HTTP.check(response, data: body); throw QingyiError.message("翻译请求失败。")
        }
        var stream = TranslationDecoder(contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "", fastParameter: parameter)
        var wire = WireLines()
        var receivedBytes = false
        var lastUpdate = Date.distantPast
        var diagnosticLines = 0
        func acceptLine(_ line: String) throws {
            try Task.checkCancellation()
            guard activeID == client, generation == run else { throw CancellationError() }
            if diagnostic != nil, !line.isEmpty, diagnosticLines < 4 {
                diagnosticLines += 1
                let scalars = line.unicodeScalars.prefix(4).map { String($0.value, radix: 16) }.joined(separator: ",")
                var keys = "not-a-single-json-object"
                if let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { keys = object.keys.sorted().joined(separator: ",") }
                diagnostic?("Body line \(diagnosticLines): bytes=\(line.utf8.count), first-scalars=\(scalars), keys=\(keys)")
            }
            if let text = try stream.line(line), Date().timeIntervalSince(lastUpdate) > 0.04 || stream.completed {
                onUpdate(text); lastUpdate = Date()
            }
        }
        for try await byte in bytes {
            receivedBytes = true
            if let line = try wire.append(byte) {
                try acceptLine(line)
                if stream.completed { break }
            }
        }
        if !stream.completed, let tail = try wire.finish() { try acceptLine(tail) }
        try FastTranslationFallbackReason.checkEmptyResponse(http, receivedBytes: receivedBytes)
        let result = try stream.finish()
        try Task.checkCancellation()
        guard activeID == client, generation == run else { throw CancellationError() }
        diagnostic?("Decoded response format: \(stream.format.rawValue)")
        onUpdate(result)
        onThinking(stream.thinkingEvidence)
        return result
    }
    private static func emailKey(_ email: String) -> String? {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.contains("@") ? value : nil
    }
    // Called only after signature, audience, nonce and callback validation.
    // A verified email is display metadata, never a registration identity.
    func saveVerifiedRegistration(client: String, identity: VerifiedIdentity, saved: Credentials, replacing registration: Registration?) throws {
        guard !client.isEmpty, client != "dynamic_agent_client",
              registration == nil || registration?.id == client else {
            throw QingyiError.message("返回的授权连接与原连接不同，请重新授权。")
        }
        for previous in [registration, registrations.first(where: { $0.id == client })].compactMap({ $0 }) {
            guard previous.subject.isEmpty || previous.subject == identity.subject else {
                throw QingyiError.message("返回的账号与原账号不同。请使用“添加账号”重新授权。")
            }
        }
        guard saved.scopes.contains("chatgpt.tokens.use.direct") else {
            throw QingyiError.message("已验证登录身份，但未获准使用订阅额度。请重新登录并开启授权。")
        }
        // Persist credentials before changing the visible selection. A failed
        // keychain write leaves all registrations, models and active state intact.
        try vault.save(saved, id: client)
        let account = Registration(id: client, subject: identity.subject, email: identity.email)
        if let index = registrations.firstIndex(where: { $0.id == client }) { registrations[index] = account }
        else { registrations.append(account) }
        persistRegistrations()
        resetModelLoading(); models = []; temporaryModels = []; temporaryModelsAccountID = ""; credentialRead = nil
        activeID = client; defaults.set(client, forKey: "activeRegistration")
        credentials = saved; loadedCredentials = true; signedIn = true
        modelID = defaults.string(forKey: "model.\(client)") ?? ""
        if defaults.string(forKey: "pendingClient") == client { defaults.removeObject(forKey: "pendingClient") }
    }
    private func persistRegistrations() { defaults.set(try? JSONEncoder().encode(registrations), forKey: "registrations") }
}
