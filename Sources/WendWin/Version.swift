// Version: the marketing version shown in the menu and in feedback reports.
//
// The macOS build reads this from the app bundle's Info.plist, which a Windows executable has
// no equivalent of without a resource script SwiftPM can't compile. Keep it in step with
// SHORT_VERSION in scripts/package.sh until the Windows packaging script exists to stamp it.

enum Version {
    static let short = "1.2.4"
}
