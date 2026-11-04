import AppKit
import ApplicationServices

// A small, extensible host for desktop features. The taskbar is the first feature.
struct WindowRecord {
    let app: NSRunningApplication
    let element: AXUIElement
    let title: String
    let displayID: CGDirectDisplayID
    let minimized: Bool
}

func attribute<T>(_ element: AXUIElement, _ name: CFString, as: T.Type = T.self) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value as? T
}

func windowRect(_ element: AXUIElement) -> CGRect? {
    guard let position: AXValue = attribute(element, kAXPositionAttribute as CFString),
          let size: AXValue = attribute(element, kAXSizeAttribute as CFString) else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions),
          dimensions.width > 0, dimensions.height > 0 else { return nil }
    return CGRect(origin: point, size: dimensions)
}

func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

func windows(previous: [WindowRecord]) -> [WindowRecord] {
    let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
        guard let id = displayID(screen) else { return nil }
        return (id, CGDisplayBounds(id))
    }
    var result: [WindowRecord] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated && !app.isHidden {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let elements: [AXUIElement] = attribute(root, kAXWindowsAttribute as CFString) ?? []
        for element in elements {
            let subrole: String = attribute(element, kAXSubroleAttribute as CFString) ?? ""
            guard subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else { continue }
            let minimized: Bool = attribute(element, kAXMinimizedAttribute as CFString) ?? false
            let oldDisplay = previous.first { CFEqual($0.element, element) }?.displayID
            let rect = windowRect(element)
            let best = rect.flatMap { rect in screens.map({ ($0.0, $0.1.intersection(rect)) }).max(by: {
                max(0, $0.1.width) * max(0, $0.1.height) < max(0, $1.1.width) * max(0, $1.1.height)
            }) }
            let currentDisplay = best.flatMap { !$0.1.isNull && !$0.1.isEmpty ? $0.0 : nil }
            guard let chosen = (minimized ? oldDisplay : nil) ?? currentDisplay,
                  screens.contains(where: { $0.0 == chosen }) else { continue }
            let title: String = attribute(element, kAXTitleAttribute as CFString) ?? app.localizedName ?? "Window"
            result.append(WindowRecord(app: app, element: element, title: title, displayID: chosen, minimized: minimized))
        }
    }
    return result
}

final class HoverButton: NSButton {
    var onHover: ((HoverButton) -> Void)?
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?(self) }
}

