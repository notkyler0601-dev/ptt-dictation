import AppKit
import IOKit.hid

/// System-wide listener for the push-to-talk key (right Option), built on a
/// CGEventTap.
///
/// Right Option is ideal (same reasoning as the prototype): it never collides
/// with app shortcuts, and modifier keys don't auto-repeat — the tap only sees
/// `flagsChanged` transitions, so we get exactly one press and one release
/// per hold.
final class HotkeyManager {
    /// Called on the main thread when the hotkey goes down / comes up.
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    private var tap: CFMachPort?
    private var hotkeyDown = false

    /// Right Option's virtual keycode (kVK_RightOption).
    private static let rightOptionKeycode: Int64 = 61

    /// `.maskAlternate` is set for *either* Option key, so it can't tell us
    /// which side changed (hold left, release right → mask still set, and
    /// we'd think the hotkey is still down). The raw flags word has
    /// device-specific bits; 0x40 is NX_DEVICERALTKEYMASK (IOLLEvent.h),
    /// set only while the *right* Option is physically down — same key
    /// identity the prototype got from pynput's `alt_r`.
    private static let rightOptionDeviceBit: UInt64 = 0x40

    /// Listen-only event taps are gated by the Input Monitoring TCC
    /// permission. Creating a tap without it just returns nil, so check
    /// first and let macOS show its prompt if needed.
    var hasPermission: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Returns true if the tap is live. Safe to call repeatedly (no-op once
    /// running) — used by the menu's Retry button after granting permission.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        if !hasPermission {
            // Triggers the system prompt and adds us to the Input Monitoring
            // list in System Settings. Returns immediately; the user grants
            // asynchronously and then hits Retry (or relaunches).
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        // C function pointers can't capture Swift context, so `self` rides
        // along through the opaque userInfo pointer instead.
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,  // we observe; we never modify or swallow keys
            eventsOfInterest: 1 << CGEventType.flagsChanged.rawValue,
            callback: { _, type, event, refcon in
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
                manager.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps it deems unresponsive (or after secure-input
        // sessions); these pseudo-events are our cue to switch it back on,
        // otherwise the hotkey silently dies until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOptionKeycode
        else { return }

        let down = event.flags.rawValue & Self.rightOptionDeviceBit != 0
        guard down != hotkeyDown else { return }
        hotkeyDown = down

        // Gotcha 3: return from the tap callback in microseconds. Even
        // though our handlers are cheap today, dispatching keeps the
        // contract honest when later stages hang real work off these.
        let callback = down ? onPress : onRelease
        DispatchQueue.main.async { callback() }
    }
}
