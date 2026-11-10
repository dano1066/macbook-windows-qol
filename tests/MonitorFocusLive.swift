// Compiled after the production declarations, replacing the normal app entry point.
// --taskbar-minimize also minimizes and restores the target Firefox window.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let reportURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("monitor-focus-live.json")
var report: [String: Any] = [:]
var cover: NSWindow?
var localCover: NSWindow?
var minimizedTarget: WindowRecord?
let checkMinimize = CommandLine.arguments.contains("--taskbar-minimize")
let checkCoveredFocus = CommandLine.arguments.contains("--taskbar-focus")
let coverKeyWindow = CommandLine.arguments.contains("--covered-key-window")
let originalApp = NSWorkspace.shared.frontmostApplication
let originalRoot = originalApp.map { AXUIElementCreateApplication($0.processIdentifier) }
let originalWindow: AXUIElement? = originalRoot.flatMap { attribute($0, kAXFocusedWindowAttribute as CFString) }

func snapshot() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}
func quartzID(_ record: WindowRecord) -> CGWindowID? {
    guard let frame = windowRect(record.element) else { return nil }
    let matches = snapshot().filter {
        guard ($0[kCGWindowOwnerPID as String] as? Int) == Int(record.app.processIdentifier),
              ($0[kCGWindowLayer as String] as? Int) == 0,
              let raw = $0[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
        return abs(frame.minX - rect.minX) + abs(frame.minY - rect.minY) + abs(frame.width - rect.width) + abs(frame.height - rect.height) < 12
    }
    guard matches.count == 1 else { return nil }
    return (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value
}
func finish(_ error: String? = nil) {
    if let error { report["error"] = error }
    if let target = minimizedTarget {
        AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        if let id = quartzID(target) {
            report["restoreTargetStatus"] = WindowsQoLActivateWindowOnly(target.app.processIdentifier, target.element, id)
        }
    }
    localCover?.close(); localCover = nil
    cover?.close(); cover = nil
    if let originalApp, let originalWindow,
       let record = windows(previous: []).first(where: { CFEqual($0.element, originalWindow) }),
       let id = quartzID(record) {
        report["restoreStatus"] = WindowsQoLActivateWindowOnly(originalApp.processIdentifier, originalWindow, id)
    }
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: reportURL)
    }
    app.terminate(nil)
}
func topAt(_ point: CGPoint) -> CGWindowID? {
    for info in snapshot() {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let raw = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.contains(point) else { continue }
        return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }
    return nil
}
func runLiveCheck() {
    report["accessibility"] = AXIsProcessTrusted()
    guard AXIsProcessTrusted() else { finish("Live probe lacks Accessibility; no windows changed."); return }
    let firefox = windows(previous: []).filter { $0.app.bundleIdentifier == "org.mozilla.firefox" && !$0.minimized }
    report["firefoxWindowCount"] = firefox.count
    let requestedID = CommandLine.arguments.last.flatMap(UInt32.init)
    guard let target = (requestedID.flatMap { wanted in firefox.first { quartzID($0) == wanted } } ?? firefox.first),
          let remote = firefox.first(where: { $0.displayID != target.displayID }),
          let targetID = quartzID(target), let remoteID = quartzID(remote),
          let targetFrame = target.frame, let remoteFrame = remote.frame,
          let screen = NSScreen.screens.first(where: { displayID($0) == remote.displayID }) else {
        finish("Need two visible Firefox windows on separate displays."); return
    }
    report["targetWindow"] = targetID
    report["remoteWindow"] = remoteID
    report["targetDisplay"] = target.displayID
    report["remoteDisplay"] = remote.displayID
    // Arrange a reproducible baseline, then cover the other Firefox window.
    AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
    let window = NSWindow(contentRect: screen.visibleFrame.insetBy(dx: 8, dy: 8), styleMask: [.titled], backing: .buffered, defer: false)
    window.setFrame(screen.visibleFrame.insetBy(dx: 8, dy: 8), display: true)
    window.title = "Windows QoL focus regression — temporary cover"
    window.isReleasedWhenClosed = false
    cover = window
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    if checkMinimize || checkCoveredFocus {
        // Establish the clicked window as key without the cover application's
        // activation or an AXRaise changing the target-display baseline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            report["setupTargetStatus"] = WindowsQoLActivateWindowOnly(target.app.processIdentifier, target.element, targetID)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        let remotePoint = CGPoint(x: remoteFrame.midX, y: remoteFrame.midY)
        let targetPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        report["coverWindow"] = window.windowNumber
        report["baselineRemoteTop"] = topAt(remotePoint) ?? 0
        report["baselineTargetTop"] = topAt(targetPoint) ?? 0
        report["coverFrame"] = NSStringFromRect(window.frame)
        report["targetFrame"] = NSStringFromRect(targetFrame)
        report["remoteFrame"] = NSStringFromRect(remoteFrame)
        guard topAt(remotePoint) == CGWindowID(window.windowNumber), topAt(targetPoint) == targetID else {
            finish("Could not establish a visible target and covered remote window."); return
        }
        report["remoteTopBefore"] = window.windowNumber
        let controller = AppDelegate()
        controller.focusOnMonitorEntry(target, windowID: targetID)
        if checkCoveredFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let targetScreen = NSScreen.screens.first(where: { displayID($0) == target.displayID }) else {
                    finish("Target display disappeared."); return
                }
                let local = NSWindow(contentRect: targetScreen.visibleFrame.insetBy(dx: 8, dy: 8), styleMask: [.titled], backing: .buffered, defer: false)
                local.title = "Windows QoL focus regression — local cover"
                local.isReleasedWhenClosed = false
                localCover = local
                local.orderFrontRegardless()
                if !coverKeyWindow { app.activate(ignoringOtherApps: true) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    report["targetAlreadyKeyBeforeClick"] = controller.isActive(target)
                    report["localCoverWindow"] = local.windowNumber
                    report["coveredTargetTopBefore"] = topAt(targetPoint) ?? 0
                    guard topAt(targetPoint) == CGWindowID(local.windowNumber),
                          topAt(remotePoint) == CGWindowID(window.windowNumber),
                          controller.isActive(target) == coverKeyWindow else {
                        finish("Could not establish the covered-window baseline."); return
                    }
                    controller.records = windows(previous: [])
                    controller.toggle(target)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        let minimized: Bool = attribute(target.element, kAXMinimizedAttribute as CFString) ?? true
                        let remoteMinimized: Bool = attribute(remote.element, kAXMinimizedAttribute as CFString) ?? true
                        let raised = topAt(targetPoint) == targetID
                        let covered = topAt(remotePoint) == CGWindowID(window.windowNumber)
                        let unchangedFrames = windowRect(target.element) == targetFrame && windowRect(remote.element) == remoteFrame
                        report["targetRaised"] = raised
                        report["targetFocused"] = controller.isActive(target)
                        report["targetRemainsUnminimized"] = !minimized
                        report["remoteRemainsCovered"] = covered
                        report["remoteRemainsUnminimized"] = !remoteMinimized
                        report["framesUnchanged"] = unchangedFrames
                        report["passed"] = raised && controller.isActive(target) && !minimized && covered && !remoteMinimized && unchangedFrames
                        finish()
                    }
                }
            }
            return
        }
        if checkMinimize {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard controller.isActive(target), topAt(remotePoint) == CGWindowID(window.windowNumber) else {
                    finish("Could not focus target without uncovering remote Firefox."); return
                }
                minimizedTarget = target
                controller.records = windows(previous: [])
                controller.toggle(target)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let minimized: Bool = attribute(target.element, kAXMinimizedAttribute as CFString) ?? false
                    let remoteMinimized: Bool = attribute(remote.element, kAXMinimizedAttribute as CFString) ?? true
                    let covered = topAt(remotePoint) == CGWindowID(window.windowNumber)
                    report["targetMinimized"] = minimized
                    report["remoteRemainsCovered"] = covered
                    report["remoteRemainsUnminimized"] = !remoteMinimized
                    report["passed"] = minimized && covered && !remoteMinimized
                    // Exercise the taskbar restore path as well.
                    controller.records = windows(previous: controller.records)
                    guard let restored = controller.records.first(where: { CFEqual($0.element, target.element) }) else {
                        finish("Lost target after minimizing."); return
                    }
                    report["taskbarRestoreStatus"] = controller.focus(restored)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let restoredMinimized: Bool = attribute(target.element, kAXMinimizedAttribute as CFString) ?? true
                        let restoredCovered = topAt(remotePoint) == CGWindowID(window.windowNumber)
                        let restoredRaised = topAt(targetPoint) == targetID
                        let unchangedFrames = windowRect(target.element) == targetFrame && windowRect(remote.element) == remoteFrame
                        report["restoredTargetFocused"] = controller.isActive(target)
                        report["remoteCoveredAfterRestore"] = restoredCovered
                        report["restoredTargetRaised"] = restoredRaised
                        report["framesUnchanged"] = unchangedFrames
                        report["passed"] = (report["passed"] as? Bool == true) && !restoredMinimized && restoredCovered && restoredRaised && controller.isActive(target) && unchangedFrames
                        finish()
                    }
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let root = AXUIElementCreateApplication(target.app.processIdentifier)
            let focused: AXUIElement? = attribute(root, kAXFocusedWindowAttribute as CFString)
            let focusedCorrectly = focused.map { CFEqual($0, target.element) } ?? false
            let remoteTop = topAt(remotePoint) ?? 0
            let unchangedFrames = windowRect(target.element) == targetFrame && windowRect(remote.element) == remoteFrame
            let remoteMinimized: Bool = attribute(remote.element, kAXMinimizedAttribute as CFString) ?? true
            let frontCorrectly = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier
            report["remoteTopAfter"] = remoteTop
            report["focusedTarget"] = focusedCorrectly
            report["frontmostTargetApp"] = frontCorrectly
            report["framesUnchanged"] = unchangedFrames
            report["remoteRemainsCovered"] = remoteTop == CGWindowID(window.windowNumber)
            report["remoteRemainsUnminimized"] = !remoteMinimized
            report["passed"] = focusedCorrectly && frontCorrectly && unchangedFrames && !remoteMinimized && remoteTop == CGWindowID(window.windowNumber)
            finish()
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: runLiveCheck)
app.run()
