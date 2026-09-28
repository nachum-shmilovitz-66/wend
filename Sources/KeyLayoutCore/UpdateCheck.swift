// UpdateCheck: which published release is the newest for this platform, and how it compares
// with the running version. Parsing and comparison only: each platform layer does its own
// fetch, since URLSession on Windows would pull FoundationNetworking and libcurl into the
// package.
//
// "Newest for this platform", not simply the newest release: a release can ship one platform
// only (1.2.5 to 1.2.8 carried no Windows build), and pointing a Windows user at one of those
// would offer them an update with nothing in it they can install.

import Foundation

/// A dotted numeric version such as `1.2.8`. A leading `v` is accepted, as in release tags.
/// Missing trailing parts count as zero, so `1.3` equals `1.3.0`.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let n = Int(piece), n >= 0 else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for i in 0..<count {
            let l = i < lhs.parts.count ? lhs.parts[i] : 0
            let r = i < rhs.parts.count ? rhs.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The platform whose installer a release has to carry. The suffixes follow the release
/// naming in CLAUDE.md ("Every artifact names its platform").
public enum UpdatePlatform: Sendable {
    case macOS
    case windows

    var installerSuffix: String {
        switch self {
        case .macOS: return "-macOS.pkg"
        case .windows: return "-windows-x64.msi"
        }
    }
}

/// A published release that carries an installer for the platform asked about.
public struct AvailableRelease: Equatable, Sendable {
    public let version: AppVersion
    /// The release page: notes, checksums, every download.
    public let pageURL: String
    public let installerName: String
    public let installerURL: String
}

public enum UpdateStatus: Equatable, Sendable {
    /// The running version is the newest release for this platform.
    case upToDate(AvailableRelease)
    /// A newer release carries an installer for this platform.
    case available(AvailableRelease)
    /// The running version is newer than any release: a test or development build.
    case aheadOfRelease(AvailableRelease)
    /// No published release carries an installer for this platform.
    case noRelease
}

public enum UpdateCheck {
    /// Public, no sign-in needed. Newest first; 30 is far more than a platform ever lags by.
    public static let releasesAPI = "https://api.github.com/repos/nachum-shmilovitz-66/wend/releases?per_page=30"
    public static let releasesPage = "https://github.com/nachum-shmilovitz-66/wend/releases"

    /// The newest published release (not a draft, not a pre-release) that carries this
    /// platform's installer, from the GitHub releases list.
    public static func latestRelease(in json: Data, for platform: UpdatePlatform) throws -> AvailableRelease? {
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: json)
        var best: AvailableRelease?
        for release in releases where !release.draft && !release.prerelease {
            guard let version = AppVersion(release.tagName),
                  let installer = release.assets.first(where: { $0.name.hasSuffix(platform.installerSuffix) })
            else { continue }
            if let current = best, !(current.version < version) { continue }
            best = AvailableRelease(
                version: version,
                pageURL: release.htmlURL,
                installerName: installer.name,
                installerURL: installer.downloadURL
            )
        }
        return best
    }

    public static func status(current: AppVersion, latest: AvailableRelease?) -> UpdateStatus {
        guard let latest else { return .noRelease }
        if current < latest.version { return .available(latest) }
        if latest.version < current { return .aheadOfRelease(latest) }
        return .upToDate(latest)
    }

    /// The fields Wend reads from one entry of GitHub's releases list.
    private struct GitHubRelease: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let htmlURL: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let downloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease
            case htmlURL = "html_url"
            case assets
        }
    }
}
