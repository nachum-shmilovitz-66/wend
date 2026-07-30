// Settings (Windows): the stand-in for the macOS build's UserDefaults — a handful of flags
// under HKCU\Software\Wend. The registry rather than a file so the settings survive the app
// being moved or reinstalled, and so there is no path to get wrong before the log exists.

import WinSDK

enum Settings {
    private static let subkey = "Software\\Wend"

    static func bool(_ name: String, default fallback: Bool = false) -> Bool {
        var value: DWORD = 0
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = withWide(subkey) { key in
            withWide(name) { valueName in
                RegGetValueW(hkeyCurrentUser, key, valueName, DWORD(RRF_RT_REG_DWORD),
                             nil, &value, &size)
            }
        }
        guard status == 0 else { return fallback }
        return value != 0
    }

    static func setBool(_ name: String, _ newValue: Bool) {
        var value: DWORD = newValue ? 1 : 0
        _ = withWide(subkey) { key in
            withWide(name) { valueName in
                RegSetKeyValueW(hkeyCurrentUser, key, valueName, DWORD(REG_DWORD),
                                &value, DWORD(MemoryLayout<DWORD>.size))
            }
        }
    }
}
