// UpdateChecker (macOS): "Check for Updates…". Asks GitHub for the published releases, lets
// KeyLayoutCore pick the newest one that carries a Mac installer, and says what it found.
// It runs only when the user asks: Wend makes no network request on its own.

import AppKit
import KeyLayoutCore

final class UpdateChecker {
    /// Called with true when a check starts and false when it ends, so the menu item can say
    /// it's busy and a second click can't start a second check.
    var onBusyChange: (Bool) -> Void = { _ in }
    private var isChecking = false

    private enum Outcome {
        case status(UpdateStatus)
        /// `reason` is shown to the user; `log` is the metadata-only form for the log.
        case failed(reason: String, log: String)
    }

    /// `current` is the running marketing version (CFBundleShortVersionString).
    func check(current: String) {
        guard !isChecking else { return }
        guard let version = AppVersion(current) else {
            Log.write("update check: this build has no version number")
            show(title: "Can't check for updates",
                 text: "This copy of Wend has no version number, so there is nothing to compare.",
                 offerReleasesPage: true)
            return
        }

        isChecking = true
        onBusyChange(true)
        Log.write("update check: asking GitHub, current=\(version)")

        var request = URLRequest(url: URL(string: UpdateCheck.releasesAPI)!,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Wend/\(version) (macOS)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let outcome = Self.evaluate(version, data: data, response: response, error: error)
            DispatchQueue.main.async {
                self.isChecking = false
                self.onBusyChange(false)
                self.present(outcome, current: version)
            }
        }.resume()
    }

    private static func evaluate(_ current: AppVersion, data: Data?, response: URLResponse?,
                                 error: Error?) -> Outcome {
        if let error = error as NSError? {
            return .failed(reason: error.localizedDescription,
                           log: "network error \(error.domain) \(error.code)")
        }
        guard let http = response as? HTTPURLResponse, let data else {
            return .failed(reason: "GitHub didn't answer.", log: "no response")
        }
        guard http.statusCode == 200 else {
            // Without signing in, GitHub allows 60 requests an hour from one address.
            let limited = http.statusCode == 403 || http.statusCode == 429
            return .failed(
                reason: limited
                    ? "GitHub is limiting how often it can be asked. Try again in an hour."
                    : "GitHub answered with error \(http.statusCode).",
                log: "HTTP \(http.statusCode)"
            )
        }
        do {
            let latest = try UpdateCheck.latestRelease(in: data, for: .macOS)
            return .status(UpdateCheck.status(current: current, latest: latest))
        } catch {
            return .failed(reason: "GitHub's answer couldn't be read.", log: "unreadable response")
        }
    }

    private func present(_ outcome: Outcome, current: AppVersion) {
        switch outcome {
        case .failed(let reason, let log):
            Log.write("update check failed: \(log)")
            show(title: "Couldn't check for updates", text: reason, offerReleasesPage: true)

        case .status(.available(let release)):
            Log.write("update check: available latest=\(release.version)")
            offerDownload(release, current: current)

        case .status(.upToDate(let release)):
            Log.write("update check: up to date latest=\(release.version)")
            show(title: "Wend is up to date",
                 text: "Version \(current) is the latest version.",
                 offerReleasesPage: false)

        case .status(.aheadOfRelease(let release)):
            Log.write("update check: newer than the latest release latest=\(release.version)")
            show(title: "Wend is up to date",
                 text: "This is version \(current), newer than the latest release, \(release.version).",
                 offerReleasesPage: false)

        case .status(.noRelease):
            Log.write("update check: no release has a Mac installer")
            show(title: "No Mac release found",
                 text: "None of Wend's published releases has a Mac installer.",
                 offerReleasesPage: true)
        }
    }

    private func offerDownload(_ release: AvailableRelease, current: AppVersion) {
        let alert = NSAlert()
        alert.messageText = "Wend \(release.version) is available"
        alert.informativeText = "You have version \(current). Download the installer and open it: "
            + "it quits this copy of Wend, installs the new one and starts it."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch runModal(alert) {
        case .alertFirstButtonReturn: openOnGitHub(release.installerURL)
        case .alertSecondButtonReturn: openOnGitHub(release.pageURL)
        default: break
        }
    }

    private func show(title: String, text: String, offerReleasesPage: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if offerReleasesPage { alert.addButton(withTitle: "Open Releases Page") }
        if runModal(alert) == .alertSecondButtonReturn { openOnGitHub(UpdateCheck.releasesPage) }
    }

    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // Accessory (LSUIElement) app: without this the alert opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    /// Opens a link from GitHub's answer in the browser, but only an https link on github.com:
    /// the answer comes from the network, so nothing else in it gets opened.
    private func openOnGitHub(_ string: String) {
        guard let url = URL(string: string), url.scheme == "https", url.host == "github.com" else {
            Log.write("update check: refused to open a link outside github.com")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
