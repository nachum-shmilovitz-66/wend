// SettingsWindowController (macOS): Wend's control-panel window. Shown on reopen (relaunching
// Wend — e.g. double-clicking it in /Applications while it's already running) and from the
// menu's "Wend Settings…" item. Wend is a menu-bar accessory app (no Dock icon), so a relaunch
// is otherwise a silent no-op, and the menu-bar icon can be impossible to see (menu-bar
// overflow, the notch, a manager like Bartender). This window is a reliable home that mirrors
// every menu action plus the Accessibility status.
//
// The window is a dumb view: AppDelegate wires the closures below so the fix / toggle /
// permission logic stays there as the single source of truth.

import AppKit

final class SettingsWindowController: NSWindowController {

    // Status providers.
    var isTrusted: () -> Bool = { false }
    var isSwitchAfterFix: () -> Bool = { false }
    var isLoginEnabled: () -> Bool = { false }
    // Actions.
    var onFix: () -> Void = {}
    var onToggleSwitchAfterFix: () -> Void = {}
    var onToggleLogin: () -> Void = {}
    var onOpenAccessibility: () -> Void = {}
    var onAbout: () -> Void = {}
    var onQuit: () -> Void = {}

    private var axIcon: NSImageView!
    private var axStatus: NSTextField!
    private var axButton: NSButton!
    private var switchCheckbox: NSButton!
    private var loginCheckbox: NSButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wend"
        window.isReleasedWhenClosed = false   // reused across reopens
        self.init(window: window)
        buildUI()
    }

    /// Bring the window forward (accessory apps must activate explicitly) and refresh state.
    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        let trusted = isTrusted()
        let symbol = trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        let color: NSColor = trusted ? .systemGreen : .systemOrange
        axIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        axStatus.stringValue = trusted ? "Accessibility: Granted" : "Accessibility: Not granted"
        axStatus.textColor = trusted ? .systemGreen : .systemOrange
        axButton.isHidden = trusted   // only offer the shortcut when action is needed
        switchCheckbox.state = isSwitchAfterFix() ? .on : .off
        loginCheckbox.state = isLoginEnabled() ? .on : .off
    }

    // MARK: - UI

    private func buildUI() {
        guard let window = window, let content = window.contentView else { return }

        let title = label("Wend lives in your menu bar", font: .systemFont(ofSize: 15, weight: .semibold))
        let hint = label(
            "Select text typed in the wrong layout in any app and double-tap Shift to fix it. "
                + "These controls also live in the keyboard icon near the top-right of the screen.",
            font: .systemFont(ofSize: 11)
        )
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 0

        // Accessibility status row.
        axIcon = NSImageView()
        axIcon.setContentHuggingPriority(.required, for: .horizontal)
        axStatus = label("Accessibility: …", font: .systemFont(ofSize: 13))
        axButton = smallButton("Open Settings…", action: #selector(openAccessibility))
        let axRow = row([axIcon, axStatus, spacer(), axButton])

        // Primary action.
        let fixButton = NSButton(title: "Fix Selection  (⇧⇧)", target: self, action: #selector(fix))
        fixButton.bezelStyle = .rounded
        fixButton.keyEquivalent = "\r"   // default button

        switchCheckbox = NSButton(checkboxWithTitle: "Switch Layout After Fix",
                                  target: self, action: #selector(toggleSwitchAfterFix))
        loginCheckbox = NSButton(checkboxWithTitle: "Launch at Login",
                                 target: self, action: #selector(toggleLogin))

        // Footer.
        let about = smallButton("About Wend", action: #selector(about))
        let quit = smallButton("Quit Wend", action: #selector(quit))
        let footer = row([spacer(), about, quit])

        let stack = NSStackView(views: [
            title, hint, separator(), axRow, separator(),
            fixButton, switchCheckbox, loginCheckbox, separator(), footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        // Fixed content width — otherwise the single-line hint resists compression and stretches
        // the window very wide. The hint wraps to this width instead.
        let contentWidth: CGFloat = 300
        hint.preferredMaxLayoutWidth = contentWidth
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        // Full-width rows: hint wraps, separators span, the trailing buttons right-align.
        for v in [hint, axRow, fixButton, footer] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for s in stack.arrangedSubviews where (s as? NSBox)?.boxType == .separator {
            s.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Snug-fit the window to the content (width fixed above, height from the laid-out stack).
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: contentWidth + 40, height: stack.fittingSize.height + 40))
        window.center()
    }

    // MARK: - View helpers

    private func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        return field
    }

    private func smallButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 8
        return r
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - Actions

    @objc private func fix() {
        // Close so focus returns to the app the user was actually in, then run the fix there.
        window?.orderOut(nil)
        onFix()
    }
    @objc private func toggleSwitchAfterFix() { onToggleSwitchAfterFix(); refresh() }
    @objc private func toggleLogin() { onToggleLogin(); refresh() }
    @objc private func openAccessibility() { onOpenAccessibility(); refresh() }
    @objc private func about() { onAbout() }
    @objc private func quit() { onQuit() }
}
