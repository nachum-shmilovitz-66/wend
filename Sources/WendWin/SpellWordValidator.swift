// SpellWordValidator (Windows): backs Core's WordValidator with the Windows Spell Checking
// API, reached through the CWinSpell shim.
//
// Two guards keep cross-script false positives out, the same two the macOS build applies:
//  1. Windows must actually have a dictionary for the language (else we can't validate it).
//  2. The word's letters must belong to that language's script — see ScriptGuard.
//
// One Windows-specific wrinkle: the API is keyed by full BCP-47 tags ("he-IL"), while Core
// speaks in primary languages ("he"), so the tag has to be resolved against what is installed.
// Windows ships fewer dictionaries than macOS and gates most of them behind an optional
// language feature, so on a bare install this will validate English and nothing else — which
// degrades to "no conversion wins", not to a wrong conversion.

import CWinSpell
import WinSDK
import KeyLayoutCore

final class SpellWordValidator: WordValidator {

    /// Primary language → the installed tag to ask about, or nil if there is none. Cached
    /// because resolving means enumerating everything Windows supports.
    private var resolvedTags: [String: String?] = [:]

    func isValidWord(_ word: String, language: String) -> Bool {
        guard let tag = tag(for: language) else { return false }
        guard ScriptGuard.word(word, matchesScriptOf: tag) else { return false }
        if check(word, tag: tag) { return true }

        // Case matters to the spell-checker: it rejects "argentina" but accepts "Argentina".
        // Layout conversion reproduces whatever the user typed, so it can't supply the capital
        // — which would leave every lowercase proper noun (countries, cities, names, months)
        // invisible to detection. Only the first letter is raised; `.capitalized` would lower
        // the rest and break names like "McDonald".
        let capitalized = word.prefix(1).uppercased() + word.dropFirst()
        guard capitalized != word else { return false }
        return check(capitalized, tag: tag)
    }

    private func check(_ word: String, tag: String) -> Bool {
        withWide(tag) { tagBuffer in
            withWide(word) { wordBuffer in
                // -1 means it couldn't be checked, which is no evidence that it is a word.
                wend_spell_check(tagBuffer, wordBuffer) == 1
            }
        }
    }

    /// The installed tag to use for a primary language, e.g. "he" → "he-IL".
    private func tag(for language: String) -> String? {
        if let cached = resolvedTags[language] { return cached }

        let installed = Self.supportedTags()
        // Nothing came back — the factory may not be up yet. Don't cache that as "unsupported",
        // or the first call would poison every later one.
        guard !installed.isEmpty else { return nil }

        let match = installed.first { $0 == language }
            ?? installed.first { $0.hasPrefix(language + "-") }
        resolvedTags[language] = match
        return match
    }

    /// The dictionaries Windows actually has. Surfaced by `--dump-layouts` because a score of
    /// zero across the board almost always means "no dictionary for that language" rather than
    /// anything wrong with the conversion, and the two are indistinguishable from the outside.
    static func installedDictionaries() -> [String] {
        supportedTags()
    }

    private static func supportedTags() -> [String] {
        var buffer = [WCHAR](repeating: 0, count: 4096)
        let written = buffer.withUnsafeMutableBufferPointer {
            wend_spell_languages($0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return [] }
        return stringFromWide(buffer).split(separator: "\n").map(String.init)
    }
}
