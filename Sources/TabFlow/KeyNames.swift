import Cocoa
import Carbon

enum KeyNames {
    private static let special: [Int64: String] = [
        48: "Tab", 49: "Space", 36: "Return", 76: "Enter", 53: "Esc", 51: "Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Human-readable name for a key code, using the current keyboard layout.
    static func name(_ code: Int64) -> String {
        if let s = special[code] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status: OSStatus = data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &dead, 4, &len, &chars)
        }
        guard status == noErr, len > 0 else { return "Key \(code)" }
        let s = String(utf16CodeUnits: chars, count: len).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Key \(code)" : s.uppercased()
    }
}
