import SwiftUI

/// The pill shown while the hotkey is held: mic icon + live level bars.
///
/// AppState keeps a rolling window of recent mic levels; each tap buffer
/// pushes a new value and drops the oldest, so the bars read as a waveform
/// scrolling right-to-left. Because AppState is @Observable, this view
/// re-renders on every push with no explicit subscription.
struct RecordingHUD: View {
    var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.red)

            HStack(spacing: 3) {
                ForEach(state.hudLevels.indices, id: \.self) { index in
                    Capsule()
                        .frame(width: 4, height: 6 + 26 * state.hudLevels[index])
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            // Animate height changes between pushes (~12/s), so bars glide
            // instead of stepping.
            .animation(.easeOut(duration: 0.08), value: state.hudLevels)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        // Solid dark pill rather than a system material: materials need
        // more window cooperation to render in a clear borderless panel,
        // and a HUD should read instantly over any background anyway.
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        // Center within whatever size the panel gives us.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    RecordingHUD(state: AppState())
        .frame(width: 240, height: 72)
}
