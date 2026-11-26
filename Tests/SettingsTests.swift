import AppKit
import Foundation
import SwiftUI

extension QingyiTests {
    @MainActor static func selectTrialSample(_ sample: SelectionTrialSample, in root: NSView) throws {
        @MainActor func trialPicker(in view: NSView) -> NSSegmentedControl? {
            if let picker = view as? NSSegmentedControl, picker.segmentCount == 2,
               picker.label(forSegment: 0) == SelectionTrialSample.english.rawValue { return picker }
            return view.subviews.lazy.compactMap { trialPicker(in: $0) }.first
        }
        root.layoutSubtreeIfNeeded()
        guard let picker = trialPicker(in: root) else { throw QingyiError.message("Missing trial language picker") }
        picker.selectedSegment = sample == .english ? 0 : 1
        try expect(picker.sendAction(picker.action, to: picker.target))
    }

    @MainActor static func settingsTests() {
        check("Keychain return survives a stale foreground PID when settings first gains focus") {
            var state = CredentialWindowReturnState()
            let opening = CredentialWindowReturnState.Foreground(appIsActive: true,
                frontmostPID: 200, ownerPID: 100, authorizationIsFrontmost: false)
            try expect(state.update(at: 0, foreground: opening, authorizationVisible: false,
                accessFinished: false, sourceAvailable: true) == .waiting)
            let prompt = CredentialWindowReturnState.Foreground(appIsActive: true,
                frontmostPID: 300, ownerPID: 100, authorizationIsFrontmost: true)
            try expect(state.update(at: 0.1, foreground: prompt, authorizationVisible: false,
                accessFinished: false, sourceAvailable: true) == .waiting && state.sawAuthorization)
            try expect(state.update(at: 1, foreground: .other, authorizationVisible: false,
                accessFinished: true, sourceAvailable: true) == .restore)
        }
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
            floating.showResult(preview: true)
            floating.state.text = "已有译文"; floating.state.pinned = true
            floating.offerAutomaticTranslation(for: "https://example.com", position: .lowerLeft, preserveResult: true)
            try expect(floating.resultPanel.isVisible && floating.state.pinned && floating.state.text == "已有译文")
            try expect(!floating.buttonPanel.isVisible && triggers == 0)
        }
        check("Settings preview opens a completed sample service card using the preferred font and placement") {
            let domain = "qingyi-result-preview-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let preferences = Preferences(defaults: defaults)
            let app = AppDelegate(preferences: preferences)
            let session = FixtureAPIProtocol.session()
            let api = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            let engine = TranslationEngine(chat: ChatGPT(defaults: defaults, session: session), configuration: api,
                                          client: CustomAPIClient(session: session))
            app.prepareBuiltinFixture(engine: engine, client: BuiltinTranslationClient(session: session),
                                      settings: BuiltinTranslationSettings(defaults: defaults))
            var requests = 0
            FixtureAPIProtocol.handle = { _ in requests += 1; throw URLError(.notConnectedToInternet) }
            defer { app.floating.hide(); session.invalidateAndCancel(); FixtureAPIProtocol.handle = nil }
            let state = app.floating.state
            state.pinned = true
            state.resultActions = [.polishing]
            state.services = [ServiceTranslationResult(id: .ai, loading: false, error: "previous error")]
            for (position, size) in [(TranslationWindowPosition.upperLeft, 12.0), (.upperRight, 14.3), (.belowPointer, 24.0)] {
                preferences.translationWindowPosition = position
                preferences.translationFontSize = size
                app.showPreview()
                let panel = app.floating.resultPanel
                try expect(panel.isVisible && state.complete && !state.loading && !state.error)
                try expect(state.operation == .translation && !state.pinned && state.resultActions.isEmpty)
                try expect(!state.modelSelectionEnabled && state.choice == nil && state.defaultChoice == nil)
                try expect(abs(state.fontSize - size) < 0.01)
                try expect(state.services.map(\.id) == [.youdao])
                let sample = state.services[0]
                try expect(!sample.loading && sample.error == nil && sample.result.text == TranslationWindowExample.translation)
                if position.isScreenCorner, let screen = panel.screen?.visibleFrame {
                    let x = position == .upperLeft ? screen.minX : screen.maxX - panel.frame.width
                    try expect(abs(panel.frame.minX - x) < 1 && abs(panel.frame.maxY - screen.maxY) < 1)
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            try expect(requests == 0)
        }
        check("The settings illustration renders the same native translation text and responds to placement and font changes") {
            let host = NSHostingView(rootView: SettingsWindowIllustration(position: .upperRight, fontSize: 15))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 290),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            @MainActor func resultText(in view: NSView) -> TranslationResultTextView? {
                if let text = view as? TranslationResultTextView { return text }
                return view.subviews.lazy.compactMap { resultText(in: $0) }.first
            }
            var origins: [TranslationWindowPosition: CGFloat] = [:]
            for (position, size) in [(TranslationWindowPosition.upperRight, 15.0), (.upperLeft, 12.0), (.belowPointer, 24.0)] {
                host.rootView = SettingsWindowIllustration(position: position, fontSize: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                guard let text = resultText(in: host), text.string == TranslationWindowExample.translation,
                      let font = text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
                    throw QingyiError.message("Missing native sample translation in the settings illustration")
                }
                try expect(abs(font.pointSize - size) < 0.01)
                origins[position] = text.convert(text.bounds, to: host).minX
            }
            try expect(origins[.upperLeft]! < origins[.belowPointer]! && origins[.belowPointer]! < origins[.upperRight]!)
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
        check("Selection guidance follows enabled actions, modifier and press or hold behavior") {
            let domain = "qingyi-selection-guidance-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AITextSettings(defaults: defaults)
            let action = AIAction(name: "总结", prompt: "总结输入。")
            try expect(settings.selectionActionHint.contains("新建或启用"))
            try settings.saveAction(action)
            for modifier in AIActionModifier.allCases {
                settings.actionModifier = modifier
                settings.actionTrigger = .press
                try expect(settings.selectionActionHint.contains("按一下 " + modifier.title) && settings.selectionActionHint.contains("再按一下关闭"))
                settings.actionTrigger = .hold
                try expect(settings.selectionActionHint.contains("按住 " + modifier.title) && settings.selectionActionHint.contains("松开即关闭"))
            }
            try settings.setEnabled(false, for: .custom(action))
            try expect(settings.selectionActionHint.contains("新建或启用"))
        }
        check("Exclusion menu names the frontmost application and the next action") {
            try expect(AppDelegate.exclusionMenuTitle(for: "Safari", excluded: false) == "在 Safari 中暂停划词与悬停翻译")
            try expect(AppDelegate.exclusionMenuTitle(for: "备忘录", excluded: true) == "在 备忘录 中恢复划词与悬停翻译")
        }
        check("The local selection trial uses the native glyph and responds to press, hold, mode and pause") {
            let domain = "qingyi-selection-trial-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let preferences = Preferences(defaults: defaults), settings = AITextSettings(defaults: defaults)
            let practiceAction = AIAction(name: "试用动作", prompt: "仅供本地示例")
            try settings.saveAction(practiceAction)
            try settings.moveOperation(practiceAction.id.uuidString, to: TextOperation.translation.key)
            settings.actionDisplayLimit = 1
            let host = NSHostingView(rootView: SelectionTrial(preferences: preferences, settings: settings, manageActions: {}))
            // A nonactivating panel can take key focus in the accessory test process
            // without activating it in place of the user's foreground application.
            let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 540, height: 265),
                                 styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            @MainActor func glyph(in view: NSView) -> HoverButton? {
                if let button = view as? HoverButton { return button }
                return view.subviews.lazy.compactMap { glyph(in: $0) }.first
            }
            @MainActor func settle() {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            }
            @MainActor func flags(_ value: NSEvent.ModifierFlags) {
                let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: value,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
                NSApp.sendEvent(event)
                settle()
            }
            settle()
            try expect(window.isKeyWindow)
            try expect(glyph(in: host)?.operation == .translation)
            try expect(glyph(in: host)?.accessibilityPerformPress() == true)
            try selectTrialSample(.chinese, in: host)
            settle()
            try expect(glyph(in: host)?.operation == .polishing)
            settings.polishingEnabled = false
            settle()
            try expect(glyph(in: host) == nil)
            settings.polishingEnabled = true
            settle()
            try expect(glyph(in: host)?.operation == .polishing)
            try selectTrialSample(.english, in: host)
            settle()
            try expect(glyph(in: host)?.operation == .translation)
            flags(.option)
            try expect(glyph(in: host) == nil, "Press should replace the glyph with custom actions")
            flags([])
            try expect(glyph(in: host) == nil)
            flags(.option); flags([])
            try expect(glyph(in: host) != nil)
            settings.actionTrigger = .hold
            settle()
            flags(.option)
            try expect(glyph(in: host) == nil)
            flags([])
            try expect(glyph(in: host) != nil)
            preferences.selectionMode = .toolbar
            settle()
            try expect(glyph(in: host) == nil)
            preferences.selectionMode = .compact
            preferences.selectionEnabled = false
            settle()
            try expect(glyph(in: host) == nil)
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
        check("A re-rendered API editor guards genuine edits and lets an untouched provider return directly") {
            let domain = "qingyi-api-editor-dirty-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let store = APIConfigurationStore(defaults: defaults, vault: MemoryAPIKeyVault())
            var provider = fixtureProvider()
            provider.selectedModelID = "model-a"
            try store.save(provider, replacementKey: "fixture-only")
            let navigation = SettingsNavigation(section: .services, detail: .api(provider))
            @MainActor func editor() -> APIProviderEditor { APIProviderEditor(api: store, provider: provider, navigation: navigation) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: editor())
            window.contentView = host
            @MainActor func render() {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            render()
            host.rootView = editor()
            render()
            try expect(!navigation.editorDirty, "Rebuilding rows must not mark a saved model as edited")
            @MainActor func nameField(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable && field.stringValue == provider.name { return field }
                return view.subviews.lazy.compactMap { nameField(in: $0) }.first
            }
            guard let field = nameField(in: host), window.makeFirstResponder(field), let input = field.currentEditor() else {
                throw QingyiError.message("Missing editable provider name")
            }
            input.selectAll(nil)
            input.insertText("Edited fixture")
            render()
            try expect(navigation.editorDirty, "Editing the actual name field must guard leaving")
            var returns = 0
            navigation.requestLeave { returns += 1 }
            try expect(navigation.confirmDiscard && returns == 0)
            navigation.continueEditing()
            input.selectAll(nil)
            input.insertText(provider.name)
            render()
            try expect(!navigation.editorDirty)
            navigation.requestLeave { returns += 1 }
            try expect(!navigation.confirmDiscard && returns == 1)
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
