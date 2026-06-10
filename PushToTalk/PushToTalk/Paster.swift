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

    func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        // v1 preserves plain text only — images/rich content on the
        // clipboard are not restored. (Prototype parity.)
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    private func pressCmdV() {
        for keyDown in [true, false] {
            let event = CGEvent(
                keyboardEventSource: nil, virtualKey: Self.vKeycode, keyDown: keyDown)
            // Explicit flags: the event carries exactly Cmd, regardless of
            // what physical modifiers happen to be held at that moment.
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
