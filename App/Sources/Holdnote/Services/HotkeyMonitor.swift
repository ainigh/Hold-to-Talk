import AppKit
import CoreGraphics
import Foundation
import Harness

/// Sees the hotkey go down and up anywhere on the Mac, through a listen-only event tap on the
/// session (needs Input Monitoring, which the setup window asks for). Fn and the right Option
/// key arrive as `flagsChanged` events; ⌃⌥Space as a key down and up. The tap also carries
/// ⌘⇧H, which shows or hides the window from any app.
///
/// Everything here runs on the main thread: the tap's run loop source is on the main run loop.
@MainActor
final class HotkeyMonitor {
    enum Event {
        case pressed(modifiers: CGEventFlags)
        case released
        case toggleWindow
    }

    var hotkey: Settings.Hotkey = .fn
    var onEvent: ((Event) -> Void)?
    /// Pause hotkey (the menu): events are seen but not acted on.
    var paused = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var down = false

    /// Whether the tap is running. False until Input Monitoring is allowed.
    private(set) var isRunning = false

    static let fnKeyCode: Int64 = 63
    static let rightOptionKeyCode: Int64 = 61
    static let spaceKeyCode: Int64 = 49
    static let hKeyCode: Int64 = 4

    /// Input Monitoring: already allowed?
    static var isAllowed: Bool { CGPreflightListenEventAccess() }

    /// Asks macOS for Input Monitoring (shows the system prompt the first time; later the user
    /// turns it on in System Settings, which the setup window opens).
    @discardableResult
    static func request() -> Bool { CGRequestListenEventAccess() }

    /// Starts the tap. False when Input Monitoring isn't allowed yet (try again after it is).
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: HotkeyMonitor.callback, userInfo: refcon) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRunning = false
        down = false
    }

    /// The hotkey was released as far as the app is concerned (the recording stopped another way).
    func forgetPress() { down = false }

    /// A C callback: no captures, the monitor comes through `refcon`.
    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
        return Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; this one does nothing slow, so turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        default:
            break
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        // ⌘⇧H from anywhere: show or hide the window.
        if type == .keyDown, keyCode == Self.hKeyCode, flags.contains(.maskCommand), flags.contains(.maskShift),
           !flags.contains(.maskControl), !flags.contains(.maskAlternate), event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            onEvent?(.toggleWindow)
            return
        }
        guard !paused else { return }
        switch hotkey {
        case .fn:
            guard type == .flagsChanged, keyCode == Self.fnKeyCode else { return }
            set(down: flags.contains(.maskSecondaryFn), flags: flags)
        case .rightOption:
            guard type == .flagsChanged, keyCode == Self.rightOptionKeyCode else { return }
            set(down: flags.contains(.maskAlternate), flags: flags)
        case .controlOptionSpace:
            guard keyCode == Self.spaceKeyCode else { return }
            if type == .keyDown {
                guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
                if flags.contains(.maskControl), flags.contains(.maskAlternate) { set(down: true, flags: flags) }
            } else if type == .keyUp {
                set(down: false, flags: flags)
            }
        }
    }

    private func set(down newDown: Bool, flags: CGEventFlags) {
        guard newDown != down else { return }
        down = newDown
        onEvent?(newDown ? .pressed(modifiers: flags) : .released)
    }
}
