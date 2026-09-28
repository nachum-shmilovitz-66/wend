import XCTest
@testable import KeyLayoutCore

// The releases list below has the shape of GitHub's API response, trimmed to the fields
// UpdateCheck reads, and mirrors the real history: 1.2.4 shipped both platforms, 1.2.5 to 1.2.8
// shipped macOS only.
private let releasesJSON = """
[
  {"tag_name": "v1.3.0", "draft": true, "prerelease": false,
   "html_url": "https://example.test/v1.3.0",
   "assets": [{"name": "Wend-1.3.0-macOS.pkg", "browser_download_url": "https://example.test/1.3.0.pkg"}]},
  {"tag_name": "v1.2.9", "draft": false, "prerelease": true,
   "html_url": "https://example.test/v1.2.9",
   "assets": [{"name": "Wend-1.2.9-macOS.pkg", "browser_download_url": "https://example.test/1.2.9.pkg"}]},
  {"tag_name": "v1.2.8", "draft": false, "prerelease": false,
   "html_url": "https://example.test/v1.2.8",
   "assets": [{"name": "Wend-1.2.8-macOS.pkg", "browser_download_url": "https://example.test/1.2.8.pkg"},
              {"name": "Wend-1.2.8-SHA256SUMS.txt", "browser_download_url": "https://example.test/1.2.8.txt"}]},
  {"tag_name": "v1.2.4", "draft": false, "prerelease": false,
   "html_url": "https://example.test/v1.2.4",
   "assets": [{"name": "Wend-1.2.4-macOS.pkg", "browser_download_url": "https://example.test/1.2.4.pkg"},
              {"name": "Wend-1.2.4-windows-x64.msi", "browser_download_url": "https://example.test/1.2.4.msi"},
              {"name": "Wend-1.2.4-windows-x64-portable.zip", "browser_download_url": "https://example.test/1.2.4.zip"}]}
]
""".data(using: .utf8)!

final class UpdateCheckTests: XCTestCase {
    private func v(_ s: String) -> AppVersion { AppVersion(s)! }

    func testVersionParsing() {
        XCTAssertEqual(AppVersion("1.2.8")?.parts, [1, 2, 8])
        XCTAssertEqual(AppVersion("v1.2.8")?.parts, [1, 2, 8])
        XCTAssertNil(AppVersion("?"))          // the Mac app run without a bundle
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("1.2.8-beta"))
    }

    /// Numeric, not text: 1.2.10 is newer than 1.2.9, and a missing part counts as zero.
    func testVersionOrdering() {
        XCTAssertLessThan(v("1.2.9"), v("1.2.10"))
        XCTAssertLessThan(v("1.2.8"), v("1.3"))
        XCTAssertLessThan(v("1.9.9"), v("2.0.0"))
        XCTAssertEqual(v("1.3"), v("1.3.0"))
        XCTAssertFalse(v("1.2.8") < v("1.2.8"))
    }

    /// Drafts and pre-releases never count, only published releases with a Mac installer.
    func testLatestForMacSkipsDraftsAndPrereleases() throws {
        let latest = try UpdateCheck.latestRelease(in: releasesJSON, for: .macOS)
        XCTAssertEqual(latest?.version, v("1.2.8"))
        XCTAssertEqual(latest?.installerName, "Wend-1.2.8-macOS.pkg")
        XCTAssertEqual(latest?.installerURL, "https://example.test/1.2.8.pkg")
        XCTAssertEqual(latest?.pageURL, "https://example.test/v1.2.8")
    }

    /// Releases without a Windows installer are skipped, so a Windows user is pointed at the
    /// newest build they can actually install, not at a Mac-only release.
    func testLatestForWindowsNeedsAWindowsInstaller() throws {
        let latest = try UpdateCheck.latestRelease(in: releasesJSON, for: .windows)
        XCTAssertEqual(latest?.version, v("1.2.4"))
        XCTAssertEqual(latest?.installerName, "Wend-1.2.4-windows-x64.msi")
    }

    /// Picks the highest version, whatever order the list arrives in.
    func testLatestIsTheHighestVersionNotTheFirstListed() throws {
        let json = """
            [{"tag_name": "v1.2.9", "draft": false, "prerelease": false, "html_url": "a",
              "assets": [{"name": "Wend-1.2.9-macOS.pkg", "browser_download_url": "a"}]},
             {"tag_name": "v1.2.10", "draft": false, "prerelease": false, "html_url": "b",
              "assets": [{"name": "Wend-1.2.10-macOS.pkg", "browser_download_url": "b"}]}]
            """.data(using: .utf8)!
        XCTAssertEqual(try UpdateCheck.latestRelease(in: json, for: .macOS)?.version, v("1.2.10"))
    }

    func testStatus() throws {
        let latest = try XCTUnwrap(UpdateCheck.latestRelease(in: releasesJSON, for: .macOS))
        XCTAssertEqual(UpdateCheck.status(current: v("1.2.7"), latest: latest), .available(latest))
        XCTAssertEqual(UpdateCheck.status(current: v("1.2.8"), latest: latest), .upToDate(latest))
        XCTAssertEqual(UpdateCheck.status(current: v("1.2.9"), latest: latest), .aheadOfRelease(latest))
        XCTAssertEqual(UpdateCheck.status(current: v("1.2.8"), latest: nil), .noRelease)
    }

    func testMalformedResponseThrows() {
        let rateLimited = #"{"message": "API rate limit exceeded"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try UpdateCheck.latestRelease(in: rateLimited, for: .macOS))
    }
}
