# Wend

Fix text typed in the wrong keyboard layout on macOS. You meant `שלום` but the English
layout was active, so you got `akuo` — select it, double-tap **Shift**, and it becomes
`שלום`. Works for **any** language you have installed (Hebrew, Arabic, German, …) with no
per-language code: it reads your actual system layouts at runtime.

## How it works

- **`KeyLayoutCore`** (pure Swift, no AppKit — portable to a future Windows port)
  - `LayoutTable` — physical-key ↔ character map for one layout.
  - `LayoutMapper` — re-map text as if the same keys were pressed under another layout.
  - `LayoutDetector` — pick the conversion that produces the most real words.
  - `WordValidator` — protocol; "is this a real word in language X?".
- **`Wend`** (macOS app)
  - `InputSourceProvider` — reads installed layouts via TIS + `UCKeyTranslate`.
  - `SpellWordValidator` — `NSSpellChecker`-backed `WordValidator`.
  - `SelectionService` — clipboard round-trip (⌘C → transform → ⌘V → restore).
  - `HotkeyManager` — double-Shift trigger.
  - `InputSourceSwitcher` — optionally switch the active layout after a fix.
  - `PermissionsManager` — Accessibility prompt.
  - `AppDelegate` — menu-bar UI (Fix Selection, Switch Layout After Fix, Launch at Login,
    About) and first-run Launch-at-Login via `SMAppService`.
  - `Log` — file logger at `~/Library/Logs/Wend.log` for support/diagnosis.

## Build & test

```sh
swift build
swift test                          # 18 Core unit tests, no system dependency
swift run Wend --dump-layouts   # diagnostic: prints your live layouts + a sample fix
```

## Run

```sh
swift run Wend
```

The first launch prompts for **Accessibility** access (System Settings ▸ Privacy &
Security ▸ Accessibility) — required to simulate ⌘C/⌘V and watch for the hotkey. Then:
select wrong-layout text in any app and **double-tap Shift**. A keyboard icon appears in
the menu bar with: **Fix Selection** (same as double-Shift), **Switch Layout After Fix**,
**Launch at Login**, **Open Accessibility Settings…**, and **About Wend**.

On first launch the app auto-enables **Launch at Login** (via `SMAppService`) so it returns
after a restart; the menu toggle turns it off.

> Running as a bare SwiftPM executable is fine for development. Note: `SMAppService`
> registration and stable Accessibility trust need a signed `.app` bundle, not `swift run`.

## Package as a `.app` (signed + notarized)

This app can't be sandboxed / App-Store-distributed — it needs Accessibility + global
event access — so it ships as a notarized, hardened-runtime `.app`, wrapped in a `.pkg`
(or `.dmg`) installer (see **Build an installer** below). Always sign with the **Developer
ID Application** identity: Accessibility trust is keyed to the signing identity, so it
survives rebuilds — an unsigned/ad-hoc build loses trust on every rebuild.

```sh
# 1. Build + bundle (unsigned)
bash scripts/package.sh

# 2. Build + bundle + sign with hardened runtime
SIGN_IDENTITY="Developer ID Application: Nachum Shmilovitz (96Y4LX7FVB)" \
  bash scripts/package.sh

# 3. Notarize + staple (after one-time credential setup, see scripts/notarize.sh)
bash scripts/notarize.sh
```

Output: `dist/Wend.app`.

### Prerequisites (one-time, already set up on this machine)

- **Developer ID Application** certificate in the keychain
  (`Developer ID Application: Nachum Shmilovitz (96Y4LX7FVB)`).
- A stored notary credential profile named **`KLF-notary`**, created with:
  ```sh
  xcrun notarytool store-credentials "KLF-notary" \
    --apple-id "nachumsh@gmail.com" --team-id 96Y4LX7FVB \
    --password "<app-specific-password>"   # from account.apple.com → App-Specific Passwords
  ```

### Release in two commands

```sh
SIGN_IDENTITY="Developer ID Application: Nachum Shmilovitz (96Y4LX7FVB)" bash scripts/package.sh
bash scripts/notarize.sh
```

`notarize.sh` zips, submits to Apple, staples the ticket, and runs a Gatekeeper check, so
the resulting `dist/Wend.app` opens on any Mac without a security warning.

For quick local testing without notarization, sign with the Apple Development identity:
`SIGN_IDENTITY="Apple Development: nachumsh@gmail.com (9DLP6W93FA)" bash scripts/package.sh`.
Note: Apple Development trust is pinned to the binary hash, so it drops on every rebuild —
use **Developer ID Application** to keep Accessibility trust stable.

## App icon

The icon (a double-Shift keycap) is generated from code; only the built `.icns` is
committed (`Packaging/Wend.icns`). Regenerate it after editing `scripts/icon_render.swift`:

```sh
bash scripts/make_icon.sh        # renders the icon -> Packaging/Wend.icns
```

`package.sh` copies `Packaging/Wend.icns` into the bundle (`CFBundleIconFile = Wend`).

## Build an installer

Recommended: a **`.pkg`**. It installs Wend to `/Applications`, then a postinstall script
launches it so the user can grant Accessibility immediately. On first launch Wend also
auto-enables **Launch at Login**.

```sh
# sign the app (Developer ID), then build the installer
SIGN_IDENTITY="Developer ID Application: Nachum Shmilovitz (96Y4LX7FVB)" bash scripts/package.sh
bash scripts/make_pkg.sh         # -> dist/Wend-<version>.pkg
```

- The pkg sets `BundleIsRelocatable=false`. Without it the Installer finds a dev build via
  Spotlight and installs *over it* instead of into `/Applications`.
- For distribution to other Macs the pkg must be **signed + notarized**. pkg signing needs
  a **Developer ID Installer** cert (separate from the Application cert):
  `PKG_SIGN_IDENTITY="Developer ID Installer: Nachum Shmilovitz (96Y4LX7FVB)" bash scripts/make_pkg.sh`.
- postinstall logs to `/tmp/wend-postinstall.log` for diagnosis.

Alternative: a styled drag-to-Applications **`.dmg`** — `bash scripts/make_dmg.sh`
(-> `dist/Wend-<version>.dmg`). Unlike the pkg it can't auto-launch the app after copy.

## Uninstall

macOS `.pkg` installers are install-only — there's no built-in uninstall. To remove Wend,
toggle **Launch at Login** off in its menu first, then run:

```sh
bash scripts/uninstall.sh        # quits Wend, removes the app, receipt, and user data
```

Or manually: quit Wend, drag `/Applications/Wend.app` to the Trash, and remove it from
System Settings ▸ General ▸ Login Items.

## Roadmap

- **Automatic mode** — a `CGEventTap` keystroke buffer that auto-fixes on word boundary
  (needs password-field exclusion + undo). Reuses `KeyLayoutCore` unchanged.
- **Windows port** — reimplement the `InputSourceProvider` / `SelectionService` shims
  (`GetKeyboardLayoutList` + `ToUnicodeEx`, `SendInput`, `RegisterHotKey`); `KeyLayoutCore`
  ports as-is.
