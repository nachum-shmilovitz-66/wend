// InputSourceSwitcher (macOS): switch the active keyboard layout after a fix, so the
// user's next keystrokes land in the language they actually meant.

import Foundation
import Carbon

final class InputSourceSwitcher {
    func selectLayout(id: String) {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(filter, false) else { return }
        let list = unmanaged.takeRetainedValue()
        guard CFArrayGetCount(list) > 0, let raw = CFArrayGetValueAtIndex(list, 0) else { return }
        let source = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
        TISSelectInputSource(source)
    }
}
