// FixController (Windows): the fix action. Reads the selection, asks Core which conversion
// makes the most real words, pastes it back, and optionally switches the active layout.

import WinSDK
import Foundation
import KeyLayoutCore

final class FixController {
    private let inputSources = InputSourceProvider()
    private let selection: SelectionService
    private let switcher = InputSourceSwitcher()

    var switchInputSourceAfterFix = true

    /// Fixing again this soon after a rejected attempt means "convert it anyway": the user is
    /// insisting the text is wrong, so the dictionary gets skipped. Chosen over a second
    /// hotkey because retrying is what people already do when nothing happens.
    private let forceWindow: TimeInterval = 2
    private var lastRejectionAt: Date?

    /// A fix pumps the message loop while it waits for the clipboard, so a second double-Shift
    /// arriving mid-fix would be dispatched straight back into here. The macOS build gets this
    /// for free by never re-entering its run loop the same way.
    private var isFixing = false

    init(window: HWND) {
        self.selection = SelectionService(window: window)
    }

    /// Do the expensive first-time work at launch instead of during the user's first fix.
    ///
    /// Both halves are one-off: the ToUnicodeEx sweep across every installed layout, and
    /// bringing up the COM apartment and loading a dictionary. Left where they fall, they land
    /// in the middle of the first fix — between the copy and the paste — which is the one place
    /// in the whole flow where a delay is not merely slow but wrong: the clipboard is in a
    /// borrowed state and another app is waiting on a paste.
    func prepare() {
        _ = inputSources.installedLayouts()
        // Any word will do; the point is to make the spell-checker exist.
        _ = SpellWordValidator().isValidWord("wend", language: "en")
        Log.write("warmed up")
    }

    /// Fix the current selection. No-op (silent) if nothing is selected or no conversion wins.
    func performFix() {
        guard !isFixing else { return }
        isFixing = true
        defer { isFixing = false }

        Log.write("performFix start")
        let now = Date()
        let force = lastRejectionAt.map { now.timeIntervalSince($0) <= forceWindow } ?? false
        let layouts = inputSources.installedLayouts()
        guard layouts.count >= 2 else {
            MessageBeep(UINT(MB_OK))   // need at least two layouts to convert between
            return
        }
        let currentID = inputSources.currentLayoutID()

        // Built here rather than at app init, matching macOS: the spell-checker is asked for
        // the languages it supports, and that answer is only meaningful once COM is up.
        let detector = LayoutDetector(validator: SpellWordValidator())

        var chosen: ConversionCandidate?
        let outcome = selection.transformSelection { text in
            Log.write("captured len=\(text.count) nl=\(text.filter(\.isNewline).count)")
            var best = detector.bestConversion(of: text, layouts: layouts, currentLayoutID: currentID)
            if best == nil, force {
                best = detector.forcedConversion(of: text, layouts: layouts, currentLayoutID: currentID)
                if best != nil { Log.write("forced conversion (repeat trigger)") }
            }
            guard let candidate = best else {
                Log.write("no winning conversion")
                return nil
            }
            // Log only metadata — never any substring of the user's text (it may be sensitive).
            // `nl` counts line breaks: comparing it against the captured count pins down
            // whether a lost newline went missing inside Wend or in the receiving app.
            Log.write("""
                convert score=\(candidate.score) len=\(candidate.converted.count) \
                nl=\(candidate.converted.filter(\.isNewline).count)
                """)
            chosen = candidate
            return candidate.converted
        }

        // Say why an attempt ended, not just that it did — see WND-26.
        switch outcome {
        case .replaced:           break // the convert/captured lines above already tell the story
        case .secureInput:        Log.write("skipped: secure input active")
        case .blockedByPrivilege: Log.write("skipped: foreground window is more privileged")
        case .noSelection:        Log.write("nothing captured: no selection")
        case .noTextFlavor:       Log.write("nothing captured: selection carried no text")
        case .declined:           break // "no winning conversion" already logged
        }
        let didReplace = outcome == .replaced
        Log.write("didReplace=\(didReplace)")

        // Nothing to work on is worth a nudge: the fix is invisible when it works on nothing,
        // and the commonest cause — the selection lost to a previous fix's paste — is invisible
        // too. A privilege block gets the same treatment, since it also leaves the user staring
        // at text that didn't change. Secure input stays silent on purpose: a stray double-shift
        // while typing a password should not make noise, and there is nothing the user should do
        // about it. A captured-but-declined attempt also stays silent, because fixing again
        // within the force window is the intended next step.
        if outcome == .noSelection || outcome == .noTextFlavor || outcome == .blockedByPrivilege {
            MessageBeep(UINT(MB_OK))
        }

        // Arm (or disarm) the escalation window. Only a captured-then-declined attempt arms it;
        // a capture that never happened — nothing selected — leaves it untouched, so an
        // accidental trigger doesn't cancel a retry the user is in the middle of.
        switch outcome {
        case .replaced: lastRejectionAt = nil
        case .declined: lastRejectionAt = now
        case .secureInput, .blockedByPrivilege, .noSelection, .noTextFlavor: break
        }

        guard didReplace else { return }
        if switchInputSourceAfterFix, let target = chosen?.target {
            switcher.selectLayout(id: target.id)
        }
    }
}
