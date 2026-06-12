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

    /// The side-agnostic mask for this key's modifier pair, for the stuck-key
    /// watchdog. It polls `CGEventSource.flagsState` rather than reading an
    /// event, and the device side bits aren't guaranteed to survive in that
    /// aggregated state — but if the *pair* mask is clear, neither side is
    /// held, so our key is definitely up. (Holding the opposite side merely
    /// delays the watchdog, it can't confuse it.)
    var pairMask: CGEventFlags {
        switch self {
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        case .function: .maskSecondaryFn
        }
    }
}

/// System-wide listener for the push-to-talk key (and the optional rewrite
/// key), built on a CGEventTap.
///
/// Reliability matters more than it looks: macOS *disables* taps it deems
/// slow to respond (and during secure-input sessions), and events that occur
/// while a tap is disabled are dropped, not queued. A dropped *release*
/// leaves the app convinced the key is still held — recording runs forever
/// and the dictation never finishes. Two defenses:
///   1. The tap lives on its own thread, so a busy main thread can never
///      delay servicing past the unresponsiveness timeout.
///   2. While a key is believed down, a watchdog polls the real modifier
///      state and synthesizes the release if the key is physically up —
///      bounding any missed-event damage to a fraction of a second.
final class HotkeyManager {
    /// Called on the main thread when the hotkey goes down / comes up.
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Rewrite-mode key callbacks (hold, speak an instruction, release).
    var onRewritePress: () -> Void = {}
    var onRewriteRelease: () -> Void = {}

    /// Settable live from Settings; the tap itself doesn't change (it
    /// always watches flagsChanged), only the matching logic does.
    var hotkey: HotkeyChoice = .rightOption
    /// nil disables rewrite. If set equal to `hotkey`, the main key wins
    /// (it's matched first) and rewrite simply never fires.
    var rewriteHotkey: HotkeyChoice?

    private var tap: CFMachPort?
    private var tapThread: Thread?
    /// Down/up bookkeeping lives on the main thread only — the tap callback
    /// forwards raw (keycode, flags) here, so the watchdog and real events
    /// can never race over it.
    private var hotkeyDown = false
    private var rewriteDown = false
    private var watchdog: Timer?

    /// How often the watchdog re-checks while a key is believed down. Short
    /// enough that a stuck recording ends almost as crisply as a real
    /// release; long enough to cost nothing.
    private static let watchdogInterval: TimeInterval = 0.25

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

        // Service the tap on a dedicated thread. On the main run loop, any
        // stall (SwiftUI churn while transcribing, the menu being open)
        // delays tap servicing, and past ~1 s macOS flags the tap
        // unresponsive and disables it — dropping whatever key transitions
        // happen next. A thread that does nothing else can't fall behind.
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()  // parks here for the life of the app
        }
        thread.name = "HotkeyManager tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
        return true
    }

    /// Runs on the tap thread: decide fast, dispatch, return (Gotcha 3).
    /// All state lives on the main thread, so this only extracts the raw
    /// facts from the event and forwards them.
    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps it deems unresponsive (or after secure-input
        // sessions); these pseudo-events are our cue to switch it back on,
        // otherwise the hotkey silently dies until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard type == .flagsChanged else { return }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        DispatchQueue.main.async { self.match(keycode: keycode, flags: flags) }
    }

    /// Main thread: map a flags transition onto our two keys.
    private func match(keycode: Int64, flags: CGEventFlags) {
        if keycode == hotkey.keycode {
            update(down: hotkey.isDown(flags), isRewrite: false)
        } else if let rewrite = rewriteHotkey, keycode == rewrite.keycode {
            update(down: rewrite.isDown(flags), isRewrite: true)
        }
    }

    /// Main thread: deduplicate (a synthesized release followed by the real
    /// one must fire the callback once) and notify.
    private func update(down: Bool, isRewrite: Bool) {
        if isRewrite {
            guard down != rewriteDown else { return }
            rewriteDown = down
            (down ? onRewritePress : onRewriteRelease)()
        } else {
            guard down != hotkeyDown else { return }
            hotkeyDown = down
            (down ? onPress : onRelease)()
        }

        // Watchdog runs exactly while some key is believed down.
        let anyDown = hotkeyDown || rewriteDown
        if anyDown, watchdog == nil {
            let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
                self?.checkStuckKeys()
            }
            // .common, not .default: default-mode timers pause while the
            // menu bar window tracks events — exactly when stalls happen.
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        } else if !anyDown {
            watchdog?.invalidate()
            watchdog = nil
        }
    }

    /// Main thread (watchdog tick). Recover from the two ways a release
    /// gets lost: the tap was disabled when it happened (re-arm it), and
    /// the event is gone for good (poll the live modifier state and
    /// synthesize the release ourselves).
    private func checkStuckKeys() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        let flags = CGEventSource.flagsState(.combinedSessionState)
        if hotkeyDown, !flags.contains(hotkey.pairMask) {
            update(down: false, isRewrite: false)
        }
        if rewriteDown, let rewrite = rewriteHotkey, !flags.contains(rewrite.pairMask) {
            update(down: false, isRewrite: true)
        }
    }
}
