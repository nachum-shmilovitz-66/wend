// Entry point: a tray-only app (no window, no taskbar button).

import WinSDK
import ucrt
import KeyLayoutCore

/// The executable is linked as a GUI subsystem app so the tray build never flashes a console
/// window, which also means it starts with nowhere to print. The diagnostic modes below need
/// stdout, so they borrow the console that launched them.
///
/// Only when there isn't one already: a redirected stdout (`--dump-layouts > out.txt`, or a
/// pipe) is inherited and works untouched, and reopening CONOUT$ over it would send the output
/// to the console instead of the file the caller asked for.
private func attachToParentConsole() {
    if let existing = GetStdHandle(STD_OUTPUT_HANDLE), existing != INVALID_HANDLE_VALUE {
        return
    }
    let attachParentProcess = DWORD(bitPattern: -1)
    guard AttachConsole(attachParentProcess) else { return }
    // `stdout` and `stderr` are macros over __acrt_iob_func, so the importer has neither.
    _ = freopen("CONOUT$", "w", __acrt_iob_func(1))
    _ = freopen("CONOUT$", "w", __acrt_iob_func(2))
}

// Diagnostic: dump the layouts read from the live system + a sample conversion, then exit.
// Reading layouts needs no special privileges, so this runs headless for verification.
if CommandLine.arguments.contains("--dump-layouts") {
    attachToParentConsole()

    let provider = InputSourceProvider()
    let layouts = provider.installedLayouts()
    let current = provider.currentLayoutID()
    print("Current layout: \(current ?? "nil")")
    print("Installed keyboard layouts: \(layouts.count)")
    for table in layouts {
        print("  • \(table.localizedName)  [\(table.id)]  lang=\(table.languageCode ?? "?")  mappedKeys=\(table.forward.count)")
    }
    if let source = layouts.first(where: { $0.languageCode == "en" }) ?? layouts.first {
        for target in layouts where target.id != source.id {
            let demo = LayoutMapper.remap("akuo guko", from: source, to: target)
            print("  remap 'akuo guko'  \(source.localizedName) -> \(target.localizedName)  =>  '\(demo)'")
        }
    }

    let dictionaries = SpellWordValidator.installedDictionaries()
    print("Spell-check dictionaries: \(dictionaries.isEmpty ? "none" : dictionaries.joined(separator: ", "))")

    let validator = SpellWordValidator()
    let detector = LayoutDetector(validator: validator)
    if let best = detector.bestConversion(of: "akuo", layouts: layouts, currentLayoutID: current) {
        print("Detector: 'akuo' => '\(best.converted)'  (\(best.target.localizedName), score \(best.score))")
    } else {
        print("Detector: no winning conversion for 'akuo' (need Hebrew layout + dictionary installed)")
    }

    // Optional: --detect "<text>" prints every source->target candidate + score.
    if let index = CommandLine.arguments.firstIndex(of: "--detect"),
       index + 1 < CommandLine.arguments.count {
        let text = CommandLine.arguments[index + 1]
        print("\n--detect input: '\(text)'")
        for source in layouts {
            for target in layouts where target.id != source.id {
                let converted = LayoutMapper.remap(text, from: source, to: target)
                let tokens = LayoutDetector.wordTokens(converted)
                let valid = tokens.filter { validator.isValidWord($0, language: target.languageCode ?? "") }
                let ratio = tokens.isEmpty ? 0 : Double(valid.count) / Double(tokens.count)
                print("  \(source.localizedName)->\(target.localizedName): '\(converted)'  score=\(ratio)  valid=\(valid)")
            }
        }
        if let best = detector.bestConversion(of: text, layouts: layouts, currentLayoutID: current) {
            print("  BEST => '\(best.converted)' (\(best.target.localizedName), \(best.score))")
        } else {
            print("  BEST => nil (no conversion beats threshold)")
        }
    }
    exit(0)
}

let app = App()
App.shared = app
exit(app.run())
