// ReportWindow (Windows): "Report a Problem…" — the Win32 counterpart of the macOS
// ReportWindowController, replacing the old compose-only "Send Feedback". The user picks what
// they're reporting (the same four choices as on macOS, from KeyLayoutCore), describes it, and
// either saves a report zip to Downloads or saves it and opens an email to send it with.
//
// Plain Win32 controls on an ordinary window rather than a dialog template: the build has no
// resource compiler step (see make_setup_win.ps1), and a handful of CreateWindowEx calls is
// the smaller thing to keep in step with the macOS form. App's message loop routes this
// window's keystrokes through IsDialogMessage, which is what gives it Tab between controls,
// arrow keys within the radio group, Enter for Save Report and Esc for Cancel.
//
// Like App's hidden window, this one can be found and posted to by anything in the session.
// Unlike it, nothing here acts on the user's text: the worst a forged click does is save a
// report or open a compose page, so the controls carry no cookie.

import WinSDK
import Foundation
import KeyLayoutCore

private let reportClassName = "WendReportWindow"

// Save Report and Cancel use the stock ids, so IsDialogMessage turns Enter and Esc into them.
private let idSave: UInt16 = 1       // IDOK
private let idCancel: UInt16 = 2     // IDCANCEL
private let idEmail: UInt16 = 100
private let idEdit: UInt16 = 101
private let idFirstKind: UInt16 = 200

// Dialog-manager messages, as numbers: IsDialogMessage sends these to the window it serves,
// and only DefDlgProc answers them — which an ordinary window doesn't have, so this one does.
private let wmNextDlgCtl: UINT = 0x0028   // WM_NEXTDLGCTL: move focus (Tab out of the edit box)
private let dmGetDefID: UINT = 0x0400     // DM_GETDEFID: which button Enter presses
private let dcHasDefID: Int = 0x534B      // DC_HASDEFID, the high word of a DM_GETDEFID answer

final class ReportWindow {
    /// The window procedure is a bare C function pointer and can capture nothing — same
    /// arrangement as App.shared.
    static var shared: ReportWindow?

    var recipient = ""
    /// Short diagnostics for the email body.
    var diagnostics: () -> String = { "" }
    /// Build and save the report zip; returns its native path.
    var saveReport: (ReportKind, String) throws -> String = { _, _ in throw ReportUnavailable() }

    private(set) var window: HWND?
    private var edit: HWND?
    private var kindButtons: [(ReportKind, HWND)] = []
    private var fonts: [HFONT] = []
    /// The control that had focus when the form was deactivated, restored on reactivation.
    private var savedFocus: HWND?

    // Layout, in the 96-DPI units Windows scales for a DPI-unaware app.
    private let margin: Int32 = 20
    private let contentWidth: Int32 = 380

    func show() {
        if window == nil { create() }
        guard let window else { return }
        // Fresh form for each incident — but choosing the menu item again while the form is
        // already open just brings it forward, keeping whatever has been typed.
        guard !IsWindowVisible(window) else {
            SetForegroundWindow(window)
            return
        }
        for (index, entry) in kindButtons.enumerated() {
            SendMessageW(entry.1, UINT(BM_SETCHECK), WPARAM(index == 0 ? BST_CHECKED : BST_UNCHECKED), 0)
        }
        if let edit { _ = withWide("") { SetWindowTextW(edit, $0) } }
        savedFocus = kindButtons.first?.1
        ShowWindow(window, Int32(SW_SHOWNORMAL))
        SetForegroundWindow(window)
        if let first = kindButtons.first?.1 { SetFocus(first) }
    }

    // MARK: - Building

