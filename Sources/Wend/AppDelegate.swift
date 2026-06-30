// AppDelegate (macOS): menu-bar item + wiring. No Dock icon (accessory activation policy).

import AppKit
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
    private var axStatusItem: NSMenuItem!

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
        wc.onFeedback = { [weak self] in self?.openFeedback() }
        return wc
    }()

    private lazy var feedbackWindow: FeedbackWindowController = {
        let wc = FeedbackWindowController()
        wc.recipient = "nachumsh2@gmail.com"
        wc.diagnostics = { [weak self] in self?.feedbackContext() ?? "" }
        wc.logTail = { [weak self] in self?.wendLogTail() }
        return wc
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedSwitch = UserDefaults.standard.object(forKey: switchAfterFixKey) as? Bool ?? true
        controller.switchInputSourceAfterFix = savedSwitch

        enableLaunchAtLoginOnFirstRun()   // before the menu, so its checkmark is correct

        buildStatusItem()

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

        let axItem = menu.addItem(
            withTitle: "Open Accessibility Settings…",
            action: #selector(openAccessibility),
            keyEquivalent: ""
        )
        axItem.target = self

        let feedbackItem = menu.addItem(withTitle: "Send Feedback…", action: #selector(openFeedback), keyEquivalent: "")
        feedbackItem.target = self

        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Wend", action: #selector(showAbout), keyEquivalent: "")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.controller.performFix()
        }
    }

    @objc private func toggleSwitchAfterFix() {
        controller.switchInputSourceAfterFix.toggle()
        switchItem.state = controller.switchInputSourceAfterFix ? .on : .off
        UserDefaults.standard.set(controller.switchInputSourceAfterFix, forKey: switchAfterFixKey)
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

    // MARK: - Feedback

    @objc private func openFeedback() {
        feedbackWindow.show()
    }

    /// Auto-collected diagnostics appended to a feedback email so reports are actionable.
    private func feedbackContext() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let layouts = InputSourceProvider().installedLayouts()
            .map { $0.localizedName }.joined(separator: ", ")
        let ax = permissions.isTrusted() ? "granted" : "not granted"
        return "Wend \(version)\nmacOS: \(os)\nLayouts: \(layouts)\nAccessibility: \(ax)"
    }

    private func wendLogURL() -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Wend.log")
    }

    /// Recent tail of the log, inlined into feedback (a compose URL can't attach a file).
    private func wendLogTail(maxChars: Int = 4000) -> String? {
        guard let url = wendLogURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.count <= maxChars ? text : "…(truncated)\n" + String(text.suffix(maxChars))
    }

    @objc private func showAbout() {
        // Accessory (LSUIElement) app: bring it forward so the panel isn't hidden.
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let credits = NSAttributedString(
            string: "Created by Shmilovitz",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Wend",
            .applicationVersion: version,
            .credits: credits,
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
