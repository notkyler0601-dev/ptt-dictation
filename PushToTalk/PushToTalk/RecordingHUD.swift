import SwiftUI

/// The pill shown during a dictation. Two faces, driven by phase:
///   - recording: mic icon + live level bars (AppState keeps a rolling
///     window of recent mic levels, so the bars read as a scrolling
///     waveform),
///   - processing: animated waveform + "Transcribing…" until the paste
///     lands, so releasing the key doesn't feel like the app went dead.
/// Because AppState is @Observable, this re-renders on every level push
/// and phase change with no explicit subscription.
struct RecordingHUD: View {
    var state: AppState

    var body: some View {
        Group {
            switch state.phase {
            case .processing:
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        // Ripples the symbol's layers continuously — the
                        // "I'm working" pulse.
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    Text("Transcribing…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            default:
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
                    // Animate height changes between pushes (~12/s), so
                    // bars glide instead of stepping.
                    .animation(.easeOut(duration: 0.08), value: state.hudLevels)
                }
            }
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
