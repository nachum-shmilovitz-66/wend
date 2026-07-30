// InputSourceProvider (Windows): reads every installed keyboard layout and renders each into
// a Core LayoutTable using ToUnicodeEx. Same job as the macOS TIS/UCKeyTranslate provider, and
// the same payoff: whatever layouts the user adds under Settings ▸ Time & language become
// available here with no per-language code.
//
// The physical-key identity in a KeyStroke is the **scan code**, not the virtual key. Windows
// virtual keys are layout-dependent — the key that types `q` on a US layout reports VK_A under
// French — so a virtual key would identify a *character position*, which is exactly the thing
// the conversion is trying to change. Scan codes are the hardware position and are stable.

import WinSDK
import Foundation
import KeyLayoutCore

final class InputSourceProvider {

    /// The character-producing block of a PC keyboard: number row, the three letter rows, and
    /// the OEM keys among them. Deliberately not the whole 0x00…0x58 range — Escape, Tab,
    /// Enter, Space and the function keys produce nothing convertible, and the numeric keypad
    /// would contribute a second key for digits every layout already agrees on, muddying the
    /// character→key map for no gain.
    private static let scanCodes: [UInt16] =
        Array(0x02...0x0D)      // 1 2 3 … 0 - =
        + Array(0x10...0x1B)    // Q W E … [ ]
        + Array(0x1E...0x28)    // A S D … ; '
        + [0x29]                // ` (backquote)
        + Array(0x2B...0x35)    // \ Z X C … , . /
        + [0x56]                // the extra key on 102-key boards

    /// ToUnicodeEx is not a pure function — see `translate` — so the sweep is run once per set
    /// of installed layouts rather than on every fix. The signature is the layout handles
    /// themselves, so adding or removing a layout rebuilds and nothing else does.
    private var cache: (signature: [UInt], tables: [LayoutTable])?

    /// All installed keyboard layouts as Core tables.
    func installedLayouts() -> [LayoutTable] {
        let handles = layoutHandles()
        let signature = handles.map(hklValue)
        if let cache, cache.signature == signature { return cache.tables }

        let tables = handles.compactMap(buildTable(from:))
        cache = (signature, tables)
        return tables
    }

    /// The layout the *foreground* window types in — which is the one the user typed the
    /// selected text with, and not necessarily Wend's own. Keyboard layout is per-thread on
    /// Windows, so asking for "the current layout" without saying whose gives the wrong answer.
    func currentLayoutID() -> String? {
        let foreground = GetForegroundWindow()
        let thread = GetWindowThreadProcessId(foreground, nil)
        guard let hkl = GetKeyboardLayout(thread) else { return nil }
        return Self.identifier(for: hkl)
    }

    // MARK: - Enumeration

    private func layoutHandles() -> [HKL?] {
        let count = GetKeyboardLayoutList(0, nil)
        guard count > 0 else { return [] }
        var list = [HKL?](repeating: nil, count: Int(count))
        let filled = list.withUnsafeMutableBufferPointer {
            GetKeyboardLayoutList(count, $0.baseAddress)
        }
        guard filled > 0 else { return [] }
        return Array(list.prefix(Int(filled)))
    }

    /// Stable identity for a layout within this run. An HKL is a handle, not a persisted id —
    /// nothing in Wend stores one across launches, so its numeric value is identity enough,
    /// and `InputSourceSwitcher` turns it straight back into a handle.
    static func identifier(for hkl: HKL?) -> String {
        hex(UInt32(truncatingIfNeeded: hklValue(hkl)), width: 8)
    }

    // MARK: - Building one table

    private func buildTable(from hkl: HKL?) -> LayoutTable? {
        guard let hkl else { return nil }
        let value = hklValue(hkl)
        let languageID = loWord(value)
        let entries = translateAllKeys(hkl: hkl)
        guard !entries.isEmpty else { return nil }

        return LayoutTable(
            id: Self.identifier(for: hkl),
            localizedName: Self.layoutName(hklValue: value, languageID: languageID),
            languageCode: Self.languageCode(languageID: languageID),
            entries: entries
        )
    }

