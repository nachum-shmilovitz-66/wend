// App (Windows): the tray icon, its menu, and the hidden window everything else hangs off.
// The counterpart of the macOS AppDelegate's status item.
//
// Wend has no window of its own, by design — the same shape as the macOS menu-bar app. The
// window created here is never shown; it exists because the clipboard is opened against an
// owner window, a low-level hook needs somewhere to post to, and a tray icon delivers its
// notifications as window messages.

import WinSDK
import Foundation
import KeyLayoutCore

private let windowClassName = "WendHiddenWindow"

private let messageFix = UINT(WM_APP + 1)
private let messageTray = UINT(WM_APP + 2)
/// Sent by a second launch to the copy already running.
private let messageReopen = UINT(WM_APP + 3)

private let fixDelayTimer = UINT_PTR(1)

private enum Command: UINT {
    case fix = 1
    case switchAfterFix
    case launchAtLogin
    case logging
    case feedback
    case about
    case quit
}

private let switchAfterFixKey = "switchInputSourceAfterFix"

final class App {
    /// The window procedure is a bare C function pointer and can capture nothing, so the one
    /// App instance has to be reachable without one.
    static var shared: App?

    private var window: HWND?
    private var controller: FixController?
    private let hotkeys = HotkeyManager()
    private var trayIcon: NOTIFYICONDATAW?
    private var instanceMutex: HANDLE?

    // MARK: - Lifecycle

    func run() -> Int32 {
        guard claimSingleInstance() else { return 0 }
        guard createWindow() else { return 1 }
        guard let window else { return 1 }

        let controller = FixController(window: window)
        controller.switchInputSourceAfterFix = Settings.bool(switchAfterFixKey, default: true)
        self.controller = controller

        LaunchAtLogin.enableOnFirstRun()   // before the menu, so its checkmark is correct
        addTrayIcon()

        Log.write("launch version=\(Version.short)")
        controller.prepare()

        hotkeys.targetWindow = window
        hotkeys.triggerMessage = messageFix
        hotkeys.start()

        return messageLoop()
    }

    /// A second launch shouldn't start a second Wend. It asks the copy already running to
    /// re-assert its tray icon and say hello instead — the Windows counterpart of the macOS
    /// reopen behaviour, and the answer to the icon having been buried in the overflow area.
    private func claimSingleInstance() -> Bool {
        instanceMutex = withWide("Local\\WendSingleInstance") { CreateMutexW(nil, true, $0) }
        guard GetLastError() == DWORD(ERROR_ALREADY_EXISTS) else { return true }

        if let existing = withWide(windowClassName, { FindWindowW($0, nil) }) {
            PostMessageW(existing, messageReopen, 0, 0)
        }
        return false
    }

    private func createWindow() -> Bool {
        let instance = GetModuleHandleW(nil)
        var registered = false
        withWide(windowClassName) { className in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = windowProcedure
            windowClass.hInstance = instance
            windowClass.lpszClassName = className
            registered = RegisterClassExW(&windowClass) != 0
        }
        guard registered else { return false }

        // Top-level but never shown: the style omits WS_VISIBLE, and WS_EX_TOOLWINDOW keeps it
        // out of the taskbar and the Alt-Tab list. A message-only window (HWND_MESSAGE) would
        // be the tidier fit for something that only receives messages, except that those are
        // invisible to cross-process window lookup — which is exactly how a second launch has
        // to find the copy already running.
        window = withWide(windowClassName) { className in
            withWide("Wend") { title in
                CreateWindowExW(DWORD(WS_EX_TOOLWINDOW), className, title, 0,
                                0, 0, 0, 0, nil, nil, instance, nil)
            }
        }
        return window != nil
    }

