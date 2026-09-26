// ProblemReportFormat: the parts of "Report a Problem…" both apps share — what a user can
// report, how the report is named, and the fixed text that explains it. Kept here so a report
// from a Mac and one from Windows read the same and can be triaged with one set of eyes; each
// app supplies only the facts it alone can gather and the wording that genuinely differs.

/// What the user is reporting. The first two are the conversion problems the trail was built
/// to explain; the last two are the general-purpose bug and idea.
public enum ReportKind: CaseIterable, Sendable {
    case pressedTwice, notConverted, bug, idea

    /// The choice as the report form offers it.
    public var title: String {
        switch self {
        case .pressedTwice: return "I had to press ⇧⇧ twice before it converted"
        case .notConverted: return "The text didn't convert at all"
        case .bug:          return "Another bug"
        case .idea:         return "An idea or a suggestion"
        }
    }

    /// Short form for the report header and an email subject.
    public var tag: String {
        switch self {
        case .pressedTwice: return "Had to press ⇧⇧ twice"
        case .notConverted: return "Conversion did not happen"
        case .bug:          return "Bug"
        case .idea:         return "Idea"
        }
    }

    /// The two conversion problems explain themselves and the trail carries the rest;
    /// "another bug" and an idea say nothing until they're described.
    public var needsDescription: Bool { self == .bug || self == .idea }

    /// The form leaves a gap after this choice, so the conversion problems and the bug / idea
    /// pair read as two groups while staying one set of radio buttons.
    public static let groupEndsAfter: ReportKind = .notConverted
}

/// A local wall-clock time, broken down — Core has no Foundation, so each app converts its own
/// clock into this.
public struct ReportTimestamp: Sendable, Equatable {
    public let year, month, day, hour, minute, second: Int

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        self.year = year; self.month = month; self.day = day
        self.hour = hour; self.minute = minute; self.second = second
    }
}

/// The wording that differs between the two apps.
public struct ReportPlatform: Sendable {
    /// "⌘C" / "Ctrl+C", as the trail's copy line should be explained.
    public let copyShortcut: String
    /// Where the opt-in disk log lives, as the user would type it.
    public let logPath: String
    /// What the `crash/` folder holds on this platform.
    public let crashDescription: String

    public init(copyShortcut: String, logPath: String, crashDescription: String) {
        self.copyShortcut = copyShortcut
        self.logPath = logPath
        self.crashDescription = crashDescription
    }
}

public enum ReportText {
    /// `Wend Problem Report 2026-09-26 at 17.45.12` — Finder's own screenshot style: local time
    /// to the second, and no colons, which neither Finder nor a Windows file name accepts.
    public static func baseName(_ t: ReportTimestamp) -> String {
        "Wend Problem Report \(t.year)-\(pad(t.month))-\(pad(t.day)) at \(pad(t.hour)).\(pad(t.minute)).\(pad(t.second))"
    }

    /// `report.txt`. `created` is the time as each app formats it (local, with its UTC
    /// equivalent); `facts` is the app's own "-- Section --" block.
    public static func summary(
        kind: ReportKind,
        created: String,
        details: String,
        facts: String,
        platform: ReportPlatform
    ) -> String {
        let text = details.trimmingWhitespace()
        return """
            Wend problem report
            ===================
            Type:     \(kind.tag)
            Created:  \(created)

            Described by the user:
            \(text.isEmpty ? "(nothing written)" : text)

            \(facts)

            -- Files in this report --
            report.txt    this summary
            trail.log     in-memory event trail since Wend launched. Always on, metadata only,
                          never written to disk except into a report like this one. UTC, ms.
            Wend.log      the opt-in disk log (\(platform.logPath)), if it exists. UTC.
            settings.txt  Wend's saved preferences
            crash/        \(platform.crashDescription), if any

            -- Reading the trail --
            ⇧ L tap held=85 ms: first tap         a clean Shift tap (L/R = which Shift), waiting for its partner
            ⇧ R tap held=90 gap=250 ms: double-tap, trigger
                                                  second tap within the double-tap interval: fix runs
            … gap=520 ms > 400: first tap (again) partner came too late; this tap starts a new pair
            ⇧ L press held=450 ms > 300: not a tap
                                                  Shift held too long to count. Seconds or more = a stale
                                                  press (a release Wend never saw)
            ⇧ L down while ⇧ already down for …  the other Shift joined in, or the last release was missed
            ⇧ second tap spoiled: …               a key or modifier landed during the second tap
            double-shift trigger / menu fix       a fix started, from ⇧⇧ or from the menu
            performFix start front=<app> force=<bool> sinceDecline=<ms>
                                                  force=true: a repeat within the force window, which
                                                  converts what the dictionary declined
            copy: clipboard changed after N ms    the app answered \(platform.copyShortcut) (no change = nothing selected)
            decision=<reason> tokens original best threshold
                                                  why the dictionary accepted or declined, with the
                                                  valid-word ratios it decided on
            convert … / didReplace=<bool>         what was pasted back (lengths and layout ids only)

            """
    }

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}

private extension String {
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        while let c = s.first, c.isWhitespace { s.removeFirst() }
        while let c = s.last, c.isWhitespace { s.removeLast() }
        return String(s)
    }
}
