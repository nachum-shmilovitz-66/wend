// FeedbackWindowController (macOS): a small "Send Feedback" form. The user picks a type
// (Bug / Feature / Other), writes a message, optionally leaves a reply email, and sends.
//
// Delivery (zero backend): opens Gmail's web compose URL, prefilled with recipient, subject, and
// a body carrying auto-collected diagnostics (app version, macOS, installed layouts) so reports
// are actionable. (macOS always registers Mail.app as the mailto: handler even when it's never
// been configured, so a mailto: would just launch an empty, unset-up Mail — web compose is
// reliable for a Gmail user.) A compose URL can't attach a file, so when "include recent log" is
// on, the recent tail of ~/Library/Logs/Wend.log is inlined into the body instead.
//
// Injected by AppDelegate so the recipient, diagnostics, and log tail live in one place.

import AppKit

final class FeedbackWindowController: NSWindowController {

    var recipient: String = ""
    var diagnostics: () -> String = { "" }
    var logTail: () -> String? = { nil }

    private var typePopup: NSPopUpButton!
    private var messageView: NSTextView!
    private var emailField: NSTextField!
    private var includeLog: NSButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Send Feedback"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI

    private func buildUI() {
        guard let window = window, let content = window.contentView else { return }
        let width: CGFloat = 340

        let title = label("Tell us about a bug or an idea", font: .systemFont(ofSize: 15, weight: .semibold))

        typePopup = NSPopUpButton()
        typePopup.addItems(withTitles: ["Bug", "Feature", "Other"])
        let typeRow = NSStackView(views: [label("Type:", font: .systemFont(ofSize: 13)), typePopup, spacer()])
        typeRow.orientation = .horizontal
        typeRow.alignment = .centerY
        typeRow.spacing = 8

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        messageView = NSTextView()
        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: 12)
        messageView.isVerticallyResizable = true
        messageView.textContainer?.widthTracksTextView = true
        scroll.documentView = messageView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        emailField = NSTextField()
        emailField.placeholderString = "Your email for follow-up (optional)"

        includeLog = NSButton(checkboxWithTitle: "Include recent log in the message",
                              target: nil, action: nil)
        includeLog.state = .on

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"   // Esc
        let send = NSButton(title: "Send", target: self, action: #selector(send))
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"          // default button
        let footer = NSStackView(views: [spacer(), cancel, send])
        footer.orientation = .horizontal
        footer.spacing = 8

        let stack = NSStackView(views: [title, typeRow, label("Message:", font: .systemFont(ofSize: 13)),
                                        scroll, emailField, includeLog, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        for v in [typeRow, scroll, emailField, footer] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: width + 40, height: stack.fittingSize.height + 40))
        window.center()
    }

    // MARK: - Send

    @objc private func send() {
        let message = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { NSSound.beep(); return }

        let type = typePopup.titleOfSelectedItem ?? "Feedback"
        let firstLine = message.split(separator: "\n").first.map(String.init) ?? type
        let subject = "[Wend \(type)] \(firstLine)"

        var body = message + "\n\n----- diagnostics -----\n" + diagnostics()
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty { body += "\nReply-to: \(email)" }
        if includeLog.state == .on {
            body += "\n\n----- Wend.log (recent) -----\n" + (logTail() ?? "(log unavailable)")
        }
        // Keep the compose URL within what browsers / Gmail accept.
        if body.count > 9000 { body = String(body.prefix(9000)) + "\n…(truncated)" }

        if let gmail = gmailComposeURL(subject: subject, body: body) {
            NSWorkspace.shared.open(gmail)
        }
        window?.close()
    }

    @objc private func cancel() { window?.close() }

    private func gmailComposeURL(subject: String, body: String) -> URL? {
        var comps = URLComponents(string: "https://mail.google.com/mail/")
        comps?.queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: recipient),
            URLQueryItem(name: "su", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return comps?.url
    }

    // MARK: - Helpers

    private func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        return field
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }
}
