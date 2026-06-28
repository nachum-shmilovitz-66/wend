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
  - `PermissionsManager` — Accessibility prompt. `AppDelegate` — menu-bar UI.

## Build & test

```sh
swift build
swift test                          # 10 Core unit tests, no system dependency
swift run Wend --dump-layouts   # diagnostic: prints your live layouts + a sample fix
```

## Run

```sh
swift run Wend
```

The first launch prompts for **Accessibility** access (System Settings ▸ Privacy &
Security ▸ Accessibility) — required to simulate ⌘C/⌘V and watch for the hotkey. Then:
select wrong-layout text in any app and **double-tap Shift**. A keyboard icon appears in
the menu bar with a toggle for "Switch Layout After Fix".

> Running as a bare SwiftPM executable is fine for development.

## Package as a `.app` (signed + notarized)

This app can't be sandboxed / App-Store-distributed — it needs Accessibility + global
event access — so it ships as a notarized, hardened-runtime `.app` distributed directly.

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

## Roadmap

- **Automatic mode** — a `CGEventTap` keystroke buffer that auto-fixes on word boundary
  (needs password-field exclusion + undo). Reuses `KeyLayoutCore` unchanged.
- **Windows port** — reimplement the `InputSourceProvider` / `SelectionService` shims
  (`GetKeyboardLayoutList` + `ToUnicodeEx`, `SendInput`, `RegisterHotKey`); `KeyLayoutCore`
  ports as-is.
