// InputSourceSwitcher (Windows): switch the active keyboard layout after a fix, so the user's
// next keystrokes land in the language they actually meant.
//
// ActivateKeyboardLayout would only change Wend's own thread, which types nothing at all —
// the layout is per-thread on Windows. The request has to go to the window that has focus,
// and it has to be posted rather than sent: the target processes it on its own input thread.

import WinSDK

final class InputSourceSwitcher {
    func selectLayout(id: String) {
        guard let value = UInt(id, radix: 16), value != 0 else { return }
        guard let window = GetForegroundWindow() else { return }
        PostMessageW(window, UINT(WM_INPUTLANGCHANGEREQUEST), 0,
                     LPARAM(Int(bitPattern: value)))
    }
}
