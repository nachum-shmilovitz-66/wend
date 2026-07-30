# Changelog

All notable changes to Wend. Newest first.

## [1.2.4] — 2026-07-30

**Wend now runs on Windows.** Same app, same double-tap Shift, same trick: it reads the keyboard layouts you actually have installed and works out which conversion turns your text into real words. All the conversion and detection logic is the code the Mac has been using — only the parts that talk to the operating system are written twice — so the two behave identically by construction rather than by imitation.

- **Windows build, as an installer or a portable folder.** `Wend-1.2.4-windows-x64.msi` installs per user, so it never asks for an administrator password: Start-menu entry, uninstall entry, and it starts itself when it finishes. `Wend-1.2.4-windows-x64-portable.zip` is the same thing with nothing to install — unzip it anywhere and run `Wend.exe`, which is the answer for machines whose policy refuses installers.
- **No permission grant needed on Windows.** There is no counterpart of the macOS Accessibility prompt; it simply works once it's running. Layouts come from the ones you've added under Settings ▸ Time & language, and the tray menu carries the same controls as the menu-bar menu on the Mac — Fix Selection, Switch Layout After Fix, Launch at Login, Enable Diagnostic Logging, Send Feedback, About.
- **Two differences worth knowing about on Windows.** Detection needs a spell-check dictionary for each language you convert *into*, and Windows doesn't install them all by default — add them under Language options. And text in a window running as administrator can't be fixed unless Wend is too; Windows blocks the keystrokes, so Wend beeps and says so in the log rather than appearing to do nothing.
- **Password fields are less protected on Windows than on macOS.** macOS exposes a system-wide secure-input flag that Wend refuses to touch. Windows has no equivalent, so Wend can only recognise a classic Windows password box — one inside a browser or an Electron app is invisible to it. Wend still never writes your text to disk, and the clipboard it borrows is marked to stay out of clipboard history and off the cloud clipboard.
- **Fixed (Windows): double-tapping Shift could type a stray `c` and destroy the selection.** In Chrome, Edge, VS Code and other Chromium-based apps, the copy Wend synthesizes arrived as a plain character instead of Ctrl+C — so a `c` replaced whatever you had selected, and the log recorded only that nothing was captured. Wend now paces the keystrokes it sends so the modifier is unmistakable, and waits for any key you're still holding to come up first.

macOS is unchanged in this release — no macOS code was touched, and 1.2.4 behaves exactly as 1.2.3 did there.

## [1.2.3] — 2026-07-30

- **A fix that has nothing to work on now says so.** Double-tapping Shift with nothing selected — most often straight after a successful fix, since pasting the result clears the selection — did nothing at all, with no sound and nothing in the diagnostic log to explain it. It now beeps, and the log names the reason instead of leaving you to infer it from a missing line. Password fields stay silent on purpose, and so does a conversion Wend declined, because fixing again within two seconds is the intended next step there.

- **The menu bar menu now shows which version is running** — the *About Wend* item reads *About Wend 1.2.3*. Reporting a problem no longer means opening the About panel to find out what you're running. The About panel itself now shows the version alone too, without the build number after it.
- **Fixed: text no dictionary recognises now converts on the first double-tap.** Words like `gdut` (on the way to *GDUtility*), acronyms, and search fragments read as nothing in any of your languages, so the fix used to decline and you had to double-tap Shift a second time to force it. When the text isn't a word in *any* installed language there is nothing for the dictionary to weigh, so it now converts straight away. Fixing again converts it back, so an unwanted conversion costs one more double-tap. Text that does contain real words is unchanged — it still takes the second double-tap to override.
- **Fixed: installing an upgrade appeared to change nothing.** The installer copied the new app but left the old copy running, and because a copy was already running, the post-install launch just brought that old process to the front — so you kept using the previous version until the next login. The installer now quits the running copy before installing (asking it to quit first, so it shuts down cleanly), then launches the new one.

## [1.2.2] — 2026-07-23

