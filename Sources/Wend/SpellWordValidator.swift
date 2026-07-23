// SpellWordValidator (macOS): backs Core's WordValidator with NSSpellChecker, which ships
// dictionaries for English, Hebrew, German, Arabic, and many more.
//
// Two guards keep cross-script false positives out:
//  1. Language must have a macOS dictionary (else we can't validate it).
//  2. The word's letters must belong to the language's script. NSSpellChecker reports a
//     Hebrew word as a *correct* English word (it can't evaluate the foreign script), which
//     would make wrong-layout gibberish look already-valid. The exemplar character set from
//     Locale (general, not hardcoded per language) rejects that.

import AppKit
import KeyLayoutCore

final class SpellWordValidator: WordValidator {
    private let checker = NSSpellChecker.shared
    // Read live (no caching): this object may be built before the app finishes launching,
    // when availableLanguages is still empty; caching then would reject everything.
    private var available: Set<String> { Set(checker.availableLanguages) }
    // Exemplar sets are stable, so cache them per language.
    private var exemplarCache: [String: CharacterSet?] = [:]

    func isValidWord(_ word: String, language: String) -> Bool {
        guard supports(language) else { return false }
        guard wordMatchesScript(word, language: language) else { return false }
        if spelledCorrectly(word, language: language) { return true }

        // Case matters to NSSpellChecker: it rejects "argentina" but accepts "Argentina".
        // Layout conversion reproduces whatever the user typed, so it can't supply the
        // capital — which would leave every lowercase proper noun (countries, cities, names,
        // months) invisible to detection. Only the first letter is raised; `.capitalized`
        // would lower the rest and break names like "McDonald".
        let capitalized = word.prefix(1).uppercased() + word.dropFirst()
        guard capitalized != word else { return false }
        return spelledCorrectly(capitalized, language: language)
    }

    /// A correctly-spelled word yields no misspelling range (location == NSNotFound).
    private func spelledCorrectly(_ word: String, language: String) -> Bool {
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

    /// True if every letter of `word` belongs to `language`'s script. Falls back to true if
    /// the locale exposes no exemplar set (don't block unknown languages).
    private func wordMatchesScript(_ word: String, language: String) -> Bool {
        guard let set = exemplarSet(for: language) else { return true }
        for scalar in word.lowercased().unicodeScalars where CharacterSet.letters.contains(scalar) {
            if !set.contains(scalar) { return false }
        }
        return true
    }

    private func exemplarSet(for language: String) -> CharacterSet? {
        if let cached = exemplarCache[language] { return cached }
        let locale = NSLocale(localeIdentifier: language)
        let set = locale.object(forKey: .exemplarCharacterSet) as? CharacterSet
        exemplarCache[language] = set
        return set
    }
}
