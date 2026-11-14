import Cocoa
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var permTimer: Timer?
    private var watchdog: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.write("TabFlow launched (ax=\(Permissions.accessibility), screenRecording=\(Permissions.screenRecording))")
        installSignalHandlers()
        DebugCommands.install()
        setupStatusItem()
        _ = SwitcherController.shared
        WindowStore.shared.start()

        Prefs.shared.$s
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { s in
                SystemHotkeys.apply(s, active: HotkeyManager.shared.isRunning)
                WindowStore.shared.scheduleRefresh()
            }
            .store(in: &cancellables)

        if !startHotkeys() {
            Permissions.requestAccessibility()
            permTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
                if self?.startHotkeys() == true {
                    t.invalidate()
                    WindowStore.shared.reobserveAll()
                }
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in HotkeyManager.shared.ensureEnabled() }

        if !Prefs.shared.s.onboarded || !Permissions.accessibility {
            Prefs.shared.s.onboarded = true
            SettingsWindowController.shared.show(tab: .permissions)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemHotkeys.restoreAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    @discardableResult
    private func startHotkeys() -> Bool {
        guard Permissions.accessibility, HotkeyManager.shared.start() else { return false }
        SystemHotkeys.apply(Prefs.shared.s, active: true)
        Log.write("keyboard hook started; system hotkeys disabled: \(SystemHotkeys.disabled.sorted())")
        return true
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { _ in
                SystemHotkeys.restoreAll()
                exit(0)
            }
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "TabFlow")
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Prefs.shared.s
        let title = NSMenuItem(title: "TabFlow", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for sc in s.shortcuts where sc.enabled {
            let i = NSMenuItem(title: "  \(sc.display)  —  \(sc.apps == .activeApp ? "current app's windows" : "all windows")",
                               action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(item("Search Windows…", #selector(searchWindows)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        if !Permissions.accessibility || !Permissions.screenRecording {
            menu.addItem(item("⚠️ Grant Permissions…", #selector(openPermissions)))
        }
        let pause = item(s.paused ? "Resume TabFlow" : "Pause TabFlow", #selector(togglePause))
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(item("Quit TabFlow", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func searchWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { SwitcherController.shared.openFromMenu() }
    }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openPermissions() { SettingsWindowController.shared.show(tab: .permissions) }
    @objc private func togglePause() { Prefs.shared.s.paused.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}
