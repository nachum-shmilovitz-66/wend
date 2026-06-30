// AppDelegate (macOS): menu-bar item + wiring. No Dock icon (accessory activation policy).

import AppKit
import ServiceManagement

private let switchAfterFixKey = "switchInputSourceAfterFix"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = FixController()
    private let hotkeys = HotkeyManager()
    private let permissions = PermissionsManager()
    private var switchItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var axStatusItem: NSMenuItem!

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

        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Wend", action: #selector(showAbout), keyEquivalent: "")
        about.target = self

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Wend", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        refreshStatus()   // set the initial status row before the menu is first shown
        statusItem.menu = menu
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

    @objc private func fixNow() {
        // Let the menu fully dismiss and the previous app regain focus before we
        // synthesize ⌘C — otherwise the copy targets nothing and the fix no-ops.
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
