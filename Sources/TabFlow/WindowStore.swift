import Cocoa

final class WindowItem {
    let wid: CGWindowID          // 0 = app with no open windows
    let pid: pid_t
    var ax: AXUIElement?
    var title: String
    var titleIsEmpty = false
    let appName: String
    let bundleID: String?
    let icon: NSImage
    var isMinimized = false
    var isFullscreen = false
    var isAppHidden = false
    var isOnCurrentSpace = true
    var spaceLabel: String?
    var spaceOrder = 0
    var frame: CGRect = .zero    // global CG coordinates
    var zOrder = Int.max
    var thumbnail: CGImage?

    init(wid: CGWindowID, pid: pid_t, ax: AXUIElement?, title: String, appName: String, bundleID: String?, icon: NSImage) {
        self.wid = wid; self.pid = pid; self.ax = ax; self.title = title
        self.appName = appName; self.bundleID = bundleID; self.icon = icon
    }

    var isWindowless: Bool { wid == 0 }
    var key: String { isWindowless ? "app-\(pid)" : "w-\(wid)" }

    var badges: [String] {
        var b: [String] = []
        if isWindowless { b.append("No windows") }
        if isMinimized { b.append("Minimized") }
        if isAppHidden { b.append("Hidden") }
        if isFullscreen { b.append("Full screen") }
        if let s = spaceLabel, !isFullscreen, !isOnCurrentSpace { b.append(s) }
        return b
    }
}

private struct AppSnapshot {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage
    let hidden: Bool
}

private struct RawWindow {
    let wid: CGWindowID
    let pid: pid_t
    let ax: AXUIElement?
    let title: String
    let minimized: Bool
    let fullscreen: Bool
    let frame: CGRect
    let zOrder: Int
    let spaceIDs: [CGSSpaceID]
}

/// Keeps an up-to-date list of every window, plus a most-recently-used order.
final class WindowStore {
    static let shared = WindowStore()

    private(set) var items: [WindowItem] = []
    private(set) var mru: [CGWindowID] = []
    private var appMRU: [pid_t] = []
    var onChange: (() -> Void)?

    private let scanQueue = DispatchQueue(label: "tabflow.scan", qos: .userInteractive)
    private let focusQueue = DispatchQueue(label: "tabflow.focus", qos: .userInteractive)
    private let thumbQueue = DispatchQueue(label: "tabflow.thumbs", qos: .userInitiated)

    // scanQueue-owned caches
    private var axCache: [CGWindowID: AXUIElement] = [:]
    private var failedLookups = Set<CGWindowID>()
    private var lastGood: [pid_t: [RawWindow]] = [:]

    // main-thread state
    private var thumbCache: [CGWindowID: CGImage] = [:]
    private var refreshing = false
    private var refreshAgain = false
    private var pendingCallbacks: [() -> Void] = []
    private var debounce: DispatchWorkItem?
    private var observers: [pid_t: AXObserver] = [:]
    private var timer: Timer?

    private let myPID = ProcessInfo.processInfo.processIdentifier

