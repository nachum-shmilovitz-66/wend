// PermissionsManager (macOS): Accessibility trust, required for synthesizing ⌘C/⌘V and
// for global keyboard monitoring. Without it the app can read nothing and fix nothing.

import AppKit
import ApplicationServices

final class PermissionsManager {

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user (system dialog) to grant Accessibility access if not already trusted.
    @discardableResult
    func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
