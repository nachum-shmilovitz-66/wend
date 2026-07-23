// PlainTextHTML: render plain text as a minimal, style-free HTML fragment.
//
// Lives in Core (not the macOS layer) purely so it stays unit-testable and dependency-free —
// it's plain string work, no AppKit. Used for the clipboard's `html` flavor: some web editors
// (Google Chat's compose box) collapse a bare LF coming from the plain-text flavor into a
// single line, while `<br>` is unambiguous.

public enum PlainTextHTML {
    /// `text` as an HTML fragment: markup-significant characters escaped, line breaks as `<br>`.
    ///
    /// Carries no styling — the receiving editor applies its own. CRLF and a lone CR count as
    /// one break, matching how the text would render.
    public static func fragment(for text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        // Line breaks are decided per Character (so CRLF is one break, not two), but escaping
        // is decided per scalar: "<" carrying a combining mark is a single Character that
        // isn't == "<", which would otherwise emit a raw "<" into the fragment.
        for char in text {
            if char.isNewline {
                out += "<br>"
                continue
            }
            for scalar in char.unicodeScalars {
                switch scalar {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                case "'": out += "&#39;"
                default: out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
