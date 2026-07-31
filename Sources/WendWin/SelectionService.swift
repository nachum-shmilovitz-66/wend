// SelectionService (Windows): read the current selection and replace it, in any app, via the
// clipboard — synthesize Ctrl+C, transform, synthesize Ctrl+V, then put back what was on the
// clipboard before. Works everywhere an ordinary copy/paste works.

import WinSDK
import Foundation
import CWinUIA
import KeyLayoutCore

/// Why a fix attempt ended the way it did. A plain Bool couldn't tell "you had nothing
/// selected" apart from "the conversion was declined", which made a failed fix
/// indistinguishable in the log — the attempt appeared to vanish with no reason recorded.
enum SelectionOutcome {
    /// The selection was converted and pasted back.
    case replaced
    /// Focus is in a password field — deliberately untouched.
    case secureInput
    /// The foreground window belongs to a process Wend may not send input to: an app running
    /// elevated while Wend is not. Windows drops the keystroke silently (UIPI), so without
    /// naming this the fix looks broken for a reason the user can actually act on.
    case blockedByPrivilege
    /// Ctrl+C produced nothing: no selection, or the app didn't answer in time.
    case noSelection
    /// The copy landed but carried no text flavor (an image, a file drop).
    case noTextFlavor
    /// Text was captured, and `transform` chose not to change it.
    case declined
}

final class SelectionService {

    /// Wend's hidden window. The clipboard is opened against an owner window, and the message
    /// pumping below belongs to its thread.
    private let window: HWND

    init(window: HWND) {
        self.window = window
    }

    /// Copy the selection, run `transform`, paste the result back. The original clipboard is
    /// preserved. The outcome says whether it replaced anything, and if not, why.
    @discardableResult
    func transformSelection(_ transform: (String) -> String?) -> SelectionOutcome {
        // Never touch a password field — don't synthesize Ctrl+C against it, which would put
        // the secret on the clipboard.
        guard !isPasswordFieldFocused() else { return .secureInput }
        guard canSendInputToForeground() else { return .blockedByPrivilege }

        let saved = saveClipboard()

        let captured = copySelectedText()
        guard case .text(let selected) = captured else {
            restoreClipboard(saved)
            return captured == .noTextFlavor ? .noTextFlavor : .noSelection
        }
        guard let replacement = transform(selected) else {
            restoreClipboard(saved)
            return .declined
        }

        pasteText(replacement)
        // Let the paste consume our text before the clipboard goes back to what the user had.
        // The macOS build defers this onto the main queue; here the whole fix is already a
        // synchronous run of the message loop, so this stays one — and the restore is
        // therefore guaranteed to have happened by the time the fix returns.
        //
        // Longer than the 0.25s macOS waits, because the Windows clipboard is an exclusive
        // lock rather than a snapshot: while the restore below holds it open, a Ctrl+V being
        // serviced at that moment can't open it and pastes *nothing*, wiping the selection
        // instead of replacing it. Nothing reports when a paste has completed, so the only
        // lever is to be well clear of it first.
        pumpMessages(for: 0.4)
        restoreClipboard(saved)
        return .replaced
    }

    // MARK: - Copy / paste primitives

    /// Result of the Ctrl+C round-trip. Distinguishes "the clipboard never changed" (nothing
    /// was selected) from "it changed but holds no text", which need different reports.
    private enum Capture: Equatable {
        case text(String)
        case noSelection
        case noTextFlavor
    }

