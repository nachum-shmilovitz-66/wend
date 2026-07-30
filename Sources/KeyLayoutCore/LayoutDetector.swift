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

    public init(validator: WordValidator, threshold: Double = 0.5) {
        self.validator = validator
        self.threshold = threshold
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

        // Nothing in the text reads as a word in any installed language, so the dictionary has
        // no evidence either way and the threshold has nothing to measure. Declining here is
        // what made the fix appear dead on words no dictionary carries — a proper noun or its
        // prefix ("gdut" on the way to GDUtility), an acronym, a search fragment — while the
        // user could see perfectly well that the text was wrong. Convert on the same evidence
        // the forced path uses: highest score, then the pair changing the most characters.
        // A conversion that turns out to be unwanted is undone by fixing again, since the
        // result is equally scoreless and maps straight back.
        if originalScore == 0 {
            return forcedConversion(of: text, layouts: layouts, currentLayoutID: currentLayoutID)
        }

        // Invoking the fix is an explicit "this text is wrong" from the user, so a conversion
        // that merely ties the original is still offered. Requiring a strict improvement used
        // to lose the common two-token case where exactly one token is valid on each side
        // ("re ehcbv" -> "רק קיבנה": 0.5 vs 0.5), which failed silently. Text that already
        // reads perfectly is still left untouched, and a conversion is never a step backwards.
        guard let candidate = best,
              candidate.score >= threshold,
              originalScore < 1.0,
              candidate.score >= originalScore
        else { return nil }
        return candidate
    }

    /// Best conversion ignoring the dictionary entirely — for when the user insists the text
    /// is wrong after `bestConversion` declined (a half-typed word, a search fragment, a
    /// proper noun no dictionary carries). Never returns a candidate that leaves the text
    /// unchanged, so it can't "succeed" by pasting back exactly what was selected.
    ///
    /// Still prefers the highest-scoring pair, so when some conversion does produce real
    /// words that one wins; scoreless ties fall to the pair that changes the most characters,
    /// then to the active layout as the source.
    public func forcedConversion(
        of text: String,
        layouts: [LayoutTable],
        currentLayoutID: String? = nil
    ) -> ConversionCandidate? {
        let tokens = Self.wordTokens(text)
        guard !tokens.isEmpty else { return nil }

        var sources = layouts
        if let id = currentLayoutID, let idx = sources.firstIndex(where: { $0.id == id }) {
            sources.insert(sources.remove(at: idx), at: 0)
        }

        var best: ConversionCandidate?
        var bestChanged = 0
        for source in sources {
            for target in layouts where target.id != source.id {
                let converted = LayoutMapper.remap(text, from: source, to: target)
                guard converted != text else { continue }
                let score = target.languageCode.map { validRatio(Self.wordTokens(converted), language: $0) } ?? 0
                let changed = zip(text, converted).reduce(0) { $1.0 == $1.1 ? $0 : $0 + 1 }
                if best == nil || score > best!.score || (score == best!.score && changed > bestChanged) {
                    best = ConversionCandidate(source: source, target: target, converted: converted, score: score)
                    bestChanged = changed
                }
            }
        }
        return best
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
