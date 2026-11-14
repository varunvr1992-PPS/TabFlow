import Cocoa

/// State machine for one switcher session: open → navigate → commit/cancel.
final class SwitcherController {
    static let shared = SwitcherController()

    private(set) var isActive = false
    private(set) var shortcut: ShortcutConfig?
    /// Search mode keeps the switcher open after the modifier is released.
    private(set) var searching = false
    private var query = ""

    private var all: [WindowItem] = []
    private(set) var items: [WindowItem] = []
    private var selectedIndex = 0
    private var selectedKey: String?

    private lazy var panel: SwitcherPanel = {
        let p = SwitcherPanel()
        p.onHover = { [weak self] i in
            guard let self, Prefs.shared.s.hoverSelects else { return }
            // Only a real mouse movement selects — not the panel appearing under a resting pointer.
            let loc = NSEvent.mouseLocation
            guard hypot(loc.x - self.lastMouse.x, loc.y - self.lastMouse.y) > 3 else { return }
            self.lastMouse = loc
            self.select(i)
        }
        p.onClick = { [weak self] i in self?.select(i); self?.commit() }
        p.onClose = { [weak self] i in self?.select(i); self?.perform(.close) }
        return p
    }()
    private var panelShown = false
    private var showWork: DispatchWorkItem?
    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    private var frontPID: pid_t = 0
    private var mouseMonitor: Any?
    private var captured = Set<CGWindowID>()
    private var lastMouse = NSPoint.zero

    private var store: WindowStore { .shared }
    private var prefs: Settings { Prefs.shared.s }

    init() {
        WindowStore.shared.onChange = { [weak self] in self?.storeChanged() }
    }

    // MARK: Session

