// Lightweight file logger (kept in the shipping build for support/diagnosis).
// Writes to %LOCALAPPDATA%\Wend\Wend.log. Opt-in (off by default) and size-capped, matching
// the macOS build's ~/Library/Logs/Wend.log.
//
// The macOS build creates the file 0600 explicitly. Here the directory is under LocalAppData,
// which the profile's ACL already restricts to the user, so the file inherits that and there
// is nothing to tighten. As on macOS: metadata only, never any substring of the user's text.

import WinSDK
import Foundation

enum Log {
    static let url: URL = {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base)
            .appendingPathComponent("Wend")
            .appendingPathComponent("Wend.log")
    }()

    private static let enabledKey = "diagnosticLoggingEnabled"
    private static let maxBytes = 512 * 1024

    /// Diagnostic logging is opt-in — default off, so nothing is written unless the user
    /// enables it (e.g. to capture a repro for feedback).
    static var isEnabled: Bool {
        get { Settings.bool(enabledKey) }
        set { Settings.setBool(enabledKey, newValue) }
    }

    static func write(_ message: String) {
        guard isEnabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\r\n"
        guard let data = line.data(using: .utf8) else { return }

        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !manager.fileExists(atPath: url.path) {
            _ = manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
        rotateIfNeeded()
    }

    /// Keep the log bounded: when it exceeds the cap, trim to the most recent half.
    private static func rotateIfNeeded() {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .intValue ?? 0
        guard size > maxBytes, let data = try? Data(contentsOf: url) else { return }
        try? data.suffix(maxBytes / 2).write(to: url, options: .atomic)
    }
}
