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

func displayPinKey(_ id: CGDirectDisplayID) -> String {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
          let value = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { return "display-\(id)" }
    return value as String
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

class TaskbarClickButton: HoverButton {
    func showClickFeedback() {
        wantsLayer = true
        guard let layer = layer else { return }
        let flash = CALayer()
        flash.frame = layer.bounds.insetBy(dx: 3, dy: 3)
        flash.cornerRadius = 10
        flash.backgroundColor = NSColor.white.withAlphaComponent(0.30).cgColor
        layer.addSublayer(flash)
        CATransaction.begin()
        CATransaction.setCompletionBlock { flash.removeFromSuperlayer() }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0; animation.toValue = 0.0; animation.duration = 0.45
        flash.opacity = 0
        flash.add(animation, forKey: "click")
        CATransaction.commit()
    }
    override func mouseDown(with event: NSEvent) {
        showClickFeedback()
        super.mouseDown(with: event)
    }
}

final class AppIconButton: TaskbarClickButton {
    var appIcon: NSImage?
    var windowCount = 0
    var hasVisibleWindow = false
    var isFocused = false
    var remoteDirections: Set<Int> = []
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
                else if bounds.contains(convert(next.locationInWindow, from: nil)) { showClickFeedback(); performClick(nil) }
                break
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let icon = appIcon else { return }
        // NSButton draws in flipped coordinates: y = 0 is the top.
        if windowCount > 1 {
            let origins = windowCount == 2
                ? [NSPoint(x: 11, y: 6), NSPoint(x: 5, y: 12)]
                : [NSPoint(x: 13, y: 4), NSPoint(x: 9, y: 8), NSPoint(x: 5, y: 12)]
            for origin in origins {
                icon.draw(in: NSRect(origin: origin, size: NSSize(width: 41, height: 41)), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        } else {
            icon.draw(in: NSRect(x: 6, y: 9, width: 46, height: 46), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if windowCount > 0 {
            (isFocused ? NSColor.systemCyan : (hasVisibleWindow ? NSColor.systemBlue : NSColor.systemBlue.withAlphaComponent(0.45))).setFill()
            let lineHeight: CGFloat = hasVisibleWindow ? 5 : 3
            NSBezierPath(roundedRect: NSRect(x: 10, y: bounds.height - lineHeight - 2, width: 38, height: lineHeight), xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        } else if !remoteDirections.isEmpty {
            let left = remoteDirections.contains(-1)
            let right = remoteDirections.contains(1)
            let center = remoteDirections.contains(0) || (left && right)
            let clear = NSColor.systemBlue.withAlphaComponent(0.0)
            let blue = NSColor.systemBlue
            let colors = center ? [clear, blue, clear] : (left ? [blue, clear] : [clear, blue])
            let rect = NSRect(x: 10, y: bounds.height - 7, width: 38, height: 5)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).addClip()
            NSGradient(colors: colors)?.draw(in: rect, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

// macOS Zoom behaves differently between apps (notably Finder). Intercept only
// unmodified title-bar double clicks and retain each window's previous frame.
final class TitlebarZoom {
    private struct SavedFrame { let window: AXUIElement; let frame: CGRect }
    private struct Animation { let window: AXUIElement; let target: CGRect; let timer: Timer }
    private var saved: [SavedFrame] = []
    private var animations: [Animation] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowMouseUp = false
    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context = context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<TitlebarZoom>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port; source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let source = source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }
    func stop() {
        animations.forEach { $0.timer.invalidate() }; animations.removeAll()
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; swallowMouseUp = false
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            swallowMouseUp = false
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp && swallowMouseUp { swallowMouseUp = false; return nil }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        guard type == .leftMouseDown, event.getIntegerValueField(.mouseEventClickState) == 2,
              event.flags.intersection(modifiers).isEmpty,
              let window = titlebarWindow(at: event.location) else { return Unmanaged.passUnretained(event) }
        swallowMouseUp = true
        DispatchQueue.main.async { [weak self] in self?.toggle(window) }
        return nil
    }
    private func titlebarWindow(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        let interactive: Set<String> = ["AXButton", "AXTextField", "AXTextArea", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTab", "AXMenuButton", "AXLink", "AXSlider"]
        for _ in 0..<12 {
            let role: String = attribute(element, kAXRoleAttribute as CFString) ?? ""
            if interactive.contains(role) { return nil }
            if role == kAXWindowRole as String {
                let fullscreen: Bool = attribute(element, "AXFullScreen" as CFString) ?? false
                guard !fullscreen, let rect = windowRect(element), point.y >= rect.minY, point.y <= rect.minY + 28,
                      point.x >= rect.minX + 75, point.x <= rect.maxX - 10 else { return nil }
                return element
            }
            guard let parent: AXUIElement = attribute(element, kAXParentAttribute as CFString) else { return nil }
            element = parent
        }
        return nil
    }
    private func toggle(_ window: AXUIElement) {
        guard let current = windowRect(window) else { return }
        let screens = NSScreen.screens.compactMap { screen -> (NSScreen, CGRect)? in
            guard let id = displayID(screen) else { return nil }
            return (screen, CGDisplayBounds(id))
        }
        guard let (screen, display) = screens.max(by: { a, b in
            let aa = a.1.intersection(current); let bb = b.1.intersection(current)
            return (aa.isNull ? 0 : aa.width * aa.height) < (bb.isNull ? 0 : bb.width * bb.height)
        }), !display.intersection(current).isEmpty else { return }
        let visible = screen.visibleFrame
        let topInset = screen.frame.maxY - visible.maxY
        let leftInset = visible.minX - screen.frame.minX
        let bottomInset = max(taskbarHeight, visible.minY - screen.frame.minY)
        let target = CGRect(x: display.minX + leftInset, y: display.minY + topInset,
                            width: visible.width, height: display.height - topInset - bottomInset)
        guard target.width > 100, target.height > 100 else { return }
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 14 && abs(a.minY - b.minY) < 14 && abs(a.width - b.width) < 14 && abs(a.height - b.height) < 14
        }
        let active = animations.first { CFEqual($0.window, window) }
        active?.timer.invalidate()
        animations.removeAll { CFEqual($0.window, window) }
        let existing = saved.firstIndex { CFEqual($0.window, window) }
        let destination: CGRect
        if near(current, target) || active.map({ near($0.target, target) }) == true {
            if let existing = existing { destination = saved.remove(at: existing).frame }
            else {
                let width = target.width * 0.72, height = target.height * 0.72
                destination = CGRect(x: target.midX - width / 2, y: target.midY - height / 2, width: width, height: height)
            }
        } else {
            if let existing = existing { saved.remove(at: existing) }
            saved.append(SavedFrame(window: window, frame: current))
            if saved.count > 200 { saved.removeFirst() }
            destination = target
        }
        animate(window, from: current, to: destination)
    }
    private func animate(_ window: AXUIElement, from start: CGRect, to end: CGRect) {
        let started = ProcessInfo.processInfo.systemUptime
        let duration = 0.22
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            let progress = min(1.0, (ProcessInfo.processInfo.systemUptime - started) / duration)
            let eased = 1 - pow(1 - progress, 3)
            func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
            var point = CGPoint(x: lerp(start.minX, end.minX), y: lerp(start.minY, end.minY))
            var size = CGSize(width: lerp(start.width, end.width), height: lerp(start.height, end.height))
            guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else {
                timer.invalidate(); self?.animations.removeAll { $0.timer === timer }; return
            }
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
            let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
            if progress >= 1 || result != .success {
                timer.invalidate(); self?.animations.removeAll { $0.timer === timer }
            }
        }
        animations.append(Animation(window: window, target: end, timer: timer))
        RunLoop.main.add(timer, forMode: .common)
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
    var settingsContent: NSView?
    var sidebarButtons: [NSButton] = []
    var selectedSettingsCategory = 0
    var lastExternalApplication: NSRunningApplication?
    var shortcutStatusLabel: NSTextField?
    var accessibilityStatus: NSTextField?
    var screenCaptureStatus: NSTextField?
    var loginStatusLabel: NSTextField?
    var loginButton: NSButton?
    let shortcuts = WindowsShortcuts()
    let titlebarZoom = TitlebarZoom()
    let shortcutsKey = "fnShortcutsEnabled"
    var shortcutsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: shortcutsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: shortcutsKey) }
    }
    let pinnedKey = "pinnedApplications"
    let displayPinsKey = "pinnedApplicationsByDisplay"
    let dockBackupKey = "dockDelayBackup"
    var pinned: [String] {
        get { UserDefaults.standard.stringArray(forKey: pinnedKey) ?? ["com.apple.finder", "com.apple.Safari"] }
        set { UserDefaults.standard.set(newValue, forKey: pinnedKey); signature = "" }
    }
    var displayPins: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: displayPinsKey) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: displayPinsKey); signature = "" }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        lastExternalApplication = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        let defaults = UserDefaults.standard
        if let previous = defaults.persistentDomain(forName: "local.dan.windows-qol") {
            for key in [pinnedKey, dockBackupKey] where defaults.object(forKey: key) == nil {
                if let value = previous[key] { defaults.set(value, forKey: key) }
            }
        }
        prepareDock()
        if let icon = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Windows QoL") {
            let configured = icon.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)) ?? icon
            configured.isTemplate = true
            status.button?.image = configured
            status.button?.imagePosition = .imageOnly
        } else {
            status.button?.title = "▣"
        }
        status.button?.toolTip = "Windows QoL"
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
        titlebarZoom.stop()
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
        let settings = NSMenuItem(title: "Settings…", action: #selector(showPermissions), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        menu.addItem(.separator())
        let reload = NSMenuItem(title: "Reload Windows QoL", action: #selector(reloadApp), keyEquivalent: "")
        reload.target = self
        reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(reload)
        let quit = NSMenuItem(title: "Quit Windows QoL", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit); status.menu = menu
    }
    @objc func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApplication = app
    }
    @objc func showPermissions() {
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = app
        }
        if let window = permissionsWindow {
            displaySettingsCategory(selectedSettingsCategory)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 710, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Windows QoL Settings"; window.isReleasedWhenClosed = false
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 190, height: 420))
        sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.state = .active
        let categories = [("General", "gearshape"), ("Taskbar", "rectangle.bottomthird.inset.filled"), ("Shortcuts", "keyboard"), ("Permissions", "lock.shield")]
        sidebarButtons = []
        for (index, category) in categories.enumerated() {
            let button = NSButton(title: category.0, target: self, action: #selector(selectSettingsCategory(_:)))
            button.frame = NSRect(x: 12, y: 354 - CGFloat(index) * 39, width: 166, height: 32)
            button.tag = index; button.bezelStyle = .regularSquare; button.isBordered = false; button.alignment = .left
            button.image = NSImage(systemSymbolName: category.1, accessibilityDescription: nil); button.imagePosition = .imageLeading
            button.imageHugsTitle = false; button.wantsLayer = true; button.layer?.cornerRadius = 6
            sidebar.addSubview(button); sidebarButtons.append(button)
        }
        let content = NSView(frame: NSRect(x: 190, y: 0, width: 520, height: 420))
        window.contentView?.addSubview(sidebar); window.contentView?.addSubview(content)
        settingsContent = content; permissionsWindow = window
        displaySettingsCategory(0)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func selectSettingsCategory(_ sender: NSButton) { displaySettingsCategory(sender.tag) }
    func displaySettingsCategory(_ category: Int) {
        guard let content = settingsContent else { return }
        selectedSettingsCategory = category
        content.subviews.forEach { $0.removeFromSuperview() }
        accessibilityStatus = nil; screenCaptureStatus = nil; loginStatusLabel = nil; loginButton = nil; shortcutStatusLabel = nil
        for button in sidebarButtons {
            button.layer?.backgroundColor = (button.tag == category ? NSColor.controlAccentColor.withAlphaComponent(0.22) : NSColor.clear).cgColor
        }
        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text); label.font = .boldSystemFont(ofSize: 22)
            label.frame = NSRect(x: 30, y: 361, width: 460, height: 30); content.addSubview(label)
        }
        func text(_ value: String, y: CGFloat, height: CGFloat = 38) {
            let label = NSTextField(wrappingLabelWithString: value); label.font = .systemFont(ofSize: 13)
            label.frame = NSRect(x: 30, y: y, width: 450, height: height); content.addSubview(label)
        }
        func button(_ title: String, y: CGFloat, action: Selector, width: CGFloat = 165) -> NSButton {
            let control = NSButton(title: title, target: self, action: action)
            control.bezelStyle = .rounded; control.frame = NSRect(x: 26, y: y, width: width, height: 32)
            content.addSubview(control); return control
        }
        switch category {
        case 0:
            heading("General")
            text("Start Windows QoL automatically when you log in to your Mac.", y: 296)
            let state = NSTextField(labelWithString: ""); state.frame = NSRect(x: 30, y: 264, width: 360, height: 20); content.addSubview(state)
            loginStatusLabel = state; loginButton = button("Enable", y: 218, action: #selector(toggleLaunchAtLogin))
            text("macOS may ask you to approve this in Login Items & Extensions.", y: 160)
        case 1:
            heading("Taskbar")
            text("Pin your most recently used app to the primary taskbar, or right-click any taskbar icon to pin or unpin it.", y: 282, height: 56)
            let name = lastExternalApplication?.localizedName ?? "No app selected"
            text("Last used app: \(name)", y: 250, height: 22)
            let pin = button("Pin last used app", y: 204, action: #selector(pinFrontmost), width: 175)
            pin.isEnabled = lastExternalApplication?.bundleIdentifier != nil
            text("Restore the default pinned apps and clear pins on other displays.", y: 146)
            _ = button("Reset pinned apps", y: 101, action: #selector(resetPins), width: 175)
        case 2:
            heading("Shortcuts")
            let toggle = NSButton(checkboxWithTitle: "Enable Windows-style Fn shortcuts", target: self, action: #selector(toggleShortcuts))
            toggle.state = shortcutsEnabled ? .on : .off; toggle.frame = NSRect(x: 30, y: 302, width: 440, height: 28); content.addSubview(toggle)
            let state = NSTextField(labelWithString: ""); state.textColor = .secondaryLabelColor; state.font = .systemFont(ofSize: 11)
            state.frame = NSRect(x: 30, y: 287, width: 450, height: 16); content.addSubview(state); shortcutStatusLabel = state
            text("Fn-C/V/X: copy, paste, cut. Fn-A: select all. Fn-Z/Y: undo and redo. Fn-F: find. Fn-E: new Finder window.", y: 214, height: 72)
            text("Fn-S: screenshot of the current display. Fn-Shift-S: select an area. Both copy to the clipboard.", y: 145, height: 55)
            text("Fn-C and Fn-A replace macOS shortcuts while enabled.", y: 95)
        default:
            heading("Permissions")
            text("Accessibility is needed for window controls and Fn shortcuts.", y: 300)
            let ax = NSTextField(labelWithString: ""); ax.frame = NSRect(x: 30, y: 268, width: 280, height: 20); content.addSubview(ax)
            accessibilityStatus = ax; _ = button("Enable Accessibility…", y: 223, action: #selector(requestAccessibilityFromSettings), width: 190)
            text("Screen capture is needed for screenshots and previews. It grants broader screen access.", y: 149, height: 50)
            let capture = NSTextField(labelWithString: ""); capture.frame = NSRect(x: 30, y: 120, width: 280, height: 20); content.addSubview(capture)
            screenCaptureStatus = capture; _ = button("Enable Screen Capture…", y: 74, action: #selector(requestScreenCaptureFromSettings), width: 210)
            text("macOS manages permissions; changes may require reopening the app.", y: 22)
        }
        updatePermissionStatuses()
    }
    func updatePermissionStatuses() {
        shortcutStatusLabel?.stringValue = shortcutsEnabled ? (shortcuts.isRunning ? "Status: Active" : "Status: Unavailable — check Accessibility permission") : "Status: Off"
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
        updatePermissionStatuses(); rebuildMenu()
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
        guard let app = lastExternalApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        if !pinned.contains(id) { pinned.append(id) }
        refresh()
    }
    @objc func resetPins() {
        UserDefaults.standard.removeObject(forKey: pinnedKey)
        UserDefaults.standard.removeObject(forKey: displayPinsKey)
        signature = ""; refresh()
    }
    @objc func displaysChanged() { closeHover(); for panel in panels.values { panel.close() }; panels.removeAll(); signature = ""; refresh() }
    @objc func refresh() {
        if permissionsWindow?.isVisible == true { updatePermissionStatuses() }
        let trusted = AXIsProcessTrusted()
        if trusted && !titlebarZoom.isRunning { _ = titlebarZoom.start() }
        if !trusted && titlebarZoom.isRunning { titlebarZoom.stop() }
        if shortcutsEnabled && trusted && !shortcuts.isRunning, shortcuts.start() { signature = "" }
        if (!shortcutsEnabled || !trusted) && shortcuts.isRunning { shortcuts.stop(); signature = "" }
        records = trusted ? windows(previous: records) : []
        if trusted { keepMaximizedWindowsAboveTaskbars() }
        let displayPinState = displayPins.keys.sorted().map { "\($0):\((displayPins[$0] ?? []).joined(separator: ","))" }.joined(separator: "|")
        let state = "\(trusted)|\(pinned.joined(separator: ","))|\(displayPinState)|" + NSScreen.screens.map { "\(displayID($0) ?? 0):\($0.frame)" }.joined(separator: "|") + records.map { "\($0.app.processIdentifier):\($0.displayID):\($0.title):\($0.minimized):\(isActive($0))" }.sorted().joined(separator: "|")
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
            let isPrimary = id == primary
            let key = displayPinKey(id)
            let localPins = isPrimary ? pinned : (displayPins[key] ?? [])
            var ids: [String] = localPins
            let local = records.filter { $0.displayID == id }
            for record in local {
                if let bundle = record.app.bundleIdentifier, !ids.contains(bundle) { ids.append(bundle) }
            }
            let spotlight = TaskbarClickButton(frame: NSRect(x: 8, y: 3, width: 58, height: 66))
            spotlight.bezelStyle = .regularSquare; spotlight.isBordered = false
            spotlight.title = "\u{F8FF}"
            spotlight.font = .systemFont(ofSize: 46)
            spotlight.contentTintColor = .white
            spotlight.toolTip = "Spotlight Search"
            spotlight.target = self; spotlight.action = #selector(openSpotlight)
            bar.addSubview(spotlight)
            var x: CGFloat = 70
            for bundle in ids {
                guard x + 58 <= screen.frame.width - 200 else { break }
                let app = local.first { $0.app.bundleIdentifier == bundle }?.app
                let url = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                guard let appURL = url else { continue }
                let button = AppIconButton(frame: NSRect(x: x, y: 3, width: 58, height: 66))
                button.bezelStyle = .regularSquare; button.isBordered = false
                button.appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
                let localWindows = local.filter { $0.app.bundleIdentifier == bundle }
                if localPins.contains(bundle) && localWindows.isEmpty {
                    let currentBounds = CGDisplayBounds(id)
                    for remote in records where remote.app.bundleIdentifier == bundle && remote.displayID != id {
                        let other = CGDisplayBounds(remote.displayID)
                        if other.maxX <= currentBounds.minX { button.remoteDirections.insert(-1) }
                        else if other.minX >= currentBounds.maxX { button.remoteDirections.insert(1) }
                        else { button.remoteDirections.insert(0) }
                    }
                }
                button.windowCount = localWindows.count
                button.hasVisibleWindow = localWindows.contains { !$0.minimized }
                button.isFocused = localWindows.contains { isActive($0) }
                button.toolTip = app?.localizedName ?? FileManager.default.displayName(atPath: appURL.path)
                button.identifier = NSUserInterfaceItemIdentifier(bundle)
                button.target = self; button.action = #selector(appClicked(_:))
                button.onHover = { [weak self] button in self?.scheduleHover(button) }
                button.contextMenu = { [weak self] in self?.appContextMenu(bundle: bundle, displayKey: key, isPrimary: isPrimary) ?? NSMenu() }
                if localPins.contains(bundle) {
                    let leftEdge = screen.frame.minX + 70
                    button.onReorder = { [weak self] screenX in self?.reorderPin(bundle, targetX: screenX - leftEdge, displayKey: key, isPrimary: isPrimary) }
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
                let button = TaskbarClickButton(frame: NSRect(x: utilityX, y: 15, width: 44, height: 42))
                button.bezelStyle = .regularSquare; button.isBordered = false
                button.toolTip = bundle == "com.apple.Terminal" ? "Terminal" : "System Settings"
                button.image = NSImage(systemSymbolName: bundle == "com.apple.Terminal" ? "terminal" : "gearshape", accessibilityDescription: button.toolTip)
                button.imagePosition = .imageOnly; button.imageScaling = .scaleProportionallyDown
                button.contentTintColor = .white
                button.identifier = NSUserInterfaceItemIdentifier(bundle)
                button.target = self; button.action = #selector(launchUtility(_:))
                bar.addSubview(button)
            }
            let trash = TaskbarClickButton(frame: NSRect(x: max(0, screen.frame.width - 100), y: 15, width: 44, height: 42))
            trash.bezelStyle = .regularSquare; trash.isBordered = false
            trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Trash")
            trash.imagePosition = .imageOnly; trash.imageScaling = .scaleProportionallyDown
            trash.contentTintColor = .white; trash.toolTip = "Open Trash"
            trash.target = self; trash.action = #selector(openTrash(_:))
            bar.addSubview(trash)
            let dockButton = TaskbarClickButton(frame: NSRect(x: max(0, screen.frame.width - 52), y: 15, width: 44, height: 42))
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
    @objc func openSpotlight() {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false) else { return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    @objc func launchUtility(_ sender: NSButton) {
        guard let bundle = sender.identifier?.rawValue, let screen = sender.window?.screen,
              let display = displayID(screen) else { return }
        let previous = applicationWindows(bundle)
        if bundle == "com.apple.Terminal" {
            // With no target window, Terminal creates a new window. `cd` uses the
            // shell's home directory without touching existing Terminal sessions.
            let source = "tell application id \"com.apple.Terminal\"\ndo script \"cd\"\nactivate\nend tell"
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error = error {
                let alert = NSAlert(); alert.messageText = "Couldn’t open a new Terminal window"
                alert.informativeText = "Allow Windows QoL to control Terminal in System Settings → Privacy & Security → Automation, then try again.\n\n\(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")"
                alert.runModal()
            }
            if error == nil { placeOpenedWindow(bundle: bundle, previous: previous, on: display, allowExisting: false) }
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { self?.placeOpenedWindow(bundle: bundle, previous: previous, on: display, allowExisting: true) }
        }
    }
    func appContextMenu(bundle: String, displayKey: String, isPrimary: Bool) -> NSMenu {
        let menu = NSMenu()
        let primaryItem = NSMenuItem(title: pinned.contains(bundle) ? "Unpin from primary taskbar" : "Pin to primary taskbar", action: #selector(togglePin(_:)), keyEquivalent: "")
        primaryItem.target = self; primaryItem.representedObject = ["bundle": bundle, "scope": "primary"]; menu.addItem(primaryItem)
        if !isPrimary {
            let isPinnedHere = (displayPins[displayKey] ?? []).contains(bundle)
            let localItem = NSMenuItem(title: isPinnedHere ? "Unpin from this taskbar" : "Pin to this taskbar", action: #selector(togglePin(_:)), keyEquivalent: "")
            localItem.target = self; localItem.representedObject = ["bundle": bundle, "scope": displayKey]; menu.addItem(localItem)
        }
        return menu
    }
    @objc func togglePin(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? [String: String], let bundle = context["bundle"], let scope = context["scope"] else { return }
        if scope == "primary" {
            if pinned.contains(bundle) { pinned.removeAll { $0 == bundle } } else { pinned.append(bundle) }
        } else {
            var all = displayPins; var pins = all[scope] ?? []
            if pins.contains(bundle) { pins.removeAll { $0 == bundle } } else { pins.append(bundle) }
            if pins.isEmpty { all.removeValue(forKey: scope) } else { all[scope] = pins }
            displayPins = all
        }
        refresh()
    }
    func reorderPin(_ bundle: String, targetX: CGFloat, displayKey: String, isPrimary: Bool) {
        var items = isPrimary ? pinned : (displayPins[displayKey] ?? [])
        guard let oldIndex = items.firstIndex(of: bundle) else { return }
        items.remove(at: oldIndex)
        let target = min(max(Int((targetX / 62).rounded(.down)), 0), items.count)
        items.insert(bundle, at: target)
        if isPrimary { pinned = items } else { var all = displayPins; all[displayKey] = items; displayPins = all }
        refresh()
    }
    func applicationWindows(_ bundle: String) -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        return attribute(root, kAXWindowsAttribute as CFString) ?? []
    }
    func moveWindow(_ window: AXUIElement, to display: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { displayID($0) == display }),
              let rect = windowRect(window) else { return }
        let bounds = CGDisplayBounds(display)
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        let leftInset = screen.visibleFrame.minX - screen.frame.minX
        let usableWidth = screen.visibleFrame.width
        let usableHeight = max(0, bounds.height - topInset - taskbarHeight)
        var point = CGPoint(x: bounds.minX + leftInset + max(0, (usableWidth - rect.width) / 2),
                            y: bounds.minY + topInset + max(0, (usableHeight - rect.height) / 2))
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    func placeOpenedWindow(bundle: String, previous: [AXUIElement], on display: CGDirectDisplayID, allowExisting: Bool) {
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            attempts += 1
            let current = self.applicationWindows(bundle)
            let created = current.first { candidate in !previous.contains { CFEqual($0, candidate) } && windowRect(candidate) != nil }
            var target = created
            // Some apps reuse a window. Give newly created windows time to appear first.
            if target == nil && allowExisting && !previous.isEmpty && attempts >= 15,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                target = attribute(root, kAXFocusedWindowAttribute as CFString)
            }
            if let target = target {
                self.moveWindow(target, to: display)
                timer.invalidate()
            } else if attempts >= 100 { timer.invalidate() }
        }
    }
    func newFinderWindow(on screen: NSScreen) {
        guard let display = displayID(screen) else { return }
        let previous = applicationWindows("com.apple.finder")
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\"\nactivate\nmake new Finder window\nend tell")?.executeAndReturnError(&error)
        if let error = error {
            let alert = NSAlert(); alert.messageText = "Couldn’t open a Finder window"
            alert.informativeText = "Allow Windows QoL to control Finder in System Settings → Privacy & Security → Automation.\n\n\(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")"
            alert.runModal(); return
        }
        placeOpenedWindow(bundle: "com.apple.finder", previous: previous, on: display, allowExisting: false)
    }
    @objc func openTrash(_ sender: NSButton) {
        guard let screen = sender.window?.screen, let display = displayID(screen) else { return }
        let previous = applicationWindows("com.apple.finder")
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true))
        placeOpenedWindow(bundle: "com.apple.finder", previous: previous, on: display, allowExisting: true)
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
        else if records.contains(where: { $0.app.bundleIdentifier == bundle }) {
            let remote = records.filter { $0.app.bundleIdentifier == bundle }
            let primary = NSScreen.screens.first.flatMap(displayID) == id
            let pins = primary ? pinned : (displayPins[displayPinKey(id)] ?? [])
            if pins.contains(bundle), let record = remote.first(where: { isActive($0) }) ?? remote.first {
                closeHover(); if !isActive(record) { focus(record) }
            } else if bundle == "com.apple.finder" { closeHover(); newFinderWindow(on: screen) }
            else { showWindows(remote, anchoredTo: sender) }
        }
        else if bundle == "com.apple.finder" { closeHover(); newFinderWindow(on: screen) }
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
            let previous = applicationWindows(bundle)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                guard error == nil else { return }
                DispatchQueue.main.async { self?.placeOpenedWindow(bundle: bundle, previous: previous, on: id, allowExisting: true) }
            }
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
