# Wend — working notes

## Issue tracking

Work items live in **Jira**, project **WND**, at `nachum-shmilovitz.atlassian.net`
(the `atlassian-private` account — never the work instance).

GitHub holds **code and releases only**. Its Issues tab is intentionally unused: two
trackers means every bug gets filed twice or drifts out of sync. One tracker, and it is
Jira.

The link between the two is the issue key in the commit subject:

    WND-18 Add force-convert on repeat trigger

A `commit-msg` hook enforces this. Enable it once per clone:

    git config core.hooksPath .githooks

Merges, reverts and `fixup!`/`squash!` commits are exempt; `--no-verify` bypasses it.

If the *GitHub for Jira* app is connected on the Atlassian side, smart-commit actions
also apply — `WND-18 #close ...` transitions the ticket when the commit is pushed.

Close the loop after a fix: update the ticket, and name the commit and released version
in it.

## Releases

`scripts/release.sh` is the only supported path. It builds, signs with Developer ID,
notarizes, staples, and refuses to emit an unsigned or un-notarized artifact.

    SIGN_IDENTITY="Developer ID Application: Nachum Shmilovitz (96Y4LX7FVB)" \
    PKG_SIGN_IDENTITY="Developer ID Installer: Nachum Shmilovitz (96Y4LX7FVB)" \
      bash scripts/release.sh

The version lives in `scripts/package.sh` (`SHORT_VERSION` / `BUILD_VERSION`) — bump it
before releasing, and add a `CHANGELOG.md` entry with a matching link reference.

`dist/` is gitignored; the `.pkg` ships as a GitHub release asset, not in the tree.

On Windows, `scripts/make_setup_win.ps1` is the equivalent of `make_pkg.sh` — it stages via
`package_win.ps1` into `.build/win-stage/` and emits two artifacts into `dist/`: a per-user
`.msi`, and a portable `.zip` for hosts that refuse it (a non-admin account on a Server SKU
is one, by SKU default rather than policy). The icon and version are stamped into the exe as
PE resources after the link, since SwiftPM can't compile a resource script.

Both scripts read the version from `scripts/package.sh`, so there is one source for both
platforms — but `Sources/WendWin/Version.swift` has to be bumped alongside it, and they
refuse to build when the two disagree.

**Still no signing on Windows** (WND-27): the MSI is unsigned, so SmartScreen warns. There
is no `release.sh` counterpart yet either.

## Platforms

`Package.swift` selects the app target by **host OS**: `Wend` (AppKit) on macOS, `WendWin`
(Win32 + the `CWinSpell` C shim) on Windows. Both build the product name `Wend`, so
`swift build` / `swift run Wend` are the same commands either side. Neither platform can
compile the other's sources, so a change to one is untested by the other's CI — when you
touch behaviour that both share, change both layers or say plainly that you didn't.

`KeyLayoutCore` is the only code both use. Keep it free of AppKit *and* WinSDK.

**A platform fix stays in that platform's layer, and must be flagged as such.** Before making
a change, say which side it lands on:

- `Sources/Wend/` or `Sources/WendWin/` — one platform only. State that the other is
  untouched, so nobody has to diff it to find out.
- `Sources/KeyLayoutCore/`, `Package.swift`, `Tests/`, `Packaging/`, `scripts/` — **shared**.
  Say so out loud, every time. These reach both platforms, only one of them can be built on
  any given machine, and an unflagged shared change is a change nobody has compiled.

This runs both ways: don't fix a Windows symptom in shared code when the Windows layer can
carry it, and don't reach into `WendWin` for something the Mac needs. Where a fault is genuinely
common to both — Core logic, or a behaviour the two layers are meant to mirror — fix both sides
or say plainly which one you left alone and why.

## Tests

`swift test` after every code change, not only at the end of a task.

Core logic lives in `KeyLayoutCore` and is platform-agnostic and unit-tested. The platform
targets (`Wend`, `WendWin`) have no test target — verify changes there against the real API in
a scratch script, or in the running app via the diagnostic log.

On Windows the toolchain is the swift.org one plus Visual Studio Build Tools; build from a
developer command prompt. `--dump-layouts` also prints the installed spell-check
dictionaries, which is usually the answer when every conversion scores zero.

## Diagnostic log

`~/Library/Logs/Wend.log` on macOS (created 0600); `%LOCALAPPDATA%\Wend\Wend.log` on Windows,
where the profile ACL already restricts it to the user. Opt-in via the menu, off by default,
size-capped.

It records **metadata only — never any substring of the user's text**. Keep it that way:
lengths, counts, scores, and fixed strings are fine; anything derived from the content is
not.