    private func messageLoop() -> Int32 {
        var message = MSG()
        // GetMessage also returns -1 on error, but the overlay maps its BOOL to Bool and drops
        // that case. It needs an invalid window handle or message filter to happen, and this
        // call passes neither, so there is nothing lost here.
        while GetMessageW(&message, nil, 0, 0) {
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        return Int32(message.wParam)
    }

    // MARK: - Messages

    /// Returns nil for anything it doesn't handle, so the caller can fall through to
    /// DefWindowProc.
    fileprivate func handle(
        window: HWND?,
        message: UINT,
        wParam: WPARAM,
        lParam: LPARAM
    ) -> LRESULT? {
        switch message {
        case messageFix:
            Log.write("double-shift trigger")
            controller?.performFix()
            return 0

        case messageReopen:
            // The icon may have been lost rather than merely hidden; re-adding is cheap and
            // covers both. Never silently do nothing — same rule as WND-3 on macOS.
            addTrayIcon()
            showBalloon(title: "Wend is running", text: "Select text and double-tap Shift to fix it.")
            return 0

        case messageTray:
            let event = UINT(lParam & 0xFFFF)
            if event == UINT(WM_LBUTTONUP) || event == UINT(WM_RBUTTONUP) {
                showMenu()
            }
            return 0

        case UINT(WM_COMMAND):
            perform(command: Command(rawValue: UINT(wParam & 0xFFFF)))
            return 0

        case UINT(WM_TIMER):
            guard wParam == fixDelayTimer else { return nil }
            KillTimer(window, fixDelayTimer)
            controller?.performFix()
            return 0

        case UINT(WM_DESTROY):
            PostQuitMessage(0)
            return 0

        default:
            return nil
        }
    }

    private func perform(command: Command?) {
        guard let command else { return }
        switch command {
        case .fix:
            performFixSoon()

        case .switchAfterFix:
            guard let controller else { return }
            controller.switchInputSourceAfterFix.toggle()
            Settings.setBool(switchAfterFixKey, controller.switchInputSourceAfterFix)

        case .launchAtLogin:
            LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)

        case .logging:
            Log.isEnabled.toggle()

        case .feedback:
            openFeedback()

        case .about:
            showAbout()

        case .quit:
            quit()
        }
    }

    /// Let the menu dismiss and the previous app regain focus before we synthesize Ctrl+C —
    /// otherwise the copy targets nothing and the fix no-ops.
    private func performFixSoon() {
        SetTimer(window, fixDelayTimer, 200, nil)
    }

    private func quit() {
        hotkeys.stop()
        removeTrayIcon()
        if let window { DestroyWindow(window) }
    }

    // MARK: - Tray icon

    private func addTrayIcon() {
        guard let window else { return }
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = window
        data.uID = 1
        data.uFlags = UINT(NIF_ICON | NIF_MESSAGE | NIF_TIP)
        data.uCallbackMessage = messageTray
        data.hIcon = loadTrayIcon()
        setWideField(&data.szTip, "Wend")

        // NIM_ADD fails if the icon is already there, in which case the modify is the one that
        // matters — the reopen path goes through here too.
        if !Shell_NotifyIconW(DWORD(NIM_ADD), &data) {
            Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
        }
        trayIcon = data
    }

    private func removeTrayIcon() {
        guard var data = trayIcon else { return }
        Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
        trayIcon = nil
    }

    private func showBalloon(title: String, text: String) {
        guard var data = trayIcon else { return }
        data.uFlags = UINT(NIF_INFO)
        setWideField(&data.szInfoTitle, title)
        setWideField(&data.szInfo, text)
        Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
    }

