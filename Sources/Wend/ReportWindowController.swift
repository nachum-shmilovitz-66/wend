// ReportWindowController (macOS): "Report a Problem…" — one form for bug reports and
// feedback alike (it replaced the separate "Send Feedback" form). The user picks what
// happened, optionally describes it, and either saves a report zip to ~/Downloads or saves
// it and opens an email to send it with.
//
// Email delivery (zero backend): opens Gmail's web compose URL, prefilled with recipient,
// subject, and a body carrying the description and diagnostics. (macOS always registers
// Mail.app as the mailto: handler even when it's never been configured, so a mailto: would
// just launch an empty, unset-up Mail — web compose is reliable for a Gmail user.) A compose
// URL can't attach a file, so the zip is revealed in Finder for the user to drag in.
//
// Injected by AppDelegate so the recipient, diagnostics, and report building live in one place.

import AppKit
import KeyLayoutCore

final class ReportWindowController: NSWindowController {

    var recipient: String = ""
    /// Short diagnostics for the email body (version, macOS, layouts, Accessibility).
    var diagnostics: () -> String = { "" }
    /// Build and save the report zip; returns where it landed.
    var saveReport: (ReportKind, String) throws -> URL = { _, _ in
        throw CocoaError(.featureUnsupported)
    }

    private var kindButtons: [(ReportKind, NSButton)] = []
    private var messageView: NSTextView!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Report a Problem"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    func show() {
        // Fresh form each time: a report describes one incident.
        kindButtons.first?.1.state = .on
        kindButtons.dropFirst().forEach { $0.1.state = .off }
        messageView.string = ""
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI

    private func buildUI() {
        guard let window = window, let content = window.contentView else { return }
        let width: CGFloat = 380

        let title = label("What are you reporting?", font: .systemFont(ofSize: 15, weight: .semibold))

        kindButtons = ReportKind.allCases.map { kind in
            (kind, NSButton(radioButtonWithTitle: kind.title, target: self, action: #selector(kindChanged)))
        }
        kindButtons.first?.1.state = .on
        let kinds = NSStackView(views: kindButtons.map(\.1))
        kinds.orientation = .vertical
        kinds.alignment = .leading
        kinds.spacing = 6
        if let groupEnd = kindButtons.first(where: { $0.0 == ReportKind.groupEndsAfter })?.1 {
            kinds.setCustomSpacing(14, after: groupEnd)
        }

        // scrollableTextView() wires the text view to track the scroll view's width. A bare
        // NSTextView() set as documentView keeps its zero frame, so typing is invisible.
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        messageView = scroll.documentView as? NSTextView
        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: 12)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        let note = label(
            "Report right after it happens. Wend keeps a short in-memory trail of recent events — "
            + "key timings, scores, and the app in front, never your text — and clears it when it "
            + "quits. The report is a zip in your Downloads folder; nothing is sent anywhere.",
            font: .systemFont(ofSize: 11)
        )
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = width
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"   // Esc
        let email = NSButton(title: "Save & Email…", target: self, action: #selector(saveAndEmail))
        email.bezelStyle = .rounded
        let save = NSButton(title: "Save Report", target: self, action: #selector(saveOnly))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"          // default button
        let footer = NSStackView(views: [spacer(), cancel, email, save])
        footer.orientation = .horizontal
        footer.spacing = 8

        let stack = NSStackView(views: [title, kinds, label("Describe it:", font: .systemFont(ofSize: 13)),
                                        scroll, note, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: kinds)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        for v in [scroll, note, footer] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: width + 40, height: stack.fittingSize.height + 40))
        window.center()
    }

    /// Radio buttons that share a superview and an action already group themselves; the
    /// action just has to exist.
    @objc private func kindChanged(_ sender: NSButton) {}

    private var selectedKind: ReportKind {
        kindButtons.first { $0.1.state == .on }?.0 ?? .bug
    }

    private var details: String {
        messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    @objc private func saveOnly() {
        guard let url = save() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        window?.close()
    }

    @objc private func saveAndEmail() {
        guard let url = save() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])

        let kind = selectedKind
        let firstLine = details.split(separator: "\n").first.map(String.init) ?? kind.tag
        let subject = "[Wend] \(kind.tag): \(firstLine)"
        let body = (details.isEmpty ? kind.tag : details)
            + "\n\nReport attached: \(url.lastPathComponent) (in Downloads)"
            + "\n\n----- diagnostics -----\n" + diagnostics()

        // The limit is on the encoded URL, not the text: Hebrew percent-encodes to about six
        // characters a letter. Trim the body until the whole URL is one Gmail will accept.
        var trimmed = body
        var gmail = gmailComposeURL(subject: subject, body: trimmed)
        while let long = gmail, long.absoluteString.count > 8000, trimmed.count > 200 {
            trimmed = String(trimmed.prefix(trimmed.count * 3 / 4))
            gmail = gmailComposeURL(subject: subject, body: trimmed + "\n…(truncated — the full report is in the zip)")
        }
        if let gmail { NSWorkspace.shared.open(gmail) }
        window?.close()
    }

    @objc private func cancel() { window?.close() }

    private func save() -> URL? {
        let kind = selectedKind
        guard !kind.needsDescription || !details.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(messageView)
            return nil
        }
        do {
            return try saveReport(kind, details)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't save the report"
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return nil
        }
    }

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
