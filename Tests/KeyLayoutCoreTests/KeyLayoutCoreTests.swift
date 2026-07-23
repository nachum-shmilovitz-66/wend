import XCTest
@testable import KeyLayoutCore

// Fixed layout tables built on shared, arbitrary-but-stable key codes (physical key
// index a=0 ... z=25). Same code = same physical key across layouts, which is all the
// mapper needs. No system / UCKeyTranslate dependency -> fully deterministic.

private func upper(_ c: Character) -> Character { Character(String(c).uppercased()) }

private func makeTable(
    id: String, name: String, lang: String?,
    base: [Character], includeShift: Bool
) -> LayoutTable {
    var entries: [(KeyStroke, Character)] = []
    for (i, ch) in base.enumerated() {
        entries.append((KeyStroke(keyCode: UInt16(i)), ch))
        if includeShift {
            entries.append((KeyStroke(keyCode: UInt16(i), shift: true), upper(ch)))
        }
    }
    return LayoutTable(id: id, localizedName: name, languageCode: lang, entries: entries)
}

// US QWERTY: physical keys a..z produce a..z.
private let usBase = Array("abcdefghijklmnopqrstuvwxyz")
// German QWERTZ: same as US except the y/z physical keys are swapped.
private let deBase: [Character] = {
    var b = usBase
    b[24] = "z"  // physical 'y' key -> 'z'
    b[25] = "y"  // physical 'z' key -> 'y'
    return b
}()
// Hebrew standard layout: physical keys a..z produce these letters.
private let heBase = Array("שנבגקכעיןחלךצמםפ/רדאוה'סטז")

private let us = makeTable(id: "test.US", name: "U.S.", lang: "en", base: usBase, includeShift: true)
private let de = makeTable(id: "test.DE", name: "German", lang: "de", base: deBase, includeShift: true)
private let he = makeTable(id: "test.HE", name: "Hebrew", lang: "he", base: heBase, includeShift: false)

// Tiny dictionary so detection is deterministic.
private struct MockValidator: WordValidator {
    let words: [String: Set<String>]
    func isValidWord(_ word: String, language: String) -> Bool {
        words[language]?.contains(word.lowercased()) ?? false
    }
}

private let validator = MockValidator(words: [
    "en": ["hello", "world", "two"],
    "he": ["שלום", "עולם"],
    "de": ["zwei", "welt"],
])

final class LayoutMapperTests: XCTestCase {

    func testHebrewWordTypedInEnglish() {
        // Intending שלום (keys a,k,u,o) but US layout active -> "akuo".
        XCTAssertEqual(LayoutMapper.remap("akuo", from: us, to: he), "שלום")
    }

    func testGermanYZSwap() {
        // Intending "zwei" but US active -> "ywei".
        XCTAssertEqual(LayoutMapper.remap("ywei", from: us, to: de), "zwei")
    }

    func testShiftPreservedAcrossLayouts() {
        // Capital handled because shift is part of the key stroke.
        XCTAssertEqual(LayoutMapper.remap("Ywei", from: us, to: de), "Zwei")
    }

    func testRoundTripIsStable() {
        let gibberish = "akuo"
        let hebrew = LayoutMapper.remap(gibberish, from: us, to: he)
        XCTAssertEqual(LayoutMapper.remap(hebrew, from: he, to: us), gibberish)
    }

    func testUnmappedCharactersPassThrough() {
        // Spaces / digits aren't in any layout's letter map -> unchanged.
        XCTAssertEqual(LayoutMapper.remap("akuo 12", from: us, to: he), "שלום 12")
    }
}

final class PlainTextHTMLTests: XCTestCase {
    func testLineBreaksBecomeBrTags() {
        XCTAssertEqual(PlainTextHTML.fragment(for: "one\ntwo"), "one<br>two")
        XCTAssertEqual(PlainTextHTML.fragment(for: "a\nb\nc"), "a<br>b<br>c")
    }

