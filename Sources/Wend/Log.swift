// Lightweight file logger (kept in the shipping build for support/diagnosis).
// Writes to ~/Library/Logs/Wend.log. Opt-in (off by default) and size-capped — see WND-12.
import Foundation

enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Wend.log")

    private static let enabledKey = "diagnosticLoggingEnabled"
    private static let maxBytes = 512 * 1024

    /// Diagnostic logging is opt-in — default off, so nothing is written unless the user
    /// enables it (e.g. to capture a repro for feedback).
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func write(_ message: String) {
        guard isEnabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        // Create the log user-only (0600) so it isn't world-readable — it can carry diagnostics.
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
        rotateIfNeeded()
    }

    /// Keep the log bounded: when it exceeds the cap, trim to the most recent half.
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard size > maxBytes, let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(maxBytes / 2)
        try? tail.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
