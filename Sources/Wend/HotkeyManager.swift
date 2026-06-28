// HotkeyManager (macOS): detects a double-tap of the Shift key as the fix trigger.
// A "tap" = Shift pressed and released quickly with no other key in between, so it does
// not fire while Shift is held to type capitals. Requires Accessibility (global monitor).

import AppKit

final class HotkeyManager {
    /// Called on the main thread when a clean double-Shift is detected.
    var onTrigger: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private let doubleTapInterval: TimeInterval = 0.4
    private let maxHold: TimeInterval = 0.3

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

    private func handle(_ event: NSEvent) {
        let now = event.timestamp

        if event.type == .keyDown {
            keyPressedDuringShift = true
            return
        }

        // .flagsChanged
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let shiftNow = flags.contains(.shift)

        if shiftNow && !shiftIsDown {
            shiftIsDown = true
            shiftDownTime = now
            keyPressedDuringShift = (flags != [.shift]) // another modifier alongside shift = dirty
        } else if !shiftNow && shiftIsDown {
            shiftIsDown = false
            let held = now - shiftDownTime
            let cleanTap = !keyPressedDuringShift && held <= maxHold
            if cleanTap {
                if now - lastTapTime <= doubleTapInterval {
                    lastTapTime = 0
                    onTrigger?()
                } else {
                    lastTapTime = now
                }
            } else {
                lastTapTime = 0
            }
        } else if !flags.subtracting(.shift).isEmpty {
            // some other modifier toggled while we were tracking -> not a clean shift tap
            keyPressedDuringShift = true
        }
    }
}
