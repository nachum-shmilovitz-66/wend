// AppDelegate (macOS): menu-bar item + wiring. No Dock icon (accessory activation policy).

import AppKit
import Carbon.HIToolbox   // IsSecureEventInputEnabled, for the report
import ServiceManagement
import KeyLayoutCore

private let switchAfterFixKey = "switchInputSourceAfterFix"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = FixController()
    private let hotkeys = HotkeyManager()
    private let permissions = PermissionsManager()
    private var switchItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var loggingItem: NSMenuItem!
    private var axStatusItem: NSMenuItem!
    private let launchedAt = Date()

    /// Shown on reopen (relaunch while already running) and from the menu. Closures keep the
    /// permission / login-item logic here in AppDelegate as the single source of truth.
    private lazy var settingsWindow: SettingsWindowController = {
        let wc = SettingsWindowController()
        wc.isTrusted = { [weak self] in self?.permissions.isTrusted() ?? false }
        wc.isSwitchAfterFix = { [weak self] in self?.controller.switchInputSourceAfterFix ?? false }
        wc.isLoginEnabled = { [weak self] in self?.launchAtLoginEnabled ?? false }
        wc.onFix = { [weak self] in self?.performFixSoon() }
        wc.onToggleSwitchAfterFix = { [weak self] in self?.toggleSwitchAfterFix() }
        wc.onToggleLogin = { [weak self] in self?.toggleLaunchAtLogin() }
        wc.onOpenAccessibility = { [weak self] in self?.permissions.openAccessibilitySettings() }
        wc.onAbout = { [weak self] in self?.showAbout() }
        wc.onQuit = { [weak self] in self?.quit() }
        wc.onFeedback = { [weak self] in self?.openReport() }
        return wc
    }()

    private lazy var reportWindow: ReportWindowController = {
        let wc = ReportWindowController()
        wc.recipient = "nachumsh2@gmail.com"
        wc.diagnostics = { [weak self] in self?.feedbackContext() ?? "" }
        wc.saveReport = { [weak self] kind, details in
            guard let self else { throw CocoaError(.featureUnsupported) }
            return try self.saveProblemReport(kind: kind, details: details)
        }
        return wc
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedSwitch = UserDefaults.standard.object(forKey: switchAfterFixKey) as? Bool ?? true
        controller.switchInputSourceAfterFix = savedSwitch

        enableLaunchAtLoginOnFirstRun()   // before the menu, so its checkmark is correct

        buildStatusItem()
        installEditMenu()

        Log.write("launch axTrusted=\(permissions.isTrusted())")
        hotkeys.onTrigger = { [weak self] in
            Log.write("double-shift trigger")
            self?.controller.performFix()
        }
        hotkeys.start()

        if !permissions.isTrusted() {
            permissions.requestTrust()   // pops the system Accessibility prompt on first launch
        }
    }

    /// Wend is an accessory app, so relaunching it (e.g. double-clicking it in /Applications
    /// while it's already running) is otherwise a silent no-op. Re-assert the menu-bar item and
    /// show the window, so a relaunch always gives feedback — and a home if the icon can't be seen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureStatusItem()
        settingsWindow.show()
        return true
    }

    // MARK: - Menu

    /// An accessory app shows no menu bar, and without an Edit menu ⌘C / ⌘V / ⌘A / ⌘Z never
    /// reach a text field: the report form's description box couldn't be pasted into. This menu
    /// is never displayed; it exists for its key equivalents, which AppKit still routes while
    /// one of Wend's windows is key.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())   // the application menu's slot, left empty
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Wend")
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // we set isEnabled on the status row ourselves

        // Live status row: Accessibility trust. Informational when granted; a one-click
        // shortcut to System Settings when it's missing. Refreshed in menuWillOpen.
        axStatusItem = NSMenuItem(title: "Accessibility: …", action: #selector(openAccessibility), keyEquivalent: "")
        axStatusItem.target = self
        menu.addItem(axStatusItem)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Fix Selection  (⇧⇧)", action: #selector(fixNow), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())

        switchItem = NSMenuItem(
            title: "Switch Layout After Fix",
            action: #selector(toggleSwitchAfterFix),
            keyEquivalent: ""
        )
        switchItem.target = self
        switchItem.state = controller.switchInputSourceAfterFix ? .on : .off
        menu.addItem(switchItem)

        loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        loggingItem = NSMenuItem(
            title: "Enable Diagnostic Logging",
            action: #selector(toggleLogging),
            keyEquivalent: ""
        )
        loggingItem.target = self
        loggingItem.state = Log.isEnabled ? .on : .off
        menu.addItem(loggingItem)

        let axItem = menu.addItem(
            withTitle: "Open Accessibility Settings…",
            action: #selector(openAccessibility),
            keyEquivalent: ""
        )
        axItem.target = self

        let reportItem = menu.addItem(withTitle: "Report a Problem…", action: #selector(openReport), keyEquivalent: "")
        reportItem.target = self

        menu.addItem(.separator())

        // Version rides on the About row rather than a row of its own: it identifies the
        // running build at a glance for a bug report, without spending a menu line on it.
        // Marketing version only — the build number is noise here, and feedback reports
        // still carry it via feedbackContext().
        let about = menu.addItem(
            withTitle: "About Wend \(Self.shortVersion)",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Wend", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        refreshStatus()   // set the initial status row before the menu is first shown
        statusItem.menu = menu
    }

    /// Rebuild the menu-bar item only if it's actually gone. (The common "can't see it" case is
    /// the system hiding it — menu-bar overflow / the notch — which recreating can't fix; that's
    /// what the window is for. This just covers a genuinely lost item, defensively.)
    private func ensureStatusItem() {
        if statusItem == nil || statusItem.button == nil {
            buildStatusItem()
        }
    }

    // MARK: - Status

    /// Refresh the live status rows (Accessibility trust + Launch at Login) each time the
    /// menu opens, so they reflect changes made in System Settings while Wend is running —
    /// e.g. the Accessibility warning clears automatically once the user grants access.
    private func refreshStatus() {
        let trusted = permissions.isTrusted()

        axStatusItem.title = trusted
            ? "Accessibility: Granted"
            : "Accessibility: Not granted — Open Settings…"
        let symbol = trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        let color: NSColor = trusted ? .systemGreen : .systemOrange
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        axStatusItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        // Greyed-out (info only) when granted; clickable shortcut to Settings when not.
        axStatusItem.isEnabled = !trusted

        loginItem.state = launchAtLoginEnabled ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatus()
    }

    @objc private func fixNow() { performFixSoon() }

    /// Let the menu/window fully dismiss and the previous app regain focus before we
    /// synthesize ⌘C — otherwise the copy targets nothing and the fix no-ops.
    private func performFixSoon() {
        Log.write("menu fix")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.controller.performFix()
        }
    }

    @objc private func toggleSwitchAfterFix() {
        controller.switchInputSourceAfterFix.toggle()
        switchItem.state = controller.switchInputSourceAfterFix ? .on : .off
        UserDefaults.standard.set(controller.switchInputSourceAfterFix, forKey: switchAfterFixKey)
    }

    @objc private func toggleLogging() {
        Log.isEnabled.toggle()
        loggingItem.state = Log.isEnabled ? .on : .off
    }

    // MARK: - Launch at Login

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// First launch only: enable Launch at Login so Wend returns after a restart.
    /// The user can turn it off from the menu afterwards — we never re-enable.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didInitialLoginItemSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            Log.write("enabled Launch at Login on first run")
        } catch {
            // register() only works from a proper, signed bundle (not `swift run`).
            Log.write("first-run login-item register failed: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Registration only works from a proper, signed bundle (not `swift run`).
            Log.write("launch-at-login toggle failed: \(error.localizedDescription)")
            NSSound.beep()
        }
        loginItem.state = launchAtLoginEnabled ? .on : .off
    }

    @objc private func openAccessibility() {
        permissions.openAccessibilitySettings()
    }

    // MARK: - Problem reports

    @objc private func openReport() {
        reportWindow.show()
    }

    private func saveProblemReport(kind: ReportKind, details: String) throws -> URL {
        Log.write("report requested: \(kind.tag)")   // lands in the trail it's about to save
        let report = ProblemReport(kind: kind, details: details, facts: reportFacts())
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let url = try report.save(in: downloads)
        Log.write("report saved")
        return url
    }

    /// Everything a report reader needs to know about this Wend and this Mac, as it stands
    /// when the report is saved. Settings, ids and counts — nothing the user typed.
    private func reportFacts() -> String {
        let info = ProcessInfo.processInfo
        let uptime = Int(Date().timeIntervalSince(launchedAt))
        let layouts = InputSourceProvider().installedLayouts()
        let current = InputSourceProvider().currentLayoutID()
        let layoutLines = layouts.map { l in
            "\(l.id == current ? "*" : " ") \(l.id)  \"\(l.localizedName)\"  lang=\(l.languageCode ?? "none")"
        }
        let spell = NSSpellChecker.shared.availableLanguages.sorted().joined(separator: ", ")
        let onOff: (Bool) -> String = { $0 ? "on" : "off" }

        return """
            -- Wend --
            Version:            \(Self.versionDisplay)
            Bundle:             \((Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath)
            Running for:        \(uptime / 3600)h \(uptime / 60 % 60)m \(uptime % 60)s (pid \(info.processIdentifier))
            Accessibility:      \(permissions.isTrusted() ? "granted" : "NOT granted")
            Secure input now:   \(onOff(IsSecureEventInputEnabled()))
            Switch after fix:   \(onOff(controller.switchInputSourceAfterFix))
            Launch at Login:    \(onOff(launchAtLoginEnabled))
            Disk log (opt-in):  \(onOff(Log.isEnabled))

            -- Mac --
            macOS:              \(info.operatingSystemVersionString)
            Model:              \(Self.hardwareModel) (\(Self.architecture))
            Locale:             \(Locale.current.identifier), time zone \(TimeZone.current.identifier)

            -- Trigger windows --
            Double-tap:         \(Int(hotkeys.doubleTapInterval * 1000)) ms, release to release
            Max tap hold:       \(Int(hotkeys.maxHold * 1000)) ms
            Force window:       \(Int(controller.forceWindow * 1000)) ms after a declined fix

            -- Keyboard layouts (* = current) --
            \(layoutLines.joined(separator: "\n"))

            -- Spell-check languages --
            \(spell.isEmpty ? "(none)" : spell)
            """
    }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    // MARK: - Version

    /// Marketing version from the bundle (`SHORT_VERSION` in scripts/package.sh).
    /// `?` when running without a bundle, e.g. straight from `swift run`.
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Marketing version plus build number, e.g. `1.2.2 (5)` — the build number distinguishes
    /// rebuilds of the same marketing version, which matters when triaging a report.
    static var versionDisplay: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        guard let build, !build.isEmpty else { return shortVersion }
        return "\(shortVersion) (\(build))"
    }

    /// Auto-collected diagnostics appended to a feedback email so reports are actionable.
    private func feedbackContext() -> String {
        let version = Self.versionDisplay
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let layouts = InputSourceProvider().installedLayouts()
            .map { $0.localizedName }.joined(separator: ", ")
        let ax = permissions.isTrusted() ? "granted" : "not granted"
        return "Wend \(version)\nmacOS: \(os)\nLayouts: \(layouts)\nAccessibility: \(ax)"
    }

    @objc private func showAbout() {
        // Accessory (LSUIElement) app: bring it forward so the panel isn't hidden.
        NSApp.activate(ignoringOtherApps: true)
        let version = Self.shortVersion
        let credits = NSAttributedString(
            string: "Created by Shmilovitz",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Wend",
            .applicationVersion: version,
            // AppKit appends CFBundleVersion in parentheses ("Version 1.2.3 (7)") unless
            // this key is supplied. Blank it to show the marketing version alone; the build
            // number is still carried in feedback reports via feedbackContext().
            .version: "",
            .credits: credits,
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
