import Cocoa
import ServiceManagement

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    static func openAccessibilityPane() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    static func openScreenRecordingPane() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
    private static func open(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    /// Screen Recording only takes effect after a relaunch.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

enum LoginItem {
    private static var agentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/local.tabflow.app.plist"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentPath)
    }

    static func set(_ on: Bool) {
        if on {
            do { try SMAppService.mainApp.register() } catch { writeAgent() }
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(atPath: agentPath)
        }
    }

    private static func writeAgent() {
        let plist: [String: Any] = [
            "Label": "local.tabflow.app",
            "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        let dir = (agentPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: agentPath, atomically: true)
    }
}

enum AppInfo {
    static func url(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
    static func name(_ bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let n = app.localizedName { return n }
        if let u = url(bundleID) { return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "") }
        return bundleID
    }
    static func icon(_ bundleID: String) -> NSImage {
        if let u = url(bundleID) { return NSWorkspace.shared.icon(forFile: u.path) }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }
}
