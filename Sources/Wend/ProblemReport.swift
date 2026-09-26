// ProblemReport (macOS): the zip that "Report a Problem…" saves to ~/Downloads.
//
// It is written to be read cold, by someone who wasn't there: the user's own description,
// the state of the machine and of Wend when it was saved, the always-on in-memory trail (the
// ⇧ taps, decisions and scores leading up to the problem), the opt-in disk log, Wend's saved
// preferences, and any recent Wend crash reports. Like the logs it carries, nothing in it is
// derived from the user's text — the one exception is the description they typed into the
// report themselves.
//
// The kinds, the name, the summary's wording and the zip format come from KeyLayoutCore, which
// the Windows build shares; this file supplies what only a Mac can gather.

import Foundation
import KeyLayoutCore

struct ProblemReport {
    let kind: ReportKind
    let details: String
    /// "-- Section --" blocks describing Wend and the machine, assembled by AppDelegate.
    let facts: String
    let created = Date()

    private static let platform = ReportPlatform(
        copyShortcut: "⌘C",
        logPath: "~/Library/Logs/Wend.log",
        crashDescription: "Wend crash reports from the last 30 days"
    )

    private var timestamp: ReportTimestamp {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: created)
        return ReportTimestamp(year: c.year ?? 1980, month: c.month ?? 1, day: c.day ?? 1,
                               hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }

    var baseName: String { ReportText.baseName(timestamp) }

    /// Build the report and zip it into `folder`. Returns the zip's URL.
    func save(in folder: URL) throws -> URL {
        let root = baseName
        var zip = ZipWriter(modified: timestamp)
        zip.add("\(root)/report.txt", text: summary())
        zip.add("\(root)/trail.log", text: Log.trailSnapshot())
        zip.add("\(root)/settings.txt", text: settings())
        if let log = try? Data(contentsOf: Log.url) {
            zip.add("\(root)/Wend.log", Array(log))
        }
        for url in recentCrashReports() {
            if let data = try? Data(contentsOf: url) {
                zip.add("\(root)/crash/\(url.lastPathComponent)", Array(data))
            }
        }

        let destination = uniqueURL(in: folder, name: baseName, ext: "zip")
        try Data(zip.archive()).write(to: destination, options: .withoutOverwriting)
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

    /// Wend's preferences domain, one sorted `key = value` per line.
    private func settings() -> String {
        guard let id = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: id)
        else { return "(no saved preferences — running without a bundle, e.g. `swift run`)\n" }
        return domain.keys.sorted().map { "\($0) = \(domain[$0]!)" }.joined(separator: "\n") + "\n"
    }

    private func recentCrashReports() -> [URL] {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let cutoff = created.addingTimeInterval(-30 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("Wend") }
            .compactMap { url -> (URL, Date)? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return date >= cutoff ? (url, date) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map(\.0)
    }

    /// `name.zip`, or `name 2.zip` and so on when a report was already saved that second.
    private func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
