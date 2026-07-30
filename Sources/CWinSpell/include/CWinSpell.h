// CWinSpell: a flat C interface over the Windows Spell Checking API.
//
// `ISpellChecker` is COM-only, and the Swift side wants one question answered — "is this a
// real word in this language?". Reaching through a COM vtable from Swift is possible but
// verbose and easy to get subtly wrong around ownership; this keeps all of that in C and
// hands Swift four ordinary functions.
//
// Everything here is single-threaded on purpose: the caller is Wend's message-loop thread,
// which is also the thread that runs a fix, and the COM apartment is initialised there.

#ifndef CWINSPELL_H
#define CWINSPELL_H

#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initialise COM and the spell-checker factory. Safe to call repeatedly; returns 1 once the
/// factory is available, 0 if it could not be created (in which case every other call fails
/// closed and Wend simply validates no words).
int wend_spell_init(void);

/// 1 if Windows has a dictionary for `language_tag` (a BCP-47 tag, e.g. "he-IL"), else 0.
int wend_spell_supports(const wchar_t *language_tag);

/// The tags Windows has dictionaries for, joined by '\n', written into `buffer`. Returns the
/// number of wchar_t written, excluding the terminator.
int wend_spell_languages(wchar_t *buffer, int capacity);

/// 1 if `word` is spelled correctly in `language_tag`, 0 if not, -1 if it could not be
/// checked at all. Callers treat -1 as "not a word": an unavailable dictionary is no evidence.
int wend_spell_check(const wchar_t *language_tag, const wchar_t *word);

/// Release the cached checkers and the factory. Called on quit for tidiness; not required.
void wend_spell_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
