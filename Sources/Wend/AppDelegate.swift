// AppDelegate (macOS): menu-bar item + wiring. No Dock icon (accessory activation policy).

import AppKit

private let switchAfterFixKey = "switchInputSourceAfterFix"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = FixController()
    private let hotkeys = HotkeyManager()
    private let permissions = PermissionsManager()
    private var switchItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedSwitch = UserDefaults.standard.object(forKey: switchAfterFixKey) as? Bool ?? true
        controller.switchInputSourceAfterFix = savedSwitch

        buildStatusItem()

        hotkeys.onTrigger = { [weak self] in self?.controller.performFix() }
        hotkeys.start()

        if !permissions.isTrusted() {
            permissions.requestTrust()
        }
    }

    // MARK: - Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Wend")
        }

        let menu = NSMenu()
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

        let axItem = menu.addItem(
            withTitle: "Open Accessibility Settings…",
            action: #selector(openAccessibility),
            keyEquivalent: ""
        )
        axItem.target = self

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Wend", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        statusItem.menu = menu
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

    @objc private func openAccessibility() {
        permissions.openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
