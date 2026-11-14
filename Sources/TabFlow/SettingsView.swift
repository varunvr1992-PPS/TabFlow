import SwiftUI
import Combine
import UniformTypeIdentifiers

enum SettingsTab: Hashable { case shortcuts, appearance, windows, exclusions, permissions, help }

final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var tab: SettingsTab = .shortcuts
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(tab: SettingsTab? = nil) {
        if let tab { SettingsNav.shared.tab = tab }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: host)
            w.title = "TabFlow Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 560))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var nav = SettingsNav.shared

    var body: some View {
        TabView(selection: $nav.tab) {
            ShortcutsTab().tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            AppearanceTab().tabItem { Label("Appearance", systemImage: "paintbrush") }.tag(SettingsTab.appearance)
            WindowsTab().tabItem { Label("Windows", systemImage: "macwindow.on.rectangle") }.tag(SettingsTab.windows)
            ExclusionsTab().tabItem { Label("Exclusions", systemImage: "nosign") }.tag(SettingsTab.exclusions)
            PermissionsTab().tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(SettingsTab.permissions)
            HelpTab().tabItem { Label("Cheat sheet", systemImage: "questionmark.circle") }.tag(SettingsTab.help)
        }
        .padding(16)
        .frame(width: 720, height: 560)
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var loginOn = LoginItem.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(prefs.s.shortcuts.indices, id: \.self) { i in
                    ShortcutEditor(index: i, sc: $prefs.s.shortcuts[i])
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Launch TabFlow at login", isOn: $loginOn)
                            .onChange(of: loginOn) { LoginItem.set($0) }
                        Toggle("Pause TabFlow (all shortcuts go back to macOS)", isOn: $prefs.s.paused)
                        HStack {
                            Text("Show the switcher after")
                            Slider(value: $prefs.s.showDelayMs, in: 0...400, step: 10).frame(width: 200)
                            Text("\(Int(prefs.s.showDelayMs)) ms").monospacedDigit().frame(width: 60, alignment: .leading)
                        }
                        Text("A quick tap-and-release jumps straight to the previous window without drawing anything — the delay lets that feel instant.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                } label: { Text("General").font(.headline) }
            }.padding(.vertical, 4)
        }
    }
}

private struct ShortcutEditor: View {
    let index: Int
    @Binding var sc: ShortcutConfig
    @State private var recording = false

    private var title: String {
        switch index {
        case 0: return "Shortcut 1 — switch between all windows"
        case 1: return "Shortcut 2 — switch between windows of the current app"
        default: return "Shortcut \(index + 1)"
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Enabled", isOn: $sc.enabled)
                    Spacer()
                    Text(sc.display).font(.system(.title3, design: .rounded)).bold()
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                }
                HStack(spacing: 6) {
                    Text("Hold")
                    modToggle("⌘ Cmd", ModMask.command)
                    modToggle("⌥ Opt", ModMask.option)
                    modToggle("⌃ Ctrl", ModMask.control)
                    Text("and press")
                    Picker("", selection: $sc.keyCode) {
                        Text("Tab").tag(KeyCodes.tab)
                        Text("\(KeyNames.name(KeyCodes.aboveTab))  (key above Tab)").tag(KeyCodes.aboveTab)
                        Text("Space").tag(KeyCodes.space)
                        if ![KeyCodes.tab, KeyCodes.aboveTab, KeyCodes.space].contains(sc.keyCode) {
                            Text(KeyNames.name(sc.keyCode)).tag(sc.keyCode)
                        }
                    }.labelsHidden().frame(width: 190)
                    Button(recording ? "Press a shortcut…" : "Record…") { record() }
                        .disabled(!HotkeyManager.shared.isRunning)
                }
                HStack {
                    Picker("Show", selection: $sc.apps) { ForEach(AppScope.allCases) { Text($0.label).tag($0) } }.frame(width: 200)
                    Picker("from", selection: $sc.spaces) { ForEach(SpaceScope.allCases) { Text($0.label).tag($0) } }.frame(width: 190)
                    Picker("on", selection: $sc.screens) { ForEach(ScreenScope.allCases) { Text($0.label).tag($0) } }.frame(width: 170)
                }
                if sc.modifiers == 0 {
                    Text("⚠️ Pick at least one modifier key.").font(.caption).foregroundStyle(.orange)
                } else if sc.modifiers == ModMask.command && sc.keyCode == KeyCodes.tab && sc.enabled {
                    Text("Replaces the built-in macOS ⌘Tab app switcher while TabFlow is running.").font(.caption).foregroundStyle(.secondary)
                } else if sc.modifiers == ModMask.command && KeyCodes.matches(sc.keyCode, KeyCodes.aboveTab) && sc.enabled {
                    Text("Replaces macOS' built-in ⌘` window cycling with a visual switcher (works on US and international keyboards).").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(4)
        } label: { Text(title).font(.headline) }
    }

