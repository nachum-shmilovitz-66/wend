// InputSourceProvider (macOS): reads every enabled keyboard layout from Text Input
// Sources and renders each into a Core LayoutTable using UCKeyTranslate. This is what
// makes the app language-agnostic: whatever layouts the user enables in System Settings
// become available here with zero per-language code.

import Foundation
import Carbon
import KeyLayoutCore

final class InputSourceProvider {

    /// All enabled keyboard layouts as Core tables. Input methods (Pinyin, Kotoeri, …)
    /// have no Unicode key-layout data and are skipped.
    func installedLayouts() -> [LayoutTable] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(filter, false) else { return [] }
        let list = unmanaged.takeRetainedValue()

        var tables: [LayoutTable] = []
        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let source = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            if let table = buildTable(from: source) {
                tables.append(table)
            }
        }
        return tables
    }

    /// The input-source id of the layout currently active (the user's typing layout).
    func currentLayoutID() -> String? {
        guard let unmanaged = TISCopyCurrentKeyboardLayoutInputSource() else { return nil }
        let source = unmanaged.takeRetainedValue()
        return stringProperty(source, kTISPropertyInputSourceID)
    }

    // MARK: - Building one table

    private func buildTable(from source: TISInputSource) -> LayoutTable? {
        guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
        guard let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil // e.g. an input method, not a plain layout
        }
        let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
        let language = primaryLanguage(of: source)
        let data = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data

        let entries = translateAllKeys(layoutData: data)
        guard !entries.isEmpty else { return nil }
        return LayoutTable(id: id, localizedName: name, languageCode: language, entries: entries)
    }

    /// Run UCKeyTranslate across the main key block × {none, shift, option, shift+option}.
    private func translateAllKeys(layoutData: Data) -> [(KeyStroke, Character)] {
        let kbdType = UInt32(LMGetKbdType())
        let noDeadKeys = OptionBits(1 << kUCKeyTranslateNoDeadKeysBit)

        // (modifierKeyState in bits 8-15, shift?, option?)
        let modifierStates: [(UInt32, Bool, Bool)] = [
            (0, false, false),
            (UInt32(shiftKey >> 8), true, false),
            (UInt32(optionKey >> 8), false, true),
            (UInt32((shiftKey | optionKey) >> 8), true, true),
        ]

        var entries: [(KeyStroke, Character)] = []
        return layoutData.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> [(KeyStroke, Character)] in
            guard let base = rawBuffer.baseAddress else { return [] }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)

            for keyCode in UInt16(0)...UInt16(127) {
                for (modState, shift, option) in modifierStates {
                    var deadKeyState: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 8)
                    var length = 0
                    let status = UCKeyTranslate(
                        layout,
                        keyCode,
                        UInt16(kUCKeyActionDown),
                        modState,
                        kbdType,
                        noDeadKeys,
                        &deadKeyState,
                        chars.count,
                        &length,
                        &chars
                    )
                    guard status == noErr, length == 1 else { continue }
                    guard let scalar = Unicode.Scalar(chars[0]), scalar.value >= 0x20 else { continue }
                    let ch = Character(scalar)
                    if ch.isWhitespace { continue }
                    entries.append((KeyStroke(keyCode: keyCode, shift: shift, option: option), ch))
                }
            }
            return entries
        }
    }

    // MARK: - Property helpers

    private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return (Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()) as String
    }

    private func primaryLanguage(of source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
        return languages?.first
    }
}
