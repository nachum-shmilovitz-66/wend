// ZipWriter: the smallest zip archive that Finder, Windows Explorer, and `unzip` all open —
// stored (uncompressed) entries, UTF-8 names, no data descriptors, no zip64.
//
// Here rather than in each app because Windows has no zip call that works on every SKU a
// user might run Wend on (`tar.exe` is absent before Windows 10 1803 and Server 2019, and
// PowerShell's Compress-Archive is a subprocess and a policy question), and a report is small
// enough — a few hundred KB of text — that compression buys nothing worth a dependency. Both
// apps use it, so the one the Mac build exercises is the one Windows ships.

public struct ZipWriter {
    private struct Record {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var body: [UInt8] = []
    private var records: [Record] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    /// `modified` stamps every entry; zip stores local wall-clock time with 2-second resolution.
    public init(modified: ReportTimestamp) {
        dosTime = UInt16((modified.hour << 11) | (modified.minute << 5) | (modified.second / 2))
        dosDate = UInt16((max(modified.year - 1980, 0) << 9) | (modified.month << 5) | modified.day)
    }

    /// Add a file. `path` uses `/` separators; folders are implied by the paths in them.
    public mutating func add(_ path: String, _ data: [UInt8]) {
        let name = Array(path.utf8)
        let crc = Self.crc32(data)
        let record = Record(name: name, crc: crc, size: UInt32(data.count), offset: UInt32(body.count))

        append32(&body, 0x0403_4b50)          // local file header
        append16(&body, 20)                   // version needed: 2.0
        append16(&body, Self.utf8NamesFlag)
        append16(&body, 0)                    // method: stored
        append16(&body, dosTime)
        append16(&body, dosDate)
        append32(&body, crc)
        append32(&body, record.size)          // compressed size = size, when stored
        append32(&body, record.size)
        append16(&body, UInt16(name.count))
        append16(&body, 0)                    // extra field length
        body += name
        body += data

        records.append(record)
    }

    public mutating func add(_ path: String, text: String) {
        add(path, Array(text.utf8))
    }

    /// The finished archive.
    public func archive() -> [UInt8] {
        var directory: [UInt8] = []
        for r in records {
            append32(&directory, 0x0201_4b50)     // central directory header
            append16(&directory, 20)              // made by: MS-DOS attributes, 2.0
            append16(&directory, 20)              // version needed
            append16(&directory, Self.utf8NamesFlag)
            append16(&directory, 0)               // stored
            append16(&directory, dosTime)
            append16(&directory, dosDate)
            append32(&directory, r.crc)
            append32(&directory, r.size)
            append32(&directory, r.size)
            append16(&directory, UInt16(r.name.count))
            append16(&directory, 0)               // extra
            append16(&directory, 0)               // comment
            append16(&directory, 0)               // disk number
            append16(&directory, 0)               // internal attributes
            append32(&directory, 0)               // external attributes: plain file
            append32(&directory, r.offset)
            directory += r.name
        }

        var end: [UInt8] = []
        append32(&end, 0x0605_4b50)               // end of central directory
        append16(&end, 0)                         // this disk
        append16(&end, 0)                         // disk with the directory
        append16(&end, UInt16(records.count))
        append16(&end, UInt16(records.count))
        append32(&end, UInt32(directory.count))
        append32(&end, UInt32(body.count))        // directory starts right after the entries
        append16(&end, 0)                         // comment length

        return body + directory + end
    }

    /// General-purpose bit 11: names are UTF-8, so a non-ASCII name (a Hebrew folder in a
    /// report path, one day) doesn't come out as mojibake.
    private static let utf8NamesFlag: UInt16 = 0x0800

    // MARK: - CRC-32 (IEEE 802.3, the one zip uses)

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// Zip is little-endian throughout.
private func append16(_ out: inout [UInt8], _ v: UInt16) {
    out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8))
}

private func append32(_ out: inout [UInt8], _ v: UInt32) {
    for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((v >> UInt32(shift)) & 0xFF)) }
}
