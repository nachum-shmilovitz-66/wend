// HotkeyManager (Windows): detects a double-tap of the Shift key as the fix trigger, using a
// low-level keyboard hook. A "tap" = Shift pressed and released quickly with no other key in
// between, so it does not fire while Shift is held to type capitals.
//
// The hook sees every keystroke on the desktop, so it deliberately keeps none of them. The
// only state it carries is a flag saying whether some non-Shift key went down during the
// current Shift press, plus a few timestamps. No key code is ever stored, logged, or copied
// anywhere — the constraint WND-8 set for the macOS event monitor applies here just as much.
//
// Why a ⇧⇧ didn't fire is otherwise invisible, so every *bare* Shift press is logged with its
// hold and its gap to the previous tap, in the same words the macOS build uses. Shift pressed
// with another key (typing a capital, a shortcut) is logged only when it spoils a pending
// second tap — it's the common case, and logging it would chart the user's typing. Timings,
// which Shift (L/R), and verdicts only; no other key is ever named. Log.write only appends to
// memory on this thread — the file write, when logging is on, is queued — so the hook still
// returns promptly.

import WinSDK

final class HotkeyManager {
    /// Where a detected trigger is delivered. The hook only posts this message: Windows
    /// silently removes a low-level hook that takes too long to return, so no work is done
    /// inside it.
    var targetWindow: HWND?
    var triggerMessage: UINT = 0
    /// Sent as the message's wParam; the window only acts on a trigger carrying it. See App.
    var triggerCookie: WPARAM = 0

    private var hook: HHOOK?

    /// The windows taps are judged by, for a problem report.
    var doubleTapInterval: DWORD { ShiftTapDetector.shared.doubleTapInterval }
    var maximumHold: DWORD { ShiftTapDetector.shared.maximumHold }

    func start() {
        ShiftTapDetector.shared.targetWindow = targetWindow
        ShiftTapDetector.shared.triggerMessage = triggerMessage
        ShiftTapDetector.shared.triggerCookie = triggerCookie
        hook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardHookProc, GetModuleHandleW(nil), 0)
        if hook == nil {
            Log.write("keyboard hook failed: \(GetLastError())")
        }
    }

    func stop() {
        if let hook {
            UnhookWindowsHookEx(hook)
            self.hook = nil
        }
    }
}

/// A low-level hook callback is a bare C function pointer, so it can capture nothing — the
/// detector below has to be reachable without one. That is safe here without any locking: a
/// WH_KEYBOARD_LL hook is always invoked on the thread that installed it, which is the one
/// message-loop thread Wend has.
private let keyboardHookProc: HOOKPROC = { code, wParam, lParam in
    if code >= 0,
       let event = UnsafeRawPointer(bitPattern: Int(lParam))?
           .assumingMemoryBound(to: KBDLLHOOKSTRUCT.self) {
        ShiftTapDetector.shared.handle(message: wParam, event: event.pointee)
    }
    return CallNextHookEx(nil, code, wParam, lParam)
}

private final class ShiftTapDetector {
    static let shared = ShiftTapDetector()

    var targetWindow: HWND?
    var triggerMessage: UINT = 0
    var triggerCookie: WPARAM = 0

    // Internal, not private: a problem report records the windows the taps were judged by.
    let doubleTapInterval: DWORD = 400
    let maximumHold: DWORD = 300
    /// Auto-repeat re-sends a held Shift's key-down every few tens of ms. A key-down while we
    /// think Shift is down, after a silence this long, is a fresh press whose release was missed.
    private let staleGap: DWORD = 1000

    private var shiftIsDown = false
    private var shiftDownTime: DWORD = 0
    private var otherKeyDuringShift = false
    private var lastTapTime: DWORD = 0
    private var lastShiftEventTime: DWORD = 0

