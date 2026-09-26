// Lightweight file logger (kept in the shipping build for support/diagnosis).
// Writes to %LOCALAPPDATA%\Wend\Wend.log. Opt-in (off by default) and size-capped, matching
// the macOS build's ~/Library/Logs/Wend.log.
//
// The macOS build creates the file 0600 explicitly. Here the directory is under LocalAppData,
// which the profile's ACL already restricts to the user, so the file inherits that and there
// is nothing to tighten. As on macOS: metadata only, never any substring of the user's text.
//
// That ACL is the whole of the protection, so the path is nil when LOCALAPPDATA is unset
// rather than falling back to the temp directory: the fallback used to resolve somewhere whose
// permissions nothing here had checked. Logging is opt-in diagnostics, so not writing at all is
// the better answer than writing to a directory that might be shared.
//
// Every line also lands in an in-memory trail that is always on, whatever the opt-in says —
// the same trail the macOS build keeps, for the same reason: a problem report needs the moments
// just before it (the ⇧⇧ that didn't take), and asking the user to enable logging first and wait
// for the fault to recur loses exactly those. The trail never touches disk on its own: it is
// written out only inside a report the user chooses to save, and it is gone when Wend exits.

import WinSDK
import Foundation

enum Log {
    static let url: URL? = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map {
        URL(fileURLWithPath: $0)
            .appendingPathComponent("Wend")
            .appendingPathComponent("Wend.log")
    }

    private static let enabledKey = "diagnosticLoggingEnabled"
    private static let maxBytes = 512 * 1024
    private static let trailCapacity = 2000

    /// Diagnostic logging is opt-in — default off, so nothing is written unless the user
    /// enables it (e.g. to capture a repro for feedback).
    static var isEnabled: Bool {
        get { Settings.bool(enabledKey) }
        set { Settings.setBool(enabledKey, newValue) }
    }

    // Milliseconds matter here: a double-tap is judged on 300/400 ms windows, and a
    // seconds-only stamp can't tell a slow second tap from a missed one.
    nonisolated(unsafe) private static let stampFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var trail: [String] = []
    nonisolated(unsafe) private static var trailDropped = 0

    /// Some lines now come from inside the low-level keyboard hook, which Windows removes if it
    /// is slow to return. Appending to the trail is a lock and an array append; the file write —
    /// open, seek, write, maybe rotate, possibly behind an antivirus scan — goes to this queue
    /// so the hook never waits on it. Serial, so lines still land in order.
    private static let diskQueue = DispatchQueue(label: "wend.log")

    static func write(_ message: String) {
        lock.lock()
        let line = "\(stampFormat.string(from: Date()))  \(message)\r\n"
        if trail.count >= trailCapacity {
            trail.removeFirst(trail.count - trailCapacity + 1)
            trailDropped += 1
        }
        trail.append(line)
        lock.unlock()

        // The opt-in is a registry read, so it's checked on the queue too, not here: this can be
        // running inside the keyboard hook.
        diskQueue.async {
            if isEnabled { append(line) }
        }
    }

    /// The in-memory trail, oldest first, with a note when its cap has already dropped lines.
    static func trailSnapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        let note = trailDropped > 0
            ? "(trail capped at \(trailCapacity) lines; \(trailDropped) older lines dropped)\r\n"
            : ""
        return note + trail.joined()
    }

    /// Wait for queued file writes, so a report saved right after a line was logged carries it.
    static func flush() {
        diskQueue.sync {}
    }

    private static func append(_ line: String) {
        guard let url, let data = line.data(using: .utf8) else { return }

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
        guard let url else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .intValue ?? 0
        guard size > maxBytes, let data = try? Data(contentsOf: url) else { return }
        try? data.suffix(maxBytes / 2).write(to: url, options: .atomic)
    }
}