- **Fix it anyway: double-tap Shift again to force a conversion.** Some text can't be recognised as words at all — a half-typed word (`argenti` on the way to *Argentina*), a search fragment, a name no dictionary carries — so Wend used to decline and appear to do nothing. Now, fixing again within 2 seconds of a rejected attempt converts the text regardless of what the dictionary thinks. The first attempt is unchanged, so nothing converts by accident.
- **Fixed: lowercase proper nouns were never recognised.** macOS's spell checker accepts `Argentina` but rejects `argentina`, and layout conversion can only reproduce the capitalisation you typed — so countries, cities, names and months were invisible to detection. Words are now checked capitalised as well as as-typed.
- **Fixed: installing an older build silently did nothing.** The installer marked the app version-checked, so installing over a newer copy skipped the app entirely while still reporting success. Installers now always install the version they contain.

## [1.2.1] — 2026-07-23

- **Fixed: the fix silently did nothing on some short two-word selections.** When the converted text scored exactly as well as what you typed — one recognized word on each side, e.g. `re ehcbv` → `רק קיבנה` — Wend required a strict improvement and gave up. Invoking the fix is an explicit "this is wrong", so a tie now converts. Text that already reads perfectly is still left untouched, and a conversion is never a step backwards.
- **Fixed: line breaks were lost when fixing multi-line text in web editors.** Google Chat's compose box hands the clipboard a *flattened* plain-text copy — line breaks replaced by spaces — while keeping the real structure in the clipboard's HTML flavor. Wend read only the plain text, so the break was gone before conversion even started. It now reads the HTML flavor when one is present and recovers the line structure from it, and offers an HTML flavor of its own (using `<br>`) when pasting multi-line text back. As a safeguard, the HTML version of a selection is used only when it matches the plain text on everything except whitespace, so it can restore line breaks but never change your text. Single-line fixes and plain-text fields are unaffected.
- Diagnostic log now records the line-break count (`nl=`) alongside the length, so a lost line break can be pinned to Wend or to the receiving app. Counts only — still no text content.

## [1.2.0] — 2026-07-01

Privacy & security hardening (from a full security review).

- **Password & secure fields are left alone** — Wend detects secure input (`IsSecureEventInputEnabled`) and won't copy or convert a focused password field.
- **The diagnostic log no longer records any of your text** — only operational metadata — and the log file is created private (owner-only, `0600`).
- **Diagnostic logging is now opt-in** (off by default) via an *Enable Diagnostic Logging* menu toggle, and the log is size-capped (512 KB).
- **"Include recent log" in Send Feedback is now opt-in** (off by default).
- **More robust clipboard handling** — the original clipboard is always restored (even under teardown), and Wend's clipboard writes are marked concealed/transient so clipboard managers skip them.
- Added a one-shot signed + notarized release script that refuses to emit an unsigned artifact.

## [1.1.0] — 2026-06-30

- **Accessibility status in the menu** — the menu-bar menu shows whether Accessibility access is granted, with a one-click shortcut to System Settings; it clears automatically once granted.
- **Control-panel window on relaunch** — relaunching Wend (e.g. double-clicking it in `/Applications`), or when the menu-bar icon is hidden by overflow or the notch, opens a small window mirroring every control, so Wend always has a reachable home.
- **Send Feedback** — a new *Send Feedback…* item opens a prefilled email (Gmail compose) with a type, message, and auto-collected diagnostics.

## [1.0.0] — 2026-06-30

- Initial release. Fix text typed in the **wrong keyboard layout** on macOS: select it and **double-tap Shift**.
- Works for **any** keyboard layout installed on the machine (Hebrew, Arabic, German, …) — read at runtime, no per-language code.
- Menu-bar app (no Dock icon); requires Accessibility; auto-enables Launch at Login on first run.
- Signed with Developer ID and notarized; ships as a `.pkg` installer.
- Requirements: Apple Silicon, macOS 13+.

[1.2.4]: https://github.com/nachum-shmilovitz-66/wend/releases/tag/v1.2.4
[1.2.3]: https://github.com/nachum-shmilovitz-66/wend/releases/tag/v1.2.3
[1.2.2]: https://github.com/nachum-shmilovitz-66/wend/releases/tag/v1.2.2
[1.2.1]: https://github.com/nachum-shmilovitz-66/wend/releases/tag/v1.2.1
[1.2.0]: https://github.com/nachum-shmilovitz-66/wend/releases/tag/v1.2.0
[1.1.0]: https://github.com/nachum-shmilovitz-66/wend/tree/v1.1.0
[1.0.0]: https://github.com/nachum-shmilovitz-66/wend/tree/v1.0.0