    private func copySelectedText() -> Capture {
        let before = GetClipboardSequenceNumber()
        sendControlShortcut(virtualKey: UInt16(0x43))   // 'C'

        // Pump the message loop until the clipboard updates or we time out.
        let deadline = Date().addingTimeInterval(0.6)
        while GetClipboardSequenceNumber() == before && Date() < deadline {
            pumpMessages(for: 0.01)
        }
        guard GetClipboardSequenceNumber() != before else { return .noSelection }
        guard let plain = clipboardUnicodeText() else { return .noTextFlavor }

        // Some web editors (Google Chat's compose box) flatten line breaks to spaces in the
        // plain-text flavor while the html flavor still carries them as block elements. Recover
        // the structure from html — but only when the two agree on everything except
        // whitespace, so html can restore line breaks and never alter the selected text.
        if let payload = clipboardUTF8Text(format: Self.htmlFormat),
           let fragment = CFHTML.fragment(from: payload) {
            let derived = HTMLPlainText.text(from: fragment)
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
        // Multi-line only: some web editors collapse the bare LF in the plain-text flavor,
        // losing the line break. An html flavor with <br> is unambiguous and rich-text
        // consumers prefer it, while plain-text fields still read CF_UNICODETEXT exactly as
        // before. Single-line text is untouched, so this can't regress the common path.
        let multiline = text.contains(where: \.isNewline)

        _ = withClipboard {
            EmptyClipboard()
            put(bytes: utf16Bytes(of: text), format: UINT(CF_UNICODETEXT))
            if multiline {
                let document = CFHTML.document(for: PlainTextHTML.fragment(for: text))
                put(bytes: Array(document.utf8), format: Self.htmlFormat)
            }
            // Keep this ephemeral — and possibly sensitive — text out of clipboard history and
            // out of the cloud clipboard. Same intent as the org.nspasteboard concealed and
            // transient types the macOS build writes; these are the documented Windows
            // equivalents, and each is a DWORD 0 meaning "no".
            for format in Self.privacyFormats {
                put(bytes: [0, 0, 0, 0], format: format)
            }
        }
        sendControlShortcut(virtualKey: UInt16(0x56))   // 'V'
    }

    /// Synthesize Ctrl+<key>. Virtual keys rather than scan codes, because Ctrl+C and Ctrl+V
    /// are defined in virtual-key terms — the target app matches on VK_C whatever layout it is
    /// typing in, and a scan code would land on whichever key that layout puts there.
    private func sendControlShortcut(virtualKey: UInt16) {
        waitForModifiersToClear()

        let sequence = [
            keyInput(virtualKey: UInt16(VK_CONTROL), keyUp: false),
            keyInput(virtualKey: virtualKey, keyUp: false),
            keyInput(virtualKey: virtualKey, keyUp: true),
            keyInput(virtualKey: UInt16(VK_CONTROL), keyUp: true),
        ]

        // One event per call, spaced apart, rather than all four in a single batch.
        //
        // A batch is delivered with effectively one timestamp, and a Chromium-based app
        // (Chrome, Edge, Electron) can then process the character key without ever observing
        // Ctrl as held. The result is not a copy that failed: it is a literal `c` arriving as
        // text, which *replaces whatever the user had selected* — the fix destroys the very
        // thing it was invoked on, and the log only says "no selection", because the clipboard
        // genuinely never changed.
        //
        // Spacing them is what a real keystroke looks like, and it is the only lever available:
        // Win32 has no per-event modifier field to pin the state to, the way CGEventFlags does
        // on macOS.
        var delivered: UINT = 0
        for (index, event) in sequence.enumerated() {
            var input = event
            delivered += SendInput(1, &input, Int32(MemoryLayout<INPUT>.size))
            // Pumping rather than sleeping, for the same reason as the modifier wait: this
            // thread owns the low-level hook and must keep answering.
            if index < sequence.count - 1 { pumpMessages(for: Self.keyEventGap) }
        }

        // Previously discarded. A short count means the tail of the shortcut was swallowed —
        // with Ctrl possibly left down — which is worth knowing about rather than guessing at.
        if delivered != UINT(sequence.count) {
            Log.write("SendInput delivered \(delivered)/\(sequence.count), error \(GetLastError())")
        }
    }

    /// Gap between the individual key events of a synthesized shortcut. Long enough for an app
    /// that samples modifier state to see Ctrl held, short enough to stay far inside the
    /// clipboard round-trip's own timeout.
    private static let keyEventGap = 0.02

    /// Hold off injecting until the user's own modifier keys are up.
    ///
    /// `SendInput` has no per-event modifier field: an injected key inherits whatever the
    /// keyboard state happens to say. A Shift the user is still holding therefore turns Ctrl+C
    /// into Ctrl+Shift+C, which is not copy in most apps — the clipboard never changes and the
    /// attempt is reported as "no selection", while some apps take the bare character and type
    /// a literal `c` into the text instead. macOS is not exposed to this at all: `CGEvent.flags`
    /// replaces the modifier set for the event outright, so a held key cannot leak in.
    ///
    /// The trigger makes this the ordinary case rather than a corner one. It is a double *Shift*
    /// tap detected on the second key-up, and the hook runs before that key-up reaches the
    /// foreground app — so at the moment the fix starts, Shift is routinely still down as far as
    /// the target is concerned, and on an unhurried release it is genuinely still held.
    ///
    /// Giving up after the timeout rather than refusing to fix: a keyboard with a stuck modifier,
    /// or a remapper holding one down by design, would otherwise make Wend permanently dead.
    private func waitForModifiersToClear(timeout: Double = 0.5) {
        guard anyModifierDown() else { return }

        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        while Date() < deadline {
            // Pumping rather than sleeping: this thread owns the low-level keyboard hook, and
            // Windows quietly removes a hook whose thread stops answering. Blocking here would
            // cost the next trigger to buy this one.
            pumpMessages(for: 0.01)
            if !anyModifierDown() {
                Log.write("waited \(Int(Date().timeIntervalSince(start) * 1000))ms for modifiers")
                return
            }
        }
        Log.write("modifiers still held after \(Int(timeout * 1000))ms — sending anyway")
    }

    /// Whether the user is holding any modifier. Deliberately reports only that much: which key
    /// it is would be a record of what the user is typing, which WND-8 keeps this app clear of.
    private func anyModifierDown() -> Bool {
        for key in [VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN]
        where GetAsyncKeyState(key) < 0 {
            return true
        }
        return false
    }

    private func keyInput(virtualKey: UInt16, keyUp: Bool) -> INPUT {
        var input = INPUT()
        input.type = DWORD(INPUT_KEYBOARD)
        input.ki.wVk = WORD(virtualKey)
        input.ki.wScan = WORD(MapVirtualKeyW(UINT(virtualKey), UINT(MAPVK_VK_TO_VSC)))
        input.ki.dwFlags = keyUp ? DWORD(KEYEVENTF_KEYUP) : 0
        // So Wend's own keyboard hook can tell these apart from the user's typing.
        input.ki.dwExtraInfo = wendInjectedSignature
        return input
    }

    /// Run the message loop for `seconds` without blocking it. Both halves of the round-trip
    /// need Wend to keep answering messages while another process does its part.
    private func pumpMessages(for seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        var message = MSG()
        repeat {
            while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
                TranslateMessage(&message)
                DispatchMessageW(&message)
            }
            Sleep(5)
        } while Date() < deadline
    }

