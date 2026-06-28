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
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