    func begin(_ sc: ShortcutConfig, reverse: Bool, immediate: Bool = false, search: Bool = false) {
        guard !isActive else { return }
        isActive = true
        shortcut = sc
        searching = search
        query = ""
        selectedKey = nil
        captured = []
        lastMouse = NSEvent.mouseLocation
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        screen = targetScreen()
        rebuild(initialReverse: reverse)
        store.refresh()
        if immediate || search {
            showPanel()
        } else {
            let w = DispatchWorkItem { [weak self] in self?.showPanel() }
            showWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, prefs.showDelayMs) / 1000, execute: w)
        }
    }

    /// Opens the switcher from the menu bar (no keys held): starts in search mode.
    func openFromMenu() {
        let sc = prefs.shortcuts.first ?? Settings().shortcuts[0]
        begin(ShortcutConfig(id: -1, enabled: true, modifiers: sc.modifiers, keyCode: sc.keyCode,
                             apps: .allApps, spaces: .allSpaces, screens: .allScreens),
              reverse: false, immediate: true, search: true)
    }

    func commit() {
        guard isActive else { return }
        let item = items[safe: selectedIndex]
        end()
        Log.write("commit -> \(item.map { "\($0.appName) — \($0.title) [\($0.wid)]" } ?? "nothing")")
        if let item {
            store.noteFocused(item.wid)
            WindowActions.focus(item)
        }
    }

    func cancel() { end() }

    private func end() {
        isActive = false
        searching = false
        query = ""
        showWork?.cancel()
        showWork = nil
        if panelShown { panel.orderOut(nil) }
        panelShown = false
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
    }

    private func showPanel() {
        guard isActive, !panelShown else { return }
        panelShown = true
        render()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.cancel()
        }
    }

    private func render() {
        guard panelShown else { return }
        panel.render(items: items, selected: selectedIndex, screen: screen, settings: prefs,
                     query: query, searching: searching)
        captureThumbs()
    }

    private func captureThumbs() {
        guard prefs.style == .thumbnails else { return }
        let wids = items.filter { !$0.isWindowless && !captured.contains($0.wid) }.map(\.wid)
        captured.formUnion(wids)
        store.captureThumbnails(wids, maxWidth: panel.thumbPixelWidth) { [weak self] wid, img in
            guard let self, self.panelShown else { return }
            self.panel.setThumbnail(img, for: wid)
        }
    }

    private func storeChanged() {
        guard isActive else { return }
        rebuild(initialReverse: false)
        render()
    }

    // MARK: Filtering

    private func rebuild(initialReverse: Bool) {
        guard let sc = shortcut else { return }
        let p = prefs
        let scr = screen.cgFrame
        let list = store.items.filter { w in
            if sc.apps == .activeApp && (w.pid != frontPID || w.isWindowless) { return false }
            if sc.spaces == .currentSpace && !w.isOnCurrentSpace { return false }
            if sc.screens == .currentScreen, !w.isWindowless, !w.isMinimized,
               !scr.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) { return false }
            if !p.showMinimized && w.isMinimized { return false }
            if !p.showHidden && w.isAppHidden { return false }
            if !p.showFullscreen && w.isFullscreen { return false }
            if !p.showWindowlessApps && w.isWindowless { return false }
            if p.hideUntitled && w.titleIsEmpty && !w.isWindowless { return false }
            return true
        }
        all = store.sorted(list, by: p.sort)
        applyQuery()

        if let k = selectedKey, let i = items.firstIndex(where: { $0.key == k }) {
            selectedIndex = i
        } else if selectedKey == nil || !query.isEmpty {
            selectedIndex = initialIndex(reverse: initialReverse)
        } else {
            selectedIndex = min(selectedIndex, max(0, items.count - 1))
        }
        selectedKey = items[safe: selectedIndex]?.key
    }

    private func initialIndex(reverse: Bool) -> Int {
        guard !items.isEmpty else { return 0 }
        if !query.isEmpty { return 0 }
        let n = items.count
        let current = items.firstIndex { !$0.isWindowless && $0.wid == store.mru.first }
        guard let cur = current else { return reverse ? n - 1 : 0 }
        return reverse ? (cur - 1 + n) % n : (cur + 1) % n
    }

    private func applyQuery() {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { items = all; return }
        let tokens = q.split(separator: " ").map(String.init)
        var scored: [(WindowItem, Int)] = []
        for w in all {
            let app = w.appName.lowercased(), title = w.title.lowercased()
            var score = 0
            var ok = true
            for t in tokens {
                if app.hasPrefix(t) { score += 3 }
                else if app.contains(t) { score += 2 }
                else if title.contains(t) { score += 1 }
                else if Self.isSubsequence(t, of: app) { score += 1 }
                else { ok = false; break }
            }
            if ok { scored.append((w, score)) }
        }
        // stable: keep recency order inside equal scores
        items = scored.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map { $0.element.0 }
    }

    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        outer: for c in needle {
            while let h = it.next() { if h == c { continue outer } }
            return false
        }
        return true
    }

    // MARK: Navigation

    func select(_ i: Int) {
        guard items.indices.contains(i) else { return }
        selectedIndex = i
        selectedKey = items[i].key
        if panelShown { panel.setSelected(i) }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let n = items.count
        select(((selectedIndex + delta) % n + n) % n)
    }

    private func moveRow(_ dir: Int) {
        let cols = panelShown ? panel.columns : 1
        if cols <= 1 { move(dir); return }
        let target = selectedIndex + dir * cols
        if items.indices.contains(target) { select(target) }
        else if dir > 0 { select(items.count - 1) }
        else { select(0) }
    }

    func perform(_ action: WindowAction) {
        guard let item = items[safe: selectedIndex] else { return }
        if item.isWindowless && action != .quitApp && action != .hideApp { return }
        if !panelShown { showWork?.cancel(); showPanel() }
        if action == .quitApp || action == .close {
            // move selection off the item that is going away
            let next = items[safe: selectedIndex + 1] ?? items[safe: selectedIndex - 1]
            selectedKey = next?.key
        }
        WindowActions.perform(action, on: item)
        captured.remove(item.wid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard self?.isActive == true else { return }
            self?.store.refresh()
        }
    }

    // MARK: Keys (called from the event tap while active)

    func handleKeyDown(keyCode: Int64, flags: UInt64, event: CGEvent) {
        guard let sc = shortcut else { return }
        let shift = flags & ModMask.shift != 0

        if KeyCodes.matches(keyCode, sc.keyCode) && !(searching && keyCode == KeyCodes.space) {
            move(shift ? -1 : 1); return
        }
        switch keyCode {
        case KeyCodes.escape:
            if searching && !query.isEmpty { query = ""; rebuild(initialReverse: false); render() }
            else { cancel() }
            return
        case KeyCodes.returnKey, KeyCodes.enter:
            commit(); return
        case KeyCodes.left: move(-1); return
        case KeyCodes.right: move(1); return
        case KeyCodes.up: moveRow(-1); return
        case KeyCodes.down: moveRow(1); return
        default: break
        }

        let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""

        if searching {
            if keyCode == KeyCodes.delete {
                if !query.isEmpty { query.removeLast() }
            } else {
                let printable = chars.filter { !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " ") }
                guard !printable.isEmpty else { return }
                query += printable
            }
            rebuild(initialReverse: false)
            render()
            return
        }

        if keyCode == KeyCodes.space || chars == "/" {
            searching = true
            showWork?.cancel()
            if panelShown { render() } else { showPanel() }
            return
        }
        if let n = KeyCodes.digits[keyCode] {
            if items.indices.contains(n - 1) { select(n - 1); commit() }
            return
        }
        switch chars.lowercased() {
        case "q": perform(.quitApp)
        case "w": perform(.close)
        case "m": perform(.minimize)
        case "h": perform(.hideApp)
        case "f": perform(.fullscreen)
        default: break
        }
    }

    // MARK: Debug hooks

    var debugSelected: String { items[safe: selectedIndex].map { "\(selectedIndex):\($0.appName):\($0.title.prefix(30))" } ?? "none" }

    func debugBegin(_ sc: ShortcutConfig) { begin(sc, reverse: false, immediate: true) }

    func debugKey(_ code: Int64, char: String?) {
        guard isActive, let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true) else { return }
        if let char {
            let u = Array(char.utf16)
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
        }
        handleKeyDown(keyCode: code, flags: shortcut?.modifiers ?? 0, event: e)
    }

    // MARK: Screen

    private func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        switch prefs.placement {
        case .mainScreen:
            return NSScreen.main ?? screens[0]
        case .mouseScreen:
            let p = NSEvent.mouseLocation
            return screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? screens[0]
        case .activeWindowScreen:
            if let w = store.items.first(where: { $0.wid == store.mru.first }) {
                let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
                if let s = screens.first(where: { $0.cgFrame.contains(c) }) { return s }
            }
            return NSScreen.main ?? screens[0]
        }
    }
}