    // MARK: - Clipboard access

    private struct ClipboardEntry {
        let format: UINT
        let bytes: [UInt8]
    }

    /// Formats whose handle is not an HGLOBAL, so their bytes can't be copied this way. They
    /// are left behind rather than guessed at: losing a bitmap off the clipboard is bad, but
    /// writing rubbish into a GDI handle is worse.
    private static let nonGlobalFormats: Set<UINT> = [
        UINT(CF_BITMAP), UINT(CF_METAFILEPICT), UINT(CF_PALETTE), UINT(CF_ENHMETAFILE),
        UINT(CF_DSPBITMAP), UINT(CF_DSPMETAFILEPICT), UINT(CF_DSPENHMETAFILE),
        UINT(CF_OWNERDISPLAY),
    ]

    private static let htmlFormat: UINT = withWide("HTML Format") {
        RegisterClipboardFormatW($0)
    }

    private static let privacyFormats: [UINT] = [
        "ExcludeClipboardContentFromMonitorProcessing",
        "CanIncludeInClipboardHistory",
        "CanUploadToCloudClipboard",
    ].map { name in withWide(name) { RegisterClipboardFormatW($0) } }

    /// The clipboard is a single system-wide lock any process can be holding, so a first
    /// attempt failing is ordinary rather than exceptional — hence the retries.
    private func withClipboard<R>(_ body: () -> R) -> R? {
        for _ in 0..<10 {
            if OpenClipboard(window) {
                defer { CloseClipboard() }
                return body()
            }
            Sleep(20)
        }
        Log.write("clipboard unavailable (locked by another app)")
        return nil
    }

    private func saveClipboard() -> [ClipboardEntry] {
        withClipboard {
            var entries: [ClipboardEntry] = []
            var skipped = 0
            var format = EnumClipboardFormats(0)
            while format != 0 {
                defer { format = EnumClipboardFormats(format) }

                guard !Self.nonGlobalFormats.contains(format), !Self.isGDIFormat(format) else {
                    skipped += 1
                    continue
                }
                // A null handle means the owner renders that format on demand, which can't be
                // captured without asking it to render — not worth doing for a 0.25s round-trip.
                guard let handle = GetClipboardData(format) else { continue }
                let size = GlobalSize(handle)
                guard size > 0, let source = GlobalLock(handle) else { continue }
                defer { GlobalUnlock(handle) }
                entries.append(ClipboardEntry(
                    format: format,
                    bytes: [UInt8](UnsafeRawBufferPointer(start: source, count: Int(size)))
                ))
            }
            if skipped > 0 {
                Log.write("clipboard: \(skipped) non-global format(s) not preserved")
            }
            return entries
        } ?? []
    }

    private func restoreClipboard(_ entries: [ClipboardEntry]) {
        _ = withClipboard {
            EmptyClipboard()
            for entry in entries {
                put(bytes: entry.bytes, format: entry.format)
            }
        }
    }

