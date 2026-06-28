// WordValidator: abstracts "is this a real word in language X?" so Core stays free of
// any platform spell-checker. macOS injects an NSSpellChecker-backed impl; a future
// Windows build would inject a Windows-spellcheck or Hunspell-backed one.

public protocol WordValidator {
    /// True if `word` is a recognized word in `language` (BCP-47, e.g. "en", "he", "de").
    func isValidWord(_ word: String, language: String) -> Bool
}
