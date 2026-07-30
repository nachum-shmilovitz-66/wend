# Wend

Fix text typed in the wrong keyboard layout, on **macOS and Windows**. You meant `שלום` but
the English layout was active, so you got `akuo` — select it, double-tap **Shift**, and it
becomes `שלום`. Works for **any** language you have installed (Hebrew, Arabic, German, …) with
no per-language code: it reads your actual system layouts at runtime.

Release history is in [CHANGELOG.md](CHANGELOG.md); downloads are on the
[Releases page](https://github.com/nachum-shmilovitz-66/wend/releases).

## How it works

One Core, two platform layers. Everything that decides *what* the text should become is
shared; everything that touches the OS is written twice, once per platform.

- **`KeyLayoutCore`** (pure Swift, no AppKit, no WinSDK — shared by both apps)
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
- **`WendWin`** (Windows app) — the same pieces against Win32:
  - `InputSourceProvider` — `GetKeyboardLayoutList` + `ToUnicodeEx`, keyed by **scan code**
    (Windows virtual keys are layout-dependent, so they can't identify a physical key).
  - `SpellWordValidator` — the Windows Spell Checking API via the `CWinSpell` C shim, plus
    `ScriptGuard` in place of the Mac's exemplar character sets.
  - `SelectionService` — clipboard round-trip (Ctrl+C → transform → Ctrl+V → restore).
  - `HotkeyManager` — double-Shift via a `WH_KEYBOARD_LL` hook.
  - `InputSourceSwitcher` — `WM_INPUTLANGCHANGEREQUEST` to the foreground window.
  - `LaunchAtLogin` — the `HKCU\…\Run` value, the counterpart of `SMAppService`.
  - `App` — tray icon, menu, and the hidden window the hook and clipboard hang off.
  - `Log` — file logger at `%LOCALAPPDATA%\Wend\Wend.log`.

The manifest picks the app by host OS, so each platform builds only its own layer.

## Build & test

```sh
swift build
swift test                       # 41 Core unit tests, no system dependency
swift run Wend --dump-layouts    # diagnostic: your live layouts, dictionaries + a sample fix
```

On Windows this needs the [swift.org toolchain](https://www.swift.org/install/windows/) and
Visual Studio Build Tools; run it from a developer command prompt so the linker and the
Windows SDK are on the path.

## Run (Windows)

```sh
swift run Wend
```

A keyboard icon appears in the **notification area**, with a menu of **Fix Selection**,
**Switch Layout After Fix**, **Launch at Login**, **Enable Diagnostic Logging**, **Send
Feedback…**, **About Wend** and **Quit**. Select wrong-layout text in any app and
**double-tap Shift**. Launching Wend a second time doesn't start a second copy — it asks the
one already running to re-assert its tray icon, for when it's buried in the overflow area.

Windows needs no permission grant for any of this. Two differences from macOS are worth
knowing:

- **Spell-check dictionaries are not all installed by default.** Detection needs one for each
  language you convert *into*; without it that direction scores zero and the fix falls back to
  the repeat-trigger force path. `--dump-layouts` prints what's installed. Add more under
  Settings ▸ Time & language ▸ Language & region ▸ (language) ▸ Language options.
- **Elevated windows can't be fixed** unless Wend is elevated too — Windows blocks synthesized
  input across that boundary. Wend detects it, beeps, and says so in the log rather than
  appearing to do nothing.

> **Password fields:** macOS exposes a system-wide secure-input flag, and Wend refuses to run
> against it. Windows has no equivalent, so the Windows build can only recognise a classic
> Win32 password box (`ES_PASSWORD`); one in a browser or an Electron app is invisible to it.
> Wend never writes captured text to disk on either platform, and the clipboard it borrows is
> marked to stay out of clipboard history and off the cloud clipboard.

## Package (Windows)

```sh
pwsh -File scripts/make_setup_win.ps1   # -> dist/Wend-<version>-x64.msi
pwsh -File scripts/package_win.ps1      # just the staged folder, no installer
```

Run it where `swift build` already works — a Visual Studio developer prompt, or any shell
with the Swift toolchain and the MSVC tools on `PATH`. It also needs Python (for the two
resource scripts).

`package_win.ps1` stages a **self-contained folder** under `.build/win-stage/Wend`:
`Wend.exe` with its icon and version stamped in, `Wend.ico` for the tray, and the Swift
runtime DLLs it links against — found by walking the import table, so nothing ships that
never loads. It runs in place on a machine with no Swift toolchain.

`make_setup_win.ps1` wraps that folder in an MSI (`Packaging/Wend.wxs`, built with WiX 5).
`dist/` holds the installer and nothing else; the staged payload stays under `.build/` with
the rest of the build output.

The MSI is a **per-user** install to `%LOCALAPPDATA%\Programs\Wend`, so it needs no
elevation — Wend keeps its settings in `HKCU` and its Launch at Login is an `HKCU\…\Run`
value, so there is nothing it needs machine-wide. It adds a Start-menu shortcut, an
Apps & Features entry, closes a running Wend before overwriting it (the counterpart of
WND-24, since Windows locks a loaded image), starts the app when it finishes, and removes
the Launch-at-Login value on uninstall so nothing is left pointing at a deleted exe.

One-time tooling:

```sh
dotnet tool install --global wix
wix extension add --global WixToolset.Util.wixext
```

> **Windows Server note.** A non-admin account on a Server SKU is refused a per-user MSI
> outright — `Non-assigned apps are disabled for non-admin users`, error 1625. That is the
> host's policy, not a fault in the package; on Windows 10/11 a per-user install needs no
> privileges. Run the staged folder directly there instead.

Two things a Windows executable carries as PE resources, which SwiftPM has no way to
produce — it can't compile a resource script — so both are stamped in after the link, in
packaging, the same place `package.sh` applies the icon and version on macOS:

- the **icon**, drawn by Explorer, Task Manager and any shortcut;
- the **version block**, read by Explorer's Details tab and by installers. `ProductVersion`
  is the marketing string and `FileVersion` the build-precise one, mirroring
  `CFBundleShortVersionString` and `CFBundleVersion`.

The version comes from `SHORT_VERSION` / `BUILD_VERSION` in `scripts/package.sh` — one
source for both platforms. `Sources/WendWin/Version.swift` has to carry the same string,
because the running app shows it in its menu and in feedback reports; the script compares
them and refuses to build on a mismatch. Afterwards it reads the icon and version back out
of the linked exe and fails if either is wrong, the way `release.sh` refuses to emit an
unsigned artifact.

> **Not an installer, and not signed.** There is no `.msi`, no Start-menu entry, no
> uninstall, and SmartScreen will warn on first run on another machine. That work is
> tracked in WND-27.

## Run (macOS)

```sh
swift run Wend
```

The first launch prompts for **Accessibility** access (System Settings ▸ Privacy &
Security ▸ Accessibility) — required to simulate ⌘C/⌘V and watch for the hotkey. Then:
select wrong-layout text in any app and **double-tap Shift**. A keyboard icon appears in the
menu bar showing the live **Accessibility status** (granted / not granted) and a menu of:
**Fix Selection** (same as double-Shift), **Switch Layout After Fix**, **Launch at Login**,
**Open Accessibility Settings…**, **Send Feedback…**, and **About Wend**.

Relaunching Wend (for example double-clicking it in `/Applications`), or whenever the menu-bar
icon is hidden by menu-bar overflow or the notch, opens a small **control-panel window** that
mirrors those controls — so the app always has a reachable home. **Send Feedback…** opens a
prefilled Gmail compose with diagnostics (and, optionally, the recent log) so issues are easy
to report.

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

The icon (a double-Shift keycap) is generated from code; only the built icons are committed
(`Packaging/Wend.icns`, `Packaging/Wend.ico`). Regenerate them after editing
`scripts/icon_render.swift`:

```sh
bash scripts/make_icon.sh                  # renders the icon -> Packaging/Wend.icns
python scripts/make_icon_win.py            # Wend.icns -> Packaging/Wend.ico (needs Pillow)
```

The Windows icon is **downsampled from the same 1024×1024 render**, not drawn again, so the
two platforms can't drift apart. It carries 16/24/32/48/64/128/256 so no shell ever has to
stretch a badly matched size — `verify_resources.py` checks for exactly those.

`package.sh` copies `Packaging/Wend.icns` into the bundle (`CFBundleIconFile = Wend`);
`package_win.ps1` stamps `Packaging/Wend.ico` into the exe and stages a copy beside it for
the tray.

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
- **Windows installer** — the port itself is done, but it ships as a folder. An `.msi` with
  a Start-menu entry, an uninstall, and an Authenticode signature is WND-27.
