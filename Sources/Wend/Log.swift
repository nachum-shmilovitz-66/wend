// Lightweight file logger (kept in the shipping build for support/diagnosis).
// Writes to ~/Library/Logs/Wend.log.
import Foundation

enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Wend.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
