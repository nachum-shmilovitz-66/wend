// LayoutMapper: rewrite text typed under one layout into what the same physical keys
// would have produced under another layout. This is the language-agnostic core trick —
// it never knows "Hebrew" or "German", only physical-key identity.

public enum LayoutMapper {
    /// Re-map `text` as if the same physical keys were pressed under `target` instead of `source`.
    ///
    /// For each character: find which key produces it under `source`, then ask `target`
    /// what that key produces. Characters with no key in `source` (spaces, digits,
    /// punctuation shared across layouts) pass through unchanged.
    public static func remap(_ text: String, from source: LayoutTable, to target: LayoutTable) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for char in text {
            if let stroke = source.keyStroke(for: char),
               let mapped = target.character(for: stroke) {
                out.append(mapped)
            } else {
                out.append(char)
            }
        }
        return out
    }
}
