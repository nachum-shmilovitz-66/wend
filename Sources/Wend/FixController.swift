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
        var rejected = false
        let didReplace = selection.transformSelection { text in
            Log.write("captured len=\(text.count) nl=\(text.filter(\.isNewline).count)")
            var best = detector.bestConversion(of: text, layouts: layouts, currentLayoutID: currentID)
            if best == nil, force {
                best = detector.forcedConversion(of: text, layouts: layouts, currentLayoutID: currentID)
                if best != nil { Log.write("forced conversion (repeat trigger)") }
            }
            guard let candidate = best else {
                Log.write("no winning conversion")
                rejected = true
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
        Log.write("didReplace=\(didReplace)")

        // Arm (or disarm) the escalation window. A capture that never happened — nothing
        // selected — leaves it untouched, so an accidental trigger doesn't cancel a retry
        // the user is in the middle of.
        if didReplace {
            lastRejectionAt = nil
        } else if rejected {
            lastRejectionAt = now
        }

        guard didReplace else { return }
        if switchInputSourceAfterFix, let target = chosen?.target {
            switcher.selectLayout(id: target.id)
        }
    }
}
