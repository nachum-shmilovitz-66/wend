// Entry point: a menu-bar-only app (accessory policy = no Dock icon, no main window).
import AppKit
import KeyLayoutCore

// Diagnostic: dump the layouts read from the live system + a sample conversion, then exit.
// Reading layouts via TIS needs no Accessibility, so this runs headless for verification.
if CommandLine.arguments.contains("--dump-layouts") {
    let provider = InputSourceProvider()
    let layouts = provider.installedLayouts()
    let current = provider.currentLayoutID()
    print("Current layout: \(current ?? "nil")")
    print("Installed keyboard layouts: \(layouts.count)")
    for t in layouts {
        print("  • \(t.localizedName)  [\(t.id)]  lang=\(t.languageCode ?? "?")  mappedKeys=\(t.forward.count)")
    }
    if let src = layouts.first(where: { $0.languageCode == "en" }) ?? layouts.first {
        for tgt in layouts where tgt.id != src.id {
            let demo = LayoutMapper.remap("akuo guko", from: src, to: tgt)
            print("  remap 'akuo guko'  \(src.localizedName) -> \(tgt.localizedName)  =>  '\(demo)'")
        }
    }
    let detector = LayoutDetector(validator: SpellWordValidator())
    if let best = detector.bestConversion(of: "akuo", layouts: layouts, currentLayoutID: current) {
        print("Detector: 'akuo' => '\(best.converted)'  (\(best.target.localizedName), score \(best.score))")
    } else {
        print("Detector: no winning conversion for 'akuo' (need Hebrew layout + dict installed)")
    }

    // Optional: --detect "<text>" prints every source->target candidate + score.
    if let i = CommandLine.arguments.firstIndex(of: "--detect"),
       i + 1 < CommandLine.arguments.count {
        let text = CommandLine.arguments[i + 1]
        print("\n--detect input: '\(text)'")
        let v = SpellWordValidator()
        for src in layouts {
            for tgt in layouts where tgt.id != src.id {
                let conv = LayoutMapper.remap(text, from: src, to: tgt)
                let toks = LayoutDetector.wordTokens(conv)
                let valid = toks.filter { v.isValidWord($0, language: tgt.languageCode ?? "") }
                let ratio = toks.isEmpty ? 0 : Double(valid.count) / Double(toks.count)
                print("  \(src.localizedName)->\(tgt.localizedName): '\(conv)'  score=\(ratio)  valid=\(valid)")
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
