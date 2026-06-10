import AppKit
import SwiftUI

/// The floating window that hosts the recording HUD.
///
/// Gotcha 1 lives here: this must never steal keyboard focus from the app
/// the user is dictating into, or the eventual Cmd+V pastes into our own
/// HUD. Three things guarantee that:
///   - `.nonactivatingPanel` in the style mask — ordering the panel on
///     screen doesn't activate our app,
///   - `canBecomeKey/Main = false` — even a stray click can't focus it,
///   - `orderFrontRegardless()` to show — displays without activation.
final class OverlayPanel: NSPanel {
    init(state: AppState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // Follow the user to every Space and over full-screen apps —
        // dictation targets live everywhere.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // the HUD view draws its own shadow
        ignoresMouseEvents = true  // display-only; clicks fall through
        contentView = NSHostingView(rootView: RecordingHUD(state: state))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows bottom-center of the screen the cursor is on (a stand-in for
    /// "where the user is working" — we can't know the focused window's
    /// screen without more Accessibility machinery).
    func show() {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        if let screen {
            let area = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: area.midX - frame.width / 2,
                y: area.minY + 100
            ))
        }
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}
