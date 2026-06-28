// SpellWordValidator (macOS): backs Core's WordValidator with NSSpellChecker, which ships
// dictionaries for English, Hebrew, German, Arabic, and many more. If macOS has no
// dictionary for a language we refuse to validate it, so conversions into unsupported
// languages never win and can't cause a bad auto-swap.

import AppKit
import KeyLayoutCore

final class SpellWordValidator: WordValidator {
    private let checker = NSSpellChecker.shared
    private let available: Set<String>

    init() {
        available = Set(NSSpellChecker.shared.availableLanguages)
    }

    func isValidWord(_ word: String, language: String) -> Bool {
        guard supports(language) else { return false }
        // A correctly-spelled word yields no misspelling range (location == NSNotFound).
        let range = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return range.location == NSNotFound
    }

    /// True if macOS has a spelling dictionary for `language` (exact or region variant).
    private func supports(_ language: String) -> Bool {
        if available.contains(language) { return true }
        return available.contains { $0.hasPrefix(language + "_") || language.hasPrefix($0 + "_") }
    }
}