    /// CRLF is one Character in Swift, so it must not produce two breaks.
    func testCarriageReturnsCountAsOneBreak() {
        XCTAssertEqual(PlainTextHTML.fragment(for: "one\r\ntwo"), "one<br>two")
        XCTAssertEqual(PlainTextHTML.fragment(for: "one\rtwo"), "one<br>two")
    }

    func testMarkupCharactersAreEscaped() {
        XCTAssertEqual(PlainTextHTML.fragment(for: "a<b>&c"), "a&lt;b&gt;&amp;c")
        XCTAssertEqual(PlainTextHTML.fragment(for: "\"x\" 'y'"), "&quot;x&quot; &#39;y&#39;")
    }

    /// Hebrew (and any non-ASCII) passes through untouched — the flavor is UTF-8.
    func testNonASCIIPassesThrough() {
        XCTAssertEqual(PlainTextHTML.fragment(for: "שלום\nעולם"), "שלום<br>עולם")
    }

    func testEmptyAndPlainTextUnchanged() {
        XCTAssertEqual(PlainTextHTML.fragment(for: ""), "")
        XCTAssertEqual(PlainTextHTML.fragment(for: "hello world"), "hello world")
    }

    /// A markup character carrying a combining mark is one Character but must still be
    /// escaped — escaping is per scalar, so no raw "<" or "&" can reach the fragment.
    func testMarkupCharacterWithCombiningMarkIsEscaped() {
        XCTAssertEqual(PlainTextHTML.fragment(for: "<\u{0301}img"), "&lt;\u{0301}img")
        XCTAssertEqual(PlainTextHTML.fragment(for: "&\u{0301}amp"), "&amp;\u{0301}amp")
        XCTAssertFalse(PlainTextHTML.fragment(for: "<\u{200D}b>").contains("<b"))
    }
}

final class HTMLPlainTextTests: XCTestCase {
    /// The exact payload Google Chat puts on the clipboard for a two-line selection —
    /// captured from the real pasteboard while diagnosing the lost-newline report.
    func testGoogleChatDivBlocks() {
        let html = "<meta charset='utf-8'><span><div>first line </div><div>second line </div></span>"
        XCTAssertEqual(HTMLPlainText.text(from: html), "first line \nsecond line ")
    }

    func testBrBecomesNewline() {
        XCTAssertEqual(HTMLPlainText.text(from: "one<br>two"), "one\ntwo")
        XCTAssertEqual(HTMLPlainText.text(from: "one<br/>two"), "one\ntwo")
        XCTAssertEqual(HTMLPlainText.text(from: "one<br />two"), "one\ntwo")
    }

    /// A block open emits a break only when text precedes it — no leading or trailing blank
    /// lines, and nesting doesn't double up.
    func testBlockEdgesDoNotProduceBlankLines() {
        XCTAssertEqual(HTMLPlainText.text(from: "<div>a</div>"), "a")
        XCTAssertEqual(HTMLPlainText.text(from: "<div><div>a</div></div>"), "a")
        XCTAssertEqual(HTMLPlainText.text(from: "<p>a</p><p>b</p>"), "a\nb")
    }

    func testEntitiesAreDecoded() {
        XCTAssertEqual(HTMLPlainText.text(from: "a&amp;b&lt;c&gt;d"), "a&b<c>d")
        XCTAssertEqual(HTMLPlainText.text(from: "&quot;x&quot; &#39;y&#39;"), "\"x\" 'y'")
        XCTAssertEqual(HTMLPlainText.text(from: "&#1513;&#x5DC;"), "של")
    }

    /// A bare ampersand is text, not a truncated entity, and must not swallow what follows.
    func testBareAmpersandSurvives() {
        XCTAssertEqual(HTMLPlainText.text(from: "a & b"), "a & b")
        XCTAssertEqual(HTMLPlainText.text(from: "a &notanentity; b"), "a &notanentity; b")
    }

    func testAttributesAndQuotedAngleBracketsAreStripped() {
        XCTAssertEqual(HTMLPlainText.text(from: "<span class='x>y'>text</span>"), "text")
        XCTAssertEqual(HTMLPlainText.text(from: "<a href=\"http://e.com\">link</a>"), "link")
    }

