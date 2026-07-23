// HTMLPlainText: recover plain text — including line structure — from an HTML fragment.
//
// The inverse of PlainTextHTML, and it exists for one reason: some web editors (Google
// Chat's compose box) put a *flattened* string on the clipboard's plain-text flavor, with
// line breaks replaced by spaces, while the html flavor still carries the structure as
// <div> blocks. Reading the html flavor is the only way to see the line breaks the user
// actually selected.
//
// Deliberately a small hand-rolled scanner rather than NSAttributedString(html:), which is
// WebKit-backed: main-thread-only, orders of magnitude slower, and willing to load remote
// resources referenced by clipboard content from arbitrary apps. Callers are expected to
// verify the result against the plain-text flavor before trusting it.

public enum HTMLPlainText {
    /// Tags that start a new visual line. A block open emits a break only when text already
    /// precedes it, so `<div>a</div><div>b</div>` yields "a\nb" — no leading or trailing blank.
    private static let blockTags: Set<String> = [
        "div", "p", "li", "tr", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
    ]
    /// Content of these is markup machinery, not user-visible text.
    private static let skippedTags: Set<String> = ["script", "style", "head", "title"]

    public static func text(from html: String) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var index = html.startIndex
        var skipUntilCloseOf: String?

        while index < html.endIndex {
            let char = html[index]

            if char == "<" {
                guard let close = tagEnd(in: html, from: index) else { break }
                let (name, isClosing) = tagName(in: html[html.index(after: index)..<close])
                index = html.index(after: close)

                if let skipped = skipUntilCloseOf {
                    if isClosing, name == skipped { skipUntilCloseOf = nil }
                    continue
                }
                if skippedTags.contains(name), !isClosing {
                    skipUntilCloseOf = name
                } else if name == "br" {
                    out.append("\n")
                } else if blockTags.contains(name), !isClosing, !out.isEmpty, out.last != "\n" {
                    out.append("\n")
                }
                continue
            }

            if skipUntilCloseOf != nil {
                index = html.index(after: index)
                continue
            }

            if char == "&", let (entity, next) = entity(in: html, from: index) {
                out += entity
                index = next
                continue
            }

            out.append(char)
            index = html.index(after: index)
        }
        return out
    }

    /// Index of the `>` closing the tag starting at `start`, skipping quoted attribute values.
    private static func tagEnd(in html: String, from start: String.Index) -> String.Index? {
        var index = html.index(after: start)
        var quote: Character?
        while index < html.endIndex {
            let char = html[index]
            if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    /// Lowercased tag name and whether it's a closing tag, from a tag's inner text.
    private static func tagName(in body: Substring) -> (name: String, isClosing: Bool) {
        var text = body
        let isClosing = text.first == "/"
        if isClosing { text = text.dropFirst() }
        let name = text.prefix { $0.isLetter || $0.isNumber }
        return (name.lowercased(), isClosing)
    }

    /// Decoded entity starting at `start`, plus the index just past its `;`.
    private static func entity(in html: String, from start: String.Index) -> (String, String.Index)? {
        // Longest real entity we handle is "&nbsp;" / "&#1234;" — cap the scan so a bare
        // "&" in the text doesn't run away looking for a semicolon.
        let limit = html.index(start, offsetBy: 10, limitedBy: html.endIndex) ?? html.endIndex
        guard let semi = html[start..<limit].firstIndex(of: ";") else { return nil }
        let body = html[html.index(after: start)..<semi]
        let next = html.index(after: semi)

        switch body.lowercased() {
        case "amp": return ("&", next)
        case "lt": return ("<", next)
        case "gt": return (">", next)
        case "quot": return ("\"", next)
        case "apos", "#39": return ("'", next)
        case "nbsp": return ("\u{00A0}", next)
        default: break
        }
        // Numeric: &#123; or &#x7B;
        guard body.first == "#" else { return nil }
        let digits = body.dropFirst()
        let scalarValue: UInt32?
        if digits.first == "x" || digits.first == "X" {
            scalarValue = UInt32(digits.dropFirst(), radix: 16)
        } else {
            scalarValue = UInt32(digits, radix: 10)
        }
        guard let value = scalarValue, let scalar = Unicode.Scalar(value) else { return nil }
        return (String(Character(scalar)), next)
    }
}
