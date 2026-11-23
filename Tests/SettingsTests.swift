import AppKit
import Foundation

extension QingyiTests {
    @MainActor static func settingsTests() {
        check("Keychain completion restores settings only after an observed authorization panel closes") {
            var state = CredentialWindowReturnState()
            try expect(state.update(at: 0, foreground: .owner, authorizationVisible: false, accessFinished: false, sourceAvailable: true) == .waiting)
            try expect(state.update(at: 0.1, foreground: .unknown, authorizationVisible: false, accessFinished: false, sourceAvailable: true) == .waiting)
            try expect(state.update(at: 1, foreground: .authorization, authorizationVisible: true, accessFinished: false, sourceAvailable: true) == .waiting)
            try expect(state.update(at: 2, foreground: .other, authorizationVisible: true, accessFinished: true, sourceAvailable: true) == .waiting)
            try expect(state.update(at: 2.2, foreground: .authorization, authorizationVisible: false, accessFinished: true, sourceAvailable: true) == .restore)
        }
        check("Authorized silent reads and deliberate switches before or during Keychain never raise settings") {
            var state = CredentialWindowReturnState()
            try expect(state.update(at: 0, foreground: .owner, authorizationVisible: false, accessFinished: true, sourceAvailable: true) == .cancel)
            state = CredentialWindowReturnState()
            try expect(state.update(at: 0.1, foreground: .other, authorizationVisible: false, accessFinished: false, sourceAvailable: true) == .cancel)
            state = CredentialWindowReturnState()
            _ = state.update(at: 0.2, foreground: .authorization, authorizationVisible: true, accessFinished: false, sourceAvailable: true)
            _ = state.update(at: 1, foreground: .other, authorizationVisible: true, accessFinished: false, sourceAvailable: true)
            try expect(state.update(at: 1.4, foreground: .other, authorizationVisible: true, accessFinished: false, sourceAvailable: true) == .cancel)
        }
        check("Keychain denial also returns focus and closed or minimized settings cancel restoration") {
            var state = CredentialWindowReturnState()
            _ = state.update(at: 0, foreground: .authorization, authorizationVisible: true, accessFinished: false, sourceAvailable: true)
            try expect(state.update(at: 1, foreground: .other, authorizationVisible: false, accessFinished: true, sourceAvailable: true) == .restore)
            try expect(state.update(at: 1, foreground: .authorization, authorizationVisible: true, accessFinished: true, sourceAvailable: false) == .cancel)
        }
        check("Long Keychain authorization keeps the focus policy and respects a deliberate app switch") {
            var state = CredentialWindowReturnState()
            _ = state.update(at: 0, foreground: .authorization, authorizationVisible: true, accessFinished: false, sourceAvailable: true)
            try expect(state.update(at: 120, foreground: .authorization, authorizationVisible: true, accessFinished: false, sourceAvailable: true) == .waiting)
            var switched = state
            try expect(state.update(at: 121, foreground: .authorization, authorizationVisible: false, accessFinished: true, sourceAvailable: true) == .restore)
            _ = switched.update(at: 120.1, foreground: .other, authorizationVisible: true, accessFinished: false, sourceAvailable: true)
            try expect(switched.update(at: 120.5, foreground: .other, authorizationVisible: true, accessFinished: false, sourceAvailable: true) == .cancel)
        }
        check("Automatic address selections create neither entry nor result panel and preserve a pinned translation") {
            _ = NSApplication.shared
            let floating = FloatingController()
            defer { floating.hide() }
            var triggers = 0
            floating.onTrigger = { triggers += 1 }
            for address in ["https://example.com", "example.com", "mailto:user@example.com", "myapp://open?id=1"] {
                floating.offerAutomaticTranslation(for: address, position: .lowerLeft)
                try expect(!floating.buttonPanel.isVisible && !floating.resultPanel.isVisible && triggers == 0)
            }
            floating.showResult(source: "Original text", preview: true)
            floating.state.text = "已有译文"; floating.state.pinned = true
            floating.offerAutomaticTranslation(for: "https://example.com", position: .lowerLeft, preserveResult: true)
            try expect(floating.resultPanel.isVisible && floating.state.pinned && floating.state.text == "已有译文")
            try expect(!floating.buttonPanel.isVisible && triggers == 0)
        }
        check("System Settings close restores once after window disappearance settles") {
            var state = SystemSettingsReturnState()
            state.begin(ownerPID: 100, at: 0)
            try expect(state.update(at: 0.1, systemSettingsPID: 200, foregroundPID: 200, hasSystemSettingsWindow: true, sourceAvailable: true) == .waiting)
            try expect(state.update(at: 1, systemSettingsPID: 200, foregroundPID: 300, hasSystemSettingsWindow: false, sourceAvailable: true) == .waiting)
            try expect(state.update(at: 1.5, systemSettingsPID: 200, foregroundPID: 300, hasSystemSettingsWindow: false, sourceAvailable: true) == .restore)
            try expect(state.update(at: 2, systemSettingsPID: nil, foregroundPID: 300, hasSystemSettingsWindow: nil, sourceAvailable: true) == .waiting)
            try expect(!state.isWaiting)
        }
        check("System Settings process exit raises an existing window even if our app is already active") {
            var state = SystemSettingsReturnState()
            state.begin(ownerPID: 100, at: 0)
            _ = state.update(at: 0.1, systemSettingsPID: 200, foregroundPID: 200, hasSystemSettingsWindow: true, sourceAvailable: true)
            try expect(state.update(at: 1, systemSettingsPID: nil, foregroundPID: 100, hasSystemSettingsWindow: nil, sourceAvailable: true) == .restore)
        }
        check("A deliberate app switch cancels return while the system window remains open") {
            var state = SystemSettingsReturnState()
            state.begin(ownerPID: 100, at: 0)
            _ = state.update(at: 0.1, systemSettingsPID: 200, foregroundPID: 200, hasSystemSettingsWindow: true, sourceAvailable: true)
            _ = state.update(at: 1, systemSettingsPID: 200, foregroundPID: 300, hasSystemSettingsWindow: true, sourceAvailable: true)
            try expect(state.update(at: 1.5, systemSettingsPID: 200, foregroundPID: 300, hasSystemSettingsWindow: true, sourceAvailable: true) == .cancelled)
            try expect(state.update(at: 2, systemSettingsPID: nil, foregroundPID: 300, hasSystemSettingsWindow: nil, sourceAvailable: true) == .waiting)
        }
        check("Closing animation does not look like a deliberate app switch") {
            var state = SystemSettingsReturnState()
            state.begin(ownerPID: 100, at: 0)
            _ = state.update(at: 0.1, systemSettingsPID: 200, foregroundPID: 200, hasSystemSettingsWindow: true, sourceAvailable: true)
            _ = state.update(at: 1, systemSettingsPID: 200, foregroundPID: 300, hasSystemSettingsWindow: true, sourceAvailable: true)
            _ = state.update(at: 1.2, systemSettingsPID: 200, foregroundPID: 300, hasSystemSettingsWindow: false, sourceAvailable: true)
            try expect(state.update(at: 1.6, systemSettingsPID: 200, foregroundPID: 300, hasSystemSettingsWindow: false, sourceAvailable: true) == .restore)
        }
        check("Source window close or minimization and desktop switch cancel the pending return") {
            var state = SystemSettingsReturnState()
            state.begin(ownerPID: 100, at: 0)
            _ = state.update(at: 0.1, systemSettingsPID: 200, foregroundPID: 200, hasSystemSettingsWindow: true, sourceAvailable: true)
            try expect(state.update(at: 1, systemSettingsPID: nil, foregroundPID: 300, hasSystemSettingsWindow: nil, sourceAvailable: false) == .cancelled)
            state.begin(ownerPID: 100, at: 2)
            state.cancel()
            try expect(state.update(at: 3, systemSettingsPID: nil, foregroundPID: 300, hasSystemSettingsWindow: nil, sourceAvailable: true) == .waiting)
        }
        check("Unavailable window data and a failed System Settings launch never steal focus") {
            var state = SystemSettingsReturnState()
            state.begin(ownerPID: 100, at: 0)
            try expect(state.update(at: 11, systemSettingsPID: nil, foregroundPID: 300, hasSystemSettingsWindow: nil, sourceAvailable: true) == .cancelled)
            state.begin(ownerPID: 100, at: 12)
            _ = state.update(at: 12.1, systemSettingsPID: 200, foregroundPID: 200, hasSystemSettingsWindow: true, sourceAvailable: true)
            try expect(state.update(at: 13, systemSettingsPID: 200, foregroundPID: 300, hasSystemSettingsWindow: nil, sourceAvailable: true) == .cancelled)
        }
        check("Positive selection toggle shares pause state and leaves hover preferences independent") {
            let domain = "qingyi-toggle-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let preferences = Preferences(defaults: defaults)
            preferences.hoverEnabled = true; preferences.hoverTrigger = .option
            preferences.buttonPosition = .upperRight
            preferences.selectionEnabled = false
            try expect(preferences.paused && preferences.hoverEnabled && preferences.hoverTrigger == .option)
            preferences.paused = false // Menu pause toggle must update the same setting.
            try expect(preferences.selectionEnabled)
            preferences.hoverEnabled = false
            try expect(preferences.selectionEnabled && preferences.buttonPosition == .upperRight)
            preferences.paused = true
            try expect(!preferences.selectionEnabled)
            preferences.selectionEnabled = true
            try expect(!preferences.paused && !preferences.hoverEnabled)
            let reopened = Preferences(defaults: defaults)
            try expect(!reopened.hoverEnabled && reopened.hoverTrigger == .option && reopened.buttonPosition == .upperRight)
        }
        check("Settings navigation starts on selection and routes account and non-active API without changing configuration") {
            let navigation = SettingsNavigation()
            try expect(navigation.section == .selection && navigation.detail == nil)
            let provider = APIProvider()
            navigation.open(.services, detail: .api(provider))
            try expect(navigation.section == .services && navigation.detail == .api(provider))
            navigation.open(.services, detail: .account)
            try expect(navigation.detail == .account)
            navigation.open(.window)
            try expect(navigation.section == .window && navigation.detail == nil)
        }
        check("Dirty API edits survive cancelled navigation and discard follows only the requested destination") {
            let provider = APIProvider()
            let navigation = SettingsNavigation(section: .services, detail: .api(provider))
            navigation.editorDirty = true
            navigation.open(.general)
            try expect(navigation.confirmDiscard && navigation.section == .services && navigation.detail == .api(provider))
            navigation.continueEditing()
            try expect(!navigation.confirmDiscard && navigation.editorDirty)
            navigation.open(.window)
            navigation.discardAndContinue()
            try expect(navigation.section == .window && navigation.detail == nil && !navigation.editorDirty)
            navigation.discardAndContinue()
            try expect(navigation.section == .window)
        }
        check("Cancelling the close confirmation never closes the window and discarding resumes close once") {
            let navigation = SettingsNavigation(section: .services, detail: .api(APIProvider()))
            navigation.editorDirty = true
            var closes = 0
            navigation.requestLeave { closes += 1 }
            navigation.continueEditing()
            navigation.discardAndContinue()
            try expect(closes == 0 && navigation.editorDirty)
            navigation.requestLeave { closes += 1 }
            navigation.discardAndContinue()
            navigation.discardAndContinue()
            try expect(closes == 1 && !navigation.editorDirty)
        }
        check("Explicit API editor finish clears the guard and returns to services") {
            let navigation = SettingsNavigation(section: .services, detail: .api(APIProvider()))
            navigation.editorDirty = true
            navigation.editorFinished()
            try expect(navigation.section == .services && navigation.detail == nil && !navigation.editorDirty)
            navigation.open(.selection)
            try expect(navigation.section == .selection && !navigation.confirmDiscard)
        }
        check("Permission action distinguishes acquiring system access from managing authorized access") {
            let denied = SettingsPermissionPresentation(trusted: false)
            let granted = SettingsPermissionPresentation(trusted: true)
            try expect(denied.action == "获取系统权限" && denied.status == "辅助功能 · 未授权")
            try expect(granted.action == "管理系统权限" && granted.status == "辅助功能 · 已授权")
            try expect(denied.help.contains("系统设置") && denied.help.contains("读取选中文字"))
        }
        check("Settings exclusions and instant preferences stay in their owning defaults suite") {
            let firstName = "qingyi-settings-" + UUID().uuidString
            let secondName = "qingyi-settings-" + UUID().uuidString
            let first = UserDefaults(suiteName: firstName)!, second = UserDefaults(suiteName: secondName)!
            defer { first.removePersistentDomain(forName: firstName); second.removePersistentDomain(forName: secondName) }
            first.set(["com.example.first"], forKey: "excludedApps")
            second.set(["com.example.second"], forKey: "excludedApps")
            let preferences = Preferences(defaults: first)
            try expect(preferences.excluded == ["com.example.first"])
            preferences.buttonPosition = .upperRight
            preferences.translationWindowPosition = .belowPointer
            let reopened = Preferences(defaults: first)
            try expect(reopened.buttonPosition == .upperRight && reopened.translationWindowPosition == .belowPointer)
            preferences.clearExclusions()
            try expect(first.stringArray(forKey: "excludedApps") == nil)
            try expect(second.stringArray(forKey: "excludedApps") == ["com.example.second"])
        }
    }
}
