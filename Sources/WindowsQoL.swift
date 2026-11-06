import AppKit
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement

let taskbarHeight: CGFloat = 60
let taskbarWindowGap: CGFloat = 2

// A small, extensible host for desktop features. The taskbar is the first feature.
struct WindowRecord {
    let app: NSRunningApplication
    let element: AXUIElement
    let title: String
    let displayID: CGDirectDisplayID
    let minimized: Bool
    let frame: CGRect?
    let subrole: String
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
            result.append(WindowRecord(app: app, element: element, title: title, displayID: chosen, minimized: minimized, frame: rect, subrole: subrole))
        }
    }
    return result
}

// Quartz supplies windows in front-to-back order; match them to tracked AX windows
// by process and geometry, avoiding guesses when the match is ambiguous.
func frontmostWindowsByDisplay(_ records: [WindowRecord], useCachedFrames: Bool = false) -> [CGDirectDisplayID: AXUIElement] {
    guard let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
    let candidates = Dictionary(grouping: records.filter { !$0.minimized }, by: { $0.app.processIdentifier })
        .mapValues { windows in windows.compactMap { record -> (WindowRecord, CGRect)? in
            guard let frame = useCachedFrames ? record.frame : windowRect(record.element) else { return nil }
            return (record, frame)
        } }
    var result: [CGDirectDisplayID: AXUIElement] = [:]
    var ambiguousDisplays: Set<CGDirectDisplayID> = []
    var focusedByPID: [pid_t: AXUIElement] = [:]
    for info in listed {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let pid = info[kCGWindowOwnerPID as String] as? Int,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
        let matches = (candidates[pid_t(pid)] ?? []).filter { _, frame in
            return abs(frame.minX - rect.minX) + abs(frame.minY - rect.minY) + abs(frame.width - rect.width) + abs(frame.height - rect.height) < 12
        }
        let record: WindowRecord
        if matches.count == 1, let match = matches.first {
            record = match.0
        } else if matches.count > 1 {
            let process = pid_t(pid)
            if focusedByPID[process] == nil {
                let app = AXUIElementCreateApplication(process)
                focusedByPID[process] = attribute(app, kAXFocusedWindowAttribute as CFString)
            }
            guard let focused = focusedByPID[process],
                  let match = matches.first(where: { CFEqual($0.0.element, focused) }) else {
                // Never promote a background app just because matching the
                // frontmost app's overlapping windows is ambiguous.
                for match in matches where result[match.0.displayID] == nil { ambiguousDisplays.insert(match.0.displayID) }
                continue
            }
            record = match.0
        } else { continue }
        guard result[record.displayID] == nil, !ambiguousDisplays.contains(record.displayID) else { continue }
        result[record.displayID] = record.element
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

// Keep the temporary order in the view until the drop animation finishes.
final class PinReorderInteraction {
    weak var bar: NSView?
    weak var dragged: AppIconButton?
    let pins: [String]
    var visibleOrder: [String] = []
    var originalX: CGFloat = 0
    var slotX: [CGFloat] = []
    let begin: () -> Void
    let commit: ([String]) -> Void
    let finishFeedback: () -> Void

    init(bar: NSView, pins: [String], begin: @escaping () -> Void, commit: @escaping ([String]) -> Void, finishFeedback: @escaping () -> Void) {
        self.bar = bar; self.pins = pins; self.begin = begin; self.commit = commit; self.finishFeedback = finishFeedback
    }
    var buttons: [AppIconButton] { bar?.subviews.compactMap { $0 as? AppIconButton } ?? [] }
    func showUnpinnedFeedback() {
        begin()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            for button in buttons where !pins.contains(button.identifier?.rawValue ?? "") { button.animator().alphaValue = 0.3 }
        }
    }
    func endUnpinnedFeedback() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            for button in buttons { button.animator().alphaValue = 1 }
        }, completionHandler: { [self] in finishFeedback() })
    }
    func start(_ button: AppIconButton) {
        guard let bar = bar else { return }
        begin()
        dragged = button; originalX = button.frame.minX
        let pinnedButtons = buttons.filter { pins.contains($0.identifier?.rawValue ?? "") }.sorted { $0.frame.minX < $1.frame.minX }
        visibleOrder = pinnedButtons.compactMap { $0.identifier?.rawValue }
        slotX = pinnedButtons.map { $0.frame.minX }
        bar.addSubview(button, positioned: .above, relativeTo: nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            for other in buttons where !pins.contains(other.identifier?.rawValue ?? "") { other.animator().alphaValue = 0.3 }
        }
    }
    func move(_ delta: CGFloat) {
        guard let button = dragged, let id = button.identifier?.rawValue, !slotX.isEmpty else { return }
        let x = min(max(originalX + delta, slotX[0] - 20), slotX[slotX.count - 1] + 20)
        button.setFrameOrigin(NSPoint(x: x, y: button.frame.minY))
        let target = slotX.enumerated().min { abs($0.element - x) < abs($1.element - x) }!.offset
        guard let old = visibleOrder.firstIndex(of: id), old != target else { return }
        visibleOrder.remove(at: old); visibleOrder.insert(id, at: target)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for other in buttons where other !== button {
                if let name = other.identifier?.rawValue, let index = visibleOrder.firstIndex(of: name) {
                    other.animator().setFrameOrigin(NSPoint(x: slotX[index], y: other.frame.minY))
                }
            }
        }
    }
    func end() {
        guard let button = dragged, let id = button.identifier?.rawValue, let index = visibleOrder.firstIndex(of: id) else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.animator().setFrameOrigin(NSPoint(x: slotX[index], y: button.frame.minY))
            for other in buttons { other.animator().alphaValue = 1 }
        }, completionHandler: { [self] in
            button.layer?.backgroundColor = NSColor.clear.cgColor
            var order = visibleOrder.makeIterator()
            let visible = Set(visibleOrder)
            commit(pins.map { visible.contains($0) ? (order.next() ?? $0) : $0 })
        })
    }
}

class TaskbarClickButton: HoverButton {
    var contextMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() ?? super.menu(for: event) }
    func showContextMenu(_ event: NSEvent) -> Bool {
        guard let menu = contextMenu?() else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }
    override func rightMouseDown(with event: NSEvent) {
        if !showContextMenu(event) { super.rightMouseDown(with: event) }
    }
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
        if event.modifierFlags.contains(.control), showContextMenu(event) { return }
        showClickFeedback()
        super.mouseDown(with: event)
    }
}