    /// Wend.ico beside the executable when the packaged build ships one, otherwise the stock
    /// application icon. A tray app with no icon is an app the user can't reach, so this never
    /// fails hard.
    private func loadTrayIcon() -> HICON? {
        let executable = URL(fileURLWithPath: LaunchAtLogin.command.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        let icon = executable.deletingLastPathComponent().appendingPathComponent("Wend.ico")
        if FileManager.default.fileExists(atPath: icon.path) {
            let loaded = withWide(icon.path) {
                LoadImageW(nil, $0, UINT(IMAGE_ICON), 0, 0,
                           UINT(LR_LOADFROMFILE | LR_DEFAULTSIZE))
            }
            // LoadImage hands back the generic HANDLE for every image type; with IMAGE_ICON
            // asked for, it is an HICON.
            if let loaded { return loaded.assumingMemoryBound(to: HICON__.self) }
        }
        // IDI_APPLICATION is MAKEINTRESOURCE(32512), a macro the importer drops.
        return LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
    }

    // MARK: - Menu

    private func showMenu() {
        guard let window, let controller, let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }

        append(menu, .fix, "Fix Selection  (Shift Shift)")
        appendSeparator(menu)
        append(menu, .switchAfterFix, "Switch Layout After Fix",
               checked: controller.switchInputSourceAfterFix)
        append(menu, .launchAtLogin, "Launch at Login", checked: LaunchAtLogin.isEnabled)
        append(menu, .logging, "Enable Diagnostic Logging", checked: Log.isEnabled)
        append(menu, .feedback, "Send Feedback…")
        appendSeparator(menu)
        // Version rides on the About row rather than a row of its own: it identifies the
        // running build at a glance for a bug report, without spending a menu line on it.
        append(menu, .about, "About Wend \(Version.short)")
        appendSeparator(menu)
        append(menu, .quit, "Quit Wend")

        var point = POINT()
        GetCursorPos(&point)
        // A tray menu that isn't owned by the foreground window doesn't dismiss when the user
        // clicks away from it; this is the documented workaround.
        SetForegroundWindow(window)
        TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil)
        PostMessageW(window, UINT(WM_NULL), 0, 0)
    }

    private func append(_ menu: HMENU, _ command: Command, _ title: String, checked: Bool = false) {
        let flags = UINT(MF_STRING) | UINT(checked ? MF_CHECKED : MF_UNCHECKED)
        _ = withWide(title) { AppendMenuW(menu, flags, UINT_PTR(command.rawValue), $0) }
    }

    private func appendSeparator(_ menu: HMENU) {
        AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    }

    // MARK: - About / feedback

    private func showAbout() {
        let text = """
            Wend \(Version.short)

            Fix text typed in the wrong keyboard layout.
            Select it and double-tap Shift.

            Created by Shmilovitz
            """
        _ = withWide(text) { body in
            withWide("About Wend") { title in
                MessageBoxW(nil, body, title, UINT(MB_OK | MB_ICONINFORMATION))
            }
        }
    }

    /// Opens Gmail's web compose prefilled with diagnostics, the same zero-backend route the
    /// macOS build takes. The log is deliberately not attached: the macOS build only inlines it
    /// behind an explicit checkbox, and there is no form here to hold one — so it stays local
    /// and the user can paste it themselves if they want to.
    private func openFeedback() {
        let body = """
            (describe the problem here)

            ----- diagnostics -----
            \(diagnostics())
            """
        var components = URLComponents(string: "https://mail.google.com/mail/")
        components?.queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: "nachumsh2@gmail.com"),
            URLQueryItem(name: "su", value: "[Wend] "),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components?.url else { return }
        _ = withWide(url.absoluteString) { address in
            withWide("open") { verb in
                ShellExecuteW(nil, verb, address, nil, nil, Int32(SW_SHOWNORMAL))
            }
        }
    }

    /// Auto-collected diagnostics for a feedback report, so reports are actionable.
    private func diagnostics() -> String {
        let layouts = InputSourceProvider().installedLayouts()
            .map(\.localizedName)
            .joined(separator: ", ")
        // The log path rather than the log: the macOS build only inlines the log behind an
        // explicit checkbox, and naming the file keeps that choice with the user while still
        // making it findable.
        return """
            Wend \(Version.short)
            Windows: \(windowsVersion())
            Layouts: \(layouts)
            Logging: \(Log.isEnabled ? "on" : "off") (\(Log.url.path))
            """
    }

    private func windowsVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

private let windowProcedure: WNDPROC = { window, message, wParam, lParam in
    if let handled = App.shared?.handle(window: window, message: message,
                                        wParam: wParam, lParam: lParam) {
        return handled
    }
    return DefWindowProcW(window, message, wParam, lParam)
}
