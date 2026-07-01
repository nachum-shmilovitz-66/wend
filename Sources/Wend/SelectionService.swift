// SelectionService (macOS): read the current selection and replace it, in any app, via
// the clipboard — simulate ⌘C, transform, simulate ⌘V, then restore the user's previous
// clipboard. Works everywhere a normal copy/paste works. Requires Accessibility.

import AppKit
import CoreGraphics
import Carbon.HIToolbox

final class SelectionService {
    private let pasteboard = NSPasteboard.general

    /// Copy the selection, run `transform`, paste the result back. Original clipboard is
    /// preserved. Returns false if nothing was selected / copy failed / transform declined.
    @discardableResult
    func transformSelection(_ transform: (String) -> String?) -> Bool {
        // Never touch a password / secure-input field — don't synthesize ⌘C against it, which
        // would put the secret on the pasteboard. Silent no-op when secure input is active.
        guard !IsSecureEventInputEnabled() else { return false }

        let saved = savePasteboard()

        guard let selected = copySelectedText() else {
            restorePasteboard(saved)
            return false
        }
        guard let replacement = transform(selected) else {
            restorePasteboard(saved)
            return false
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
        return true
    }

    // MARK: - Copy / paste primitives

    private func copySelectedText() -> String? {
        let startCount = pasteboard.changeCount
        postKeyWithCommand(CGKeyCode(kVK_ANSI_C))

        // Pump the run loop until the pasteboard updates or we time out.
        let deadline = Date().addingTimeInterval(0.6)
        while pasteboard.changeCount == startCount && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard pasteboard.changeCount != startCount else { return nil }
        return pasteboard.string(forType: .string)
    }

    private func pasteText(_ text: String) {
        // Mark this write concealed + transient so well-behaved clipboard managers skip storing
        // it — it's ephemeral (restored in 0.25s) and may be sensitive. ⌘V still reads .string.
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed, transient], owner: nil)
        pasteboard.setString(text, forType: .string)
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
