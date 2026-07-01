// FixController (macOS): the fix action. Reads the selection, asks Core which conversion
// makes the most real words, pastes it back, and optionally switches the active layout.

import AppKit
import KeyLayoutCore

final class FixController {
    private let inputSources = InputSourceProvider()
    private let selection = SelectionService()
    private let switcher = InputSourceSwitcher()

    var switchInputSourceAfterFix = true

    /// Fix the current selection. No-op (silent) if nothing is selected or no conversion wins.
    func performFix() {
        Log.write("performFix start")
        let layouts = inputSources.installedLayouts()
        guard layouts.count >= 2 else {
            NSSound.beep() // need at least two layouts to convert between
            return
        }
        let currentID = inputSources.currentLayoutID()

        // Built here (app fully launched, spell dictionaries ready), not at app init.
        let detector = LayoutDetector(validator: SpellWordValidator())

        var chosen: ConversionCandidate?
        let didReplace = selection.transformSelection { text in
            Log.write("captured len=\(text.count)")
            guard let candidate = detector.bestConversion(
                of: text, layouts: layouts, currentLayoutID: currentID
            ) else {
                Log.write("no winning conversion")
                return nil
            }
            // Log only metadata — never any substring of the user's text (it may be sensitive).
            Log.write("convert score=\(candidate.score) len=\(candidate.converted.count)")
            chosen = candidate
            return candidate.converted
        }
        Log.write("didReplace=\(didReplace)")

        guard didReplace else { return }
        if switchInputSourceAfterFix, let target = chosen?.target {
            switcher.selectLayout(id: target.id)
        }
    }
}
