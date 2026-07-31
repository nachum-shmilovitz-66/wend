#include "include/CWinUIA.h"

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
// objbase.h before uiautomation.h, and not the other way round: WIN32_LEAN_AND_MEAN keeps the
// COM base headers out of windows.h, and UIAutomationCore.h assumes the `interface` macro they
// define is already in scope. Without this it fails at its first forward declaration with
// "unknown type name 'interface'", which reads like a broken SDK rather than a missing include.
#include <objbase.h>
#include <uiautomation.h>

// Written out for the same reason CWinSpell writes its two out: the headers only *declare*
// these (EXTERN_C const IID …) and uuid.lib does not carry their definitions, so there is
// nothing to link against. Transcribed from the DECLSPEC_UUID / MIDL_INTERFACE attributes in
// uiautomationclient.h — check them against that header, not against memory. Getting one wrong
// fails as E_NOINTERFACE from CoCreateInstance, which reads like a missing feature rather than
// a typo.
//
//   CLSID_CUIAutomation   FF48DBA4-60EF-4201-AA87-54103EEF594E
//   IID_IUIAutomation     30CBE57D-D9D0-452A-AB13-7AC5AC4825EE
//   IID_IUIAutomation2    34723AFF-0C9D-49D0-9896-7AB52DF8CD8A
static const CLSID kCLSID_CUIAutomation =
    {0xff48dba4, 0x60ef, 0x4201, {0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e}};
static const IID kIID_IUIAutomation =
    {0x30cbe57d, 0xd9d0, 0x452a, {0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee}};
static const IID kIID_IUIAutomation2 =
    {0x34723aff, 0x0c9d, 0x49d0, {0x98, 0x96, 0x7a, 0xb5, 0x2d, 0xf8, 0xcd, 0x8a}};

// A UIA call reaches into the foreground process and waits for it to answer. Wend's caller is
// the thread that owns the low-level keyboard hook, and Windows quietly removes a hook whose
// thread stops answering — so an unresponsive app must not be able to park us indefinitely.
// IUIAutomation2 (Windows 8+) is where the two timeouts live; without it the call is still
// made, just unbounded, which is the pre-existing behaviour of every other call in the app.
#define WEND_UIA_CONNECTION_TIMEOUT_MS 500
#define WEND_UIA_TRANSACTION_TIMEOUT_MS 1000

static IUIAutomation *g_automation;
static int g_attempted;

int wend_uia_init(void) {
    if (g_attempted) {
        return g_automation != NULL;
    }
    g_attempted = 1;

    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    // RPC_E_CHANGED_MODE means this thread is already in a different apartment. That is not a
    // failure for our purposes — the client still works — so only a real error stops us.
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        return 0;
    }

    hr = CoCreateInstance(&kCLSID_CUIAutomation, NULL, CLSCTX_INPROC_SERVER,
                          &kIID_IUIAutomation, (void **)&g_automation);
    if (FAILED(hr)) {
        g_automation = NULL;
        return 0;
    }

    IUIAutomation2 *automation2 = NULL;
    if (SUCCEEDED(IUIAutomation_QueryInterface(g_automation, &kIID_IUIAutomation2,
                                               (void **)&automation2)) &&
        automation2 != NULL) {
        IUIAutomation2_put_ConnectionTimeout(automation2, WEND_UIA_CONNECTION_TIMEOUT_MS);
        IUIAutomation2_put_TransactionTimeout(automation2, WEND_UIA_TRANSACTION_TIMEOUT_MS);
        IUIAutomation2_Release(automation2);
    }
    return 1;
}

int wend_uia_focus_is_password(void) {
    if (!wend_uia_init()) {
        return -1;
    }

    IUIAutomationElement *focused = NULL;
    if (FAILED(IUIAutomation_GetFocusedElement(g_automation, &focused)) || focused == NULL) {
        return -1;
    }

    // The cached variant would need a request built and the element re-fetched through it;
    // Current reads it live, which is what a decision made this instant wants anyway.
    BOOL is_password = FALSE;
    HRESULT hr = IUIAutomationElement_get_CurrentIsPassword(focused, &is_password);
    IUIAutomationElement_Release(focused);
    if (FAILED(hr)) {
        return -1;
    }
    return is_password ? 1 : 0;
}

void wend_uia_shutdown(void) {
    if (g_automation != NULL) {
        IUIAutomation_Release(g_automation);
        g_automation = NULL;
    }
    g_attempted = 0;
}
