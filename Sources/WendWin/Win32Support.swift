// Win32Support: the small amount of glue Swift needs to talk to the `…W` entry points —
// wide strings, the constants and macros the Clang importer can't bring across, and the
// fixed-size WCHAR arrays that Win32 structs embed.

import WinSDK

/// Call `body` with `text` as a NUL-terminated UTF-16 buffer, which is what every `…W` entry
/// point wants. Swift bridges String to C strings as UTF-8 only, so this has to be manual.
func withWide<R>(_ text: String, _ body: (UnsafePointer<WCHAR>) throws -> R) rethrows -> R {
    var buffer = Array(text.utf16)
    buffer.append(0)
    return try buffer.withUnsafeBufferPointer { try body($0.baseAddress!) }
}

/// A NUL-terminated UTF-16 buffer as a String, stopping at the first NUL. Win32 fills buffers
/// to their declared size and terminates within them, so the tail is always junk.
func stringFromWide(_ buffer: [WCHAR]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
}

/// Copy `text` into a fixed-size WCHAR array field — Swift imports those as tuples, so they
/// can only be written through raw bytes. Truncates to fit and always leaves a terminator.
func setWideField<Field>(_ field: inout Field, _ text: String) {
    withUnsafeMutableBytes(of: &field) { raw in
        let slot = raw.bindMemory(to: WCHAR.self)
        guard slot.count > 1 else { return }
        let units = Array(text.utf16.prefix(slot.count - 1))
        for (index, unit) in units.enumerated() {
            slot[index] = unit
        }
        slot[units.count] = 0
    }
}

@inline(__always)
func loWord(_ value: UInt) -> UInt16 { UInt16(value & 0xFFFF) }

@inline(__always)
func hiWord(_ value: UInt) -> UInt16 { UInt16((value >> 16) & 0xFFFF) }

/// An `HKL` is an opaque handle, but Wend needs its numeric value twice over: as a stable
/// identity for a layout within a run, and because the language id and the layout id are
/// packed into its two halves.
func hklValue(_ hkl: HKL?) -> UInt {
    UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(hkl)))
}

// The predefined registry roots are macros that cast a constant to HKEY, which the importer
// drops on the floor.
let hkeyCurrentUser = HKEY(bitPattern: UInt(0x8000_0001))!
let hkeyLocalMachine = HKEY(bitPattern: UInt(0x8000_0002))!

/// KEY_READ, likewise a macro: STANDARD_RIGHTS_READ | KEY_QUERY_VALUE
/// | KEY_ENUMERATE_SUB_KEYS | KEY_NOTIFY.
let registryReadAccess: DWORD = 0x2_0019

/// Stamped on the keystrokes Wend synthesizes, so its own keyboard hook can recognise them.
///
/// The hook has to ignore Wend's Ctrl+C and Ctrl+V, or they would count as "a key was pressed
/// during this Shift press" and swallow the next trigger. Skipping everything marked injected
/// would do that too, but it would also ignore the user — key remappers, on-screen keyboards
/// and other assistive input all arrive injected, and their double-Shift is as real as anyone's.
let wendInjectedSignature: ULONG_PTR = 0x5745_4E44   // 'WEND'

/// Read a REG_SZ value, or nil if it isn't there.
func registryString(root: HKEY, subkey: String, name: String) -> String? {
    var size: DWORD = 0
    var status = withWide(subkey) { key in
        withWide(name) { valueName in
            RegGetValueW(root, key, valueName, DWORD(RRF_RT_REG_SZ), nil, nil, &size)
        }
    }
    guard status == 0, size > 0 else { return nil }

    var buffer = [WCHAR](repeating: 0, count: Int(size) / MemoryLayout<WCHAR>.size + 1)
    status = withWide(subkey) { key in
        withWide(name) { valueName in
            buffer.withUnsafeMutableBufferPointer { output in
                RegGetValueW(root, key, valueName, DWORD(RRF_RT_REG_SZ), nil,
                             output.baseAddress, &size)
            }
        }
    }
    guard status == 0 else { return nil }
    return stringFromWide(buffer)
}

/// Lowercase hex, fixed width — used for layout ids and KLIDs, where the width is significant.
func hex(_ value: UInt32, width: Int) -> String {
    let digits = String(value, radix: 16, uppercase: true)
    guard digits.count < width else { return digits }
    return String(repeating: "0", count: width - digits.count) + digits
}
