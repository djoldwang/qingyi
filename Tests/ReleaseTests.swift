import AppKit
import Foundation

final class AccountTestVault: ChatGPTCredentialVault {
    var values: [String: Credentials] = [:]
    var removed: [String] = []
    var failRemove = false
    var failSave = false
    func read(_ id: String) throws -> Credentials? { values[id] }
    func save(_ credentials: Credentials, id: String) throws {
        if failSave { throw QingyiError.message("fixture save failure") }
        values[id] = credentials
    }
    func remove(_ id: String) throws {
        if failRemove { throw QingyiError.message("fixture deletion failure") }
        removed.append(id); values.removeValue(forKey: id)
    }
}

extension QingyiTests {
    static func fixtureCredentials(_ access: String) -> Credentials {
        Credentials(access: access, refresh: nil, idToken: "", scopes: ["chatgpt.tokens.use.direct"], expiry: Date().addingTimeInterval(3600))
    }
    @MainActor static func releaseTests() async {
        check("Automatic symbol and single-letter filters preserve manual input and meaningful text") {
            let filtered = ["a", "I", "é", "e\u{301}", "\n A \t", "/", "\\", "---", "_", "...", " / - ", "()[]{}", "∑≈∞", "😀", "👨‍👩‍👧‍👦", "\n! \t"]
            for value in filtered {
                try expect(!TextPolicy.shouldOfferAutomaticTranslation(value), "Automatic text offered: \(value)")
                try expect(try TextPolicy.validate(value) == TextPolicy.clean(value), "Manual validation changed")
            }
            for value in ["Wi-Fi", "and/or", "C++", "hello!", "AI", "42", "1+2=3", "This is a sentence."] {
                try expect(TextPolicy.shouldOfferAutomaticTranslation(value), "Meaningful text filtered: \(value)")
            }
            for value in ["中文句子。", "這是繁體中文。", "https://example.com", "example.com"] {
                try expect(!TextPolicy.shouldOfferAutomaticTranslation(value))
            }
        }
        check("Every automatic filter hides entry and preserves an existing pinned result without requests") {
            let floating = FloatingController()
            defer { floating.hide() }
            var requests = 0
            floating.onTrigger = { requests += 1 }
            let values = ["a", "é", "---", "/", "😀", "https://example.com", "中文句子。"]
            for value in values {
                floating.offerAutomaticTranslation(for: value, position: .lowerLeft)
                try expect(!floating.buttonPanel.isVisible && !floating.resultPanel.isVisible)
            }
            floating.showResult(source: "Original text", preview: true)
            floating.state.text = "保留的译文"; floating.state.pinned = true
            for value in values {
                floating.offerAutomaticTranslation(for: value, position: .lowerLeft, preserveResult: true)
                try expect(!floating.buttonPanel.isVisible && floating.resultPanel.isVisible)
                try expect(floating.state.pinned && floating.state.text == "保留的译文")
            }
            try expect(requests == 0)
        }
        check("External mouse down invalidates the old selection immediately") {
            let monitor = SelectionMonitor()
            var clears = 0, outside = 0
            monitor.onSelection = { if $0 == nil { clears += 1 } }
            monitor.onOutsideClick = { _ in outside += 1 }
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            monitor.event(event)
            try expect(clears == 1 && outside == 1)
        }
        check("Continuous translation font persists fractions, migrates integers and normalizes invalid saved values") {
            let name = "qingyi-font-tests-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            try expect(Preferences(defaults: defaults).translationFontSize == 15)
            defaults.set(18, forKey: "translationFontSize")
            let preferences = Preferences(defaults: defaults)
            try expect(preferences.translationFontSize == 18)
            preferences.translationFontSize = 17.3
            try expect(abs(Preferences(defaults: defaults).translationFontSize - 17.3) < 0.001)
            for (saved, expected) in [(-1.0, 12.0), (99.0, 24.0), (Double.nan, 15.0), (Double.infinity, 15.0)] {
                defaults.set(saved, forKey: "translationFontSize")
                try expect(Preferences(defaults: defaults).translationFontSize == expected)
            }
        }
        check("Native result text remains selectable and read-only while fractional font changes relayout") {
            let text = String(repeating: "这是一段用于排版验证的中文译文。", count: 15)
            let view = TranslationResultTextView(text: text, dark: false, fontSize: 15)
            try expect(view.isSelectable && !view.isEditable && view.string == text)
            try expect(view.textColor == NSColor.black)
            view.updateText(text, dark: true, fontSize: 17.3)
            try expect(abs((view.font?.pointSize ?? 0) - 17.3) < 0.001 && view.string == text)
            let small = TranslationWindowLayout.contentHeight(source: "Hello", text: text, fontSize: 12)
            let large = TranslationWindowLayout.contentHeight(source: "Hello", text: text, fontSize: 24)
            try expect(large > small)
        }
        check("Native model menu temporarily yields window level and restores screenSaver level") {
            let floating = FloatingController()
            defer { floating.hide() }
            try expect(floating.resultPanel.level == .screenSaver)
            floating.handleModelMenuTracking(true)
            try expect(floating.modelMenuTracking && floating.resultPanel.level.rawValue < NSWindow.Level.popUpMenu.rawValue)
            floating.handleModelMenuTracking(false)
            try expect(!floating.modelMenuTracking && floating.resultPanel.level == .screenSaver)
        }
        check("Exclusion imports deduplicate applications, reject invalid files, remove and persist") {
            let name = "qingyi-exclusions-tests-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let preferences = Preferences(defaults: defaults)
            let app = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            let result = preferences.addExcludedApplications([app, app, URL(fileURLWithPath: "/tmp/not-an-app.txt")])
            try expect(result.added == 1 && result.duplicates == 1 && result.invalid.count == 1)
            try expect(Preferences(defaults: defaults).excluded == ["com.apple.TextEdit"])
            try expect(preferences.excludedApplicationURL("com.apple.TextEdit") == app)
            preferences.removeExclusion("com.apple.TextEdit")
            try expect(Preferences(defaults: defaults).excluded.isEmpty)
            try expect(defaults.object(forKey: "excludedAppLocations") == nil)
        }
        check("Same-email registrations survive startup and obsolete cleanup queues never delete keys") {
            let name = "qingyi-registration-startup-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let accounts = [Registration(id: "active", subject: "a", email: " User@Example.com "), Registration(id: "second", subject: "b", email: "user@example.com")]
            defaults.set(try JSONEncoder().encode(accounts), forKey: "registrations")
            defaults.set("active", forKey: "activeRegistration")
            defaults.set("keep-model", forKey: "model.active")
            defaults.set("other-model", forKey: "model.second")
            defaults.set("orphan-model", forKey: "model.orphan")
            defaults.set(["second", "orphan"], forKey: "obsoleteChatGPTCredentials")
            let vault = AccountTestVault()
            for id in ["active", "second", "orphan"] { vault.values[id] = fixtureCredentials(id) }
            let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: vault)
            chat.restore()
            try expect(chat.registrations == accounts && chat.modelID == "keep-model")
            try expect(vault.removed.isEmpty && Set(vault.values.keys) == Set(["active", "second", "orphan"]))
            try expect(defaults.object(forKey: "obsoleteChatGPTCredentials") == nil)
            try expect(defaults.string(forKey: "model.second") == "other-model" && defaults.string(forKey: "model.orphan") == "orphan-model")
            try expect(chat.accountLabel(accounts[0]) != chat.accountLabel(accounts[1]))
            let reloaded = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: vault)
            try expect(reloaded.registrations == accounts && reloaded.accountLabel(accounts[1]) == chat.accountLabel(accounts[1]))
        }
        check("A new same-email registration keeps both token sets and does not inherit the old model") {
            let name = "qingyi-registration-add-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let vault = AccountTestVault()
            let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: vault)
            let host = chat.hostID
            try chat.saveVerifiedRegistration(client: "personal", identity: VerifiedIdentity(subject: "user", email: "same@example.com"), saved: fixtureCredentials("personal-token"), replacing: nil)
            chat.modelID = "personal-model"
            let first = chat.activeAccount!
            try chat.saveVerifiedRegistration(client: "workspace", identity: VerifiedIdentity(subject: "user", email: "SAME@example.com"), saved: fixtureCredentials("workspace-token"), replacing: nil)
            try expect(chat.registrations.map(\.id) == ["personal", "workspace"])
            try expect(vault.values["personal"]?.access == "personal-token" && vault.values["workspace"]?.access == "workspace-token" && vault.removed.isEmpty)
            try expect(chat.activeID == "workspace" && chat.modelID.isEmpty && defaults.string(forKey: "model.personal") == "personal-model")
            try expect(chat.hostID == host && chat.accountLabel(first) != chat.activeAccountLabel)
        }
        check("Reauthorization updates only the issued client and preserves its model and list position") {
            let name = "qingyi-registration-reauth-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let vault = AccountTestVault()
            let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: vault)
            try chat.saveVerifiedRegistration(client: "a", identity: VerifiedIdentity(subject: "subject-a", email: "same@example.com"), saved: fixtureCredentials("a-old"), replacing: nil)
            chat.modelID = "model-a"
            let original = chat.activeAccount!
            try chat.saveVerifiedRegistration(client: "b", identity: VerifiedIdentity(subject: "subject-b", email: "same@example.com"), saved: fixtureCredentials("b"), replacing: nil)
            defaults.set("a", forKey: "pendingClient")
            try chat.saveVerifiedRegistration(client: "a", identity: VerifiedIdentity(subject: "subject-a", email: "renamed@example.com"), saved: fixtureCredentials("a-new"), replacing: original)
            try expect(chat.registrations.map(\.id) == ["a", "b"] && chat.registrations[0].email == "renamed@example.com")
            try expect(chat.activeID == "a" && chat.modelID == "model-a")
            try expect(vault.values["a"]?.access == "a-new" && vault.values["b"]?.access == "b" && vault.removed.isEmpty)
            try expect(defaults.object(forKey: "pendingClient") == nil)
        }
        check("Same email never permits a changed subject or client to overwrite a saved registration") {
            let name = "qingyi-registration-reject-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let vault = AccountTestVault()
            let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: vault)
            let identity = VerifiedIdentity(subject: "original", email: "same@example.com")
            try chat.saveVerifiedRegistration(client: "a", identity: identity, saved: fixtureCredentials("original"), replacing: nil)
            let original = chat.activeAccount!
            try rejects { try chat.saveVerifiedRegistration(client: "a", identity: VerifiedIdentity(subject: "impostor", email: identity.email), saved: fixtureCredentials("wrong"), replacing: original) }
            try rejects { try chat.saveVerifiedRegistration(client: "a", identity: VerifiedIdentity(subject: "impostor", email: identity.email), saved: fixtureCredentials("wrong"), replacing: nil) }
            try rejects { try chat.saveVerifiedRegistration(client: "other", identity: identity, saved: fixtureCredentials("wrong"), replacing: original) }
            var denied = fixtureCredentials("denied"); denied.scopes = ["openid"]
            try rejects { try chat.saveVerifiedRegistration(client: "a", identity: identity, saved: denied, replacing: original) }
            try expect(chat.registrations == [original] && chat.activeID == "a" && vault.values["a"]?.access == "original" && vault.values.count == 1)
        }
        check("A failed credential save preserves registrations active account model and pending registration") {
            let name = "qingyi-registration-save-failure-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let vault = AccountTestVault()
            let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: vault)
            try chat.saveVerifiedRegistration(client: "a", identity: VerifiedIdentity(subject: "a", email: "same@example.com"), saved: fixtureCredentials("a"), replacing: nil)
            chat.modelID = "model-a"; defaults.set("b", forKey: "pendingClient")
            let before = chat.registrations
            vault.failSave = true
            try rejects { try chat.saveVerifiedRegistration(client: "b", identity: VerifiedIdentity(subject: "b", email: "same@example.com"), saved: fixtureCredentials("b"), replacing: nil) }
            try expect(chat.registrations == before && chat.activeID == "a" && chat.modelID == "model-a" && chat.signedIn)
            try expect(defaults.string(forKey: "pendingClient") == "b" && vault.values.count == 1 && vault.removed.isEmpty)
        }
        await asyncCheck("Same-email account switching refresh and explicit deletion stay scoped to the client") {
            let name = "qingyi-registration-routing-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            let session = FixtureAPIProtocol.session()
            defer { defaults.removePersistentDomain(forName: name); session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            FixtureAPIProtocol.handle = { _ in (200, "application/json", Data(#"{"models":[]}"#.utf8)) }
            let vault = AccountTestVault()
            let chat = ChatGPT(defaults: defaults, session: session, vault: vault)
            defer { chat.cancelLogin() }
            for id in ["a", "b"] {
                try chat.saveVerifiedRegistration(client: id, identity: VerifiedIdentity(subject: "same-user", email: "same@example.com"), saved: fixtureCredentials(id), replacing: nil)
                chat.modelID = "model-" + id
            }
            chat.selectAccount("a")
            let tokenA = try await chat.accessToken()
            try expect(tokenA == "a")
            try expect(chat.modelID == "model-a")
            chat.selectAccount("b")
            let tokenB = try await chat.accessToken()
            try expect(tokenB == "b")
            try expect(chat.modelID == "model-b")
            chat.removeAccount("a")
            try expect(chat.registrations.map(\.id) == ["b"] && vault.values["b"]?.access == "b" && vault.removed == ["a"])
            try expect(defaults.string(forKey: "model.b") == "model-b")
        }
        check("Account deletion failure preserves records; deleting the active account chooses a remaining account") {
            let name = "qingyi-account-delete-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let accounts = [Registration(id: "a", subject: "a", email: "a@example.com"), Registration(id: "b", subject: "b", email: "b@example.com")]
            defaults.set(try JSONEncoder().encode(accounts), forKey: "registrations")
            defaults.set("a", forKey: "activeRegistration"); defaults.set("a-model", forKey: "model.a")
            defaults.set("b-model", forKey: "model.b"); defaults.set("a", forKey: "pendingClient")
            let vault = AccountTestVault()
            let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: vault)
            vault.failRemove = true; chat.removeAccount("a")
            try expect(chat.registrations == accounts && chat.activeID == "a" && !chat.accountError.isEmpty)
            vault.failRemove = false; chat.removeAccount("a")
            try expect(chat.registrations.map(\.id) == ["b"] && chat.activeID == "b" && chat.modelID == "b-model")
            try expect(defaults.object(forKey: "model.a") == nil && defaults.object(forKey: "pendingClient") == nil)
            chat.removeAccount("b")
            try expect(chat.registrations.isEmpty && chat.activeID.isEmpty && !chat.signedIn)
        }
        await asyncCheck("ChatGPT model refresh exposes loaded, empty and failure states while preserving defaults") {
            let name = "qingyi-model-state-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name); FixtureAPIProtocol.handle = nil }
            defaults.set(try JSONEncoder().encode([Registration(id: "account", subject: "subject", email: "fixture@example.com")]), forKey: "registrations")
            defaults.set("account", forKey: "activeRegistration"); defaults.set("preferred", forKey: "model.account")
            let vault = AccountTestVault()
            vault.values["account"] = Credentials(access: "fixture", refresh: nil, idToken: "", scopes: ["chatgpt.tokens.use.direct"], expiry: Date().addingTimeInterval(3600))
            let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: vault)
            FixtureAPIProtocol.handle = { _ in (200, "application/json", Data(#"{"models":[{"slug":"preferred","display_name":"Preferred","visibility":"list"}]}"#.utf8)) }
            await chat.refreshModels()
            try expect(chat.modelLoadState == .loaded && chat.modelsUpdatedAt != nil && chat.models.count == 1)
            FixtureAPIProtocol.handle = { _ in (200, "application/json", Data(#"{"models":[]}"#.utf8)) }
            await chat.refreshModels()
            try expect(chat.modelLoadState == .empty && chat.models.isEmpty)
            FixtureAPIProtocol.handle = { _ in (429, "application/json", Data()) }
            await chat.refreshModels()
            try expect(chat.modelLoadState.isFailure && chat.modelID == "preferred")
        }
    }
}
