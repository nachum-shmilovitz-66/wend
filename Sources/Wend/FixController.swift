// FixController (macOS): the fix action. Reads the selection, asks Core which conversion
// makes the most real words, pastes it back, and optionally switches the active layout.

import AppKit
import KeyLayoutCore

final class FixController {
    private let inputSources = InputSourceProvider()
    private let selection = SelectionService()
    private let switcher = InputSourceSwitcher()

    var switchInputSourceAfterFix = true

    /// Fixing again this soon after a rejected attempt means "convert it anyway": the user
    /// is insisting the text is wrong, so the dictionary gets skipped. Chosen over a second
    /// hotkey because retrying is what people already do when nothing happens.
    private let forceWindow: TimeInterval = 2
    private var lastRejectionAt: Date?

    /// Fix the current selection. No-op (silent) if nothing is selected or no conversion wins.
    func performFix() {
        Log.write("performFix start")
        let now = Date()
        let force = lastRejectionAt.map { now.timeIntervalSince($0) <= forceWindow } ?? false
        let layouts = inputSources.installedLayouts()
        guard layouts.count >= 2 else {
            NSSound.beep() // need at least two layouts to convert between
            return
        }
        let currentID = inputSources.currentLayoutID()

        // Built here (app fully launched, spell dictionaries ready), not at app init.
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

        // Say why an attempt ended, not just that it did. A capture that produced nothing used
        // to log "didReplace=false" with no preceding "captured" line, so the reason had to be
        // inferred from the absence of a log entry — which read as a bug in Wend when the real
        // answer was usually that the selection had gone (the paste from a previous fix clears
        // it, so fixing twice in a row hits this).
        switch outcome {
        case .replaced:      break // the convert/captured lines above already tell the story
        case .secureInput:   Log.write("skipped: secure input active")
        case .noSelection:   Log.write("nothing captured: no selection")
        case .noTextFlavor:  Log.write("nothing captured: selection carried no text")
        case .declined:      break // "no winning conversion" already logged
        }
        let didReplace = outcome == .replaced
        Log.write("didReplace=\(didReplace)")

        // Nothing to work on is worth a nudge: the fix is invisible when it works on nothing,
        // and the commonest cause — the selection lost to a previous fix's paste — is
        // invisible too. Secure input stays silent on purpose: a stray double-shift while
        // typing a password should not make noise, and there is nothing the user should do
        // about it. A captured-but-declined attempt also stays silent, because fixing again
        // within the force window is the intended next step.
        if outcome == .noSelection || outcome == .noTextFlavor {
            NSSound.beep()
        }

        // Arm (or disarm) the escalation window. Only a captured-then-declined attempt arms it;
        // a capture that never happened — nothing selected — leaves it untouched, so an
        // accidental trigger doesn't cancel a retry the user is in the middle of.
        switch outcome {
        case .replaced: lastRejectionAt = nil
        case .declined: lastRejectionAt = now
        case .secureInput, .noSelection, .noTextFlavor: break
        }

        guard didReplace else { return }
        if switchInputSourceAfterFix, let target = chosen?.target {
            switcher.selectLayout(id: target.id)
        }
    }
}
