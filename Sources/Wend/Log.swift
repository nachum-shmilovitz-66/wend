// Lightweight file logger (kept in the shipping build for support/diagnosis).
// Writes to ~/Library/Logs/Wend.log. Opt-in (off by default) and size-capped — see WND-12.
//
// Every line also lands in an in-memory trail that is always on, whatever the opt-in says.
// A problem report needs the moments just before it — the ⇧⇧ that didn't take — and asking
// the user to enable logging first and then wait for the fault to recur loses exactly those.
// The trail never touches disk on its own: it is written out only inside a report the user
// chooses to save, and it is gone when Wend quits. Same rule as the file: metadata only,
// never any substring of the user's text.
import Foundation

enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Wend.log")

    private static let enabledKey = "diagnosticLoggingEnabled"
    private static let maxBytes = 512 * 1024
    private static let trailCapacity = 2000

    /// Diagnostic logging is opt-in — default off, so nothing is written unless the user
    /// enables it (e.g. to capture a repro for feedback).
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // Milliseconds matter here: a double-tap is judged on 300/400 ms windows, and a
    // seconds-only stamp can't tell a slow second tap from a missed one.
    nonisolated(unsafe) private static let stampFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Guards the trail and the file: Log.write is called from the main thread today, but
    // nothing stops a background caller, and the formatter is shared.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var trail: [String] = []
    nonisolated(unsafe) private static var trailDropped = 0
    nonisolated(unsafe) private static var checkedPermissions = false

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(stampFormat.string(from: Date()))  \(message)\n"
        if trail.count >= trailCapacity {
            trail.removeFirst(trail.count - trailCapacity + 1)
            trailDropped += 1
        }
        trail.append(line)

        guard isEnabled, let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        // Create the log user-only (0600) so it isn't world-readable — it can carry diagnostics.
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else if !checkedPermissions {
            // A log created before the 0600 rule (or copied in) keeps whatever mode it had;
            // tighten it once per launch rather than on every line.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        checkedPermissions = true
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
        rotateIfNeeded()
    }

    /// The in-memory trail, oldest first, with a note when its cap has already dropped lines.
    static func trailSnapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        let note = trailDropped > 0
            ? "(trail capped at \(trailCapacity) lines; \(trailDropped) older lines dropped)\n"
            : ""
        return note + trail.joined()
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
