// HotkeyManager (macOS): detects a double-tap of the Shift key as the fix trigger.
// A "tap" = Shift pressed and released quickly with no other key in between, so it does
// not fire while Shift is held to type capitals. Requires Accessibility (global monitor).

import AppKit
import Carbon.HIToolbox

final class HotkeyManager {
    /// Called on the main thread when a clean double-Shift is detected.
    var onTrigger: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Internal, not private: a problem report records the windows the taps were judged by.
    let doubleTapInterval: TimeInterval = 0.4
    let maxHold: TimeInterval = 0.3

    private var shiftIsDown = false
    private var shiftDownTime: TimeInterval = 0
    private var keyPressedDuringShift = false
    private var lastTapTime: TimeInterval = 0

    func start() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // Why a ⇧⇧ didn't fire is otherwise invisible, so every *bare* Shift press is logged with
    // its hold and its gap to the previous tap, measured against the windows above. Shift
    // pressed with a letter or another modifier (typing a capital, a shortcut) is logged only
    // when it spoils a pending second tap — it's the common case, and logging it would chart
    // the user's typing. Timings, key sides, and verdicts only; no other key is ever named.
    private func handle(_ event: NSEvent) {
        let now = event.timestamp

        if event.type == .keyDown {
            // A key while Shift is down spoils the tap. Only worth a line when it spoils the
            // second tap of a pair that was about to fire.
            if shiftIsDown, !keyPressedDuringShift, secondTapPending(now) {
                Log.write("⇧ second tap spoiled: a key was pressed while ⇧ was down")
            }
            keyPressedDuringShift = true
            return
        }

        // .flagsChanged
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let shiftNow = flags.contains(.shift)

        // A Shift key going down while we already think Shift is down: either the other Shift
        // key joined in, or we never saw the last release — and a stale press makes the next
        // real tap read as one long hold, costing the first tap of the next ⇧⇧.
        if shiftIsDown, let side = Self.shiftSide(event), Self.isDown(side, event) {
            Log.write("⇧ \(side) down while ⇧ already down for \(Self.ms(now - shiftDownTime)) ms")
        }

        if shiftNow && !shiftIsDown {
            shiftIsDown = true
            shiftDownTime = now
            keyPressedDuringShift = (flags != [.shift]) // another modifier alongside shift = dirty
            if keyPressedDuringShift, secondTapPending(now) {
                Log.write("⇧ second tap spoiled: another modifier was already held")
            }
        } else if !shiftNow && shiftIsDown {
            shiftIsDown = false
            let held = now - shiftDownTime
            let cleanTap = !keyPressedDuringShift && held <= maxHold
            let side = Self.shiftSide(event) ?? "?"
            if cleanTap {
                let gap = now - lastTapTime
                if now - lastTapTime <= doubleTapInterval {
                    Log.write("⇧ \(side) tap held=\(Self.ms(held)) gap=\(Self.ms(gap)) ms: double-tap, trigger")
                    lastTapTime = 0
                    onTrigger?()
                } else {
                    Log.write(lastTapTime > 0
                        ? "⇧ \(side) tap held=\(Self.ms(held)) gap=\(Self.ms(gap)) ms > \(Self.ms(doubleTapInterval)): first tap (again)"
                        : "⇧ \(side) tap held=\(Self.ms(held)) ms: first tap")
                    lastTapTime = now
                }
            } else {
                if !keyPressedDuringShift {
                    // Bare Shift, held too long. A hold of seconds or more means the press
                    // itself was stale — see the "already down" line above.
                    Log.write("⇧ \(side) press held=\(Self.ms(held)) ms > \(Self.ms(maxHold)): not a tap")
                }
                lastTapTime = 0
            }
        } else if !flags.subtracting(.shift).isEmpty {
            // some other modifier toggled while we were tracking -> not a clean shift tap
            if shiftIsDown, !keyPressedDuringShift, secondTapPending(now) {
                Log.write("⇧ second tap spoiled: another modifier pressed while ⇧ was down")
            }
            keyPressedDuringShift = true
        }
    }

    /// A first tap is waiting for its partner — the only time a spoiled press is worth a line.
    private func secondTapPending(_ now: TimeInterval) -> Bool {
        lastTapTime > 0 && now - lastTapTime <= doubleTapInterval
    }

    // Device-dependent flag bits (IOKit NX_DEVICELSHIFTKEYMASK / NX_DEVICERSHIFTKEYMASK) tell
    // which physical Shift is down, which the device-independent `.shift` flag can't.
    private static let leftShiftBit: UInt = 0x02
    private static let rightShiftBit: UInt = 0x04

    private static func shiftSide(_ event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Shift:      return "L"
        case kVK_RightShift: return "R"
        default:             return nil
        }
    }

    private static func isDown(_ side: String, _ event: NSEvent) -> Bool {
        let bit = side == "L" ? leftShiftBit : rightShiftBit
        return event.modifierFlags.rawValue & bit != 0
    }

    private static func ms(_ t: TimeInterval) -> Int { Int((t * 1000).rounded()) }
}
