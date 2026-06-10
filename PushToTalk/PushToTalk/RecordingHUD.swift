import SwiftUI

/// The pill shown while the hotkey is held: mic icon + level bars.
///
/// Stage 2: the bars are fixed placeholder heights so the HUD has its final
/// shape. Stage 3 feeds `levels` from the recorder's live RMS so they dance
/// with the voice.
struct RecordingHUD: View {
    var levels: [CGFloat] = RecordingHUD.placeholderLevels

    static let placeholderLevels: [CGFloat] = [
        0.25, 0.55, 0.85, 0.45, 0.70, 0.35, 0.60, 0.90, 0.50, 0.30, 0.65, 0.40,
    ]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.red)

            HStack(spacing: 3) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .frame(width: 4, height: 6 + 26 * levels[index])
                }
            }
            .foregroundStyle(.white.opacity(0.9))
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
    RecordingHUD()
        .frame(width: 240, height: 72)
}
