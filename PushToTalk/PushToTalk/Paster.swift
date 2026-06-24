import AppKit

/// Lands the transcript at the cursor of whatever app has focus, via
/// clipboard swap + one synthetic Cmd+V.
///
/// Why paste instead of typing the text character-by-character: one paste
/// event is layout-independent and instant; synthetic keystrokes are slow
/// and their keycodes address physical key positions, so they break on
/// non-US layouts. (Same rationale as the prototype.)
final class Paster {
    /// ANSI 'V' — virtual keycodes map to physical key positions.
    private static let vKeycode: CGKeyCode = 9
    /// The paste lands asynchronously in the target app; give it a beat
    /// before yanking the pasteboard back (prototype value).
    private static let restoreDelay: TimeInterval = 0.4

    /// Posting CGEvents is gated by the Accessibility TCC permission.
    /// Without it, post() is silently ignored — no error, no paste.
    var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Re-checks trust, showing the system's "grant Accessibility" dialog
    /// the first time if not yet trusted.
    @discardableResult
    func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// `target` is the app that was frontmost when the user *started*
    /// dictating. We re-focus it before pasting so a slow transcription
    /// (whisper occasionally stalls for many seconds under GPU/memory
    /// contention) can't land the paste in whatever window the user
    /// wandered to in the meantime. nil keeps the old behaviour (paste at
    /// the current focus).
    func paste(_ text: String, into target: NSRunningApplication? = nil) async {
        let pasteboard = NSPasteboard.general
        // v1 preserves plain text only — images/rich content on the
        // clipboard are not restored. (Prototype parity.)
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        await restoreFocusIfNeeded(to: target)
        pressCmdV()

        // Suspends (doesn't block the main thread) — and because the
        // pipeline chain awaits us, a queued next dictation can't swap the
        // clipboard from under this paste.
        try? await Task.sleep(for: .seconds(Self.restoreDelay))

        if let saved {
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
    }

    /// Bring `target` back to the front if focus has drifted since the user
    /// started speaking. A no-op when they never left — the common, fast
    /// case — so normal dictations pay nothing for this.
    private func restoreFocusIfNeeded(to target: NSRunningApplication?) async {
        guard let target, !target.isTerminated else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier == target.processIdentifier { return }

        // Two routes on purpose. macOS's cooperative activation can refuse a
        // background agent like us, so NSRunningApplication.activate alone
        // isn't reliable from here; setting kAXFrontmost via the Accessibility
        // API (which we already hold permission for, to post the Cmd+V) forces
        // the raise when activate() is declined. Belt and suspenders.
        target.activate()
        let axApp = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        // Let the window server actually switch front before we synthesize
        // keystrokes — otherwise Cmd+V can race ahead of the activation and
        // still hit the old window. ~120 ms lands reliably without being felt.
        try? await Task.sleep(for: .seconds(0.12))
    }

    /// Grabs the frontmost app's current selection by synthesizing Cmd+C
    /// and watching the pasteboard, then restores the user's clipboard.
    /// Returns nil when nothing got copied — pasteboard `changeCount` is
    /// the tell: it only bumps if some app actually serviced the copy.
    func captureSelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let countBefore = pasteboard.changeCount

        press(key: Self.cKeycode, flags: .maskCommand)
        // Give the target app a beat to service the copy.
        try? await Task.sleep(for: .seconds(0.25))

        guard pasteboard.changeCount != countBefore else { return nil }
        let selection = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        return selection
    }

    /// For voice commands that should execute, not just type. Called after
    /// paste() returns, which is already past the paste-landed delay.
    func pressReturn() {
        press(key: 36, flags: [])  // kVK_Return
    }

    private static let cKeycode: CGKeyCode = 8  // ANSI 'C'

    private func pressCmdV() {
        // Explicit flags: the event carries exactly Cmd, regardless of
        // what physical modifiers happen to be held at that moment.
        press(key: Self.vKeycode, flags: .maskCommand)
    }

    private func press(key: CGKeyCode, flags: CGEventFlags) {
        for keyDown in [true, false] {
            let event = CGEvent(
                keyboardEventSource: nil, virtualKey: key, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
