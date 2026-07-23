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

## Tests

`swift test` after every code change, not only at the end of a task.

Core logic lives in `KeyLayoutCore` and is platform-agnostic and unit-tested. The `Wend`
target is the macOS layer (TIS/UCKeyTranslate, NSSpellChecker, clipboard, hotkeys) and has
no test target — verify changes there against the real API in a scratch script, or in the
running app via the diagnostic log.

## Diagnostic log

`~/Library/Logs/Wend.log`, opt-in via the menu, off by default, size-capped, created 0600.

It records **metadata only — never any substring of the user's text**. Keep it that way:
lengths, counts, scores, and fixed strings are fine; anything derived from the content is
not.
