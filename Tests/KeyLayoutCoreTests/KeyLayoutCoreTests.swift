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
}
