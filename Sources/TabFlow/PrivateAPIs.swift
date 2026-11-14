import Cocoa
import ApplicationServices

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

struct SpaceInfo {
    /// Space id -> 1-based "Desktop N" number (user desktops only).
    var desktopNumber: [CGSSpaceID: Int] = [:]
    /// Ordering of every space (desktops and full-screen spaces) left to right.
    var order: [CGSSpaceID: Int] = [:]
    var current: Set<CGSSpaceID> = []
    var fullscreen: Set<CGSSpaceID> = []
}

/// Thin wrappers around private macOS APIs (resolved at runtime with dlsym so a
/// missing symbol degrades gracefully instead of crashing). These are the same
/// APIs well-known window switchers rely on to see windows on other Desktops,
/// capture thumbnails quickly, and focus a specific window.
enum Private {
    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        if let h = skylight, let p = dlsym(h, name) { return unsafeBitCast(p, to: type) }
        if let p = dlsym(rtldDefault, name) { return unsafeBitCast(p, to: type) }
        return nil
    }

    private typealias MainConnectionFn = @convention(c) () -> CGSConnectionID
    private typealias HWCaptureFn = @convention(c) (CGSConnectionID, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32) -> Unmanaged<CFArray>?
    private typealias SetSymbolicHotKeyFn = @convention(c) (Int32, Bool) -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias AXCreateWithTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let mainConnectionFn = sym("CGSMainConnectionID", MainConnectionFn.self)
    private static let hwCapture = sym("CGSHWCaptureWindowList", HWCaptureFn.self)
    private static let setSymbolicHotKey = sym("CGSSetSymbolicHotKeyEnabled", SetSymbolicHotKeyFn.self)
    private static let copySpacesForWindows = sym("CGSCopySpacesForWindows", CopySpacesForWindowsFn.self)
    private static let copyManagedDisplaySpaces = sym("CGSCopyManagedDisplaySpaces", CopyManagedDisplaySpacesFn.self)
    private static let setFrontProcess = sym("_SLPSSetFrontProcessWithOptions", SetFrontProcessFn.self)
    private static let postEventRecord = sym("SLPSPostEventRecordTo", PostEventRecordFn.self)
    private static let getProcessForPID = sym("GetProcessForPID", GetProcessForPIDFn.self)
    private static let axGetWindow = sym("_AXUIElementGetWindow", AXGetWindowFn.self)
    private static let axCreateWithToken = sym("_AXUIElementCreateWithRemoteToken", AXCreateWithTokenFn.self)

    static let connection: CGSConnectionID = mainConnectionFn?() ?? 0

    // MARK: Symbolic (system) hotkeys

    enum SystemHotKey: Int32 {
        case commandTab = 1
        case commandShiftTab = 2
        case commandKeyAboveTab = 6
    }

    static func setSystemHotKey(_ id: Int32, enabled: Bool) {
        _ = setSymbolicHotKey?(id, enabled)
    }

    // MARK: Windows

    static func windowID(of el: AXUIElement) -> CGWindowID? {
        guard let f = axGetWindow else { return nil }
        var id: CGWindowID = 0
        guard f(el, &id) == .success, id != 0 else { return nil }
        return id
    }

    static var canBruteForceAX: Bool { axCreateWithToken != nil }

    /// Builds an AXUIElement for a given element id inside another process. Used to
    /// reach windows on other Desktops, which the normal AX window list omits.
    static func axElement(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        guard let f = axCreateWithToken else { return nil }
        var data = Data(count: 20)
        var p = pid, zero: Int32 = 0, magic: Int32 = 0x636f_636f, eid = elementID
        data.replaceSubrange(0..<4, with: Data(bytes: &p, count: 4))
        data.replaceSubrange(4..<8, with: Data(bytes: &zero, count: 4))
        data.replaceSubrange(8..<12, with: Data(bytes: &magic, count: 4))
        data.replaceSubrange(12..<20, with: Data(bytes: &eid, count: 8))
        return f(data as CFData)?.takeRetainedValue()
    }

    static func spaces(forWindow wid: CGWindowID) -> [CGSSpaceID] {
        guard let f = copySpacesForWindows else { return [] }
        let arr = [NSNumber(value: wid)] as CFArray
        guard let res = f(connection, 7, arr)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return res.map { $0.uint64Value }
    }

    static func spaceInfo() -> SpaceInfo {
        var info = SpaceInfo()
        guard let f = copyManagedDisplaySpaces,
              let displays = f(connection)?.takeRetainedValue() as? [[String: Any]] else { return info }
        var desktopCounter = 0
        var orderCounter = 0
        for display in displays {
            if let cur = display["Current Space"] as? [String: Any], let id = spaceID(cur) {
                info.current.insert(id)
            }
            for sp in (display["Spaces"] as? [[String: Any]]) ?? [] {
                guard let id = spaceID(sp) else { continue }
                orderCounter += 1
                info.order[id] = orderCounter
                let type = (sp["type"] as? NSNumber)?.intValue ?? 0
                if type == 4 {
                    info.fullscreen.insert(id)
                } else {
                    desktopCounter += 1
                    info.desktopNumber[id] = desktopCounter
                }
            }
        }
        return info
    }

    private static func spaceID(_ d: [String: Any]) -> CGSSpaceID? {
        if let n = d["ManagedSpaceID"] as? NSNumber { return n.uint64Value }
        if let n = d["id64"] as? NSNumber { return n.uint64Value }
        return nil
    }

    // MARK: Thumbnails

    static func captureWindow(_ wid: CGWindowID) -> CGImage? {
        if let f = hwCapture {
            var id = wid
            // ignoreGlobalClipShape | nominalResolution
            if let arr = f(connection, &id, 1, (1 << 11) | (1 << 9))?.takeRetainedValue() as [AnyObject]?,
               let first = arr.first {
                return (first as! CGImage)
            }
        }
        return nil
    }

    // MARK: Focus

    /// Brings a specific window to the front (switching Desktops if needed).
    @discardableResult
    static func focus(pid: pid_t, wid: CGWindowID) -> Bool {
        guard let getPSN = getProcessForPID, let setFront = setFrontProcess, let post = postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        _ = setFront(&psn, wid, 0x200) // userGenerated
        // "make key window" event records
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var w = wid
        withUnsafeBytes(of: &w) { raw in
            for i in 0..<4 { bytes[0x3c + i] = raw[i] }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = post(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = post(&psn, &bytes)
        return true
    }
}

// MARK: - Public Accessibility helpers

enum AX {
    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { (value(el, attr) as? NSNumber)?.boolValue }
    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func windows(_ app: AXUIElement) -> [AXUIElement] {
        guard let v = value(app, kAXWindowsAttribute) as? [AnyObject] else { return [] }
        return v.compactMap { obj in
            CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
        }
    }
    static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, attr as CFString, value) == .success
    }
    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }
}

enum ImageUtil {
    static func downscale(_ img: CGImage, maxWidth: Int) -> CGImage? {
        guard img.width > 0, img.height > 0 else { return nil }
        if img.width <= maxWidth { return img }
        let scale = CGFloat(maxWidth) / CGFloat(img.width)
        let w = maxWidth
        let h = max(1, Int(CGFloat(img.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return img }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

extension NSScreen {
    /// Screen frame in global CoreGraphics coordinates (origin top-left of main screen).
    var cgFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
