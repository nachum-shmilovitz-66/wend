// LaunchAtLogin (Windows): the counterpart of the macOS build's SMAppService registration.
//
// A value under HKCU\…\CurrentVersion\Run, which is the per-user, no-privileges-required way
// to start at sign-in. Unlike SMAppService this needs no signed bundle, so it works the same
// whether Wend was installed or is being run straight out of a build directory.

import WinSDK

enum LaunchAtLogin {
    private static let subkey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    private static let valueName = "Wend"

    /// Path of the running executable, quoted — Run entries are command lines, so an unquoted
    /// path with a space in it would be read as a command plus arguments.
    static var command: String {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let written = buffer.withUnsafeMutableBufferPointer {
            GetModuleFileNameW(nil, $0.baseAddress, DWORD($0.count))
        }
        guard written > 0 else { return "" }
        return "\"\(stringFromWide(buffer))\""
    }

    static var isEnabled: Bool {
        registryString(root: hkeyCurrentUser, subkey: subkey, name: valueName) != nil
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            let value = command
            guard !value.isEmpty else { return }
            var buffer = Array(value.utf16)
            buffer.append(0)
            let bytes = DWORD(buffer.count * MemoryLayout<WCHAR>.size)
            _ = withWide(subkey) { key in
                withWide(valueName) { name in
                    buffer.withUnsafeBufferPointer { data in
                        RegSetKeyValueW(hkeyCurrentUser, key, name, DWORD(REG_SZ),
                                        data.baseAddress, bytes)
                    }
                }
            }
        } else {
            _ = withWide(subkey) { key in
                withWide(valueName) { name in
                    RegDeleteKeyValueW(hkeyCurrentUser, key, name)
                }
            }
        }
    }

    /// First launch only: enable Launch at Login so Wend returns after a restart. The user can
    /// turn it off from the menu afterwards — we never re-enable.
    static func enableOnFirstRun() {
        let key = "didInitialLoginItemSetup"
        guard !Settings.bool(key) else { return }
        Settings.setBool(key, true)
        guard !isEnabled else { return }
        setEnabled(true)
        Log.write("enabled Launch at Login on first run")
    }
}
