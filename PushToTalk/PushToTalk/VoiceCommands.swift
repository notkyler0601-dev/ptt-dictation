import Foundation

/// One spoken-phrase → typed-text rule. Say the phrase (exactly, modulo
/// case/punctuation) and the replacement is pasted instead of the
/// transcript; optionally Return is pressed after, so commands actually run.
struct VoiceCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What you say, e.g. "cd downloads".
    var phrase: String
    /// What gets typed, e.g. "cd ~/Downloads".
    var replacement: String
    /// Press Return after pasting (runs it in a terminal). Off by default —
    /// executing things should be a deliberate choice per rule.
    var pressReturn: Bool = false
}

enum VoiceCommandStore {
    private static let key = Prefs.voiceCommands

    static func load() -> [VoiceCommand] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let commands = try? JSONDecoder().decode([VoiceCommand].self, from: data)
        else { return [] }
        return commands
    }

    static func save(_ commands: [VoiceCommand]) {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Whisper decorates speech ("cd downloads" → "CD Downloads."), so
    /// matching compares with case folded and everything but letters,
    /// numbers, and word gaps thrown away.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Exact match after normalization — predictable beats clever for
    /// something that can execute commands.
    static func match(_ transcript: String) -> VoiceCommand? {
        let spoken = normalize(transcript)
        guard !spoken.isEmpty else { return nil }
        return load().first {
            !$0.replacement.isEmpty && normalize($0.phrase) == spoken
        }
    }
}
