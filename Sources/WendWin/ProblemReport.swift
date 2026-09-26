// ProblemReport (Windows): the zip that "Report a Problem…" saves to the Downloads folder —
// the counterpart of the macOS ProblemReport, sharing its kinds, name, wording, and zip format
// through KeyLayoutCore. This file supplies what only Windows can gather.
//
// Paths are kept as native strings (backslashes) rather than URL paths throughout: Explorer's
// /select switch needs a native path, and Foundation's URL.path on Windows has come back with
// forward slashes, or a leading slash before the drive, depending on the toolchain.

import WinSDK
import Foundation
import KeyLayoutCore

struct ProblemReport {
    let kind: ReportKind
    let details: String
    /// "-- Section --" blocks describing Wend and the machine, assembled by App.
    let facts: String
    let created = Date()

    private static let platform = ReportPlatform(
        copyShortcut: "Ctrl+C",
        logPath: "%LOCALAPPDATA%\\Wend\\Wend.log",
        crashDescription: "Windows Error Reporting entries for Wend from the last 30 days"
    )

    private var timestamp: ReportTimestamp {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: created)
        return ReportTimestamp(year: c.year ?? 1980, month: c.month ?? 1, day: c.day ?? 1,
                               hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }

    /// Build the report and zip it into `folder` (a native path). Returns the zip's native path.
    func save(inFolder folder: String) throws -> String {
        Log.flush()   // the disk log is written on a queue; let it catch up first
        let root = ReportText.baseName(timestamp)
        var zip = ZipWriter(modified: timestamp)
        zip.add("\(root)/report.txt", text: crlf(summary()))
        zip.add("\(root)/trail.log", text: Log.trailSnapshot())
        zip.add("\(root)/settings.txt", text: crlf(settings()))
        if let url = Log.url, let log = FileManager.default.contents(atPath: url.path) {
            zip.add("\(root)/Wend.log", Array(log))
        }
        for (name, data) in recentCrashReports() {
            zip.add("\(root)/crash/\(name).wer", Array(data))
        }

        let destination = uniquePath(in: folder, name: root, ext: "zip")
        try Data(zip.archive()).write(to: URL(fileURLWithPath: destination))
        return destination
    }

    // MARK: - Contents

    private func summary() -> String {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        let utc = ISO8601DateFormatter().string(from: created)
        return ReportText.summary(
            kind: kind,
            created: "\(local.string(from: created))  (\(utc))",
            details: details,
            facts: facts,
            platform: Self.platform
        )
    }

    /// Wend's registry settings. Settings.bool can't tell a missing value from 0, so a value
    /// that was never written reads as 0 here — the defaults are what App applies anyway.
    private func settings() -> String {
        let names = ["switchInputSourceAfterFix", "diagnosticLoggingEnabled", "didInitialLoginItemSetup"]
        var lines = ["HKCU\\Software\\Wend"]
        lines += names.map { "  \($0) = \(Settings.bool($0) ? 1 : 0)" }
        lines.append("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run")
        lines.append("  Wend = \(LaunchAtLogin.isEnabled ? "present" : "absent")")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Report.wer from each recent Wend crash Windows Error Reporting kept, per-user and
    /// machine-wide, newest first. Each is keyed by its folder name, which carries the
    /// faulting module and a hash.
    private func recentCrashReports() -> [(String, Data)] {
        let env = ProcessInfo.processInfo.environment
        let archives = [
            env["LOCALAPPDATA"].map { "\($0)\\Microsoft\\Windows\\WER\\ReportArchive" },
            env["PROGRAMDATA"].map { "\($0)\\Microsoft\\Windows\\WER\\ReportArchive" },
        ].compactMap { $0 }
        let cutoff = created.addingTimeInterval(-30 * 24 * 3600)
        let fm = FileManager.default

        var found: [(name: String, path: String, date: Date)] = []
        for archive in archives {
            for name in (try? fm.contentsOfDirectory(atPath: archive)) ?? []
            where name.lowercased().hasPrefix("appcrash_wend.exe") {
                let dir = "\(archive)\\\(name)"
                let date = (try? fm.attributesOfItem(atPath: dir))?[.modificationDate] as? Date ?? .distantPast
                if date >= cutoff { found.append((name, "\(dir)\\Report.wer", date)) }
            }
        }
        return found
            .sorted { $0.date > $1.date }
            .prefix(5)
            .compactMap { entry in fm.contents(atPath: entry.path).map { (entry.name, $0) } }
    }

    // MARK: - Files

    /// `name.zip`, or `name 2.zip` and so on when a report was already saved that second.
    private func uniquePath(in folder: String, name: String, ext: String) -> String {
        var path = "\(folder)\\\(name).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: path) {
            path = "\(folder)\\\(name) \(n).\(ext)"
            n += 1
        }
        return path
    }

    /// Notepad has read LF since 2018, but not every viewer on every Windows a user might send
    /// this from has; the trail and the disk log are CRLF already.
    private func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// The user's Downloads folder, native path. The registry's User Shell Folders entry is
    /// the one Explorer honours, so a Downloads moved to another drive or into OneDrive is
    /// found; RegGetValue expands its %USERPROFILE%. The profile default is the fallback.
    static func downloadsFolder() -> String? {
        let downloadsID = "{374DE290-123F-4565-9164-39C4925E467B}"   // FOLDERID_Downloads
        if let path = registryString(
            root: hkeyCurrentUser,
            subkey: "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders",
            name: downloadsID
        ), FileManager.default.fileExists(atPath: path) {
            return path
        }
        guard let profile = ProcessInfo.processInfo.environment["USERPROFILE"] else { return nil }
        let fallback = "\(profile)\\Downloads"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }
}
