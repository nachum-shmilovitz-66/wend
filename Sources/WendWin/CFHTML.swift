// CFHTML: the "HTML Format" clipboard wrapper.
//
// Windows doesn't put bare HTML on the clipboard. It puts a UTF-8 payload prefixed by a small
// header of byte offsets into itself, which is why writing one means measuring it first. Core
// deals in plain fragments (PlainTextHTML / HTMLPlainText); this is the envelope around them.

import Foundation

enum CFHTML {

    private static let startMarker = "<!--StartFragment-->"
    private static let endMarker = "<!--EndFragment-->"
    private static let prefix = "<html><body>"
    private static let suffix = "</body></html>"

    /// The fragment inside a CF_HTML payload, or nil if there isn't one to be found.
    ///
    /// The markers are used rather than the header's byte offsets on purpose: the offsets are
    /// counted in bytes over the UTF-8 encoding, and applying them to a Swift String means
    /// converting back and forth for a value the markers give directly. Producers that omit
    /// the markers fall back to the body of the document.
    static func fragment(from payload: String) -> String? {
        if let start = payload.range(of: startMarker),
           let end = payload.range(of: endMarker, range: start.upperBound..<payload.endIndex) {
            return String(payload[start.upperBound..<end.lowerBound])
        }
        if let body = payload.range(of: "<body", options: .caseInsensitive),
           let open = payload.range(of: ">", range: body.upperBound..<payload.endIndex) {
            return String(payload[open.upperBound...])
        }
        return nil
    }

    /// A complete CF_HTML payload carrying `fragment`.
    ///
    /// The four offsets are byte counts into the finished payload, so the header has to be a
    /// fixed width whatever they turn out to be — hence the zero-padded ten-digit fields,
    /// which let the header be measured before its own numbers are known.
    static func document(for fragment: String) -> String {
        let headerLength = header(startHTML: 0, endHTML: 0, startFragment: 0, endFragment: 0)
            .utf8.count

        let startHTML = headerLength
        let startFragment = startHTML + (prefix + startMarker).utf8.count
        let endFragment = startFragment + fragment.utf8.count
        let endHTML = endFragment + (endMarker + suffix).utf8.count

        return header(startHTML: startHTML, endHTML: endHTML,
                      startFragment: startFragment, endFragment: endFragment)
            + prefix + startMarker + fragment + endMarker + suffix
    }

    private static func header(
        startHTML: Int,
        endHTML: Int,
        startFragment: Int,
        endFragment: Int
    ) -> String {
        "Version:0.9\r\n"
            + "StartHTML:\(padded(startHTML))\r\n"
            + "EndHTML:\(padded(endHTML))\r\n"
            + "StartFragment:\(padded(startFragment))\r\n"
            + "EndFragment:\(padded(endFragment))\r\n"
    }

    /// Ten digits, zero-padded — the width the offsets are declared at.
    private static func padded(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count < 10 else { return digits }
        return String(repeating: "0", count: 10 - digits.count) + digits
    }
}
