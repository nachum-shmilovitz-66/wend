// ScriptGuard: "are this word's letters written in the script this language uses?".
//
// It exists for the same reason the macOS build consults Locale's exemplar character set: a
// spell-checker asked about a word in a script it can't evaluate tends to answer "correct",
// which would make wrong-layout gibberish look like text that needs no fixing. Checking the
// script first removes that whole class of false positive.
//
// Windows has no exemplar-set API, so this pairs the locale's declared script (LOCALE_SSCRIPTS
// gives ISO 15924 codes — "Hebr;", "Latn;") with a table of the Unicode ranges those scripts
// occupy. Unknown scripts pass: the guard is there to reject a confident wrong answer, not to
// block languages it hasn't heard of.

import WinSDK

enum ScriptGuard {

    /// ISO 15924 code → the ranges of letters written in it. Only the scripts a keyboard
    /// layout is plausibly for; anything missing falls through to "allowed".
    private static let ranges: [String: [ClosedRange<UInt32>]] = [
        "Latn": [0x0041...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF],
        "Grek": [0x0370...0x03FF, 0x1F00...0x1FFF],
        "Cyrl": [0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F],
        "Armn": [0x0530...0x058F],
        "Hebr": [0x0590...0x05FF, 0xFB1D...0xFB4F],
        "Arab": [0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF],
        "Syrc": [0x0700...0x074F],
        "Thaa": [0x0780...0x07BF],
        "Deva": [0x0900...0x097F],
        "Beng": [0x0980...0x09FF],
        "Guru": [0x0A00...0x0A7F],
        "Gujr": [0x0A80...0x0AFF],
        "Orya": [0x0B00...0x0B7F],
        "Taml": [0x0B80...0x0BFF],
        "Telu": [0x0C00...0x0C7F],
        "Knda": [0x0C80...0x0CFF],
        "Mlym": [0x0D00...0x0D7F],
        "Sinh": [0x0D80...0x0DFF],
        "Thai": [0x0E00...0x0E7F],
        "Laoo": [0x0E80...0x0EFF],
        "Tibt": [0x0F00...0x0FFF],
        "Mymr": [0x1000...0x109F],
        "Geor": [0x10A0...0x10FF, 0x2D00...0x2D2F],
        "Hang": [0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF],
        "Ethi": [0x1200...0x137F],
        "Khmr": [0x1780...0x17FF],
        "Hira": [0x3040...0x309F],
        "Kana": [0x30A0...0x30FF],
        "Hani": [0x3400...0x4DBF, 0x4E00...0x9FFF],
    ]

    /// Scripts are a property of the locale, so they are cached per language tag.
    private static var cache: [String: [[ClosedRange<UInt32>]]] = [:]

    /// True if every letter of `word` is written in one of `languageTag`'s scripts.
    static func word(_ word: String, matchesScriptOf languageTag: String) -> Bool {
        let allowed = scriptRanges(for: languageTag)
        guard !allowed.isEmpty else { return true }

        for scalar in word.unicodeScalars where scalar.properties.isAlphabetic {
            let value = scalar.value
            let known = allowed.contains { script in
                script.contains { $0.contains(value) }
            }
            guard known else { return false }
        }
        return true
    }

    private static func scriptRanges(for languageTag: String) -> [[ClosedRange<UInt32>]] {
        if let cached = cache[languageTag] { return cached }

        var result: [[ClosedRange<UInt32>]] = []
        if let scripts = localeScripts(for: languageTag) {
            // "Latn;Cyrl;" — a semicolon-terminated list, so the trailing empty piece is dropped.
            for code in scripts.split(separator: ";") where !code.isEmpty {
                if let script = ranges[String(code)] {
                    result.append(script)
                }
            }
        }
        cache[languageTag] = result
        return result
    }

    private static func localeScripts(for languageTag: String) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 128)
        let written = withWide(languageTag) { name in
            buffer.withUnsafeMutableBufferPointer { output in
                GetLocaleInfoEx(name, DWORD(LOCALE_SSCRIPTS), output.baseAddress,
                                Int32(output.count))
            }
        }
        guard written > 0 else { return nil }
        return stringFromWide(buffer)
    }
}
