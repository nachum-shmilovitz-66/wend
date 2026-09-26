// FixController (Windows): the fix action. Reads the selection, asks Core which conversion
// makes the most real words, pastes it back, and optionally switches the active layout.

import WinSDK
import Foundation
import CWinUIA
import KeyLayoutCore

final class FixController {
    private let inputSources = InputSourceProvider()
    private let selection: SelectionService
    private let switcher = InputSourceSwitcher()

    var switchInputSourceAfterFix = true

    /// Fixing again this soon after a rejected attempt means "convert it anyway": the user is
    /// insisting the text is wrong, so the dictionary gets skipped. Chosen over a second
    /// hotkey because retrying is what people already do when nothing happens.
    let forceWindow: TimeInterval = 2   // internal: a problem report records it
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
    /// All of it is one-off: the ToUnicodeEx sweep across every installed layout, and bringing
    /// up the COM apartment for the spell-checker and the UI Automation client. Left where they
    /// fall, they land in the middle of the first fix — between the copy and the paste — which
    /// is the one place in the whole flow where a delay is not merely slow but wrong: the
    /// clipboard is in a borrowed state and another app is waiting on a paste.
    func prepare() {
        _ = inputSources.installedLayouts()
        // Any word will do; the point is to make the spell-checker exist.
        _ = SpellWordValidator().isValidWord("wend", language: "en")
        // Worth naming in the log: without a UIA client the password guard is back to the
        // ES_PASSWORD check alone, which cannot see a browser or Electron password box.
        let uia = wend_uia_init() != 0
        Log.write("warmed up (uia=\(uia ? "ready" : "unavailable"))")
    }

    /// Fix the current selection. No-op (silent) if nothing is selected or no conversion wins.
    func performFix() {
        guard !isFixing else { return }
        isFixing = true
        defer { isFixing = false }

        let now = Date()
        let force = lastRejectionAt.map { now.timeIntervalSince($0) <= forceWindow } ?? false
        // The front app is the likeliest variable when a fix works in one place and not
        // another. Its executable name names the app, not anything typed into it.
        let sinceDecline = lastRejectionAt.map { "\(Int(now.timeIntervalSince($0) * 1000)) ms" } ?? "none"
        Log.write("performFix start front=\(Self.foregroundExecutable()) force=\(force) sinceDecline=\(sinceDecline)")
        let layouts = inputSources.installedLayouts()
        guard layouts.count >= 2 else {
            Log.write("skipped: \(layouts.count) layout(s) installed, need 2")
            MessageBeep(UINT(MB_OK))   // need at least two layouts to convert between
            return
        }
        let currentID = inputSources.currentLayoutID()
        Log.write("layouts=\(layouts.count) current=\(currentID ?? "?")")

        // Built here rather than at app init, matching macOS: the spell-checker is asked for
        // the languages it supports, and that answer is only meaningful once COM is up.
        let detector = LayoutDetector(validator: SpellWordValidator())

        var chosen: ConversionCandidate?
        let outcome = selection.transformSelection { text in
            Log.write("captured len=\(text.count) nl=\(text.filter(\.isNewline).count)")
            let decision = detector.decide(of: text, layouts: layouts, currentLayoutID: currentID)
            // Scores and counts only. A decline here is the first half of "I had to press ⇧⇧
            // twice", so the report needs the numbers it was declined on.
            let ratio = { (value: Double) in String(format: "%.2f", value) }
            Log.write("""
                decision=\(decision.reason.rawValue) tokens=\(decision.tokenCount) \
                original=\(ratio(decision.originalScore)) best=\(ratio(decision.bestScore)) \
                threshold=\(ratio(decision.threshold))
                """)
            var best = decision.candidate
            if best == nil, force {
                best = detector.forcedConversion(of: text, layouts: layouts, currentLayoutID: currentID)
                if best != nil { Log.write("forced conversion (repeat trigger)") }
            }
            guard let candidate = best else {
                Log.write(force
                    ? "no winning conversion, even forced"
                    : "no winning conversion; ⇧⇧ again within \(Int(forceWindow)) s forces it")
                return nil
            }
            // Log only metadata — never any substring of the user's text (it may be sensitive).
            // `nl` counts line breaks: comparing it against the captured count pins down
            // whether a lost newline went missing inside Wend or in the receiving app.
            Log.write("""
                convert score=\(candidate.score) len=\(candidate.converted.count) \
                nl=\(candidate.converted.filter(\.isNewline).count) \
                source=\(candidate.source.id) target=\(candidate.target.id)
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

    /// `chrome.exe` for the foreground window's process, or `?` when Windows won't say (an
    /// elevated app refuses the query). The file name only — the full path can carry a user name.
    static func foregroundExecutable() -> String {
        guard let foreground = GetForegroundWindow() else { return "?" }
        var processID: DWORD = 0
        GetWindowThreadProcessId(foreground, &processID)
        guard processID != 0,
              let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, processID)
        else { return "?" }
        defer { CloseHandle(process) }

        var buffer = [WCHAR](repeating: 0, count: 1024)
        var size = DWORD(buffer.count)
        let ok = buffer.withUnsafeMutableBufferPointer {
            QueryFullProcessImageNameW(process, 0, $0.baseAddress, &size)
        }
        guard ok else { return "?" }
        let path = stringFromWide(buffer)
        return path.split(separator: "\\").last.map(String.init) ?? "?"
    }
}
