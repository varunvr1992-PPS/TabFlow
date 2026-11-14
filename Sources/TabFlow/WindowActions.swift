import Cocoa

enum WindowAction {
    case close, minimize, hideApp, quitApp, fullscreen
}

enum WindowActions {
    private static let queue = DispatchQueue(label: "tabflow.actions", qos: .userInteractive)

    static func focus(_ item: WindowItem) {
        let app = NSRunningApplication(processIdentifier: item.pid)
        if item.isWindowless {
            // Re-opening an app with no windows usually makes it open a fresh one.
            if let url = app?.bundleURL {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            } else {
                app?.activate(options: [.activateIgnoringOtherApps])
            }
            return
        }
        let ax = item.ax
        let pid = item.pid, wid = item.wid, minimized = item.isMinimized
        if app?.isHidden == true { app?.unhide() }
        queue.async {
            if minimized, let ax { AX.set(ax, kAXMinimizedAttribute, kCFBooleanFalse) }
            let ok = Private.focus(pid: pid, wid: wid)
            if let ax {
                AX.perform(ax, kAXRaiseAction)
                AX.set(ax, kAXMainAttribute, kCFBooleanTrue)
            }
            if !ok {
                DispatchQueue.main.async { app?.activate(options: [.activateIgnoringOtherApps]) }
            }
        }
    }

    static func perform(_ action: WindowAction, on item: WindowItem) {
        let app = NSRunningApplication(processIdentifier: item.pid)
        switch action {
        case .quitApp:
            app?.terminate()
        case .hideApp:
            if app?.isHidden == true { app?.unhide() } else { app?.hide() }
        case .close:
            guard let ax = item.ax else { return }
            queue.async {
                if let btn = AX.element(ax, kAXCloseButtonAttribute) { AX.perform(btn, kAXPressAction) }
            }
        case .minimize:
            guard let ax = item.ax else { return }
            let target = !item.isMinimized
            queue.async { AX.set(ax, kAXMinimizedAttribute, target ? kCFBooleanTrue : kCFBooleanFalse) }
        case .fullscreen:
            guard let ax = item.ax else { return }
            let target = !item.isFullscreen
            queue.async { AX.set(ax, "AXFullScreen", target ? kCFBooleanTrue : kCFBooleanFalse) }
        }
    }
}
