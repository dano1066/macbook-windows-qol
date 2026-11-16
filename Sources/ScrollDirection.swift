import AppKit
import ApplicationServices

enum ScrollDirection: String, CaseIterable {
    case system, natural, traditional

    var title: String {
        switch self {
        case .system: return "Follow macOS"
        case .natural: return "Natural"
        case .traditional: return "Traditional"
        }
    }

    func reverses(systemIsNatural: Bool) -> Bool {
        self != .system && ((self == .natural) != systemIsNatural)
    }
}

final class ScrollDirectionOverride {
    static let mouseKey = "mouseScrollDirection"
    static let trackpadKey = "trackpadScrollDirection"

    private let defaults: UserDefaults
    private(set) var mouse: ScrollDirection
    private(set) var trackpad: ScrollDirection
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var attemptedStart = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mouse = defaults.string(forKey: Self.mouseKey).flatMap(ScrollDirection.init(rawValue:)) ?? .system
        trackpad = defaults.string(forKey: Self.trackpadKey).flatMap(ScrollDirection.init(rawValue:)) ?? .system
    }

    var hasOverride: Bool { mouse != .system || trackpad != .system }
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func set(_ direction: ScrollDirection, trackpad isTrackpad: Bool) {
        if isTrackpad { trackpad = direction } else { mouse = direction }
        defaults.set(direction.rawValue, forKey: isTrackpad ? Self.trackpadKey : Self.mouseKey)
        attemptedStart = false
    }

    func update(trusted: Bool) {
        guard trusted, hasOverride else { stop(); return }
        guard tap == nil, !attemptedStart else { return }
        attemptedStart = true
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: { _, type, event, context in
            if let context = context {
                Unmanaged<ScrollDirectionOverride>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return
        }
        tap = port
        source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
    }

    func stop() {
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        attemptedStart = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .scrollWheel else { return }
        // Quartz reports line vs. pixel scrolling, not physical device identity.
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let direction = continuous ? trackpad : mouse
        guard direction != .system, let appEvent = NSEvent(cgEvent: event),
              direction.reverses(systemIsNatural: appEvent.isDirectionInvertedFromDevice) else { return }
        Self.reverseVerticalDelta(event)
    }

    static func reverseVerticalDelta(_ event: CGEvent) {
        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let points = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        guard lines != 0 || points != 0 || fixed != 0 else { return }
        // Setting the line delta recalculates the other representations. Restore
        // their original magnitudes so reversing does not change scroll speed.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lines)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -points)
    }
}
