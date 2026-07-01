# Changelog

All notable changes to Wend. Newest first.

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

[1.2.0]: https://github.com/nachum-shmilovitz-66/wend/releases/tag/v1.2.0
[1.1.0]: https://github.com/nachum-shmilovitz-66/wend/tree/v1.1.0
[1.0.0]: https://github.com/nachum-shmilovitz-66/wend/tree/v1.0.0