    func testScriptAndStyleContentIsDropped() {
        XCTAssertEqual(HTMLPlainText.text(from: "a<script>var x = 1;</script>b"), "ab")
        XCTAssertEqual(HTMLPlainText.text(from: "a<style>.c { color: red }</style>b"), "ab")
    }

    /// Round-trips with its inverse, which is what the clipboard actually does.
    func testRoundTripWithPlainTextHTML() {
        let text = "שלום עולם\nsecond & <third>"
        XCTAssertEqual(HTMLPlainText.text(from: PlainTextHTML.fragment(for: text)), text)
    }

    func testUnterminatedTagDoesNotHang() {
        XCTAssertEqual(HTMLPlainText.text(from: "text<div"), "text")
        XCTAssertEqual(HTMLPlainText.text(from: ""), "")
    }
}

final class LayoutDetectorTests: XCTestCase {
    private let detector = LayoutDetector(validator: validator)
    private let layouts = [us, de, he]

    func testDetectsHebrewFromGibberish() {
        let result = detector.bestConversion(of: "akuo", layouts: layouts, currentLayoutID: us.id)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.converted, "שלום")
        XCTAssertEqual(result?.target.id, he.id)
    }

    func testMultiWord() {
        // "שלום עולם" -> keys a,k,u,o / g,u,k,o -> "akuo guko".
        let result = detector.bestConversion(of: "akuo guko", layouts: layouts, currentLayoutID: us.id)
        XCTAssertEqual(result?.converted, "שלום עולם")
        XCTAssertEqual(result?.score ?? 0, 1.0, accuracy: 0.0001)
    }

    func testGermanDetection() {
        let result = detector.bestConversion(of: "ywei", layouts: layouts, currentLayoutID: us.id)
        XCTAssertEqual(result?.converted, "zwei")
        XCTAssertEqual(result?.target.id, de.id)
    }

    func testLeavesCorrectTextAlone() {
        // "hello" is already valid English -> no conversion should win.
        XCTAssertNil(detector.bestConversion(of: "hello", layouts: layouts, currentLayoutID: us.id))
    }

    func testNilWhenNothingValid() {
        XCTAssertNil(detector.bestConversion(of: "xqzj", layouts: layouts, currentLayoutID: us.id))
    }

    // MARK: - Source selection / regression coverage

    /// Regression: after a fix, "Switch Layout After Fix" makes the active layout the
    /// target. Undoing and re-fixing the same gibberish must still convert it, even though
    /// the active layout is no longer the layout the text was typed under. (Previously the
    /// detector tried only the active layout as a source and returned nothing.)
    func testConvertsWhenActiveLayoutIsNotTheSource() {
        // "akuo" was typed under US, but the active layout is now Hebrew (the prior target).
        let result = detector.bestConversion(of: "akuo", layouts: layouts, currentLayoutID: he.id)
        XCTAssertEqual(result?.converted, "שלום")
        XCTAssertEqual(result?.source.id, us.id)
        XCTAssertEqual(result?.target.id, he.id)
    }

    /// Same property for the German case (active layout = German, text typed under US).
    func testGermanReFixAfterLayoutSwitch() {
        let result = detector.bestConversion(of: "ywei", layouts: layouts, currentLayoutID: de.id)
        XCTAssertEqual(result?.converted, "zwei")
        XCTAssertEqual(result?.source.id, us.id)
    }

    /// With no active-layout hint, every layout is tried as a source.
    func testDetectsWithoutCurrentLayoutHint() {
        let result = detector.bestConversion(of: "akuo", layouts: layouts, currentLayoutID: nil)
        XCTAssertEqual(result?.converted, "שלום")
    }

    /// An unknown currentLayoutID is ignored (treated as no hint), not a hard filter.
    func testUnknownCurrentLayoutIDStillConverts() {
        let result = detector.bestConversion(of: "akuo", layouts: layouts, currentLayoutID: "test.NOPE")
        XCTAssertEqual(result?.converted, "שלום")
    }

    func testEmptyAndWhitespaceYieldNil() {
        XCTAssertNil(detector.bestConversion(of: "", layouts: layouts, currentLayoutID: us.id))
        XCTAssertNil(detector.bestConversion(of: "   \n\t", layouts: layouts, currentLayoutID: us.id))
        XCTAssertNil(detector.bestConversion(of: "12 34!", layouts: layouts, currentLayoutID: us.id))
    }

    /// A single layout (or a layout with no language) gives nothing to convert to.
    func testNoConversionWithFewerThanTwoLanguages() {
        XCTAssertNil(detector.bestConversion(of: "akuo", layouts: [us], currentLayoutID: us.id))
    }

    /// Regression: a conversion that ties the original's score is still offered. Real case
    /// was "re ehcbv" -> "רק קיבנה" — one valid token on each side, 0.5 vs 0.5 — which the
    /// old strict-improvement rule rejected, so the fix silently did nothing.
    func testTiedScoreStillConverts() {
        // "hello akuo": valid EN tokens 1/2, and converting US->HE also gives 1/2 ("שלום").
        let result = detector.bestConversion(of: "hello akuo", layouts: layouts, currentLayoutID: us.id)
        XCTAssertEqual(result?.target.id, he.id)
        XCTAssertEqual(result?.score ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result?.converted.hasSuffix("שלום"), true)
    }

    /// The tie rule must not fire on text that already reads perfectly.
    func testFullyValidTextStillLeftAlone() {
        XCTAssertNil(detector.bestConversion(of: "hello world", layouts: layouts, currentLayoutID: us.id))
    }

    /// Threshold: a partly-valid conversion below 0.5 is rejected.
    func testBelowThresholdRejected() {
        // Only 1 of 3 tokens maps to a real word -> ratio 0.33 < 0.5.
        let strict = LayoutDetector(validator: validator, threshold: 0.5)
        XCTAssertNil(strict.bestConversion(of: "akuo xqzj wwww", layouts: layouts, currentLayoutID: us.id))
    }

    // MARK: - Forced conversion (repeat-trigger escalation)

    /// The case that motivated it: a half-typed word no dictionary carries. bestConversion
    /// declines; forcing converts anyway.
    func testForcedConvertsWhatTheDictionaryRejects() {
        // "akuoo" -> "שלומ" — not a word in the mock dictionary, so scoring gives up.
        XCTAssertNil(detector.bestConversion(of: "akuoo", layouts: layouts, currentLayoutID: us.id))
        let forced = detector.forcedConversion(of: "akuoo", layouts: layouts, currentLayoutID: us.id)
        XCTAssertNotNil(forced)
        XCTAssertNotEqual(forced?.converted, "akuoo")
    }

    /// Forcing still prefers a conversion that produces real words when one exists.
    func testForcedPrefersHigherScore() {
        let forced = detector.forcedConversion(of: "akuo", layouts: layouts, currentLayoutID: us.id)
        XCTAssertEqual(forced?.converted, "שלום")
        XCTAssertEqual(forced?.target.id, he.id)
        XCTAssertEqual(forced?.score ?? 0, 1.0, accuracy: 0.0001)
    }

    /// Never "succeeds" by handing back exactly what was selected.
    func testForcedNeverReturnsUnchangedText() {
        for text in ["akuo", "xqzj", "hello"] {
            let forced = detector.forcedConversion(of: text, layouts: layouts, currentLayoutID: us.id)
            XCTAssertNotEqual(forced?.converted, text, "forced conversion left \(text) unchanged")
        }
    }

    func testForcedNeedsTokensAndATarget() {
        XCTAssertNil(detector.forcedConversion(of: "  12 !", layouts: layouts, currentLayoutID: us.id))
        XCTAssertNil(detector.forcedConversion(of: "akuo", layouts: [us], currentLayoutID: us.id))
    }

    func testWordTokensSplitsOnNonLetters() {
        XCTAssertEqual(LayoutDetector.wordTokens("akuo guko 12!"), ["akuo", "guko"])
        XCTAssertEqual(LayoutDetector.wordTokens("  hi-there  "), ["hi", "there"])
        XCTAssertEqual(LayoutDetector.wordTokens(""), [])
    }
}