    func handle(message: WPARAM, event: KBDLLHOOKSTRUCT) {
        // Wend's own synthesized Ctrl+C / Ctrl+V come back through this hook. Counting them as
        // real keys would mark the following Shift tap dirty and eat the next trigger. Only
        // Wend's own are skipped, not everything injected — see wendInjectedSignature.
        guard event.dwExtraInfo != wendInjectedSignature else { return }

        let isDown = message == WPARAM(WM_KEYDOWN) || message == WPARAM(WM_SYSKEYDOWN)
        let isUp = message == WPARAM(WM_KEYUP) || message == WPARAM(WM_SYSKEYUP)
        guard isDown || isUp else { return }

        let key = Int32(event.vkCode)
        let isShift = key == VK_SHIFT || key == VK_LSHIFT || key == VK_RSHIFT
        let time = event.time

        if isDown {
            guard isShift else {
                if shiftIsDown, !otherKeyDuringShift, secondTapPending(time) {
                    Log.write("⇧ second tap spoiled: a key was pressed while ⇧ was down")
                }
                otherKeyDuringShift = true
                return
            }
            // Auto-repeat re-sends key-down while Shift is held; only the first one starts the
            // clock, or holding Shift would look like a very short press.
            guard !shiftIsDown else {
                // A key-down after a long silence is not a repeat: it's a new press, and the
                // last release never reached us. The stale press makes this one read as a long
                // hold, costing the first tap of the next ⇧⇧.
                if elapsed(from: lastShiftEventTime, to: time) > staleGap {
                    Log.write("⇧ \(side(key)) down while ⇧ already down for \(elapsed(from: shiftDownTime, to: time)) ms")
                }
                lastShiftEventTime = time
                return
            }
            shiftIsDown = true
            shiftDownTime = time
            lastShiftEventTime = time
            otherKeyDuringShift = anotherModifierHeld()
            if otherKeyDuringShift, secondTapPending(time) {
                Log.write("⇧ second tap spoiled: another modifier was already held")
            }
            return
        }

        guard isShift, shiftIsDown else { return }
        shiftIsDown = false
        lastShiftEventTime = time
        let held = elapsed(from: shiftDownTime, to: time)

        guard !otherKeyDuringShift, held <= maximumHold else {
            if !otherKeyDuringShift {
                // Bare Shift, held too long. Seconds or more means the press itself was stale —
                // see the "already down" line above.
                Log.write("⇧ \(side(key)) press held=\(held) ms > \(maximumHold): not a tap")
            }
            lastTapTime = 0
            return
        }
        let gap = elapsed(from: lastTapTime, to: time)
        if lastTapTime != 0, gap <= doubleTapInterval {
            Log.write("⇧ \(side(key)) tap held=\(held) gap=\(gap) ms: double-tap, trigger")
            lastTapTime = 0
            if let window = targetWindow, triggerMessage != 0 {
                PostMessageW(window, triggerMessage, triggerCookie, 0)
            }
        } else {
            Log.write(lastTapTime != 0
                ? "⇧ \(side(key)) tap held=\(held) gap=\(gap) ms > \(doubleTapInterval): first tap (again)"
                : "⇧ \(side(key)) tap held=\(held) ms: first tap")
            lastTapTime = time
        }
    }

    /// A first tap is waiting for its partner — the only time a spoiled press is worth a line.
    private func secondTapPending(_ time: DWORD) -> Bool {
        lastTapTime != 0 && elapsed(from: lastTapTime, to: time) <= doubleTapInterval
    }

    /// Which Shift, for the log. A low-level hook reports the side-specific codes.
    private func side(_ key: Int32) -> String {
        switch key {
        case VK_LSHIFT: return "L"
        case VK_RSHIFT: return "R"
        default:        return "?"
        }
    }

    /// Another modifier down alongside Shift means this isn't a bare Shift tap — it's the
    /// start of Shift+Ctrl+something.
    private func anotherModifierHeld() -> Bool {
        for key in [VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN] where GetAsyncKeyState(key) < 0 {
            return true
        }
        return false
    }

    /// Event times are tick counts, which wrap every 49 days. Wrapping subtraction keeps the
    /// one comparison that straddles the wrap from reading as a month-long interval.
    private func elapsed(from earlier: DWORD, to later: DWORD) -> DWORD {
        later &- earlier
    }
}
