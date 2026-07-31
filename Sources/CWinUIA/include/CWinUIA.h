// CWinUIA: a flat C interface over the one UI Automation question Wend needs answered —
// "is the thing with keyboard focus a password field?".
//
// The same shape, and for the same reason, as CWinSpell: IUIAutomation is COM-only, and
// reaching through a COM vtable from Swift is verbose and easy to get subtly wrong around
// ownership. This keeps all of that in C and hands Swift two ordinary functions.
//
// Why it exists at all: the Win32 test Wend has always used reads the ES_PASSWORD style off
// the focused window, which only means anything on a classic edit control. A password box in
// a browser or an Electron app — which is where most passwords are actually typed — is not a
// window of its own and is invisible to that test. UI Automation can see it, because Chromium
// and Electron both publish IsPassword for it.
//
// Everything here is single-threaded on purpose: the caller is Wend's message-loop thread,
// which is also the thread that runs a fix, and the COM apartment is initialised there.

#ifndef CWINUIA_H
#define CWINUIA_H

#ifdef __cplusplus
extern "C" {
#endif

/// Initialise COM and the UI Automation client. Safe to call repeatedly; returns 1 once the
/// client is available, 0 if it could not be created. Worth calling once at launch so the
/// first fix doesn't pay for bringing COM up.
int wend_uia_init(void);

/// 1 if the focused element is a password field, 0 if it is not, -1 if UI Automation could not
/// answer — an unreachable or unresponsive app, or no client at all. Callers must not read -1
/// as "not a password": it is no evidence either way, and the Win32 check is the fallback.
int wend_uia_focus_is_password(void);

/// Release the client. Called on quit for tidiness; not required.
void wend_uia_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
