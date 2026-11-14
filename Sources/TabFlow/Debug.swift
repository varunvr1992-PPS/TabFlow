import Cocoa

/// Appends lines to ~/Library/Logs/TabFlow.log (kept small).
enum Log {
    private static let path = NSHomeDirectory() + "/Library/Logs/TabFlow.log"
    private static let queue = DispatchQueue(label: "tabflow.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date()))  \(msg)\n"
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(atPath: path)
            }
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Test hooks, only active after:  defaults write local.tabflow.app debugCommands -bool YES
/// Send with: distributed notification "local.tabflow.debug", object = command string.
enum DebugCommands {
    static func install() {
        guard UserDefaults.standard.bool(forKey: "debugCommands") else { return }
        Log.write("debug commands enabled")
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.tabflow.debug"),
                                                            object: nil, queue: .main) { n in
            guard let cmd = n.object as? String else { return }
            run(cmd)
        }
    }

    private static func run(_ cmd: String) {
        Log.write("debug cmd: \(cmd)")
        let sw = SwitcherController.shared
        let parts = cmd.split(separator: " ").map(String.init)
        switch parts.first ?? "" {
        case "open":
            let i = Int(parts[safe: 1] ?? "0") ?? 0
            if let sc = Prefs.shared.s.shortcuts[safe: i] { sw.debugBegin(sc) }
        case "next": sw.debugKey(KeyCodes.tab, char: nil)
        case "key": sw.debugKey(Int64(parts[safe: 1] ?? "0") ?? 0, char: parts[safe: 2])
        case "commit": sw.commit()
        case "cancel": sw.cancel()
        case "dump":
            let st = WindowStore.shared
            Log.write("tap running=\(HotkeyManager.shared.isRunning) ax=\(Permissions.accessibility) sr=\(Permissions.screenRecording) items=\(st.items.count) mru=\(st.mru.prefix(5))")
            for w in st.sorted(st.items, by: .recent) {
                Log.write("  [\(w.wid)] \(w.appName) — \(w.title)  min=\(w.isMinimized) hid=\(w.isAppHidden) fs=\(w.isFullscreen) cur=\(w.isOnCurrentSpace) space=\(w.spaceLabel ?? "-") ax=\(w.ax != nil)")
            }
        case "axdebug":
            let name = parts.dropFirst().joined(separator: " ").lowercased()
            for app in NSWorkspace.shared.runningApplications where (app.localizedName ?? "").lowercased() == name {
                let el = AXUIElementCreateApplication(app.processIdentifier)
                var v: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v)
                let wins = AX.windows(el)
                Log.write("axdebug \(name) pid=\(app.processIdentifier) policy=\(app.activationPolicy.rawValue) windowsErr=\(err.rawValue) count=\(wins.count)")
                for w in wins {
                    Log.write("   role=\(AX.string(w, kAXRoleAttribute) ?? "-") sub=\(AX.string(w, kAXSubroleAttribute) ?? "-") title=\(AX.string(w, kAXTitleAttribute) ?? "-") size=\(AX.size(w, kAXSizeAttribute).map { "\($0)" } ?? "-") wid=\(Private.windowID(of: w).map(String.init) ?? "-")")
                }
                let cg = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) }
                for d in cg {
                    Log.write("   cg wid=\(d[kCGWindowNumber as String] ?? "-") layer=\(d[kCGWindowLayer as String] ?? "-") onscreen=\(d[kCGWindowIsOnscreen as String] ?? "-") bounds=\(d[kCGWindowBounds as String] ?? "-") name=\(d[kCGWindowName as String] ?? "-")")
                }
            }
        case "state":
            Log.write("switcher active=\(sw.isActive) searching=\(sw.searching) items=\(sw.items.map { "\($0.appName):\($0.title.prefix(25))" }) selected=\(sw.debugSelected)")
        default: break
        }
    }
}