    /// Hand `bytes` to the clipboard under `format`. Must be called with the clipboard open.
    private func put(bytes: [UInt8], format: UINT) {
        guard !bytes.isEmpty, let handle = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes.count))
        else { return }
        guard let destination = GlobalLock(handle) else {
            GlobalFree(handle)
            return
        }
        bytes.withUnsafeBytes { source in
            destination.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
        GlobalUnlock(handle)
        // On success the clipboard owns the handle; on failure we still do.
        if SetClipboardData(format, handle) == nil {
            GlobalFree(handle)
        }
    }

    private func clipboardUnicodeText() -> String? {
        withClipboard {
            guard let handle = GetClipboardData(UINT(CF_UNICODETEXT)),
                  let pointer = GlobalLock(handle) else { return nil }
            defer { GlobalUnlock(handle) }

            let capacity = Int(GlobalSize(handle)) / MemoryLayout<WCHAR>.size
            let units = pointer.assumingMemoryBound(to: WCHAR.self)
            var characters: [WCHAR] = []
            var index = 0
            while index < capacity, units[index] != 0 {
                characters.append(units[index])
                index += 1
            }
            return String(decoding: characters, as: UTF16.self)
        } ?? nil
    }

    /// A UTF-8 clipboard format (CF_HTML is one) as a String.
    private func clipboardUTF8Text(format: UINT) -> String? {
        withClipboard {
            guard let handle = GetClipboardData(format),
                  let pointer = GlobalLock(handle) else { return nil }
            defer { GlobalUnlock(handle) }

            let capacity = Int(GlobalSize(handle))
            let bytes = UnsafeRawBufferPointer(start: pointer, count: capacity)
            let content = bytes.prefix { $0 != 0 }
            return String(decoding: content, as: UTF8.self)
        } ?? nil
    }

    private func utf16Bytes(of text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity((text.utf16.count + 1) * 2)
        for unit in text.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        bytes.append(0)   // CF_UNICODETEXT is NUL-terminated
        bytes.append(0)
        return bytes
    }

    /// GDI object formats, which like the fixed ones above aren't HGLOBALs.
    private static func isGDIFormat(_ format: UINT) -> Bool {
        (UINT(CF_GDIOBJFIRST)...UINT(CF_GDIOBJLAST)).contains(format)
    }

    // MARK: - Guards

    /// True when focus is in a password field.
    ///
    /// Two tests, and the weaker one is still here as the fallback. UI Automation is asked
    /// first because it is the only one that can see a password box inside a browser or an
    /// Electron app — which is where most passwords are actually typed, and the gap this check
    /// used to have. It answers "don't know" (-1) when the client couldn't be created or the
    /// target didn't respond in time, and that is not read as "not a password": the Win32 test
    /// runs on 0 and on -1 alike, so the result can only ever be more protective than the
    /// ES_PASSWORD check alone.
    ///
    /// Still weaker than macOS, which exposes a system-wide secure-input flag that covers every
    /// app at once whether or not it publishes anything. What holds either way is that Wend
    /// never writes captured text anywhere, and the clipboard it touches is marked to stay out
    /// of history and off the cloud.
    private func isPasswordFieldFocused() -> Bool {
        if wend_uia_focus_is_password() == 1 { return true }
        return isClassicPasswordFieldFocused()
    }

    /// The ES_PASSWORD style of a Win32 edit control. Only meaningful on a classic control —
    /// a password box in a browser or an Electron app is not a window and is invisible here.
    private func isClassicPasswordFieldFocused() -> Bool {
        guard let foreground = GetForegroundWindow() else { return false }
        let foregroundThread = GetWindowThreadProcessId(foreground, nil)
        let ownThread = GetCurrentThreadId()
        guard foregroundThread != 0, foregroundThread != ownThread else { return false }

        // Focus is per-input-queue, so the queues have to be joined to ask about it at all.
        guard AttachThreadInput(ownThread, foregroundThread, true) else { return false }
        defer { AttachThreadInput(ownThread, foregroundThread, false) }

        guard let focused = GetFocus() else { return false }

        var className = [WCHAR](repeating: 0, count: 64)
        let written = className.withUnsafeMutableBufferPointer {
            GetClassNameW(focused, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return false }
        // The style bit only means "password" on an edit control; elsewhere it means something
        // else entirely, so the class has to be checked before the style.
        guard stringFromWide(className).lowercased().contains("edit") else { return false }

        let esPassword: LONG_PTR = 0x0020
        return GetWindowLongPtrW(focused, GWL_STYLE) & esPassword != 0
    }

    /// False when the foreground window belongs to a more privileged process. Windows drops
    /// synthesized input across that boundary without reporting it, so the copy would simply
    /// come back empty.
    private func canSendInputToForeground() -> Bool {
        guard let foreground = GetForegroundWindow() else { return true }
        var processID: DWORD = 0
        GetWindowThreadProcessId(foreground, &processID)
        guard processID != 0, processID != GetCurrentProcessId() else { return true }

        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, processID)
        else {
            // Anything other than a refusal (a process that just exited, say) isn't evidence
            // of a privilege boundary, so only access-denied counts.
            return GetLastError() != DWORD(ERROR_ACCESS_DENIED)
        }
        CloseHandle(process)
        return true
    }
}