    /// Run ToUnicodeEx across the character block × {none, shift, AltGr, shift+AltGr}.
    ///
    /// AltGr is the Windows counterpart of the Mac's Option, and is Ctrl+Alt as far as the
    /// keyboard state array is concerned — which is why both bytes go down for it.
    private func translateAllKeys(hkl: HKL) -> [(KeyStroke, Character)] {
        let modifierStates: [(shift: Bool, option: Bool)] = [
            (false, false),
            (true, false),
            (false, true),
            (true, true),
        ]

        var entries: [(KeyStroke, Character)] = []
        var state = [BYTE](repeating: 0, count: 256)

        for scanCode in Self.scanCodes {
            let virtualKey = MapVirtualKeyExW(UINT(scanCode), UINT(MAPVK_VSC_TO_VK_EX), hkl)
            guard virtualKey != 0 else { continue }

            for modifiers in modifierStates {
                for index in state.indices { state[index] = 0 }
                if modifiers.shift {
                    state[Int(VK_SHIFT)] = 0x80
                }
                if modifiers.option {
                    state[Int(VK_CONTROL)] = 0x80
                    state[Int(VK_MENU)] = 0x80
                }
                guard let character = translate(
                    virtualKey: virtualKey,
                    scanCode: scanCode,
                    state: &state,
                    hkl: hkl
                ) else { continue }

                entries.append((
                    KeyStroke(keyCode: scanCode, shift: modifiers.shift, option: modifiers.option),
                    character
                ))
            }
        }
        return entries
    }