    private func modToggle(_ label: String, _ mask: UInt64) -> some View {
        Toggle(label, isOn: Binding(
            get: { sc.modifiers & mask != 0 },
            set: { on in if on { sc.modifiers |= mask } else { sc.modifiers &= ~mask } }
        )).toggleStyle(.button)
    }

    private func record() {
        recording = true
        let binding = $sc
        HotkeyManager.shared.recordHandler = { code, mods in
            DispatchQueue.main.async {
                if code != KeyCodes.escape {
                    binding.wrappedValue.keyCode = code
                    if mods != 0 { binding.wrappedValue.modifiers = mods }
                }
                recording = false
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        Form {
            Picker("Style", selection: $prefs.s.style) { ForEach(SwitcherStyle.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
            Picker("Size", selection: $prefs.s.size) { ForEach(SizePreset.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
            Picker("Theme", selection: $prefs.s.theme) { ForEach(Theme.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
            Picker("Show switcher on", selection: $prefs.s.placement) { ForEach(Placement.allCases) { Text($0.label).tag($0) } }
            Toggle("Hovering the mouse over a window selects it", isOn: $prefs.s.hoverSelects)
            Toggle("Show number hints (press 1–9 to jump)", isOn: $prefs.s.showNumberHints)
            Toggle("Show status badges (Minimized, Hidden, Desktop 2…)", isOn: $prefs.s.showBadges)
            Toggle("Show close button on hover", isOn: $prefs.s.showCloseButtons)
            Toggle("Show keyboard hint bar", isOn: $prefs.s.showHintBar)
            if prefs.s.style == .thumbnails && !Permissions.screenRecording {
                Text("Thumbnails need Screen Recording permission — see the Permissions tab. App icons are shown until then.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.formStyle(.grouped)
    }
}

// MARK: - Windows

private struct WindowsTab: View {
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        Form {
            Picker("Order windows by", selection: $prefs.s.sort) { ForEach(SortOrder.allCases) { Text($0.label).tag($0) } }
            Section("Include") {
                Toggle("Minimized windows", isOn: $prefs.s.showMinimized)
                Toggle("Windows of hidden apps", isOn: $prefs.s.showHidden)
                Toggle("Full-screen windows", isOn: $prefs.s.showFullscreen)
                Toggle("Apps with no open windows (selecting one opens a new window)", isOn: $prefs.s.showWindowlessApps)
                Toggle("Hide windows that have no title", isOn: $prefs.s.hideUntitled)
            }
            Text("Which apps, Desktops and screens each shortcut shows is set per shortcut on the Shortcuts tab.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

// MARK: - Exclusions

private struct ExclusionsTab: View {
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        VStack(spacing: 12) {
            AppListEditor(title: "Never show these apps in the switcher",
                          caption: "e.g. utilities or background apps you never switch to.",
                          ids: $prefs.s.excludedApps)
            AppListEditor(title: "Turn shortcuts off while these apps are in front",
                          caption: "e.g. games, virtual machines or remote desktop apps that need ⌥Tab / ⌘Tab themselves.",
                          ids: $prefs.s.disabledInApps)
        }
    }
}

private struct AppListEditor: View {
    let title: String
    let caption: String
    @Binding var ids: [String]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(ids, id: \.self) { id in
                        HStack {
                            Image(nsImage: AppInfo.icon(id)).resizable().frame(width: 18, height: 18)
                            Text(AppInfo.name(id))
                            Text(id).font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Button { ids.removeAll { $0 == id } } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.red)
                        }
                    }
                    if ids.isEmpty { Text("None").foregroundStyle(.secondary) }
                }.frame(height: 140)
                HStack {
                    Menu("Add running app") {
                        ForEach(runningApps(), id: \.0) { app in
                            Button(app.1) { add(app.0) }
                        }
                    }.frame(width: 180)
                    Button("Choose app…") { choose() }
                }
            }.padding(4)
        } label: { Text(title).font(.headline) }
    }

    private func runningApps() -> [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !ids.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
            .sorted { $0.1.lowercased() < $1.1.lowercased() }
    }

    private func add(_ id: String) { if !ids.contains(id) { ids.append(id) } }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        if p.runModal() == .OK {
            for u in p.urls { if let id = Bundle(url: u)?.bundleIdentifier { add(id) } }
        }
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @State private var ax = Permissions.accessibility
    @State private var sr = Permissions.screenRecording
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TabFlow needs two macOS permissions. Nothing ever leaves your Mac.")
                .font(.headline)
            row(ok: ax, title: "Accessibility (required)",
                detail: "Lets TabFlow listen for its shortcuts and focus, close or minimize windows.",
                request: { Permissions.requestAccessibility(); Permissions.openAccessibilityPane() })
            row(ok: sr, title: "Screen Recording (for thumbnails)",
                detail: "Lets TabFlow draw live window previews and read window titles on other Desktops. Optional — icons are used without it.",
                request: { Permissions.requestScreenRecording(); Permissions.openScreenRecordingPane() })
            Divider()
            Text("After turning on Screen Recording, macOS requires the app to restart.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Restart TabFlow") { Permissions.relaunch() }
            Text("Tip: if TabFlow is already ticked in the list but nothing works (this happens after rebuilding the app), remove it with the – button and add it again.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
        .onReceive(tick) { _ in ax = Permissions.accessibility; sr = Permissions.screenRecording }
    }

    private func row(ok: Bool, title: String, detail: String, request: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Grant…", action: request) } else { Text("Granted").foregroundStyle(.green) }
        }
    }
}

// MARK: - Help

private struct HelpTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("While the switcher is open (keep holding the modifier):").font(.headline)
                Group {
                    key("Tab / ⇧Tab", "next / previous window")
                    key("← → ↑ ↓", "move around the grid")
                    key("1 – 9", "jump straight to that window")
                    key("Release modifier", "switch to the selected window")
                    key("Q", "quit the selected app")
                    key("W", "close the selected window")
                    key("M", "minimize / restore the selected window")
                    key("H", "hide / show the selected app")
                    key("F", "toggle full screen for the selected window")
                    key("Space or /", "search mode — release the keys and type to filter, ↩ to open")
                    key("Esc", "cancel (or clear the search)")
                    key("Mouse", "hover to select, click to switch, × to close")
                }
                Divider()
                Text("Tips").font(.headline)
                Text("• Tap ⌥Tab and let go quickly to flip between your last two windows instantly.")
                Text("• ⌘` (the key above Tab) shows only the front app's windows — great for many browser or Finder windows.")
                Text("• Click the menu-bar icon → “Search Windows…” to find any window by typing.")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func key(_ k: String, _ d: String) -> some View {
        HStack {
            Text(k).font(.system(.body, design: .monospaced)).bold().frame(width: 170, alignment: .leading)
            Text(d)
        }
    }
}
