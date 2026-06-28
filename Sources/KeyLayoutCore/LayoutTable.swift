// LayoutTable: a physical-key → character map for one keyboard layout, plus the
// reverse (character → physical key). Platform-agnostic value type — the macOS layer
// fills it from UCKeyTranslate; a future Windows layer would fill it from ToUnicodeEx.
// No Foundation import on purpose, so this whole module ports as-is.

/// One physical key press: a virtual key code plus the modifier state that produced a char.
public struct KeyStroke: Hashable, Sendable {
    public let keyCode: UInt16
    public let shift: Bool
    public let option: Bool

    public init(keyCode: UInt16, shift: Bool = false, option: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
        self.option = option
    }

    /// Fewer modifiers = "simpler" key. Used to prefer the base key when a character
    /// can be produced more than one way (e.g. plain `a` over some option-combo).
    var modifierWeight: Int { (shift ? 1 : 0) + (option ? 2 : 0) }
}

/// A complete keyboard layout: which character each key produces, and the inverse.
public struct LayoutTable: Sendable {
    /// Input-source id, e.g. "com.apple.keylayout.US". Stable identity for "current layout".
    public let id: String
    /// Human-readable name, e.g. "U.S." / "Hebrew".
    public let localizedName: String
    /// Best-effort BCP-47 language code for spell-checking, e.g. "en", "he", "de". May be nil.
    public let languageCode: String?

    /// key press -> produced character
    public let forward: [KeyStroke: Character]
    /// produced character -> the simplest key press that makes it
    public let reverse: [Character: KeyStroke]

    public init(
        id: String,
        localizedName: String,
        languageCode: String?,
        entries: [(KeyStroke, Character)]
    ) {
        self.id = id
        self.localizedName = localizedName
        self.languageCode = languageCode

        var forward: [KeyStroke: Character] = [:]
        var reverse: [Character: KeyStroke] = [:]
        for (stroke, char) in entries {
            forward[stroke] = char
            // When a character is reachable via several keys, keep the one with the
            // fewest modifiers so reverse-mapping picks the natural key.
            if let existing = reverse[char] {
                if stroke.modifierWeight < existing.modifierWeight {
                    reverse[char] = stroke
                }
            } else {
                reverse[char] = stroke
            }
        }
        self.forward = forward
        self.reverse = reverse
    }

    /// The character this layout produces for a given key press.
    public func character(for stroke: KeyStroke) -> Character? { forward[stroke] }

    /// The simplest key press that produces `character` under this layout.
    public func keyStroke(for character: Character) -> KeyStroke? { reverse[character] }
}