final class TaskbarPanel: NSPanel {
    init(screen: NSScreen) {
        let height: CGFloat = 52
        super.init(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.94)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hasShadow = true
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var panels: [CGDirectDisplayID: TaskbarPanel] = [:]
    var timer: Timer?
    var records: [WindowRecord] = []
    var signature = ""
    var hoverPanel: NSPanel?
    var hoverAnchor: NSRect = .zero
    var hoverPending: DispatchWorkItem?
    var hoverMonitor: Timer?
    let pinnedKey = "pinnedApplications"
    let dockBackupKey = "dockDelayBackup"
    var pinned: [String] {
        get { UserDefaults.standard.stringArray(forKey: pinnedKey) ?? ["com.apple.finder", "com.apple.Safari"] }
        set { UserDefaults.standard.set(newValue, forKey: pinnedKey); signature = "" }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        if let previous = defaults.persistentDomain(forName: "local.dan.windows-qol") {
            for key in [pinnedKey, dockBackupKey] where defaults.object(forKey: key) == nil {
                if let value = previous[key] { defaults.set(value, forKey: key) }
            }
        }
        prepareDock()
        status.button?.title = "▣"
        rebuildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
    }
    @discardableResult
    func runCommand(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let task = Process(); task.executableURL = URL(fileURLWithPath: path); task.arguments = arguments
        let output = Pipe(); task.standardOutput = output; task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (task.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        } catch { return (-1, "") }
    }
    func prepareDock() {
        let defaults = UserDefaults.standard
        if defaults.dictionary(forKey: dockBackupKey) == nil {
            let (status, value) = runCommand("/usr/bin/defaults", ["read", "com.apple.dock", "autohide-delay"])
            defaults.set(["exists": status == 0, "value": value], forKey: dockBackupKey)
        }
        let (_, current) = runCommand("/usr/bin/defaults", ["read", "com.apple.dock", "autohide-delay"])
        if Double(current) != 1000 {
            let (status, _) = runCommand("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
            if status == 0 { runCommand("/usr/bin/killall", ["Dock"]) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let backup = defaults.dictionary(forKey: dockBackupKey)
        let (status, current) = runCommand("/usr/bin/defaults", ["read", "com.apple.dock", "autohide-delay"])
        var restored = true
        if status == 0 && Double(current) == 1000, let backup = backup {
            if backup["exists"] as? Bool == true, let value = backup["value"] as? String, Double(value) != nil {
                restored = runCommand("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", value]).0 == 0
            } else {
                restored = runCommand("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"]).0 == 0
            }
        }
        // On exit, make the Dock visible even when Automation access is denied.
        let shown = runCommand("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"]).0 == 0
        if shown || restored { runCommand("/usr/bin/killall", ["Dock"]) }
        if restored { defaults.removeObject(forKey: dockBackupKey) }
    }
    func rebuildMenu() {
        let menu = NSMenu()
        let permission = NSMenuItem(title: AXIsProcessTrusted() ? "Accessibility access enabled" : "Enable Accessibility access…", action: AXIsProcessTrusted() ? nil : #selector(requestAccess), keyEquivalent: "")
        permission.target = self; menu.addItem(permission)
        let pin = NSMenuItem(title: "Pin frontmost app to primary bar", action: #selector(pinFrontmost), keyEquivalent: "")
        pin.target = self; menu.addItem(pin)
        let reset = NSMenuItem(title: "Reset pinned apps", action: #selector(resetPins), keyEquivalent: "")
        reset.target = self; menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Windows QoL", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit); status.menu = menu
    }
    @objc func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @objc func pinFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        if !pinned.contains(id) { pinned.append(id) }
        refresh()
    }
    @objc func resetPins() { UserDefaults.standard.removeObject(forKey: pinnedKey); signature = ""; refresh() }
    @objc func displaysChanged() { closeHover(); for panel in panels.values { panel.close() }; panels.removeAll(); signature = ""; refresh() }
    @objc func refresh() {
        let trusted = AXIsProcessTrusted()
        records = trusted ? windows(previous: records) : []
        let state = "\(trusted)|\(pinned.joined(separator: ","))|" + NSScreen.screens.map { "\(displayID($0) ?? 0):\($0.frame)" }.joined(separator: "|") + records.map { "\($0.app.processIdentifier):\($0.displayID):\($0.title):\($0.minimized)" }.sorted().joined(separator: "|")
        guard state != signature else { return }
        signature = state
        closeHover()
        rebuildMenu()
        let primary = NSScreen.screens.first.flatMap(displayID)
        for screen in NSScreen.screens {
            guard let id = displayID(screen) else { continue }
            let panel = panels[id] ?? TaskbarPanel(screen: screen)
            panels[id] = panel
            panel.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 52), display: false)
            let bar = NSView(frame: NSRect(x: 0, y: 0, width: screen.frame.width, height: 52))
            let utilityIDs = ["com.apple.Terminal", "com.apple.systempreferences"]
            var ids: [String] = id == primary ? pinned.filter { !utilityIDs.contains($0) } : []
            let local = records.filter { $0.displayID == id }
            for record in local {
                if let bundle = record.app.bundleIdentifier, !utilityIDs.contains(bundle), !ids.contains(bundle) { ids.append(bundle) }
            }
            var x: CGFloat = 8
            for bundle in ids {
                guard x + 46 <= screen.frame.width - 200 else { break }
                let app = local.first { $0.app.bundleIdentifier == bundle }?.app
                let url = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                guard let appURL = url else { continue }
                let button = HoverButton(frame: NSRect(x: x, y: 5, width: 44, height: 42))
                button.bezelStyle = .regularSquare; button.isBordered = false
                button.image = NSWorkspace.shared.icon(forFile: appURL.path); button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.toolTip = app?.localizedName ?? FileManager.default.displayName(atPath: appURL.path)
                button.identifier = NSUserInterfaceItemIdentifier(bundle)
                button.target = self; button.action = #selector(appClicked(_:))
                button.onHover = { [weak self] button in self?.scheduleHover(button) }
                bar.addSubview(button)
                if app != nil {
                    let dot = NSView(frame: NSRect(x: x + 16, y: 2, width: 12, height: 3))
                    dot.wantsLayer = true; dot.layer?.backgroundColor = NSColor.systemBlue.cgColor; dot.layer?.cornerRadius = 1.5
                    bar.addSubview(dot)
                }
                x += 48
            }
            if !trusted {
                let label = NSTextField(labelWithString: "Accessibility needed: remove and re-add Windows QoL in System Settings")
                label.textColor = .white; label.font = .systemFont(ofSize: 12)
                label.frame = NSRect(x: x + 8, y: 17, width: max(0, screen.frame.width - x - 216), height: 18)
                bar.addSubview(label)
            }
            for (index, bundle) in utilityIDs.enumerated() {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { continue }
                let utilityX = max(0, screen.frame.width - 196 + CGFloat(index) * 48)
                let button = HoverButton(frame: NSRect(x: utilityX, y: 5, width: 44, height: 42))
                button.bezelStyle = .regularSquare; button.isBordered = false
                button.image = NSWorkspace.shared.icon(forFile: url.path); button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.toolTip = bundle == "com.apple.Terminal" ? "Terminal" : "System Settings"
                button.identifier = NSUserInterfaceItemIdentifier(bundle)
                button.target = self; button.action = #selector(appClicked(_:))
                button.onHover = { [weak self] button in self?.scheduleHover(button) }
                bar.addSubview(button)
                if local.contains(where: { $0.app.bundleIdentifier == bundle }) {
                    let dot = NSView(frame: NSRect(x: utilityX + 16, y: 2, width: 12, height: 3))
                    dot.wantsLayer = true; dot.layer?.backgroundColor = NSColor.systemBlue.cgColor; dot.layer?.cornerRadius = 1.5
                    bar.addSubview(dot)
                }
            }
            let trash = NSButton(frame: NSRect(x: max(0, screen.frame.width - 100), y: 5, width: 44, height: 42))
            trash.bezelStyle = .regularSquare; trash.isBordered = false
            trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Trash")
            trash.imagePosition = .imageOnly; trash.imageScaling = .scaleProportionallyDown
            trash.contentTintColor = .white; trash.toolTip = "Open Trash"
            trash.target = self; trash.action = #selector(openTrash)
            bar.addSubview(trash)
            let dockButton = NSButton(frame: NSRect(x: max(0, screen.frame.width - 52), y: 5, width: 44, height: 42))
            dockButton.bezelStyle = .regularSquare; dockButton.isBordered = false
            dockButton.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Toggle Dock auto-hide")
            dockButton.contentTintColor = .white
            dockButton.toolTip = "Toggle Apple Dock auto-hide (all displays)"
            dockButton.target = self; dockButton.action = #selector(toggleDockAutoHide)
            bar.addSubview(dockButton)
            panel.contentView = bar; panel.orderFrontRegardless()
        }
    }
    @objc func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true))
    }
    @objc func toggleDockAutoHide() {
        // System Events applies the global Dock preference without restarting Dock.
        let source = "tell application \"System Events\" to tell dock preferences to set autohide to not autohide"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change the Dock setting"
            alert.informativeText = "Allow Windows QoL to control System Events in System Settings → Privacy & Security → Automation, then try again.\n\n\(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")"
            alert.runModal()
        }
    }
    @objc func appClicked(_ sender: NSButton) {
        guard let bundle = sender.identifier?.rawValue, let panel = sender.window,
              let screen = panel.screen, let id = displayID(screen) else { return }
        let matches = records.filter { $0.displayID == id && $0.app.bundleIdentifier == bundle }
        if matches.count > 1 {
            if let active = matches.first(where: isActive) { closeHover(); toggle(active) }
            else { showWindows(matches, anchoredTo: sender) }
        } else if let record = matches.first { closeHover(); toggle(record) }
        else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    func scheduleHover(_ button: HoverButton) {
        hoverPending?.cancel()
        let pending = DispatchWorkItem { [weak self, weak button] in
            guard let self = self, let button = button, let window = button.window,
                  let bundle = button.identifier?.rawValue, let screen = window.screen,
                  let id = displayID(screen) else { return }
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            guard rect.contains(NSEvent.mouseLocation) else { return }
            let matches = self.records.filter { $0.displayID == id && $0.app.bundleIdentifier == bundle }
            if matches.count > 1 { self.showWindows(matches, anchoredTo: button) }
        }
        hoverPending = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: pending)
    }
    func closeHover() {
        hoverPending?.cancel(); hoverPending = nil
        hoverMonitor?.invalidate(); hoverMonitor = nil
        hoverPanel?.close(); hoverPanel = nil
    }
    func showWindows(_ matches: [WindowRecord], anchoredTo button: NSButton) {
        guard let window = button.window, let screen = window.screen else { return }
        closeHover()
        hoverAnchor = window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -5, dy: -8)
        let width: CGFloat = 280, rowHeight: CGFloat = 36
        let height = min(CGFloat(matches.count) * rowHeight + 12, max(80, screen.visibleFrame.height - 70))
        let x = min(max(screen.frame.minX, hoverAnchor.midX - width / 2), screen.frame.maxX - width)
        let panel = NSPanel(contentRect: NSRect(x: x, y: window.frame.maxY, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.98)
        panel.level = .floating; panel.hasShadow = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let scroll = NSScrollView(frame: NSRect(x: 4, y: 4, width: width - 8, height: height - 8))
        scroll.hasVerticalScroller = CGFloat(matches.count) * rowHeight > height - 8
        scroll.drawsBackground = false
        let listHeight = max(height - 8, CGFloat(matches.count) * rowHeight)
        let list = NSView(frame: NSRect(x: 0, y: 0, width: width - 8, height: listHeight))
        for (index, record) in matches.enumerated() {
            let row = WindowButton(frame: NSRect(x: 4, y: listHeight - CGFloat(index + 1) * rowHeight, width: width - 16, height: rowHeight))
            row.title = (record.minimized ? "◌  " : "") + (record.title.isEmpty ? (record.app.localizedName ?? "Window") : record.title)
            row.record = record; row.target = self; row.action = #selector(windowSelected(_:))
            row.bezelStyle = .regularSquare; row.isBordered = false; row.alignment = .left
            row.contentTintColor = .white; row.font = .systemFont(ofSize: 13)
            row.lineBreakMode = .byTruncatingTail
            list.addSubview(row)
        }
        scroll.documentView = list; panel.contentView = scroll
        hoverPanel = panel; panel.orderFrontRegardless()
        hoverMonitor = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, let panel = self.hoverPanel else { return }
            let mouse = NSEvent.mouseLocation
            if !self.hoverAnchor.contains(mouse) && !panel.frame.insetBy(dx: -8, dy: -8).contains(mouse) { self.closeHover() }
        }
    }
    @objc func windowSelected(_ sender: WindowButton) {
        guard let record = sender.record else { return }
        closeHover(); focus(record)
    }
    func isActive(_ record: WindowRecord) -> Bool {
        guard !record.minimized, NSWorkspace.shared.frontmostApplication?.processIdentifier == record.app.processIdentifier else { return false }
        let root = AXUIElementCreateApplication(record.app.processIdentifier)
        guard let focused: AXUIElement = attribute(root, kAXFocusedWindowAttribute as CFString) else { return false }
        return CFEqual(focused, record.element)
    }
    func toggle(_ record: WindowRecord) {
        if isActive(record) {
            let result = AXUIElementSetAttributeValue(record.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            if result != .success { focus(record) }
        } else { focus(record) }
    }
    func focus(_ record: WindowRecord) {
        if record.minimized { AXUIElementSetAttributeValue(record.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        record.app.activate(options: [])
        AXUIElementPerformAction(record.element, kAXRaiseAction as CFString)
    }
}
final class WindowButton: NSButton { var record: WindowRecord? }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
