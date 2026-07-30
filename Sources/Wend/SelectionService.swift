// SelectionService (macOS): read the current selection and replace it, in any app, via
// the clipboard — simulate ⌘C, transform, simulate ⌘V, then restore the user's previous
// clipboard. Works everywhere a normal copy/paste works. Requires Accessibility.

import AppKit
import CoreGraphics
import Carbon.HIToolbox
import KeyLayoutCore

/// Why a fix attempt ended the way it did. A plain Bool couldn't tell "you had nothing
/// selected" apart from "the conversion was declined", which made a failed fix
/// indistinguishable in the log — the attempt appeared to vanish with no reason recorded.
enum SelectionOutcome {
    /// The selection was converted and pasted back.
    case replaced
    /// Secure input (a password field) is active — deliberately untouched.
    case secureInput
    /// ⌘C produced nothing: no selection, or the app didn't answer in time.
    case noSelection
    /// The copy landed but carried no text flavor (an image, a file promise).
    case noTextFlavor
    /// Text was captured, and `transform` chose not to change it.
    case declined
}

final class SelectionService {
    private let pasteboard = NSPasteboard.general

    /// Copy the selection, run `transform`, paste the result back. Original clipboard is
    /// preserved. The outcome says whether it replaced anything, and if not, why.
    @discardableResult
    func transformSelection(_ transform: (String) -> String?) -> SelectionOutcome {
        // Never touch a password / secure-input field — don't synthesize ⌘C against it, which
        // would put the secret on the pasteboard. Silent no-op when secure input is active.
        guard !IsSecureEventInputEnabled() else { return .secureInput }

        let saved = savePasteboard()

        let captured = copySelectedText()
        guard case .text(let selected) = captured else {
            restorePasteboard(saved)
            return captured == .noTextFlavor ? .noTextFlavor : .noSelection
        }
        guard let replacement = transform(selected) else {
            restorePasteboard(saved)
            return .declined
        }

        pasteText(replacement)
        // Restore the user's clipboard once the paste has consumed our text. Capture the
        // pasteboard directly (not self) so restore still runs even if the service is
        // deallocated within the delay — otherwise the original clipboard would be lost.
        let pb = pasteboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        return .replaced
    }

    // MARK: - Copy / paste primitives

    /// Result of the ⌘C round-trip. Distinguishes "the clipboard never changed" (nothing was
    /// selected) from "it changed but holds no text", which need different reports.
    private enum Capture: Equatable {
        case text(String)
        case noSelection
        case noTextFlavor
    }

    private func copySelectedText() -> Capture {
        let startCount = pasteboard.changeCount
        postKeyWithCommand(CGKeyCode(kVK_ANSI_C))

        // Pump the run loop until the pasteboard updates or we time out.
        let deadline = Date().addingTimeInterval(0.6)
        while pasteboard.changeCount == startCount && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard pasteboard.changeCount != startCount else { return .noSelection }
        guard let plain = pasteboard.string(forType: .string) else { return .noTextFlavor }

        // Some web editors (Google Chat's compose box) flatten line breaks to spaces in the
        // plain-text flavor while the html flavor still carries them as <div> blocks. Recover
        // the structure from html — but only when the two agree on everything except
        // whitespace, so html can restore line breaks and never alter the selected text.
        if let html = pasteboard.string(forType: .html) {
            let derived = HTMLPlainText.text(from: html)
            if !derived.isEmpty, sameIgnoringWhitespace(derived, plain) {
                if derived != plain { Log.write("capture via html (recovered line structure)") }
                return .text(derived)
            }
        }
        return .text(plain)
    }

    /// Same visible content, whitespace aside — the guard on trusting the html flavor.
    private func sameIgnoringWhitespace(_ lhs: String, _ rhs: String) -> Bool {
        lhs.filter { !$0.isWhitespace } == rhs.filter { !$0.isWhitespace }
    }

    private func pasteText(_ text: String) {
        // Mark this write concealed + transient so well-behaved clipboard managers skip storing
        // it — it's ephemeral (restored in 0.25s) and may be sensitive. ⌘V still reads .string.
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

        // Multi-line only: some web editors (Google Chat's compose box) collapse the bare LF
        // in the plain-text flavor, losing the line break. An html flavor with <br> is
        // unambiguous and rich-text consumers prefer it, while plain-text fields (Terminal,
        // editors) still read .string exactly as before. Single-line text is untouched, so
        // this can't regress the common path.
        let multiline = text.contains(where: \.isNewline)

        var types: [NSPasteboard.PasteboardType] = [.string, concealed, transient]
        if multiline { types.insert(.html, at: 0) }

        pasteboard.clearContents()
        pasteboard.declareTypes(types, owner: nil)
        pasteboard.setString(text, forType: .string)
        if multiline {
            pasteboard.setString(PlainTextHTML.fragment(for: text), forType: .html)
        }
        pasteboard.setString("", forType: concealed)
        pasteboard.setString("", forType: transient)
        postKeyWithCommand(CGKeyCode(kVK_ANSI_V))
    }

    private func postKeyWithCommand(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard save / restore

    private func savePasteboard() -> [NSPasteboardItem] {
        pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
    }

    private func restorePasteboard(_ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