    private func create() {
        let instance = GetModuleHandleW(nil)
        withWide(reportClassName) { className in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = reportProcedure
            windowClass.hInstance = instance
            windowClass.lpszClassName = className
            // COLOR_BTNFACE + 1, the dialog background; IDC_ARROW is MAKEINTRESOURCE(32512),
            // a macro the importer drops.
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            _ = RegisterClassExW(&windowClass)   // fails harmlessly if already registered
        }

        let (bodyFont, headingFont) = makeFonts()

        // The window is sized from the client area the controls need.
        let clientHeight: Int32 = 412
        let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
        let exStyle = DWORD(WS_EX_DLGMODALFRAME)
        var frame = RECT(left: 0, top: 0, right: contentWidth + 2 * margin, bottom: clientHeight)
        AdjustWindowRectEx(&frame, style, false, exStyle)
        let width = frame.right - frame.left
        let height = frame.bottom - frame.top
        let x = (GetSystemMetrics(SM_CXSCREEN) - width) / 2
        let y = (GetSystemMetrics(SM_CYSCREEN) - height) / 3

        window = withWide(reportClassName) { className in
            withWide("Report a Problem") { title in
                CreateWindowExW(exStyle, className, title, style,
                                x, y, width, height, nil, nil, instance, nil)
            }
        }
        guard let window else { return }

        var top: Int32 = 16
        add("STATIC", "What are you reporting?", style: DWORD(SS_LEFT),
            x: margin, y: top, width: contentWidth, height: 24, font: headingFont)
        top += 32

        kindButtons = []
        for (index, kind) in ReportKind.allCases.enumerated() {
            // WS_GROUP on the first radio starts the group; the next WS_GROUP (the label
            // below) ends it, which is what scopes both auto-unchecking and arrow keys.
            var radioStyle = DWORD(BS_AUTORADIOBUTTON)
            if index == 0 { radioStyle |= DWORD(WS_GROUP) | DWORD(WS_TABSTOP) }
            let button = add("BUTTON", kind.title, style: radioStyle,
                             x: margin, y: top, width: contentWidth, height: 20,
                             id: idFirstKind + UInt16(index), font: bodyFont)
            if let button { kindButtons.append((kind, button)) }
            // A gap between the conversion problems and the bug / idea pair, as on macOS.
            top += kind == ReportKind.groupEndsAfter ? 32 : 22
        }
        top += 10

        add("STATIC", "Describe it:", style: DWORD(SS_LEFT) | DWORD(WS_GROUP),
            x: margin, y: top, width: contentWidth, height: 18, font: bodyFont)
        top += 22

        edit = add("EDIT", "",
                   style: DWORD(WS_TABSTOP) | DWORD(WS_VSCROLL) | DWORD(ES_MULTILINE)
                       | DWORD(ES_AUTOVSCROLL) | DWORD(ES_WANTRETURN),
                   exStyle: DWORD(WS_EX_CLIENTEDGE),
                   x: margin, y: top, width: contentWidth, height: 110, id: idEdit, font: bodyFont)
        top += 120

        add("STATIC",
            "Report right after it happens. Wend keeps a short in-memory trail of recent events "
            + "— key timings, scores, and the app in front, never your text — and clears it when "
            + "it exits. The report is a zip in your Downloads folder; nothing is sent anywhere.",
            style: DWORD(SS_LEFT), x: margin, y: top, width: contentWidth, height: 68, font: bodyFont)
        top += 78

        // Right-aligned buttons: Cancel, Save & Email…, Save Report (default).
        let buttonHeight: Int32 = 26
        let right = margin + contentWidth
        add("BUTTON", "Save Report", style: DWORD(BS_DEFPUSHBUTTON) | DWORD(WS_TABSTOP),
            x: right - 100, y: top, width: 100, height: buttonHeight, id: idSave, font: bodyFont)
        // "&&": a single & would underline the next letter as a mnemonic.
        add("BUTTON", "Save && Email…", style: DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP),
            x: right - 216, y: top, width: 110, height: buttonHeight, id: idEmail, font: bodyFont)
        add("BUTTON", "Cancel", style: DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP),
            x: right - 302, y: top, width: 80, height: buttonHeight, id: idCancel, font: bodyFont)
    }

    /// The system message font (what dialogs use), and a larger semibold one for the heading.
    private func makeFonts() -> (HFONT?, HFONT?) {
        let size = UINT(MemoryLayout<NONCLIENTMETRICSW>.size)
        var metrics = NONCLIENTMETRICSW()
        metrics.cbSize = size
        guard SystemParametersInfoW(UINT(SPI_GETNONCLIENTMETRICS), size, &metrics, 0) else {
            return (nil, nil)
        }
        var body = metrics.lfMessageFont
        var heading = metrics.lfMessageFont
        heading.lfWeight = LONG(FW_SEMIBOLD)
        heading.lfHeight = heading.lfHeight * 5 / 4
        let bodyFont = CreateFontIndirectW(&body)
        let headingFont = CreateFontIndirectW(&heading)
        fonts = [bodyFont, headingFont].compactMap { $0 }
        return (bodyFont, headingFont)
    }

    @discardableResult
    private func add(
        _ className: String, _ text: String, style: DWORD, exStyle: DWORD = 0,
        x: Int32, y: Int32, width: Int32, height: Int32, id: UInt16 = 0, font: HFONT?
    ) -> HWND? {
        let control = withWide(className) { cls in
            withWide(text) { title in
                CreateWindowExW(exStyle, cls, title, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style,
                                x, y, width, height, window,
                                HMENU(bitPattern: UInt(id)), GetModuleHandleW(nil), nil)
            }
        }
        if let control, let font {
            SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), 1)
        }
        return control
    }

    // MARK: - Messages

    fileprivate func handle(window: HWND?, message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT? {
        switch message {
        case UINT(WM_COMMAND):
            // Only button clicks (and IsDialogMessage's Enter / Esc, which arrive the same way).
            // The edit control's change notifications share its id and are ignored.
            guard hiWord(UInt(wParam)) == UInt16(BN_CLICKED) else { return nil }
            switch loWord(UInt(wParam)) {
            case idSave:   saveOnly()
            case idEmail:  saveAndEmail()
            case idCancel: hide()
            default:       return nil
            }
            return 0

        case UINT(WM_CLOSE):
            hide()   // kept for next time rather than destroyed
            return 0

        // Keep the focused control across deactivation. DefWindowProc would put focus on the
        // frame on reactivation (after Alt+Tab, or after the save-error message box), where
        // typing goes nowhere and Enter quietly saves.
        case UINT(WM_ACTIVATE):
            if loWord(UInt(wParam)) == UInt16(WA_INACTIVE) {
                if let focus = GetFocus(), let window, IsChild(window, focus) { savedFocus = focus }
            } else if let target = savedFocus ?? kindButtons.first?.1 {
                SetFocus(target)
            }
            return 0

        // Tab / Shift+Tab out of the multiline edit: it asks its parent to move focus.
        case wmNextDlgCtl:
            guard let window else { return 0 }
            let next = lParam != 0
                ? HWND(bitPattern: UInt(wParam))
                : GetNextDlgTabItem(window, GetFocus(), wParam != 0)
            if let next { SetFocus(next) }
            return 0

        // Enter presses the focused push button when Tab has put focus on one, and Save Report
        // otherwise — the default-button bookkeeping a real dialog gets from DefDlgProc.
        case dmGetDefID:
            var id = idSave
            if let focus = GetFocus() {
                let focused = UInt16(truncatingIfNeeded: GetDlgCtrlID(focus))
                if focused == idEmail || focused == idCancel { id = focused }
            }
            return LRESULT((dcHasDefID << 16) | Int(id))

        default:
            return nil
        }
    }

    private func hide() {
        if let window { ShowWindow(window, Int32(SW_HIDE)) }
    }

    // MARK: - Actions

    private var selectedKind: ReportKind {
        kindButtons.first { SendMessageW($0.1, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) }?.0 ?? .bug
    }

    /// The description, with the edit control's CRLFs normalised to the LF the report uses.
    private var details: String {
        guard let edit else { return "" }
        let length = GetWindowTextLengthW(edit)
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        _ = buffer.withUnsafeMutableBufferPointer {
            GetWindowTextW(edit, $0.baseAddress, Int32($0.count))
        }
        return stringFromWide(buffer)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveOnly() {
        guard let path = save() else { return }
        reveal(path)
        hide()
    }

    private func saveAndEmail() {
        guard let path = save() else { return }
        reveal(path)

        let kind = selectedKind
        let text = details
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? kind.tag
        let name = path.split(separator: "\\").last.map(String.init) ?? path
        let body = (text.isEmpty ? kind.tag : text)
            + "\n\nReport attached: \(name) (in Downloads)"
            + "\n\n----- diagnostics -----\n" + diagnostics()
        let subject = "[Wend] \(kind.tag): \(firstLine)"

        // The limit is on the encoded URL, not the text: Hebrew percent-encodes to about six
        // characters a letter, and a command line past 32K characters never reaches the browser.
        // Trim the body until the whole URL fits comfortably.
        var trimmed = body
        var url = composeURL(subject: subject, body: trimmed)
        while let long = url, long.absoluteString.count > 8000, trimmed.count > 200 {
            trimmed = String(trimmed.prefix(trimmed.count * 3 / 4))
            url = composeURL(subject: subject, body: trimmed + "\n…(truncated — the full report is in the zip)")
        }

        // ShellExecute reports success as a value above 32.
        let opened = url.map { url in
            withWide(url.absoluteString) { address in
                withWide("open") { verb in
                    Int(bitPattern: UnsafeRawPointer(ShellExecuteW(nil, verb, address, nil, nil, Int32(SW_SHOWNORMAL)))) > 32
                }
            }
        } ?? false
        if !opened {
            message("Couldn't open the email page. The report is saved in your Downloads folder.")
        }
        hide()
    }

    private func composeURL(subject: String, body: String) -> URL? {
        var components = URLComponents(string: "https://mail.google.com/mail/")
        components?.queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: recipient),
            URLQueryItem(name: "su", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }

    private func message(_ text: String) {
        _ = withWide(text) { body in
            withWide("Wend") { title in
                MessageBoxW(window, body, title, UINT(MB_OK | MB_ICONWARNING))
            }
        }
    }

    /// Bug and Idea need a description; the conversion problems don't. Nil when nothing saved.
    private func save() -> String? {
        let kind = selectedKind
        guard !kind.needsDescription || !details.isEmpty else {
            MessageBeep(UINT(MB_OK))
            if let edit { SetFocus(edit) }
            return nil
        }
        do {
            return try saveReport(kind, details)
        } catch {
            message("Couldn't save the report.\n\n\(error.localizedDescription)")
            return nil
        }
    }

    /// Open Explorer on the Downloads folder with the new zip selected.
    private func reveal(_ path: String) {
        _ = withWide("explorer.exe") { program in
            withWide("/select,\"\(path)\"") { arguments in
                withWide("open") { verb in
                    ShellExecuteW(nil, verb, program, arguments, nil, Int32(SW_SHOWNORMAL))
                }
            }
        }
    }
}

private let reportProcedure: WNDPROC = { window, message, wParam, lParam in
    if let handled = ReportWindow.shared?.handle(window: window, message: message,
                                                 wParam: wParam, lParam: lParam) {
        return handled
    }
    return DefWindowProcW(window, message, wParam, lParam)
}

/// Thrown by the placeholder `saveReport` until App wires the real one in.
private struct ReportUnavailable: Error {}