    /// One key press under one modifier state, or nil if it produces nothing usable.
    ///
    /// ToUnicodeEx keeps pending dead-key state inside the keyboard layout itself, not in the
    /// buffer it is handed. A dead key left pending by this sweep would therefore combine with
    /// the next character the *user* types in whatever app has focus — the sweep would corrupt
    /// live typing. Every translation is bracketed by a flush that drains it.
    private func translate(
        virtualKey: UINT,
        scanCode: UInt16,
        state: inout [BYTE],
        hkl: HKL
    ) -> Character? {
        flushDeadKeys(hkl: hkl)
        var buffer = [WCHAR](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBufferPointer { output in
            state.withUnsafeMutableBufferPointer { keyState in
                ToUnicodeEx(virtualKey, UINT(scanCode), keyState.baseAddress,
                            output.baseAddress, Int32(output.count), 0, hkl)
            }
        }
        flushDeadKeys(hkl: hkl)

        // 0 = the key produces nothing, negative = it is a dead key, >1 = a ligature. Only a
        // single character can take part in a one-to-one key remap.
        guard count == 1 else { return nil }
        guard let scalar = Unicode.Scalar(buffer[0]), scalar.value >= 0x20 else { return nil }
        let character = Character(scalar)
        return character.isWhitespace ? nil : character
    }

    /// Drain any pending dead key by translating a space until the layout stops reporting one.
    private func flushDeadKeys(hkl: HKL) {
        var state = [BYTE](repeating: 0, count: 256)
        var buffer = [WCHAR](repeating: 0, count: 8)
        let scanCode = MapVirtualKeyExW(UINT(VK_SPACE), UINT(MAPVK_VK_TO_VSC), hkl)

        // Two dead keys can be pending at once on some layouts; the bound stops a broken
        // layout turning this into a spin.
        for _ in 0..<4 {
            let count = buffer.withUnsafeMutableBufferPointer { output in
                state.withUnsafeMutableBufferPointer { keyState in
                    ToUnicodeEx(UINT(VK_SPACE), scanCode, keyState.baseAddress,
                                output.baseAddress, Int32(output.count), 0, hkl)
                }
            }
            if count >= 0 { return }
        }
    }

    // MARK: - Naming

    private static let layoutsKey = "SYSTEM\\CurrentControlSet\\Control\\Keyboard Layouts"

    /// Best-effort BCP-47 primary language for the layout — "he", "en", "de" — which is the key
    /// the spell-checker is asked about. Region is dropped to match what Core expects.
    static func languageCode(languageID: UInt16) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 85)   // LOCALE_NAME_MAX_LENGTH
        let written = buffer.withUnsafeMutableBufferPointer {
            LCIDToLocaleName(DWORD(languageID), $0.baseAddress, Int32($0.count), 0)
        }
        guard written > 0 else { return nil }
        let name = stringFromWide(buffer)               // e.g. "he-IL"
        guard let primary = name.split(separator: "-").first else { return nil }
        return String(primary)
    }

    /// The layout's own name ("US", "Hebrew Standard"). That is what tells two layouts of the
    /// same language apart, which the language display name alone cannot — so the registry is
    /// worth the lookup. Falls back to the language name, then to the raw id, so a layout is
    /// never nameless in a diagnostic dump.
    static func layoutName(hklValue value: UInt, languageID: UInt16) -> String {
        if let klid = klid(hklValue: value, languageID: languageID),
           let text = registryString(root: hkeyLocalMachine,
                                     subkey: "\(layoutsKey)\\\(klid)",
                                     name: "Layout Text"),
           !text.isEmpty {
            return text
        }
        return localeDisplayName(languageID: languageID) ?? "0x\(hex(UInt32(languageID), width: 4))"
    }

    /// The eight-hex-digit keyboard layout id the registry is keyed by.
    ///
    /// An HKL packs the language into its low word. The high word is either zero or the same
    /// language — meaning the default layout for it — or `0xFnnn`, where `nnn` is a "Layout Id"
    /// that has to be looked up, because the KLID it belongs to can't be derived from it.
    private static func klid(hklValue value: UInt, languageID: UInt16) -> String? {
        let high = hiWord(value)
        if high & 0xF000 == 0xF000 {
            return klid(forLayoutID: high & 0x0FFF)
        }
        if high == 0 || high == languageID {
            return hex(UInt32(languageID), width: 8)
        }
        return hex((UInt32(high) << 16) | UInt32(languageID), width: 8)
    }

    private static func klid(forLayoutID layoutID: UInt16) -> String? {
        var key: HKEY?
        let opened = withWide(layoutsKey) {
            RegOpenKeyExW(hkeyLocalMachine, $0, 0, registryReadAccess, &key)
        }
        guard opened == 0, let key else { return nil }
        defer { RegCloseKey(key) }

        let wanted = hex(UInt32(layoutID), width: 4)
        var index: DWORD = 0
        while true {
            var name = [WCHAR](repeating: 0, count: 64)
            var length = DWORD(name.count)
            let status = name.withUnsafeMutableBufferPointer {
                RegEnumKeyExW(key, index, $0.baseAddress, &length, nil, nil, nil, nil)
            }
            guard status == 0 else { return nil }
            index += 1

            let candidate = stringFromWide(name)
            if let id = registryString(root: hkeyLocalMachine,
                                       subkey: "\(layoutsKey)\\\(candidate)",
                                       name: "Layout Id"),
               id.uppercased() == wanted {
                return candidate
            }
        }
    }

    private static func localeDisplayName(languageID: UInt16) -> String? {
        var localeName = [WCHAR](repeating: 0, count: 85)
        let named = localeName.withUnsafeMutableBufferPointer {
            LCIDToLocaleName(DWORD(languageID), $0.baseAddress, Int32($0.count), 0)
        }
        guard named > 0 else { return nil }

        var display = [WCHAR](repeating: 0, count: 128)
        let written = localeName.withUnsafeBufferPointer { name in
            display.withUnsafeMutableBufferPointer { output in
                GetLocaleInfoEx(name.baseAddress, DWORD(LOCALE_SLOCALIZEDDISPLAYNAME),
                                output.baseAddress, Int32(output.count))
            }
        }
        guard written > 0 else { return nil }
        return stringFromWide(display)
    }
}
