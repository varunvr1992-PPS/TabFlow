import Cocoa

/// Global keyboard hook (a CGEvent tap). Needs Accessibility permission.
final class HotkeyManager {
    static let shared = HotkeyManager()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// When set, the next key press is captured for the shortcut recorder.
    var recordHandler: ((Int64, UInt64) -> Void)?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: nil)
        else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func ensureEnabled() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue

        if type == .keyDown, let rec = recordHandler {
            recordHandler = nil
            rec(keyCode, flags & ModMask.relevant)
            return nil
        }

        let sw = SwitcherController.shared
        if sw.isActive {
            switch type {
            case .flagsChanged:
                if !sw.searching, let sc = sw.shortcut, (flags & sc.modifiers) != sc.modifiers {
                    sw.commit()
                }
                return Unmanaged.passUnretained(event)
            case .keyDown:
                sw.handleKeyDown(keyCode: keyCode, flags: flags, event: event)
                return nil
            case .keyUp:
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let prefs = Prefs.shared.s
        if prefs.paused { return Unmanaged.passUnretained(event) }
        let mods = flags & ModMask.relevant
        for sc in prefs.shortcuts where sc.enabled && sc.modifiers != 0 {
            guard KeyCodes.matches(keyCode, sc.keyCode), mods == sc.modifiers else { continue }
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               prefs.disabledInApps.contains(front) {
                return Unmanaged.passUnretained(event)
            }
            Log.write("shortcut \(sc.display) pressed")
            sw.begin(sc, reverse: flags & ModMask.shift != 0)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    HotkeyManager.shared.handle(type, event)
}

/// Turns the built-in macOS shortcuts (⌘Tab, ⌘`) off while TabFlow owns them,
/// and back on when it quits or the shortcut is released.
enum SystemHotkeys {
    private(set) static var disabled = Set<Int32>()

    static func apply(_ s: Settings, active: Bool) {
        var want = Set<Int32>()
        if active && !s.paused {
            for sc in s.shortcuts where sc.enabled && sc.modifiers == ModMask.command {
                if sc.keyCode == KeyCodes.tab {
                    want.insert(Private.SystemHotKey.commandTab.rawValue)
                    want.insert(Private.SystemHotKey.commandShiftTab.rawValue)
                }
                if KeyCodes.matches(sc.keyCode, KeyCodes.aboveTab) {
                    want.insert(Private.SystemHotKey.commandKeyAboveTab.rawValue)
                }
            }
        }
        for id in disabled.subtracting(want) { Private.setSystemHotKey(id, enabled: true) }
        for id in want.subtracting(disabled) { Private.setSystemHotKey(id, enabled: false) }
        disabled = want
    }

    static func restoreAll() {
        for id in disabled { Private.setSystemHotKey(id, enabled: true) }
        disabled = []
    }
}
