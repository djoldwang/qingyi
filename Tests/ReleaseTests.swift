import AppKit
import Foundation

final class AccountTestVault: ChatGPTCredentialVault {
    var values: [String: Credentials] = [:]
    var removed: [String] = []
    var failRemove = false
    func read(_ id: String) throws -> Credentials? { values[id] }
    func save(_ credentials: Credentials, id: String) throws { values[id] = credentials }
    func remove(_ id: String) throws {
        if failRemove { throw QingyiError.message("fixture deletion failure") }
        removed.append(id); values.removeValue(forKey: id)
    }
}

extension QingyiTests {
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
        check("Saved same-email accounts merge case-insensitively and retain the active account and model") {
            let name = "qingyi-account-merge-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let accounts = [Registration(id: "active", subject: "a", email: " User@Example.com "), Registration(id: "duplicate", subject: "b", email: "user@example.com"), Registration(id: "other", subject: "c", email: "other@example.com")]
            defaults.set(try JSONEncoder().encode(accounts), forKey: "registrations")
            defaults.set("active", forKey: "activeRegistration")
            defaults.set("keep-model", forKey: "model.active")
            defaults.set("old-model", forKey: "model.duplicate")
            let vault = AccountTestVault()
            let chat = ChatGPT(defaults: defaults, session: FixtureAPIProtocol.session(), vault: vault)
            try expect(chat.registrations.map(\.id) == ["active", "other"] && chat.modelID == "keep-model")
            try expect(vault.removed.isEmpty, "Initialization must defer credential cleanup")
            chat.restore()
            try expect(vault.removed == ["duplicate"] && defaults.object(forKey: "model.duplicate") == nil)
            try expect(chat.activeID == "active" && chat.modelID == "keep-model")
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