    // MARK: Lifecycle

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.noteAppActivated(app.processIdentifier)
            self.observe(app)
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.observe(app); self.scheduleRefresh() }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.observers.removeValue(forKey: app.processIdentifier)
            self.appMRU.removeAll { $0 == app.processIdentifier }
            self.scheduleRefresh()
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() }
        }
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        if let front = NSWorkspace.shared.frontmostApplication { noteAppActivated(front.processIdentifier) }
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Re-attach AX observers (e.g. right after Accessibility permission is granted).
    func reobserveAll() {
        observers.removeAll()
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        refresh()
    }

    // MARK: MRU tracking

    func noteFocused(_ wid: CGWindowID) {
        guard wid != 0 else { return }
        if mru.first == wid { return }
        mru.removeAll { $0 == wid }
        mru.insert(wid, at: 0)
        if mru.count > 400 { mru.removeLast(mru.count - 400) }
    }

    private func noteAppActivated(_ pid: pid_t) {
        guard pid != myPID else { return }
        appMRU.removeAll { $0 == pid }
        appMRU.insert(pid, at: 0)
        focusQueue.async { [weak self] in
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            guard let el = AX.element(axApp, kAXFocusedWindowAttribute), let wid = Private.windowID(of: el) else { return }
            DispatchQueue.main.async { self?.noteFocused(wid) }
        }
    }

    fileprivate func handleAX(element: AXUIElement, notification: String) {
        if notification == kAXFocusedWindowChangedNotification || notification == kAXMainWindowChangedNotification {
            if let wid = Private.windowID(of: element) { noteFocused(wid) }
        } else {
            scheduleRefresh()
        }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, app.activationPolicy == .regular, pid != myPID, AXIsProcessTrusted() else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else { return }
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.2)
        var ok = false
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            if AXObserverAddNotification(obs, el, n as CFString, nil) == .success { ok = true }
        }
        guard ok else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    // MARK: Refresh

    func scheduleRefresh() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func refresh(_ done: (() -> Void)? = nil) {
        if let done { pendingCallbacks.append(done) }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let apps = currentApps()
        scanQueue.async { [weak self] in
            guard let self else { return }
            let (raws, spaces) = self.scan(apps: apps)
            DispatchQueue.main.async {
                self.apply(raws, spaces: spaces, apps: apps)
                self.refreshing = false
                let callbacks = self.pendingCallbacks
                self.pendingCallbacks = []
                callbacks.forEach { $0() }
                self.onChange?()
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    private func currentApps() -> [AppSnapshot] {
        let excluded = Set(Prefs.shared.s.excludedApps)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != myPID && !$0.isTerminated
                && !excluded.contains($0.bundleIdentifier ?? "") }
            .map { AppSnapshot(pid: $0.processIdentifier, name: $0.localizedName ?? "App", bundleID: $0.bundleIdentifier,
                               icon: $0.icon ?? NSImage(named: NSImage.applicationIconName)!, hidden: $0.isHidden) }
    }

    /// Runs on scanQueue. Combines the Accessibility window list (current Desktop +
    /// minimized) with CoreGraphics' list (all Desktops) for a complete picture.
    private func scan(apps: [AppSnapshot]) -> ([RawWindow], SpaceInfo) {
        guard AXIsProcessTrusted() else { return ([], SpaceInfo()) }
        let spaces = Private.spaceInfo()
        let pids = Set(apps.map(\.pid))

        struct CGWin { let wid: CGWindowID; let name: String; let bounds: CGRect; let z: Int }
        var cgByPid: [pid_t: [CGWin]] = [:]
        var zOf: [CGWindowID: Int] = [:]
        let cgList = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for (i, d) in cgList.enumerated() {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pidN = d[kCGWindowOwnerPID as String] as? Int, pids.contains(pid_t(pidN)),
                  let widN = d[kCGWindowNumber as String] as? Int else { continue }
            let alpha = (d[kCGWindowAlpha as String] as? Double) ?? 1
            var rect = CGRect.zero
            if let b = d[kCGWindowBounds as String] as? [String: Any],
               let r = CGRect(dictionaryRepresentation: b as CFDictionary) { rect = r }
            guard alpha > 0, rect.width >= 60, rect.height >= 40 else { continue }
            let wid = CGWindowID(widN)
            zOf[wid] = i
            cgByPid[pid_t(pidN), default: []].append(
                CGWin(wid: wid, name: (d[kCGWindowName as String] as? String) ?? "", bounds: rect, z: i))
        }

        var result: [RawWindow] = []
        var alive = Set<CGWindowID>()
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            var seen = Set<CGWindowID>()
            var axList: CFTypeRef?
            let axErr = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axList)
            if axErr != .success && axErr != .noValue {
                // App was too busy to answer: keep its last known windows that still exist.
                for r in lastGood[app.pid] ?? [] where zOf[r.wid] != nil {
                    result.append(r); alive.insert(r.wid)
                }
                continue
            }
            let start = result.count
            defer { lastGood[app.pid] = Array(result[start...]) }
            let axWindows = ((axList as? [AnyObject]) ?? []).compactMap { obj in
                CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
            }
            for el in axWindows {
                guard let wid = Private.windowID(of: el), !seen.contains(wid) else { continue }
                AXUIElementSetMessagingTimeout(el, 0.3)
                guard let raw = makeRaw(el, wid: wid, pid: app.pid, cgName: nil, z: zOf[wid] ?? Int.max) else { continue }
                seen.insert(wid); alive.insert(wid)
                axCache[wid] = el
                result.append(raw)
            }

            // Windows on other Desktops are missing from the AX list.
            var candidates: [(CGWin, [CGSSpaceID])] = []
            for c in cgByPid[app.pid] ?? [] where !seen.contains(c.wid) {
                let sp = Private.spaces(forWindow: c.wid)
                if sp.isEmpty || !Set(sp).isDisjoint(with: spaces.current) { continue }
                candidates.append((c, sp))
            }
            guard !candidates.isEmpty else { continue }
            let needLookup = candidates.map(\.0.wid).filter { axCache[$0] == nil && !failedLookups.contains($0) }
            if !needLookup.isEmpty { bruteForce(pid: app.pid, wanted: Set(needLookup)) }
            for (c, sp) in candidates {
                if let el = axCache[c.wid] {
                    AXUIElementSetMessagingTimeout(el, 0.3)
                    if let raw = makeRaw(el, wid: c.wid, pid: app.pid, cgName: c.name, z: c.z, knownSpaces: sp) {
                        seen.insert(c.wid); alive.insert(c.wid); result.append(raw)
                    }
                } else if !c.name.isEmpty {
                    alive.insert(c.wid)
                    result.append(RawWindow(wid: c.wid, pid: app.pid, ax: nil, title: c.name, minimized: false,
                                            fullscreen: sp.contains { spaces.fullscreen.contains($0) },
                                            frame: c.bounds, zOrder: c.z, spaceIDs: sp))
                }
            }
        }
        let allCG = Set(zOf.keys)
        axCache = axCache.filter { allCG.contains($0.key) || alive.contains($0.key) }
        let livePids = Set(apps.map(\.pid))
        lastGood = lastGood.filter { livePids.contains($0.key) }
        failedLookups = failedLookups.filter { allCG.contains($0) }
        return (result, spaces)
    }

    private func makeRaw(_ el: AXUIElement, wid: CGWindowID, pid: pid_t, cgName: String?, z: Int,
                         knownSpaces: [CGSSpaceID]? = nil) -> RawWindow? {
        let subrole = AX.string(el, kAXSubroleAttribute) ?? ""
        guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return nil }
        let pos = AX.point(el, kAXPositionAttribute) ?? .zero
        let size = AX.size(el, kAXSizeAttribute) ?? .zero
        let minimized = AX.bool(el, kAXMinimizedAttribute) ?? false
        if !minimized && (size.width < 60 || size.height < 40) { return nil }
        var title = AX.string(el, kAXTitleAttribute) ?? ""
        if title.isEmpty, let cgName { title = cgName }
        return RawWindow(wid: wid, pid: pid, ax: el, title: title, minimized: minimized,
                         fullscreen: AX.bool(el, "AXFullScreen") ?? false,
                         frame: CGRect(origin: pos, size: size), zOrder: z,
                         spaceIDs: knownSpaces ?? Private.spaces(forWindow: wid))
    }

    private func bruteForce(pid: pid_t, wanted: Set<CGWindowID>) {
        guard Private.canBruteForceAX else { failedLookups.formUnion(wanted); return }
        var remaining = wanted
        let deadline = Date().addingTimeInterval(0.6)
        for id in UInt64(0)..<1000 {
            guard let el = Private.axElement(pid: pid, elementID: id) else { continue }
            if let wid = Private.windowID(of: el), remaining.contains(wid) {
                axCache[wid] = el
                remaining.remove(wid)
                if remaining.isEmpty { break }
            }
            if Date() > deadline { break }
        }
        failedLookups.formUnion(remaining)
    }

    private func apply(_ raws: [RawWindow], spaces: SpaceInfo, apps: [AppSnapshot]) {
        var byPid: [pid_t: AppSnapshot] = [:]
        for a in apps { byPid[a.pid] = a }
        var newItems: [WindowItem] = []
        for r in raws {
            guard let app = byPid[r.pid] else { continue }
            let it = WindowItem(wid: r.wid, pid: r.pid, ax: r.ax, title: r.title.isEmpty ? app.name : r.title,
                                appName: app.name, bundleID: app.bundleID, icon: app.icon)
            it.titleIsEmpty = r.title.isEmpty
            it.isMinimized = r.minimized
            it.isFullscreen = r.fullscreen
            it.isAppHidden = app.hidden
            it.frame = r.frame
            it.zOrder = r.zOrder
            it.isOnCurrentSpace = r.minimized || r.spaceIDs.isEmpty || !Set(r.spaceIDs).isDisjoint(with: spaces.current)
            if let sid = r.spaceIDs.first {
                it.spaceOrder = spaces.order[sid] ?? 0
                if spaces.fullscreen.contains(sid) {
                    it.spaceLabel = "Full screen"
                } else if let n = spaces.desktopNumber[sid], spaces.desktopNumber.count > 1 {
                    it.spaceLabel = "Desktop \(n)"
                }
            }
            it.thumbnail = thumbCache[r.wid]
            newItems.append(it)
        }
        let withWindows = Set(newItems.map(\.pid))
        for app in apps where !withWindows.contains(app.pid) {
            let it = WindowItem(wid: 0, pid: app.pid, ax: nil, title: app.name, appName: app.name,
                                bundleID: app.bundleID, icon: app.icon)
            it.isAppHidden = app.hidden
            it.spaceOrder = Int.max
            newItems.append(it)
        }
        if mru.isEmpty {
            mru = newItems.filter { !$0.isWindowless }.sorted { $0.zOrder < $1.zOrder }.map(\.wid)
        }
        let live = Set(newItems.map(\.wid))
        thumbCache = thumbCache.filter { live.contains($0.key) }
        mru.removeAll { !live.contains($0) }
        items = newItems
    }

    // MARK: Sorting

    func sorted(_ list: [WindowItem], by sort: SortOrder) -> [WindowItem] {
        var rank: [CGWindowID: Int] = [:]
        for (i, w) in mru.enumerated() where rank[w] == nil { rank[w] = i }
        var appRank: [pid_t: Int] = [:]
        for (i, p) in appMRU.enumerated() where appRank[p] == nil { appRank[p] = i }

        func recent(_ w: WindowItem) -> (Int, Int) {
            if w.isWindowless { return (2, appRank[w.pid] ?? 9999) }
            if let r = rank[w.wid] { return (0, r) }
            return (1, w.zOrder)
        }
        switch sort {
        case .recent:
            return list.sorted { recent($0) < recent($1) }
        case .appName:
            return list.sorted {
                let a = ($0.appName.lowercased(), recent($0).0, recent($0).1)
                let b = ($1.appName.lowercased(), recent($1).0, recent($1).1)
                return a < b
            }
        case .space:
            return list.sorted {
                let a = ($0.isOnCurrentSpace ? 0 : 1, $0.spaceOrder, recent($0).0, recent($0).1)
                let b = ($1.isOnCurrentSpace ? 0 : 1, $1.spaceOrder, recent($1).0, recent($1).1)
                return a < b
            }
        }
    }

    // MARK: Thumbnails

    private var thumbGeneration = 0

    func captureThumbnails(_ wids: [CGWindowID], maxWidth: Int, onImage: @escaping (CGWindowID, CGImage) -> Void) {
        guard !wids.isEmpty, CGPreflightScreenCaptureAccess() else { return }
        thumbGeneration += 1
        let gen = thumbGeneration
        thumbQueue.async { [weak self] in
            for wid in wids {
                guard let self, gen == self.thumbGeneration else { return }
                guard let img = Private.captureWindow(wid), img.width > 1,
                      let small = ImageUtil.downscale(img, maxWidth: maxWidth) else { continue }
                DispatchQueue.main.async {
                    self.thumbCache[wid] = small
                    for it in self.items where it.wid == wid { it.thumbnail = small }
                    onImage(wid, small)
                }
            }
        }
    }
}

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    WindowStore.shared.handleAX(element: element, notification: notification as String)
}
