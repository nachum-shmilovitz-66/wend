#include "include/CWinSpell.h"

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <spellcheck.h>
#include <string.h>

// The two COM identifiers have to be written out: spellcheck.h only *declares* them
// (EXTERN_C const IID …), and uuid.lib does not carry their definitions, so there is nothing
// to link against. They are transcribed from the MIDL_INTERFACE and DECLSPEC_UUID attributes
// in spellcheck.h — check them against that header, not against memory. Getting one wrong
// fails as E_NOINTERFACE from CoCreateInstance, which reads like a missing feature rather
// than a typo.
//
//   CLSID_SpellCheckerFactory   7AB36653-1796-484B-BDFA-E74F1DB7C1DC
//   IID_ISpellCheckerFactory    8E018A9D-2415-4677-BF08-794EA61F94BB
static const CLSID kCLSID_SpellCheckerFactory =
    {0x7ab36653, 0x1796, 0x484b, {0xbd, 0xfa, 0xe7, 0x4f, 0x1d, 0xb7, 0xc1, 0xdc}};
static const IID kIID_ISpellCheckerFactory =
    {0x8e018a9d, 0x2415, 0x4677, {0xbf, 0x08, 0x79, 0x4e, 0xa6, 0x1f, 0x94, 0xbb}};

#define WEND_CACHE_SLOTS 8
#define WEND_TAG_MAX 32

static ISpellCheckerFactory *g_factory;
static int g_attempted;

struct wend_slot {
    wchar_t tag[WEND_TAG_MAX];
    ISpellChecker *checker;
};

static struct wend_slot g_slots[WEND_CACHE_SLOTS];
static int g_next_slot;

int wend_spell_init(void) {
    if (g_attempted) {
        return g_factory != NULL;
    }
    g_attempted = 1;

    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    // RPC_E_CHANGED_MODE means this thread is already in a different apartment. That is not a
    // failure for our purposes — the factory still works — so only a real error stops us.
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        return 0;
    }

    hr = CoCreateInstance(&kCLSID_SpellCheckerFactory, NULL, CLSCTX_INPROC_SERVER,
                          &kIID_ISpellCheckerFactory, (void **)&g_factory);
    if (FAILED(hr)) {
        g_factory = NULL;
        return 0;
    }
    return 1;
}

int wend_spell_supports(const wchar_t *language_tag) {
    if (!wend_spell_init() || language_tag == NULL) {
        return 0;
    }
    BOOL supported = FALSE;
    HRESULT hr = ISpellCheckerFactory_IsSupported(g_factory, language_tag, &supported);
    if (FAILED(hr)) {
        return 0;
    }
    return supported ? 1 : 0;
}

int wend_spell_languages(wchar_t *buffer, int capacity) {
    if (!wend_spell_init() || buffer == NULL || capacity <= 0) {
        return 0;
    }
    buffer[0] = L'\0';

    IEnumString *languages = NULL;
    if (FAILED(ISpellCheckerFactory_get_SupportedLanguages(g_factory, &languages)) ||
        languages == NULL) {
        return 0;
    }

    int used = 0;
    LPOLESTR tag = NULL;
    ULONG fetched = 0;
    while (IEnumString_Next(languages, 1, &tag, &fetched) == S_OK && fetched == 1) {
        int length = (int)wcslen(tag);
        // +1 for the separator, +1 for the terminator.
        if (used + length + 2 <= capacity) {
            if (used > 0) {
                buffer[used++] = L'\n';
            }
            wmemcpy(buffer + used, tag, (size_t)length);
            used += length;
        }
        CoTaskMemFree(tag);
        tag = NULL;
    }
    IEnumString_Release(languages);

    buffer[used] = L'\0';
    return used;
}

/// A checker for `tag`, created on first use and kept. Creating one is not cheap and the set
/// of languages in play is the set of installed keyboard layouts, so the cache is small and
/// effectively never turns over.
static ISpellChecker *wend_checker_for(const wchar_t *tag) {
    for (int i = 0; i < WEND_CACHE_SLOTS; i++) {
        if (g_slots[i].checker != NULL && wcscmp(g_slots[i].tag, tag) == 0) {
            return g_slots[i].checker;
        }
    }
    if (!wend_spell_init()) {
        return NULL;
    }
    if (wcslen(tag) >= WEND_TAG_MAX) {
        return NULL;
    }

    ISpellChecker *checker = NULL;
    if (FAILED(ISpellCheckerFactory_CreateSpellChecker(g_factory, tag, &checker)) ||
        checker == NULL) {
        return NULL;
    }

    int slot = -1;
    for (int i = 0; i < WEND_CACHE_SLOTS; i++) {
        if (g_slots[i].checker == NULL) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        // More languages than slots: evict round-robin rather than leak or refuse.
        slot = g_next_slot;
        g_next_slot = (g_next_slot + 1) % WEND_CACHE_SLOTS;
        ISpellChecker_Release(g_slots[slot].checker);
    }
    // Bounded by the length check above; wcscpy would only draw a deprecation warning.
    wmemcpy(g_slots[slot].tag, tag, wcslen(tag) + 1);
    g_slots[slot].checker = checker;
    return checker;
}

int wend_spell_check(const wchar_t *language_tag, const wchar_t *word) {
    if (language_tag == NULL || word == NULL || word[0] == L'\0') {
        return -1;
    }
    ISpellChecker *checker = wend_checker_for(language_tag);
    if (checker == NULL) {
        return -1;
    }

    IEnumSpellingError *errors = NULL;
    if (FAILED(ISpellChecker_Check(checker, word, &errors)) || errors == NULL) {
        return -1;
    }

    // A correctly-spelled word yields an empty enumerator, i.e. the first Next() is S_FALSE.
    ISpellingError *first = NULL;
    HRESULT hr = IEnumSpellingError_Next(errors, &first);
    int correct = (hr == S_FALSE);
    if (first != NULL) {
        ISpellingError_Release(first);
    }
    IEnumSpellingError_Release(errors);
    return correct ? 1 : 0;
}

void wend_spell_shutdown(void) {
    for (int i = 0; i < WEND_CACHE_SLOTS; i++) {
        if (g_slots[i].checker != NULL) {
            ISpellChecker_Release(g_slots[i].checker);
            g_slots[i].checker = NULL;
            g_slots[i].tag[0] = L'\0';
        }
    }
    if (g_factory != NULL) {
        ISpellCheckerFactory_Release(g_factory);
        g_factory = NULL;
    }
    g_attempted = 0;
}
