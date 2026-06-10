import AppKit
import IOKit.hid

/// The push-to-talk key options offered in Settings. All modifier-style
/// keys on purpose: they never collide with app shortcuts, and modifiers
/// don't auto-repeat — the tap only sees `flagsChanged` transitions, so we
/// get exactly one press and one release per hold (prototype rationale).
enum HotkeyChoice: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case rightControl
    case function

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .rightControl: "Right Control (⌃)"
        case .function: "Globe / Fn"
        }
    }

    /// Virtual keycode seen in the flagsChanged event.
    var keycode: Int64 {
        switch self {
        case .rightOption: 61   // kVK_RightOption
        case .rightCommand: 54  // kVK_RightCommand
        case .rightControl: 62  // kVK_RightControl
        case .function: 63      // kVK_Function
        }
    }

    /// Whether this key is physically down, from the event's flags.
    ///
    /// The public masks (.maskAlternate etc.) are set for *either* side of
    /// a modifier pair, so they can't tell us which side changed (hold left
    /// Option, release right → mask still set, and we'd think the hotkey is
    /// still down). The raw flags word has device-specific side bits from
    /// IOLLEvent.h — the same key identity the prototype got from pynput's
    /// `alt_r`. Fn has no sides, so the public mask is fine there.
    func isDown(_ flags: CGEventFlags) -> Bool {
        switch self {
        case .rightOption: flags.rawValue & 0x40 != 0    // NX_DEVICERALTKEYMASK
        case .rightCommand: flags.rawValue & 0x10 != 0   // NX_DEVICERCMDKEYMASK
        case .rightControl: flags.rawValue & 0x2000 != 0 // NX_DEVICERCTLKEYMASK
        case .function: flags.contains(.maskSecondaryFn)
        }
    }
}

/// System-wide listener for the push-to-talk key, built on a CGEventTap.
final class HotkeyManager {
    /// Called on the main thread when the hotkey goes down / comes up.
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    /// Settable live from Settings; the tap itself doesn't change (it
    /// always watches flagsChanged), only the matching logic does.
    var hotkey: HotkeyChoice = .rightOption

    private var tap: CFMachPort?
    private var hotkeyDown = false

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
              event.getIntegerValueField(.keyboardEventKeycode) == hotkey.keycode
        else { return }

        let down = hotkey.isDown(event.flags)
        guard down != hotkeyDown else { return }
        hotkeyDown = down

        // Gotcha 3: return from the tap callback in microseconds. Even
        // though our handlers are cheap today, dispatching keeps the
        // contract honest when later stages hang real work off these.
        let callback = down ? onPress : onRelease
        DispatchQueue.main.async { callback() }
    }
}
