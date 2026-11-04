import AppKit
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement

let taskbarHeight: CGFloat = 72

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

class HoverButton: NSButton {
    var onHover: ((HoverButton) -> Void)?
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?(self) }
}

final class AppIconButton: HoverButton {
    var appIcon: NSImage?
    var windowCount = 0
    var hasVisibleWindow = false
    var isFocused = false
    var contextMenu: (() -> NSMenu)?
    var onReorder: ((CGFloat) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = window.convertPoint(toScreen: next.locationInWindow)
            if next.type == .leftMouseDragged && abs(point.x - start.x) > 8 { dragging = true }
            if next.type == .leftMouseUp {
                if dragging { onReorder?(point.x) }
                else if bounds.contains(convert(next.locationInWindow, from: nil)) { performClick(nil) }
                break
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let icon = appIcon else { return }
        // NSButton draws in flipped coordinates: y = 0 is the top.
        if windowCount > 1 {
            for origin in [NSPoint(x: 13, y: 4), NSPoint(x: 9, y: 8), NSPoint(x: 5, y: 12)] {
                icon.draw(in: NSRect(origin: origin, size: NSSize(width: 41, height: 41)), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        } else {
            icon.draw(in: NSRect(x: 6, y: 9, width: 46, height: 46), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if windowCount > 0 {
            (isFocused ? NSColor.systemCyan : (hasVisibleWindow ? NSColor.systemBlue : NSColor.systemBlue.withAlphaComponent(0.45))).setFill()
            let lineHeight: CGFloat = hasVisibleWindow ? 5 : 3
            NSBezierPath(roundedRect: NSRect(x: 10, y: bounds.height - lineHeight - 2, width: 38, height: lineHeight), xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        }
    }
}

// Translate selected Fn combinations; all other events pass through.
final class WindowsShortcuts {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pressed = Set<Int64>()
    private var screenshotUsesRegion = false
    var isRunning: Bool { tap != nil }
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context = context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<WindowsShortcuts>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let source = source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }
    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; pressed.removeAll()
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            pressed.removeAll()
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        // Physical macOS key codes: C, V, S, A, Z, Y, X, F, E.
        guard [8, 9, 1, 0, 6, 16, 7, 3, 14].contains(key) else { return Unmanaged.passUnretained(event) }
        if type == .keyDown {
            let otherModifiers: CGEventFlags = key == 1 ? [.maskCommand, .maskControl, .maskAlternate] : [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            guard event.flags.contains(.maskSecondaryFn), event.flags.intersection(otherModifiers).isEmpty else { return Unmanaged.passUnretained(event) }
            if (key == 1 || key == 14) && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            if key == 1 { screenshotUsesRegion = event.flags.contains(.maskShift) }
            pressed.insert(key)
        } else {
            guard pressed.remove(key) != nil else { return Unmanaged.passUnretained(event) }
        }
        if key == 1 && !screenshotUsesRegion {
            if type == .keyDown { capturePointerDisplay() }
            return nil
        }
        if key == 14 {
            if type == .keyDown {
                DispatchQueue.main.async {
                    var error: NSDictionary?
                    NSAppleScript(source: "tell application \"Finder\"\nactivate\nmake new Finder window\nend tell")?.executeAndReturnError(&error)
                    if let error = error {
                        let alert = NSAlert()
                        alert.messageText = "Couldn’t open a Finder window"
                        alert.informativeText = "Allow Windows QoL to control Finder in System Settings → Privacy & Security → Automation, then try again.\n\n\(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")"
                        alert.runModal()
                    }
                }
            }
            return nil
        }
        event.flags.remove(.maskSecondaryFn)
        event.flags.insert(.maskCommand)
        if key == 16 { // Fn-Y: redo is Command-Shift-Z in standard Mac apps.
            event.setIntegerValueField(.keyboardEventKeycode, value: 6)
            event.flags.insert(.maskShift)
        }
        if key == 1 {
            event.setIntegerValueField(.keyboardEventKeycode, value: 21) // 4
            event.flags.formUnion([.maskControl, .maskShift])
        }
        return Unmanaged.passUnretained(event)
    }
    private func capturePointerDisplay() {
        guard let point = CGEvent(source: nil)?.location else { return }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success,
              let index = displays.prefix(Int(count)).firstIndex(where: { CGDisplayBounds($0).contains(point) }) else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-c", "-D", String(index + 1)]
        capture.terminationHandler = { process in
            if process.terminationStatus != 0 {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t capture the display"
                    alert.informativeText = "Check Screen & System Audio Recording permission for Windows QoL, then try again."
                    alert.runModal()
                }
            }
        }
        do { try capture.run() } catch { NSLog("Could not start screen capture: %@", error.localizedDescription) }
    }
}

final class TaskbarPanel: NSPanel {
    init(screen: NSScreen) {
        let height = taskbarHeight
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
    var hoverLastInside = Date()
    var permissionsWindow: NSWindow?
    var accessibilityStatus: NSTextField?
    var screenCaptureStatus: NSTextField?
    var loginStatusLabel: NSTextField?
    var loginButton: NSButton?
    let shortcuts = WindowsShortcuts()
    let shortcutsKey = "fnShortcutsEnabled"
    var shortcutsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: shortcutsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: shortcutsKey) }
    }
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
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "windowsqol-terminal", url.host == "open",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let path = components.queryItems?.first(where: { $0.name == "folder" })?.value,
                  path.hasPrefix("/"),
                  let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error = error { NSLog("Could not open Terminal: %@", error.localizedDescription) }
            }
        }
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
        var restartDock = false
        if Double(current) != 1000 {
            let (status, _) = runCommand("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
            restartDock = status == 0
        }
        let (hideStatus, hideValue) = runCommand("/usr/bin/defaults", ["read", "com.apple.dock", "autohide"])
        if hideStatus != 0 || (hideValue != "1" && hideValue.lowercased() != "true") {
            let (status, _) = runCommand("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])
            restartDock = restartDock || status == 0
        }
        if restartDock { runCommand("/usr/bin/killall", ["Dock"]) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        shortcuts.stop()
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
        let settings = NSMenuItem(title: "Settings…", action: #selector(showPermissions), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let shortcutItem = NSMenuItem(title: "Windows-style Fn shortcuts", action: #selector(toggleShortcuts), keyEquivalent: "")
        shortcutItem.target = self; shortcutItem.state = shortcutsEnabled ? .on : .off
        menu.addItem(shortcutItem)
        if shortcutsEnabled && !shortcuts.isRunning {
            let warning = NSMenuItem(title: "Fn shortcuts unavailable — check Accessibility", action: nil, keyEquivalent: "")
            menu.addItem(warning)
        }
        let pin = NSMenuItem(title: "Pin frontmost app to primary bar", action: #selector(pinFrontmost), keyEquivalent: "")
        pin.target = self; menu.addItem(pin)
        let reset = NSMenuItem(title: "Reset pinned apps", action: #selector(resetPins), keyEquivalent: "")
        reset.target = self; menu.addItem(reset)
        menu.addItem(.separator())
        let reload = NSMenuItem(title: "Reload Windows QoL", action: #selector(reloadApp), keyEquivalent: "")
        reload.target = self; menu.addItem(reload)
        let quit = NSMenuItem(title: "Quit Windows QoL", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit); status.menu = menu
    }
    @objc func showPermissions() {
        if let window = permissionsWindow {
            updatePermissionStatuses()
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 382), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Windows QoL Settings"; window.isReleasedWhenClosed = false
        let general = NSTextField(labelWithString: "Startup")
        general.font = .boldSystemFont(ofSize: 19); general.frame = NSRect(x: 24, y: 338, width: 490, height: 26)
        let loginStatus = NSTextField(labelWithString: ""); loginStatus.frame = NSRect(x: 24, y: 307, width: 350, height: 20)
        let login = NSButton(title: "Enable", target: self, action: #selector(toggleLaunchAtLogin))
        login.bezelStyle = .rounded; login.frame = NSRect(x: 365, y: 302, width: 150, height: 30)
        let title = NSTextField(labelWithString: "Permissions")
        title.font = .boldSystemFont(ofSize: 19); title.frame = NSRect(x: 24, y: 248, width: 490, height: 26)
        let accessibility = NSTextField(wrappingLabelWithString: "Accessibility — needed for window controls and Fn shortcuts.")
        accessibility.frame = NSRect(x: 24, y: 192, width: 465, height: 38)
        let axStatus = NSTextField(labelWithString: ""); axStatus.frame = NSRect(x: 24, y: 166, width: 270, height: 20)
        let axButton = NSButton(title: "Enable…", target: self, action: #selector(requestAccessibilityFromSettings))
        axButton.bezelStyle = .rounded; axButton.frame = NSRect(x: 390, y: 161, width: 125, height: 30)
        let screen = NSTextField(wrappingLabelWithString: "Screen capture — needed to copy the display under your pointer. This grants broader screen access.")
        screen.frame = NSRect(x: 24, y: 100, width: 465, height: 43)
        let captureStatus = NSTextField(labelWithString: ""); captureStatus.frame = NSRect(x: 24, y: 72, width: 280, height: 20)
        let captureButton = NSButton(title: "Enable…", target: self, action: #selector(requestScreenCaptureFromSettings))
        captureButton.bezelStyle = .rounded; captureButton.frame = NSRect(x: 390, y: 67, width: 125, height: 30)
        let note = NSTextField(labelWithString: "macOS manages permissions; changes may require reopening the app.")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11); note.frame = NSRect(x: 24, y: 22, width: 495, height: 18)
        for view in [general, loginStatus, login, title, accessibility, axStatus, axButton, screen, captureStatus, captureButton, note] as [NSView] { window.contentView?.addSubview(view) }
        loginStatusLabel = loginStatus; loginButton = login
        accessibilityStatus = axStatus; screenCaptureStatus = captureStatus; permissionsWindow = window
        updatePermissionStatuses(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func updatePermissionStatuses() {
        accessibilityStatus?.stringValue = AXIsProcessTrusted() ? "Status: Enabled" : "Status: Not enabled"
        screenCaptureStatus?.stringValue = CGPreflightScreenCaptureAccess() ? "Status: Enabled" : "Status: Not enabled"
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: loginStatusLabel?.stringValue = "Open at login: On"; loginButton?.title = "Disable"
            case .notRegistered: loginStatusLabel?.stringValue = "Open at login: Off"; loginButton?.title = "Enable"
            case .requiresApproval: loginStatusLabel?.stringValue = "Open at login: Approval needed"; loginButton?.title = "Open Settings…"
            case .notFound: loginStatusLabel?.stringValue = "Open at login: App not found"; loginButton?.title = "Enable"
            @unknown default: loginStatusLabel?.stringValue = "Open at login: Unknown"; loginButton?.title = "Open Settings…"
            }
        } else {
            loginStatusLabel?.stringValue = "Open at login: Requires macOS 13 or later"
            loginButton?.isEnabled = false
        }
    }
    @objc func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .notRegistered, .notFound: try service.register()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems(); return
            @unknown default: SMAppService.openSystemSettingsLoginItems(); return
            }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t change startup setting"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can also add or remove Windows QoL in System Settings → General → Login Items & Extensions."
            alert.runModal()
        }
        updatePermissionStatuses()
    }
    @objc func requestAccessibilityFromSettings() {
        requestAccess()
        if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        updatePermissionStatuses()
    }
    @objc func requestScreenCaptureFromSettings() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        }
        updatePermissionStatuses()
    }
    @objc func toggleShortcuts() {
        shortcutsEnabled.toggle()
        if shortcutsEnabled && AXIsProcessTrusted() { _ = shortcuts.start() } else { shortcuts.stop() }
        rebuildMenu()
    }
    @objc func reloadApp() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Arguments are passed separately so spaces and shell characters in the path are safe.
        helper.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\"", "windows-qol-reload", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t reload Windows QoL"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
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
        if permissionsWindow?.isVisible == true { updatePermissionStatuses() }
        let trusted = AXIsProcessTrusted()
        if shortcutsEnabled && trusted && !shortcuts.isRunning, shortcuts.start() { signature = "" }
        if (!shortcutsEnabled || !trusted) && shortcuts.isRunning { shortcuts.stop(); signature = "" }
        records = trusted ? windows(previous: records) : []
        if trusted { keepMaximizedWindowsAboveTaskbars() }
        let state = "\(trusted)|\(pinned.joined(separator: ","))|" + NSScreen.screens.map { "\(displayID($0) ?? 0):\($0.frame)" }.joined(separator: "|") + records.map { "\($0.app.processIdentifier):\($0.displayID):\($0.title):\($0.minimized):\(isActive($0))" }.sorted().joined(separator: "|")
        guard state != signature else { return }
        signature = state
        closeHover()
        rebuildMenu()
        let primary = NSScreen.screens.first.flatMap(displayID)
        for screen in NSScreen.screens {
            guard let id = displayID(screen) else { continue }
            let panel = panels[id] ?? TaskbarPanel(screen: screen)
            panels[id] = panel
            panel.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: taskbarHeight), display: false)
            let bar = NSView(frame: NSRect(x: 0, y: 0, width: screen.frame.width, height: taskbarHeight))
            let utilityIDs = ["com.apple.Terminal", "com.apple.systempreferences"]
            var ids: [String] = id == primary ? pinned : []
            let local = records.filter { $0.displayID == id }
            for record in local {
                if let bundle = record.app.bundleIdentifier, !ids.contains(bundle) { ids.append(bundle) }
            }
            var x: CGFloat = 8
            for bundle in ids {
                guard x + 58 <= screen.frame.width - 200 else { break }
                let app = local.first { $0.app.bundleIdentifier == bundle }?.app
                let url = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                guard let appURL = url else { continue }
                let button = AppIconButton(frame: NSRect(x: x, y: 3, width: 58, height: 66))
                button.bezelStyle = .regularSquare; button.isBordered = false
                button.appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
                let localWindows = local.filter { $0.app.bundleIdentifier == bundle }
                button.windowCount = localWindows.count
                button.hasVisibleWindow = localWindows.contains { !$0.minimized }
                button.isFocused = localWindows.contains { isActive($0) }
                button.toolTip = app?.localizedName ?? FileManager.default.displayName(atPath: appURL.path)
                button.identifier = NSUserInterfaceItemIdentifier(bundle)
                button.target = self; button.action = #selector(appClicked(_:))
                button.onHover = { [weak self] button in self?.scheduleHover(button) }
                button.contextMenu = { [weak self] in self?.appContextMenu(bundle: bundle) ?? NSMenu() }
                if id == primary && pinned.contains(bundle) {
                    let leftEdge = screen.frame.minX + 8
                    button.onReorder = { [weak self] screenX in self?.reorderPin(bundle, targetX: screenX - leftEdge) }
                }
                bar.addSubview(button)
                x += 62
            }
            if !trusted {
                let label = NSTextField(labelWithString: "Accessibility needed: remove and re-add Windows QoL in System Settings")
                label.textColor = .white; label.font = .systemFont(ofSize: 12)
                label.frame = NSRect(x: x + 8, y: 27, width: max(0, screen.frame.width - x - 216), height: 18)
                bar.addSubview(label)
            }
            for (index, bundle) in utilityIDs.enumerated() {
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil else { continue }
                let utilityX = max(0, screen.frame.width - 196 + CGFloat(index) * 48)
                let button = NSButton(frame: NSRect(x: utilityX, y: 15, width: 44, height: 42))
                button.bezelStyle = .regularSquare; button.isBordered = false
                button.toolTip = bundle == "com.apple.Terminal" ? "Terminal" : "System Settings"
                button.image = NSImage(systemSymbolName: bundle == "com.apple.Terminal" ? "terminal" : "gearshape", accessibilityDescription: button.toolTip)
                button.imagePosition = .imageOnly; button.imageScaling = .scaleProportionallyDown
                button.contentTintColor = .white
                button.identifier = NSUserInterfaceItemIdentifier(bundle)
                button.target = self; button.action = #selector(launchUtility(_:))
                bar.addSubview(button)
            }
            let trash = NSButton(frame: NSRect(x: max(0, screen.frame.width - 100), y: 15, width: 44, height: 42))
            trash.bezelStyle = .regularSquare; trash.isBordered = false
            trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Trash")
            trash.imagePosition = .imageOnly; trash.imageScaling = .scaleProportionallyDown
            trash.contentTintColor = .white; trash.toolTip = "Open Trash"
            trash.target = self; trash.action = #selector(openTrash)
            bar.addSubview(trash)
            let dockButton = NSButton(frame: NSRect(x: max(0, screen.frame.width - 52), y: 15, width: 44, height: 42))
            dockButton.bezelStyle = .regularSquare; dockButton.isBordered = false
            dockButton.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Toggle Dock auto-hide")
            dockButton.contentTintColor = .white
            dockButton.toolTip = "Toggle Apple Dock auto-hide (all displays)"
            dockButton.target = self; dockButton.action = #selector(toggleDockAutoHide)
            bar.addSubview(dockButton)
            panel.contentView = bar; panel.orderFrontRegardless()
        }
    }
    func keepMaximizedWindowsAboveTaskbars() {
        // macOS does not reserve desktop space for third-party taskbar panels.
        // Adjust only windows that span nearly the full usable display height,
        // after the user has finished dragging or resizing.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        for record in records where !record.minimized {
            guard let screen = NSScreen.screens.first(where: { displayID($0) == record.displayID }),
                  let rect = windowRect(record.element),
                  (attribute(record.element, "AXFullScreen" as CFString, as: Bool.self) ?? false) == false,
                  (attribute(record.element, kAXSubroleAttribute as CFString, as: String.self) ?? "") == kAXStandardWindowSubrole as String else { continue }
            let display = CGDisplayBounds(record.displayID)
            let topInset = screen.frame.maxY - screen.visibleFrame.maxY
            let usableTop = display.minY + topInset
            let taskbarTop = display.maxY - taskbarHeight
            guard abs(rect.minY - usableTop) <= 24,
                  abs(rect.maxY - display.maxY) <= 24,
                  rect.height >= display.height * 0.70,
                  rect.maxY > taskbarTop + 1 else { continue }
            var size = CGSize(width: rect.width, height: taskbarTop - rect.minY)
            guard size.height > 100, let value = AXValueCreate(.cgSize, &size) else { continue }
            AXUIElementSetAttributeValue(record.element, kAXSizeAttribute as CFString, value)
        }
    }
    @objc func launchUtility(_ sender: NSButton) {
        guard let bundle = sender.identifier?.rawValue,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    func appContextMenu(bundle: String) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: pinned.contains(bundle) ? "Unpin from taskbar" : "Pin to primary taskbar", action: #selector(togglePin(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = bundle; menu.addItem(item)
        return menu
    }
    @objc func togglePin(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        if pinned.contains(bundle) { pinned.removeAll { $0 == bundle } } else { pinned.append(bundle) }
        refresh()
    }
    func reorderPin(_ bundle: String, targetX: CGFloat) {
        var items = pinned
        guard let oldIndex = items.firstIndex(of: bundle) else { return }
        items.remove(at: oldIndex)
        let target = min(max(Int((targetX / 62).rounded(.down)), 0), items.count)
        items.insert(bundle, at: target)
        pinned = items; refresh()
    }
    func newFinderWindow(on screen: NSScreen) {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let display = displayID(screen) else { return }
        let root = AXUIElementCreateApplication(finder.processIdentifier)
        let previous: [AXUIElement] = attribute(root, kAXWindowsAttribute as CFString) ?? []
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\"\nactivate\nmake new Finder window\nend tell")?.executeAndReturnError(&error)
        if let error = error {
            let alert = NSAlert(); alert.messageText = "Couldn’t open a Finder window"
            alert.informativeText = "Allow Windows QoL to control Finder in System Settings → Privacy & Security → Automation.\n\n\(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")"
            alert.runModal(); return
        }
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            attempts += 1
            let current: [AXUIElement] = attribute(root, kAXWindowsAttribute as CFString) ?? []
            if let created = current.first(where: { newWindow in !previous.contains(where: { CFEqual($0, newWindow) }) }) {
                let bounds = CGDisplayBounds(display)
                let size = windowRect(created)?.size ?? CGSize(width: 700, height: 500)
                var point = CGPoint(x: bounds.minX + max(0, (bounds.width - size.width) / 2), y: bounds.minY + max(30, (bounds.height - size.height) / 2))
                if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(created, kAXPositionAttribute as CFString, value) }
                AXUIElementPerformAction(created, kAXRaiseAction as CFString)
                timer.invalidate()
            } else if attempts >= 20 { timer.invalidate() }
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
            showWindows(matches, anchoredTo: sender)
        } else if let record = matches.first { closeHover(); toggle(record) }
        else if bundle == "com.apple.finder" { closeHover(); newFinderWindow(on: screen) }
        else if records.contains(where: { $0.app.bundleIdentifier == bundle }) {
            // Let the user explicitly choose a remote window instead of silently switching displays.
            showWindows(records.filter { $0.app.bundleIdentifier == bundle }, anchoredTo: sender)
        }
        else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first, app.isHidden {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                let hiddenWindows: [AXUIElement] = attribute(root, kAXWindowsAttribute as CFString) ?? []
                if !hiddenWindows.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "\(app.localizedName ?? "App") is hidden"
                    alert.informativeText = "Its existing windows may be on another display. Show the app?"
                    alert.addButton(withTitle: "Show App"); alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
            }
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
        hoverAnchor = window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -18, dy: -14)
        let cardWidth: CGFloat = 176, cardHeight: CGFloat = 148, padding: CGFloat = 12, gap: CGFloat = 8
        let contentWidth = CGFloat(matches.count) * (cardWidth + gap) - gap + 2 * padding
        let width = min(contentWidth, max(1, screen.visibleFrame.width - 24))
        let height = cardHeight + 2 * padding
        let x = min(max(screen.visibleFrame.minX + 12, hoverAnchor.midX - width / 2), screen.visibleFrame.maxX - width - 12)
        let panel = NSPanel(contentRect: NSRect(x: x, y: window.frame.maxY, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.98)
        panel.level = .floating; panel.hasShadow = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasHorizontalScroller = contentWidth > width
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let list = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: height))
        var cards: [WindowButton] = []
        for (index, record) in matches.enumerated() {
            let row = WindowButton(frame: NSRect(x: padding + CGFloat(index) * (cardWidth + gap), y: padding, width: cardWidth, height: cardHeight))
            row.title = (record.minimized ? "◌  " : "") + (record.title.isEmpty ? (record.app.localizedName ?? "Window") : record.title)
            row.record = record; row.target = self; row.action = #selector(windowSelected(_:))
            row.bezelStyle = .regularSquare; row.isBordered = false; row.alignment = .center
            row.contentTintColor = .white; row.font = .systemFont(ofSize: 13)
            row.lineBreakMode = .byTruncatingTail; row.imagePosition = .imageAbove
            row.imageScaling = .scaleProportionallyDown; row.image = record.app.icon
            row.wantsLayer = true; row.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            row.layer?.cornerRadius = 8; row.toolTip = row.title
            list.addSubview(row)
            cards.append(row)
        }
        scroll.documentView = list; panel.contentView = scroll
        hoverPanel = panel; panel.orderFrontRegardless()
        hoverLastInside = Date()
        loadWindowPreviews(matches, cards: cards, panel: panel)
        hoverMonitor = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, let panel = self.hoverPanel else { return }
            let mouse = NSEvent.mouseLocation
            let safeArea = panel.frame.union(self.hoverAnchor).insetBy(dx: -28, dy: -20)
            if safeArea.contains(mouse) { self.hoverLastInside = Date() }
            else if Date().timeIntervalSince(self.hoverLastInside) > 0.8 { self.closeHover() }
        }
    }
    func loadWindowPreviews(_ records: [WindowRecord], cards: [WindowButton], panel: NSPanel) {
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() else { return }
        // A matching process and window geometry are required; avoid showing the wrong window.
        let frames = records.map { windowRect($0.element) }
        Task { @MainActor [weak self, weak panel] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            for (index, record) in records.enumerated() where !record.minimized {
                guard let expected = frames[index], let panel = panel, self?.hoverPanel === panel else { continue }
                let candidates = content.windows.filter { candidate in
                    let rect = candidate.frame
                    return candidate.owningApplication?.processID == record.app.processIdentifier && candidate.isOnScreen &&
                        abs(rect.minX - expected.minX) + abs(rect.minY - expected.minY) + abs(rect.width - expected.width) + abs(rect.height - expected.height) < 12
                }
                let titled = candidates.filter { $0.title == record.title }
                let matches = titled.isEmpty ? candidates : titled
                guard matches.count == 1, let window = matches.first else { continue }
                let configuration = SCStreamConfiguration()
                configuration.width = 320; configuration.height = max(1, Int(320 * window.frame.height / max(1, window.frame.width)))
                configuration.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: window)
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration), self?.hoverPanel === panel else { continue }
                cards[index].image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
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
