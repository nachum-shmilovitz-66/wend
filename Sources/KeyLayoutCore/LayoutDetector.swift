// LayoutDetector: given gibberish and the set of installed layouts, decide the most
// likely (source -> target) re-mapping by checking which conversion yields the most
// real words. Language-agnostic: it asks the injected WordValidator per target language.

public struct ConversionCandidate: Sendable {
    public let source: LayoutTable
    public let target: LayoutTable
    public let converted: String
    /// Fraction of word tokens that are valid in the target language (0...1).
    public let score: Double
}

public struct LayoutDetector {
    public let validator: WordValidator
    /// Minimum valid-word ratio for a conversion to be offered at all.
    public let threshold: Double
    /// Converted text must beat the original's own validity by at least this much,
    /// so already-correct text is left untouched.
    public let improvementMargin: Double

    public init(validator: WordValidator, threshold: Double = 0.5, improvementMargin: Double = 0.0001) {
        self.validator = validator
        self.threshold = threshold
        self.improvementMargin = improvementMargin
    }

    /// Best conversion for `text`, or nil if nothing beats leaving it as-is.
    ///
    /// - currentLayoutID: the active layout when the user typed. Used only as a tie-breaker
    ///   (tried first, so it wins equal scores). Every layout is still tried as a source:
    ///   the active layout isn't a reliable source — after a fix that switches the layout,
    ///   or any manual switch, the selected text's characters no longer came out of it, and
    ///   restricting to it would miss the real conversion (re-fixing after undo would fail).
    public func bestConversion(
        of text: String,
        layouts: [LayoutTable],
        currentLayoutID: String? = nil
    ) -> ConversionCandidate? {
        let tokens = Self.wordTokens(text)
        guard !tokens.isEmpty else { return nil }

        // How well does the text already read as some real language?
        var originalScore = 0.0
        for layout in layouts {
            guard let lang = layout.languageCode else { continue }
            originalScore = max(originalScore, validRatio(tokens, language: lang))
        }

        // Try every layout as a source, with the current one first so it wins ties.
        var sources = layouts
        if let id = currentLayoutID, let idx = sources.firstIndex(where: { $0.id == id }) {
            sources.insert(sources.remove(at: idx), at: 0)
        }

        var best: ConversionCandidate?
        for source in sources {
            for target in layouts where target.id != source.id {
                guard let lang = target.languageCode else { continue }
                let converted = LayoutMapper.remap(text, from: source, to: target)
                let score = validRatio(Self.wordTokens(converted), language: lang)
                if best == nil || score > best!.score {
                    best = ConversionCandidate(source: source, target: target, converted: converted, score: score)
                }
            }
        }

        guard let candidate = best,
              candidate.score >= threshold,
              candidate.score > originalScore + improvementMargin
        else { return nil }
        return candidate
    }

    /// Fraction of tokens recognized as words in `language`.
    private func validRatio(_ tokens: [String], language: String) -> Double {
        guard !tokens.isEmpty else { return 0 }
        var valid = 0
        for token in tokens where validator.isValidWord(token, language: language) {
            valid += 1
        }
        return Double(valid) / Double(tokens.count)
    }

    /// Split into runs of letters; drops whitespace, digits, and punctuation.
    public static func wordTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in text {
            if char.isLetter {
                current.append(char)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