final class AppIconButton: TaskbarClickButton {
    var appIcon: NSImage?
    var badge: String? { didSet { if badge != oldValue { needsDisplay = true } } }
    var windowCount = 0
    var hasVisibleWindow = false
    var isFocused = false
    var remoteDirections: Set<Int> = []
    var onDragStart: ((AppIconButton) -> Void)?
    var onDragMove: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var canReorder = false
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), showContextMenu(event) { return }
        guard let window = window else { return }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        var dragging = false
        if canReorder {
            wantsLayer = true
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            layer?.cornerRadius = 10
            NSCursor.closedHand.push()
        }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = window.convertPoint(toScreen: next.locationInWindow)
            if next.type == .leftMouseDragged && !dragging && onDragStart != nil && hypot(point.x - start.x, point.y - start.y) > 8 {
                dragging = true
                onDragStart?(self)
            }
            if next.type == .leftMouseDragged && dragging { onDragMove?(point.x - start.x) }
            if next.type == .leftMouseUp {
                if canReorder { NSCursor.pop() }
                if dragging { onDragEnd?() }
                else if bounds.contains(convert(next.locationInWindow, from: nil)) { showClickFeedback(); performClick(nil) }
                if !dragging { layer?.backgroundColor = NSColor.clear.cgColor }
                break
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let icon = appIcon else { return }
        // NSButton draws in flipped coordinates: y = 0 is the top.
        NSGraphicsContext.current?.imageInterpolation = .high
        if windowCount > 1 {
            let origins = windowCount == 2
                ? [NSPoint(x: 9, y: 3), NSPoint(x: 3, y: 9)]
                : [NSPoint(x: 11, y: 1), NSPoint(x: 7, y: 5), NSPoint(x: 3, y: 9)]
            for origin in origins {
                icon.draw(in: NSRect(origin: origin, size: NSSize(width: 39, height: 39)), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        } else {
            icon.draw(in: NSRect(x: 4, y: 5, width: 44, height: 44), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let lineRect = NSRect(x: 15, y: 50, width: 22, height: 2)
        if windowCount > 0 {
            NSGraphicsContext.saveGraphicsState()
            let color = hasVisibleWindow && isFocused ? NSColor.systemBlue : NSColor.white
            let glow = NSShadow(); glow.shadowColor = color.withAlphaComponent(0.45)
            glow.shadowBlurRadius = 4; glow.shadowOffset = .zero; glow.set()
            color.withAlphaComponent(hasVisibleWindow && isFocused ? 0.9 : 0.55).setFill()
            let indicator = hasVisibleWindow ? lineRect : NSRect(x: 24.5, y: 49.5, width: 3, height: 3)
            NSBezierPath(roundedRect: indicator, xRadius: indicator.height / 2, yRadius: indicator.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if !remoteDirections.isEmpty {
            let left = remoteDirections.contains(-1)
            let right = remoteDirections.contains(1)
            let center = remoteDirections.contains(0) || (left && right)
            let clear = NSColor.white.withAlphaComponent(0)
            let grey = NSColor.white.withAlphaComponent(0.65)
            let colors = center ? [clear, grey, clear] : (left ? [grey, clear] : [clear, grey])
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: lineRect, xRadius: 1, yRadius: 1).addClip()
            NSGradient(colors: colors)?.draw(in: lineRect, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }
        if let badge = badge, !badge.isEmpty {
            let text = badge as NSString
            let font = NSFont.boldSystemFont(ofSize: 11)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            let width = min(bounds.width - 4, max(18, size.width + 8))
            let rect = NSRect(x: bounds.width - width - 1, y: 2, width: width, height: 18)
            NSColor(srgbRed: 0.82, green: 0.0, blue: 0.08, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            NSGraphicsContext.saveGraphicsState()
            rect.insetBy(dx: 2, dy: 0).clip()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

// The Dock exposes its badge text through Accessibility, even when hidden.
// Match tiles by app bundle URL rather than a potentially ambiguous app name.
final class DockBadges {
    private var dockPID: pid_t = 0
    private var tiles: [String: AXUIElement] = [:]
    private var lastScan = Date.distantPast

    func read() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first(where: { !$0.isTerminated }) else {
            dockPID = 0; tiles.removeAll(); return [:]
        }
        if dockPID != dock.processIdentifier {
            dockPID = dock.processIdentifier; tiles.removeAll(); lastScan = .distantPast
        }
        if Date().timeIntervalSince(lastScan) >= 5 {
            var found: [String: AXUIElement] = [:]
            collect(AXUIElementCreateApplication(dockPID), depth: 0, into: &found)
            tiles = found
            lastScan = Date()
        }
        var badges: [String: String] = [:]
        var stale = false
        for (bundle, tile) in tiles {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(tile, "AXStatusLabel" as CFString, &value)
            if result == .success, let label = value as? String {
                // Some apps use a dot for unread activity even after their numbered
                // notifications are cleared. Only display meaningful badge text.
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let dots = CharacterSet(charactersIn: ".•●·∙‧")
                if !trimmed.isEmpty && trimmed.unicodeScalars.contains(where: { !dots.contains($0) }) {
                    badges[bundle] = trimmed
                }
            } else if result != .success && result != .noValue && result != .attributeUnsupported { stale = true }
        }
        if stale { lastScan = .distantPast }
        return badges
    }

    private func collect(_ element: AXUIElement, depth: Int, into tiles: inout [String: AXUIElement]) {
        guard depth < 6 else { return }
        if let url: URL = attribute(element, kAXURLAttribute as CFString),
           let bundle = Bundle(url: url)?.bundleIdentifier {
            tiles[bundle] = element
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute as CFString) ?? []
        for child in children { collect(child, depth: depth + 1, into: &tiles) }
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
        let bottomInset = taskbarHeight + taskbarWindowGap
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
    var reorderingPins = false
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var panels: [CGDirectDisplayID: TaskbarPanel] = [:]
    var timer: Timer?
    private let centeredTaskbarKey = "centeredTaskbar"
    private let taskbarSpacingKey = "centeredTaskbarSpacing"
    private var centeredTaskbar: Bool { UserDefaults.standard.bool(forKey: centeredTaskbarKey) }
    private var taskbarSpacing: Double {
        let saved = UserDefaults.standard.object(forKey: taskbarSpacingKey) as? Double ?? 24
        return min(80, max(2, saved))
    }
    var monitorFocusTimer: Timer?
    var pointerDisplay: CGDirectDisplayID?
    var pendingPointerDisplay: CGDirectDisplayID?
    var pendingMonitorWindow: WindowRecord?
    var records: [WindowRecord] = []
    // Retain only recent attempts for still-open windows. An unchanged frame
    // after a resize can mean the application ignored the request.
    var clearanceAttempts: [(element: AXUIElement, frame: CGRect, time: Date)] = []
    var startupDockRequest: DispatchWorkItem?
    var signature = ""
    var hoverPanel: NSPanel?
    var hoverAnchor: NSRect = .zero
    var hoverPending: DispatchWorkItem?
    var hoverMonitor: Timer?
    var hoverLastInside = Date()
    var pendingPreviewCloses: [(WindowRecord, Date)] = []
    var previewAnimating = false
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
    let dockBadges = DockBadges()
    var badges: [String: String] = [:]
    let shortcutsKey = "fnShortcutsEnabled"
    let monitorFocusKey = "activateOnMonitorEntry"
    var monitorFocusEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: monitorFocusKey) }
        set { UserDefaults.standard.set(newValue, forKey: monitorFocusKey) }
    }
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
        updateMonitorFocusTimer()
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
        // A defaults write and Dock restart can hide the Dock without updating
        // the space macOS reserves for it. Apply the setting through the same
        // System Events path as the taskbar toggle once Dock has relaunched.
        let startupDockRequest = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.startupDockRequest = nil
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"System Events\" to tell dock preferences to set autohide to true")?.executeAndReturnError(&error)
            if let error = error { NSLog("Could not apply Dock auto-hide at startup: %@", String(describing: error)) }
        }
        self.startupDockRequest = startupDockRequest
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: startupDockRequest)
    }
    func applicationWillTerminate(_ notification: Notification) {
        startupDockRequest?.cancel()
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 710, height: 540), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Windows QoL Settings"; window.isReleasedWhenClosed = false
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 190, height: 540))
        sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.state = .active
        let categories = [("General", "gearshape"), ("Taskbar", "rectangle.bottomthird.inset.filled"), ("Shortcuts", "keyboard"), ("Permissions", "lock.shield")]
        sidebarButtons = []
        for (index, category) in categories.enumerated() {
            let button = NSButton(title: category.0, target: self, action: #selector(selectSettingsCategory(_:)))
            button.frame = NSRect(x: 12, y: 474 - CGFloat(index) * 39, width: 166, height: 32)
            button.tag = index; button.bezelStyle = .regularSquare; button.isBordered = false; button.alignment = .left
            button.image = NSImage(systemSymbolName: category.1, accessibilityDescription: nil); button.imagePosition = .imageLeading
            button.imageHugsTitle = false; button.wantsLayer = true; button.layer?.cornerRadius = 6
            sidebar.addSubview(button); sidebarButtons.append(button)
        }
        let content = NSView(frame: NSRect(x: 190, y: 0, width: 520, height: 540))
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
            let layoutLabel = NSTextField(labelWithString: "Taskbar layout")
            layoutLabel.frame = NSRect(x: 30, y: 326, width: 150, height: 22); content.addSubview(layoutLabel)
            let layout = NSPopUpButton(frame: NSRect(x: 190, y: 321, width: 260, height: 28), pullsDown: false)
            layout.addItems(withTitles: ["Standard (left aligned)", "Centered"])
            layout.selectItem(at: centeredTaskbar ? 1 : 0)
            layout.target = self; layout.action = #selector(changeTaskbarLayout(_:)); content.addSubview(layout)
            let spacingLabel = NSTextField(labelWithString: "Preferred icon spacing")
            spacingLabel.frame = NSRect(x: 30, y: 287, width: 160, height: 22); content.addSubview(spacingLabel)
            let spacing = NSSlider(value: taskbarSpacing, minValue: 2, maxValue: 80, target: self, action: #selector(changeTaskbarSpacing(_:)))
            spacing.frame = NSRect(x: 190, y: 284, width: 220, height: 24); spacing.isEnabled = centeredTaskbar
            spacing.toolTip = "Preferred gap between icons; spacing shrinks automatically when needed."
            content.addSubview(spacing)
            let spacingValue = NSTextField(labelWithString: "\(Int(taskbarSpacing.rounded())) pt")
            spacingValue.frame = NSRect(x: 420, y: 287, width: 60, height: 22); spacingValue.tag = 817
            spacingValue.textColor = .secondaryLabelColor; content.addSubview(spacingValue)
            text("Spacing adjusts automatically to fit the available space.", y: 258, height: 22)
            let focusToggle = NSButton(checkboxWithTitle: "Activate windows when moving between monitors", target: self, action: #selector(toggleMonitorFocus(_:)))
            focusToggle.state = monitorFocusEnabled ? .on : .off
            focusToggle.frame = NSRect(x: 30, y: 222, width: 450, height: 28); content.addSubview(focusToggle)
            text("Moving to another display can change keyboard focus. Requires Accessibility access.", y: 181, height: 38)
            text("Pin your most recently used app to the primary taskbar, or right-click an icon to pin or unpin it.", y: 133, height: 38)
            let name = lastExternalApplication?.localizedName ?? "No app selected"
            text("Last used app: \(name)", y: 107, height: 22)
            let pin = button("Pin last used app", y: 70, action: #selector(pinFrontmost), width: 175)
            pin.isEnabled = lastExternalApplication?.bundleIdentifier != nil
            let reset = NSButton(title: "Reset pinned apps", target: self, action: #selector(resetPins))
            reset.bezelStyle = .rounded; reset.frame = NSRect(x: 210, y: 70, width: 175, height: 32); content.addSubview(reset)
            reset.toolTip = "Restore default pins and clear pins on other displays."
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
        for view in content.subviews { view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + 120)) }
        updatePermissionStatuses()
    }
    @objc private func changeTaskbarLayout(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 1, forKey: centeredTaskbarKey)
        signature = ""; refresh(); displaySettingsCategory(1)
    }
    @objc private func changeTaskbarSpacing(_ sender: NSSlider) {
        let value = sender.doubleValue.rounded()
        UserDefaults.standard.set(value, forKey: taskbarSpacingKey)
        (settingsContent?.viewWithTag(817) as? NSTextField)?.stringValue = "\(Int(value)) pt"
        signature = ""; refresh()
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
    @objc func toggleMonitorFocus(_ sender: NSButton) {
        monitorFocusEnabled = sender.state == .on
        updateMonitorFocusTimer()
    }
    func updateMonitorFocusTimer() {
        monitorFocusTimer?.invalidate(); monitorFocusTimer = nil
        pointerDisplay = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }.flatMap(displayID)
        pendingPointerDisplay = nil
        pendingMonitorWindow = nil
        guard monitorFocusEnabled else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.checkMonitorEntry() }
        RunLoop.main.add(timer, forMode: .common)
        monitorFocusTimer = timer
    }
    func checkMonitorEntry() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }), let id = displayID(screen) else {
            pointerDisplay = nil; pendingPointerDisplay = nil; pendingMonitorWindow = nil; return
        }
        if pointerDisplay != id {
            pointerDisplay = id; pendingPointerDisplay = id; pendingMonitorWindow = nil
        }
        guard pendingPointerDisplay == id else { return }
        // Never activate during a drag or while our settings window is active.
        guard NSEvent.pressedMouseButtons == 0, !NSApp.isActive, AXIsProcessTrusted() else {
            pendingPointerDisplay = nil; pendingMonitorWindow = nil; return
        }
        // Wait until the pointer reaches the usable window area if it entered
        // through a menu bar or taskbar; don't activate the desktop or a panel.
        guard screen.visibleFrame.contains(point), point.y >= screen.frame.minY + taskbarHeight else { return }
        guard let primary = NSScreen.screens.first else { return }
        let quartzPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        if pendingMonitorWindow == nil {
            let current = windows(previous: records)
            guard let frontmost = frontmostWindowsByDisplay(current, useCachedFrames: true)[id],
                  let record = current.first(where: { CFEqual($0.element, frontmost) }),
                  record.frame != nil else {
                pendingPointerDisplay = nil; return
            }
            pendingMonitorWindow = record
        }
        // Crossing over an exposed background window must not raise it. Keep
        // waiting until the pointer reaches the display's frontmost window.
        guard let target = pendingMonitorWindow, let targetFrame = target.frame,
              targetFrame.contains(quartzPoint) else { return }
        pendingPointerDisplay = nil; pendingMonitorWindow = nil
        let current = windows(previous: records)
        guard let frontmost = frontmostWindowsByDisplay(current, useCachedFrames: true)[id],
              CFEqual(frontmost, target.element),
              let record = current.first(where: { CFEqual($0.element, frontmost) }),
              let frame = record.frame, frame.contains(quartzPoint) else { return }
        guard let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        // Verify that no other normal window is above the target at this point.
        guard let info = listed.first(where: { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(quartzPoint)
        }), let pid = info[kCGWindowOwnerPID as String] as? Int,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return }
        guard record.app.processIdentifier == pid_t(pid),
              abs(frame.minX - rect.minX) + abs(frame.minY - rect.minY) + abs(frame.width - rect.width) + abs(frame.height - rect.height) < 12,
              !isActive(record) else { return }
        focus(record, preserveRemoteMinimized: true)
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
    @objc func displaysChanged() { closeHover(); for panel in panels.values { panel.close() }; panels.removeAll(); signature = ""; updateMonitorFocusTimer(); refresh() }
    @objc func refresh() {
        guard !reorderingPins else { return }
        if permissionsWindow?.isVisible == true { updatePermissionStatuses() }
        let trusted = AXIsProcessTrusted()
        let latestBadges = trusted ? dockBadges.read() : [:]
        if latestBadges != badges {
            badges = latestBadges
            for panel in panels.values {
                for button in panel.contentView?.subviews.compactMap({ $0 as? AppIconButton }) ?? [] {
                    button.badge = button.identifier.flatMap { badges[$0.rawValue] }
                }
            }
        }
        if trusted && !titlebarZoom.isRunning { _ = titlebarZoom.start() }
        if !trusted && titlebarZoom.isRunning { titlebarZoom.stop() }
        if shortcutsEnabled && trusted && !shortcuts.isRunning, shortcuts.start() { signature = "" }
        if (!shortcutsEnabled || !trusted) && shortcuts.isRunning { shortcuts.stop(); signature = "" }
        records = trusted ? windows(previous: records) : []
        if trusted { keepMaximizedWindowsAboveTaskbars() }
        let frontmost = frontmostWindowsByDisplay(records, useCachedFrames: true)
        let displayPinState = displayPins.keys.sorted().map { "\($0):\((displayPins[$0] ?? []).joined(separator: ","))" }.joined(separator: "|")
        let state = "\(trusted)|\(pinned.joined(separator: ","))|\(displayPinState)|" + NSScreen.screens.map { "\(displayID($0) ?? 0):\($0.frame)" }.joined(separator: "|") + records.map { record in "\(record.app.processIdentifier):\(record.displayID):\(record.title):\(record.minimized):\(frontmost[record.displayID].map { CFEqual($0, record.element) } ?? false)" }.sorted().joined(separator: "|")
        guard state != signature else { return }
        signature = state
        rebuildMenu()
        let primary = NSScreen.screens.first.flatMap(displayID)
        for screen in NSScreen.screens {
            guard let id = displayID(screen) else { continue }
            let panel = panels[id] ?? TaskbarPanel(screen: screen)
            panels[id] = panel
            panel.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: taskbarHeight), display: false)
            let bar = NSView(frame: NSRect(x: 0, y: 0, width: screen.frame.width, height: taskbarHeight))
            let utilityIDs = ["com.apple.finder", "com.apple.Terminal", "com.apple.systempreferences"]
            let isPrimary = id == primary
            let key = displayPinKey(id)
            let localPins = isPrimary ? pinned : (displayPins[key] ?? [])
            var ids: [String] = localPins
            let local = records.filter { $0.displayID == id }
            for record in local {
                if let bundle = record.app.bundleIdentifier, !ids.contains(bundle) { ids.append(bundle) }
            }
            let spotlight = TaskbarClickButton(frame: NSRect(x: 8, y: 2, width: 52, height: 56))
            spotlight.bezelStyle = .regularSquare; spotlight.isBordered = false
            spotlight.title = "\u{F8FF}"
            spotlight.font = .systemFont(ofSize: 46)
            spotlight.contentTintColor = .white
            spotlight.toolTip = "Spotlight Search"
            spotlight.target = self; spotlight.action = #selector(openSpotlight)
            bar.addSubview(spotlight)
            let availableApps = ids.compactMap { bundle -> (String, URL)? in
                let app = local.first { $0.app.bundleIdentifier == bundle }?.app
                guard let url = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
                return (bundle, url)
            }
            let leftEdge: CGFloat = 62
            let rightEdge = max(leftEdge, screen.frame.width - 216)
            let capacity = max(0, Int((rightEdge - leftEdge) / 52))
            let visibleApps = centeredTaskbar ? Array(availableApps.prefix(capacity)) : availableApps
            let count = visibleApps.count
            let gap: CGFloat
            var x: CGFloat
            if centeredTaskbar {
                let fitGap = count > 1 ? max(0, (rightEdge - leftEdge - CGFloat(count) * 52) / CGFloat(count - 1)) : 0
                gap = min(CGFloat(taskbarSpacing), fitGap)
                let groupWidth = CGFloat(count) * 52 + CGFloat(max(0, count - 1)) * gap
                x = min(max((screen.frame.width - groupWidth) / 2, leftEdge), rightEdge - groupWidth)
            } else {
                gap = 2
                x = leftEdge
            }
            for (bundle, appURL) in visibleApps {
                guard x + 52 <= screen.frame.width - 216 else { break }
                let app = local.first { $0.app.bundleIdentifier == bundle }?.app
                let button = AppIconButton(frame: NSRect(x: x, y: 2, width: 52, height: 56))
                button.bezelStyle = .regularSquare; button.isBordered = false
                button.title = ""
                button.appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
                button.badge = badges[bundle]
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
                button.isFocused = localWindows.contains { record in frontmost[id].map { CFEqual($0, record.element) } ?? false }
                if localWindows.isEmpty { button.toolTip = app?.localizedName ?? FileManager.default.displayName(atPath: appURL.path) }
                button.identifier = NSUserInterfaceItemIdentifier(bundle)
                button.target = self; button.action = #selector(appClicked(_:))
                button.onHover = { [weak self] button in self?.scheduleHover(button) }
                button.contextMenu = { [weak self] in
                    guard let self = self else { return NSMenu() }
                    self.closeHover()
                    return self.appContextMenu(bundle: bundle, displayKey: key, isPrimary: isPrimary, display: id)
                }
                bar.addSubview(button)
                x += 52 + gap
            }
            let reorder = PinReorderInteraction(bar: bar, pins: localPins, begin: { [weak self] in
                self?.reorderingPins = true
                self?.closeHover()
            }, commit: { [weak self] order in
                guard let self = self else { return }
                if isPrimary { self.pinned = order }
                else { var all = self.displayPins; all[key] = order; self.displayPins = all }
                self.reorderingPins = false
                self.refresh()
            }, finishFeedback: { [weak self] in
                self?.reorderingPins = false
                self?.refresh()
            })
            for button in bar.subviews.compactMap({ $0 as? AppIconButton }) {
                button.canReorder = localPins.contains(button.identifier?.rawValue ?? "")
                if button.canReorder {
                    button.onDragStart = { [reorder] in reorder.start($0) }
                    button.onDragMove = { [reorder] in reorder.move($0) }
                    button.onDragEnd = { [reorder] in reorder.end() }
                } else {
                    button.onDragStart = { [reorder] _ in reorder.showUnpinnedFeedback() }
                    button.onDragEnd = { [reorder] in reorder.endUnpinnedFeedback() }
                }
            }
            if !trusted {
                let label = NSTextField(labelWithString: "Accessibility needed: remove and re-add Windows QoL in System Settings")
                label.textColor = .white; label.font = .systemFont(ofSize: 12)
                label.frame = NSRect(x: x + 8, y: 21, width: max(0, screen.frame.width - x - 216), height: 18)
                bar.addSubview(label)
            }
            for (index, bundle) in utilityIDs.enumerated() {
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil else { continue }
                let utilityX = max(0, screen.frame.width - 208 + CGFloat(index) * 40)
                let button = TaskbarClickButton(frame: NSRect(x: utilityX, y: 9, width: 40, height: 42))
                button.bezelStyle = .regularSquare; button.isBordered = false
                let title = bundle == "com.apple.finder" ? "Finder" : (bundle == "com.apple.Terminal" ? "Terminal" : "System Settings")
                let symbol = bundle == "com.apple.finder" ? "folder" : (bundle == "com.apple.Terminal" ? "terminal" : "gearshape")
                button.onHover = { [weak self] button in self?.scheduleUtilityTooltip(button, title: "Open \(title)") }
                button.setAccessibilityLabel("Open \(title)")
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                if bundle != "com.apple.systempreferences" {
                    button.contextMenu = { [weak self] in
                        guard let self = self else { return NSMenu() }
                        self.closeHover()
                        return self.locationMenu(bundle: bundle, display: id)
                    }
                }
                button.imagePosition = .imageOnly; button.imageScaling = .scaleProportionallyDown
                button.contentTintColor = .white
                button.identifier = NSUserInterfaceItemIdentifier(bundle)
                button.target = self; button.action = #selector(launchUtility(_:))
                bar.addSubview(button)
            }
            let trash = TaskbarClickButton(frame: NSRect(x: max(0, screen.frame.width - 88), y: 9, width: 40, height: 42))
            trash.bezelStyle = .regularSquare; trash.isBordered = false
            trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Trash")
            trash.imagePosition = .imageOnly; trash.imageScaling = .scaleProportionallyDown
            trash.contentTintColor = .white; trash.setAccessibilityLabel("Open Trash")
            trash.onHover = { [weak self] button in self?.scheduleUtilityTooltip(button, title: "Open Trash") }
            trash.target = self; trash.action = #selector(openTrash(_:))
            bar.addSubview(trash)
            let dockButton = TaskbarClickButton(frame: NSRect(x: max(0, screen.frame.width - 48), y: 9, width: 40, height: 42))
            dockButton.bezelStyle = .regularSquare; dockButton.isBordered = false
            dockButton.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Toggle Dock auto-hide")
            dockButton.contentTintColor = .white
            dockButton.setAccessibilityLabel("Toggle Apple Dock auto-hide (all displays)")
            dockButton.onHover = { [weak self] button in self?.scheduleUtilityTooltip(button, title: "Toggle Dock auto-hide") }
            dockButton.target = self; dockButton.action = #selector(toggleDockAutoHide)
            bar.addSubview(dockButton)
            panel.contentView = bar; panel.orderFrontRegardless()
        }
    }
    func keepMaximizedWindowsAboveTaskbars() {
        // macOS does not reserve desktop space for third-party taskbar panels.
        // Adjust only windows that span nearly the full usable display height,
        // after the user has finished dragging or resizing.
        clearanceAttempts.removeAll { attempt in
            !records.contains { CFEqual($0.element, attempt.element) && $0.frame == attempt.frame }
        }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        for record in records where !record.minimized {
            guard let screen = NSScreen.screens.first(where: { displayID($0) == record.displayID }),
                  let rect = record.frame,
                  record.subrole == kAXStandardWindowSubrole as String,
                  !clearanceAttempts.contains(where: { CFEqual($0.element, record.element) && Date().timeIntervalSince($0.time) < 30 }) else { continue }
            let display = CGDisplayBounds(record.displayID)
            let topInset = screen.frame.maxY - screen.visibleFrame.maxY
            let usableTop = display.minY + topInset
            let taskbarTop = display.maxY - taskbarHeight
            let desiredBottom = taskbarTop - taskbarWindowGap
            // Windows sized by older releases may still reserve the former 72-point bar.
            let previousTaskbarBottom = display.maxY - 72 - taskbarWindowGap
            let alignedWithPreviousTaskbar = abs(rect.maxY - previousTaskbarBottom) <= 2
            let visibleBottomInset = screen.visibleFrame.minY - screen.frame.minY
            let alignedWithDockInset = visibleBottomInset > taskbarHeight + taskbarWindowGap + 1 &&
                abs(rect.maxY - (display.maxY - visibleBottomInset)) <= 2
            guard abs(rect.minY - usableTop) <= 24,
                  (abs(rect.maxY - display.maxY) <= 24 || abs(rect.maxY - taskbarTop) <= 2 || alignedWithDockInset || alignedWithPreviousTaskbar),
                  rect.height >= display.height * 0.70,
                  (rect.maxY > desiredBottom + 1 || alignedWithDockInset || alignedWithPreviousTaskbar),
                  (attribute(record.element, "AXFullScreen" as CFString, as: Bool.self) ?? false) == false else { continue }
            var size = CGSize(width: rect.width, height: desiredBottom - rect.minY)
            guard size.height > 100, let value = AXValueCreate(.cgSize, &size) else { continue }
            AXUIElementSetAttributeValue(record.element, kAXSizeAttribute as CFString, value)
            clearanceAttempts.removeAll { CFEqual($0.element, record.element) }
            clearanceAttempts.append((record.element, rect, Date()))
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
        if bundle == "com.apple.finder" { newFinderWindow(on: screen); return }
        let previous = applicationWindows(bundle)
        if bundle == "com.apple.Terminal" {
            // With no target window, Terminal creates a new window. `cd` uses the
            // shell's home directory without touching existing Terminal sessions.
            let source = "tell application id \"com.apple.Terminal\"\ndo script \"cd\"\nend tell"
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error = error {
                let alert = NSAlert(); alert.messageText = "Couldn’t open a new Terminal window"
                alert.informativeText = "Allow Windows QoL to control Terminal in System Settings → Privacy & Security → Automation, then try again.\n\n\(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")"
                alert.runModal()
            }
            if error == nil { placeOpenedWindow(bundle: bundle, previous: previous, on: display, allowExisting: false, activateOpened: true) }
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { self?.placeOpenedWindow(bundle: bundle, previous: previous, on: display, allowExisting: true, activateOpened: true) }
        }
    }
    func locationMenu(bundle: String, display: CGDirectDisplayID) -> NSMenu {
        let menu = NSMenu()
        let name = bundle == "com.apple.finder" ? "Finder" : "Terminal"
        let locations: [(String, String?)] = [
            ("Open \(name)", nil),
            ("Open in Desktop", NSHomeDirectory() + "/Desktop"),
            ("Open in Downloads", NSHomeDirectory() + "/Downloads"),
            ("Open in Documents", NSHomeDirectory() + "/Documents"),
            ("Open in Home", NSHomeDirectory())
        ]
        for (title, path) in locations {
            let item = NSMenuItem(title: title, action: #selector(openUtilityLocation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["bundle": bundle, "display": NSNumber(value: display), "path": path ?? ""] as [String: Any]
            menu.addItem(item)
        }
        return menu
    }
    @objc func openUtilityLocation(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let bundle = info["bundle"] as? String, let display = (info["display"] as? NSNumber)?.uint32Value,
              let path = info["path"] as? String else { return }
        if path.isEmpty, bundle == "com.apple.finder", let screen = NSScreen.screens.first(where: { displayID($0) == display }) {
            newFinderWindow(on: screen); return
        }
        let previous = applicationWindows(bundle)
        let source: String
        if bundle == "com.apple.finder" {
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            source = "tell application id \"com.apple.finder\"\nmake new Finder window to (POSIX file \"\(escaped)\" as alias)\nend tell"
        } else {
            let command = path.isEmpty ? "cd" : "cd '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            source = "tell application id \"com.apple.Terminal\"\ndo script \"\(escaped)\"\nend tell"
        }
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            let alert = NSAlert(); alert.messageText = "Couldn’t open a new \(bundle == "com.apple.finder" ? "Finder" : "Terminal") window"
            alert.informativeText = "Check that Windows QoL can control the app in System Settings → Privacy & Security → Automation and that the folder exists.\n\n\(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")"
            alert.runModal(); return
        }
        placeOpenedWindow(bundle: bundle, previous: previous, on: display, allowExisting: false, activateOpened: true)
    }
    func appContextMenu(bundle: String, displayKey: String, isPrimary: Bool, display: CGDirectDisplayID) -> NSMenu {
        let menu = NSMenu()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: { !$0.isTerminated })
        if running && newWindowMenuItem(bundle: bundle) != nil {
            let newWindow = NSMenuItem(title: "New Window", action: #selector(openNewWindow(_:)), keyEquivalent: "")
            newWindow.target = self
            newWindow.representedObject = ["bundle": bundle, "display": NSNumber(value: display)] as [String: Any]
            menu.addItem(newWindow)
            menu.addItem(.separator())
        }
        let primaryItem = NSMenuItem(title: pinned.contains(bundle) ? "Unpin from primary taskbar" : "Pin to primary taskbar", action: #selector(togglePin(_:)), keyEquivalent: "")
        primaryItem.target = self; primaryItem.representedObject = ["bundle": bundle, "scope": "primary"]; menu.addItem(primaryItem)
        if !isPrimary {
            let isPinnedHere = (displayPins[displayKey] ?? []).contains(bundle)
            let localItem = NSMenuItem(title: isPinnedHere ? "Unpin from this taskbar" : "Pin to this taskbar", action: #selector(togglePin(_:)), keyEquivalent: "")
            localItem.target = self; localItem.representedObject = ["bundle": bundle, "scope": displayKey]; menu.addItem(localItem)
        }
        if running {
            menu.addItem(.separator())
            if !applicationWindows(bundle).isEmpty {
                let close = NSMenuItem(title: "Close All Windows", action: #selector(closeAllApplicationWindows(_:)), keyEquivalent: "")
                close.target = self; close.representedObject = bundle; menu.addItem(close)
            }
            let quit = NSMenuItem(title: "Quit App", action: #selector(quitApplication(_:)), keyEquivalent: "")
            quit.target = self; quit.representedObject = bundle; menu.addItem(quit)
        }
        return menu
    }
    func newWindowMenuItem(bundle: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first(where: { !$0.isTerminated }) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar: AXUIElement = attribute(root, kAXMenuBarAttribute as CFString) else { return nil }
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth <= 5 else { return nil }
            let role: String = attribute(element, kAXRoleAttribute as CFString) ?? ""
            let title: String = attribute(element, kAXTitleAttribute as CFString) ?? ""
            let enabled: Bool = attribute(element, kAXEnabledAttribute as CFString) ?? false
            if role == kAXMenuItemRole as String && enabled &&
                (title == "New Window" || title == "New Finder Window") {
                var actions: CFArray?
                if AXUIElementCopyActionNames(element, &actions) == .success,
                   let names = actions as? [String], names.contains(kAXPressAction as String) { return element }
            }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute as CFString) ?? []
            for child in children { if let found = find(child, depth: depth + 1) { return found } }
            return nil
        }
        return find(menuBar, depth: 0)
    }
    @objc func openNewWindow(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? [String: Any],
              let bundle = context["bundle"] as? String,
              let display = (context["display"] as? NSNumber)?.uint32Value,
              let item = newWindowMenuItem(bundle: bundle) else { return }
        let previous = applicationWindows(bundle)
        if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            placeOpenedWindow(bundle: bundle, previous: previous, on: display, allowExisting: false)
        }
    }
    @objc func quitApplication(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) where !app.isTerminated {
            app.terminate()
        }
    }
    @objc func closeAllApplicationWindows(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        for window in applicationWindows(bundle) {
            let subrole: String = attribute(window, kAXSubroleAttribute as CFString) ?? ""
            guard subrole == kAXStandardWindowSubrole as String,
                  let close: AXUIElement = attribute(window, kAXCloseButtonAttribute as CFString) else { continue }
            AXUIElementPerformAction(close, kAXPressAction as CFString)
        }
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
    func placeOpenedWindow(bundle: String, previous: [AXUIElement], on display: CGDirectDisplayID, allowExisting: Bool, activateOpened: Bool = false) {
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
                if activateOpened {
                    self.records = windows(previous: self.records)
                    if let record = self.records.first(where: { CFEqual($0.element, target) }) {
                        self.focus(record, preserveRemoteMinimized: true)
                    } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                        app.activate(options: [])
                        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
                    }
                }
                timer.invalidate()
            } else if attempts >= 100 { timer.invalidate() }
        }
    }
    func newFinderWindow(on screen: NSScreen, activate: Bool = true) {
        guard let display = displayID(screen) else { return }
        let previous = applicationWindows("com.apple.finder")
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\"\nmake new Finder window\nend tell")?.executeAndReturnError(&error)
        if let error = error {
            let alert = NSAlert(); alert.messageText = "Couldn’t open a Finder window"
            alert.informativeText = "Allow Windows QoL to control Finder in System Settings → Privacy & Security → Automation.\n\n\(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")"
            alert.runModal(); return
        }
        placeOpenedWindow(bundle: "com.apple.finder", previous: previous, on: display, allowExisting: false, activateOpened: activate)
    }
    @objc func openTrash(_ sender: NSButton) {
        guard let screen = sender.window?.screen, let display = displayID(screen) else { return }
        let previous = applicationWindows("com.apple.finder")
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true))
        placeOpenedWindow(bundle: "com.apple.finder", previous: previous, on: display, allowExisting: true, activateOpened: true)
    }
    @objc func toggleDockAutoHide() {
        startupDockRequest?.cancel()
        startupDockRequest = nil
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
        closeHover()
        let pending = DispatchWorkItem { [weak self, weak button] in
            guard let self = self, let button = button, let window = button.window,
                  let bundle = button.identifier?.rawValue, let screen = window.screen,
                  let id = displayID(screen) else { return }
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            guard rect.contains(NSEvent.mouseLocation) else { return }
            let matches = self.records.filter { $0.displayID == id && $0.app.bundleIdentifier == bundle }
            if !matches.isEmpty { self.showWindows(matches, anchoredTo: button) }
        }
        hoverPending = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: pending)
    }
    func scheduleUtilityTooltip(_ button: HoverButton, title: String) {
        closeHover()
        let pending = DispatchWorkItem { [weak self, weak button] in
            guard let self = self, let button = button, let window = button.window, let screen = window.screen else { return }
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            guard rect.contains(NSEvent.mouseLocation) else { return }
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12); label.textColor = .white
            label.sizeToFit()
            let width = label.frame.width + 20, height: CGFloat = 28
            let x = min(max(screen.visibleFrame.minX + 8, rect.midX - width / 2), screen.visibleFrame.maxX - width - 8)
            let panel = NSPanel(contentRect: NSRect(x: x, y: window.frame.maxY + 4, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.98)
            panel.level = .floating; panel.hasShadow = true; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            label.frame.origin = NSPoint(x: 10, y: (height - label.frame.height) / 2)
            panel.contentView?.addSubview(label)
            self.hoverPanel = panel; panel.orderFrontRegardless()
            self.hoverMonitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                if !rect.contains(NSEvent.mouseLocation) { self?.closeHover() }
            }
        }
        hoverPending = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: pending)
    }
    func closeHover() {
        hoverPending?.cancel(); hoverPending = nil
        hoverMonitor?.invalidate(); hoverMonitor = nil
        pendingPreviewCloses.removeAll(); previewAnimating = false
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
        scroll.autoresizingMask = [.width, .height]
        scroll.hasHorizontalScroller = contentWidth > width
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let list = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: height))
        var cards: [WindowButton] = []
        for (index, record) in matches.enumerated() {
            let row = WindowButton(frame: NSRect(x: padding + CGFloat(index) * (cardWidth + gap), y: padding, width: cardWidth, height: cardHeight))
            row.cell = PreviewButtonCell()
            let appName = record.app.localizedName ?? "Window"
            let windowTitle = record.title.isEmpty || record.title == appName ? appName : "\(appName) — \(record.title)"
            row.title = (record.minimized ? "◌  " : "") + windowTitle
            row.record = record; row.target = self; row.action = #selector(windowSelected(_:))
            row.bezelStyle = .regularSquare; row.isBordered = false; row.alignment = .center
            row.contentTintColor = .white; row.font = .systemFont(ofSize: 13)
            row.lineBreakMode = .byTruncatingTail; row.imagePosition = .imageAbove
            row.imageScaling = .scaleProportionallyDown; row.image = record.app.icon
            row.wantsLayer = true; row.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            row.layer?.cornerRadius = 8; row.toolTip = row.title
            let close = WindowButton(frame: NSRect(x: cardWidth - 30, y: 6, width: 24, height: 24))
            close.record = record; close.target = self; close.action = #selector(closePreviewWindow(_:))
            close.title = "×"; close.font = .systemFont(ofSize: 19, weight: .medium)
            close.isBordered = false; close.contentTintColor = .white
            close.wantsLayer = true; close.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
            close.layer?.cornerRadius = 12; close.toolTip = "Close window"
            close.setAccessibilityLabel("Close \(row.title)")
            close.isEnabled = (attribute(record.element, kAXCloseButtonAttribute as CFString) as AXUIElement?) != nil
            row.addSubview(close)
            list.addSubview(row)
            cards.append(row)
        }
        scroll.documentView = list; panel.contentView = scroll
        hoverPanel = panel; panel.orderFrontRegardless()
        hoverLastInside = Date()
        loadWindowPreviews(matches, cards: cards, panel: panel)
        hoverMonitor = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, let panel = self.hoverPanel else { return }
            self.checkPreviewCloses(in: panel)
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
    @objc func closePreviewWindow(_ sender: WindowButton) {
        guard let record = sender.record else { return }
        let button: AXUIElement? = attribute(record.element, kAXCloseButtonAttribute as CFString)
        guard let button = button, AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t close the window"
            alert.informativeText = "The app did not accept the close request."
            alert.runModal()
            return
        }
        sender.isEnabled = false
        pendingPreviewCloses.append((record, Date()))
    }
    func checkPreviewCloses(in panel: NSPanel) {
        guard !previewAnimating, let scroll = panel.contentView as? NSScrollView,
              let list = scroll.documentView else { return }
        for (record, requested) in pendingPreviewCloses {
            let root = AXUIElementCreateApplication(record.app.processIdentifier)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
            if result == .success, let open = value as? [AXUIElement],
               !open.contains(where: { CFEqual($0, record.element) }) {
                pendingPreviewCloses.removeAll { CFEqual($0.0.element, record.element) }
                guard let card = list.subviews.compactMap({ $0 as? WindowButton }).first(where: {
                    $0.record.map { CFEqual($0.element, record.element) } ?? false
                }) else { return }
                previewAnimating = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    card.animator().alphaValue = 0
                } completionHandler: { [weak self, weak panel] in
                    guard let self = self, let panel = panel, self.hoverPanel === panel else { return }
                    card.removeFromSuperview()
                    let remaining = list.subviews.compactMap { $0 as? WindowButton }.sorted { $0.frame.minX < $1.frame.minX }
                    guard !remaining.isEmpty else { self.closeHover(); return }
                    let contentWidth = CGFloat(remaining.count) * 184 - 8 + 24
                    let width = min(contentWidth, max(1, (panel.screen?.visibleFrame.width ?? contentWidth) - 24))
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.18
                        for (index, item) in remaining.enumerated() {
                            item.animator().setFrameOrigin(NSPoint(x: 12 + CGFloat(index) * 184, y: item.frame.minY))
                        }
                        var frame = panel.frame; frame.size.width = width
                        panel.animator().setFrame(frame, display: true)
                    } completionHandler: {
                        guard self.hoverPanel === panel else { return }
                        list.setFrameSize(NSSize(width: contentWidth, height: list.frame.height))
                        scroll.hasHorizontalScroller = contentWidth > width
                        self.previewAnimating = false
                    }
                }
                return
            }
            if Date().timeIntervalSince(requested) > 10 {
                pendingPreviewCloses.removeAll { CFEqual($0.0.element, record.element) }
                if let card = list.subviews.compactMap({ $0 as? WindowButton }).first(where: {
                    $0.record.map { CFEqual($0.element, record.element) } ?? false
                }) { (card.subviews.first as? NSButton)?.isEnabled = true }
            }
        }
    }
    func isActive(_ record: WindowRecord) -> Bool {
        guard !record.minimized, NSWorkspace.shared.frontmostApplication?.processIdentifier == record.app.processIdentifier else { return false }
        let root = AXUIElementCreateApplication(record.app.processIdentifier)
        guard let focused: AXUIElement = attribute(root, kAXFocusedWindowAttribute as CFString) else { return false }
        return CFEqual(focused, record.element)
    }
    func toggle(_ record: WindowRecord) {
        let frontmost = frontmostWindowsByDisplay(records)[record.displayID]
        if !record.minimized && (frontmost.map { CFEqual($0, record.element) } ?? isActive(record)) {
            let result = AXUIElementSetAttributeValue(record.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            if result != .success { focus(record, preserveRemoteMinimized: true) }
        } else { focus(record, preserveRemoteMinimized: true) }
    }
    func focus(_ record: WindowRecord, preserveRemoteMinimized: Bool = false) {
        // Activating an app can raise all of its windows. Preserve the frontmost
        // windows on other displays without activating their applications.
        let remoteFrontmost = preserveRemoteMinimized ? frontmostWindowsByDisplay(records).filter { display, window in
            guard display != record.displayID,
                  let owner = records.first(where: { CFEqual($0.element, window) }) else { return false }
            return owner.app.processIdentifier != record.app.processIdentifier
        } : [:]
        let remoteMinimized = preserveRemoteMinimized ? records.filter {
            $0.app.processIdentifier == record.app.processIdentifier && $0.displayID != record.displayID && $0.minimized
        }.map { $0.element } : []
        if record.minimized { AXUIElementSetAttributeValue(record.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        record.app.activate(options: [])
        AXUIElementPerformAction(record.element, kAXRaiseAction as CFString)
        func restoreRemoteFrontmost() {
            let currentRecords = windows(previous: self.records)
            let currentFrontmost = frontmostWindowsByDisplay(currentRecords)
            for (display, previous) in remoteFrontmost {
                guard let current = currentFrontmost[display], !CFEqual(current, previous),
                      let owner = currentRecords.first(where: { CFEqual($0.element, current) }),
                      owner.app.processIdentifier == record.app.processIdentifier,
                      currentRecords.contains(where: { CFEqual($0.element, previous) && !$0.minimized }) else { continue }
                AXUIElementPerformAction(previous, kAXRaiseAction as CFString)
            }
        }
        if !remoteFrontmost.isEmpty {
            restoreRemoteFrontmost()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { restoreRemoteFrontmost() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { restoreRemoteFrontmost() }
        }
        if !remoteMinimized.isEmpty {
            func restoreMinimizedState() {
                for window in remoteMinimized {
                    let minimized: Bool = attribute(window, kAXMinimizedAttribute as CFString) ?? true
                    if !minimized { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
                }
            }
            restoreMinimizedState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { restoreMinimizedState() }
        }
    }
}
final class PreviewButtonCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 24)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 7, y: rect.maxY - 22, width: rect.width - 14, height: 18)
    }
}

final class WindowButton: NSButton { var record: WindowRecord? }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
