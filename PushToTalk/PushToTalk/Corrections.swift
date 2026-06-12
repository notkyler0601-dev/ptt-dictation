import Foundation

/// One learned mishearing: anywhere `heard` appears in a transcript
/// (ignoring case, whole words only), `corrected` replaces it. Created by
/// fixing a transcript in the menu's history, or by hand in Settings.
struct Correction: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What Whisper keeps writing, e.g. "cube or netties".
    var heard: String
    /// What it should be, e.g. "Kubernetes".
    var corrected: String
}

/// Persistence + the two algorithms: applying corrections to a transcript,
/// and extracting new ones from a user's edit. Deterministic find/replace
/// on purpose — unlike re-prompting a model, a fix made once can never
/// regress. Same UserDefaults-JSON pattern as VoiceCommandStore.
enum CorrectionStore {
    private static let key = Prefs.corrections

    static func load() -> [Correction] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let corrections = try? JSONDecoder().decode([Correction].self, from: data)
        else { return [] }
        return corrections
    }

    static func save(_ corrections: [Correction]) {
        if let data = try? JSONEncoder().encode(corrections) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Replaces every stored mishearing in `text`. Longest "heard" first, so
    /// an overlapping shorter rule can't eat part of a longer phrase before
    /// the longer one gets its chance. Matching is case-insensitive (Whisper
    /// capitalizes unpredictably) and word-bounded (a rule for "cat" must
    /// not rewrite "catalog"); the replacement is pasted exactly as stored.
    static func apply(to text: String) -> String {
        var result = text
        let corrections = load().sorted { $0.heard.count > $1.heard.count }
        for correction in corrections where !correction.heard.isEmpty {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: correction.heard) + "\\b"
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: correction.corrected))
        }
        return result
    }

    /// Diffs the original transcript against the user's edit and returns the
    /// replaced phrases as correction candidates.
    ///
    /// Word-level LCS (longest common subsequence) diff: the unchanged words
    /// anchor the alignment, and each contiguous run of removed-and-inserted
    /// words between anchors becomes one "heard" → "corrected" pair. Only
    /// replacements are kept — a pure insertion or deletion is the user
    /// editing their prose, not Whisper mishearing it.
    static func extract(from original: String, to edited: String) -> [Correction] {
        let a = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = edited.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !a.isEmpty, !b.isEmpty, a != b else { return [] }

        // dp[i][j] = LCS length of a[i...] vs b[j...]. Transcripts are a few
        // hundred words at most, so the quadratic table is nothing.
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }

        var result: [Correction] = []
        var heardRun: [String] = []
        var correctedRun: [String] = []

        func flush() {
            defer { heardRun = []; correctedRun = [] }
            guard !heardRun.isEmpty, !correctedRun.isEmpty else { return }
            // Edge punctuation belongs to the sentence, not the phrase:
            // "netties," → "Kubernetes," should learn the bare words.
            let heard = trimPunctuation(heardRun.joined(separator: " "))
            let corrected = trimPunctuation(correctedRun.joined(separator: " "))
            // != not caseInsensitive: a pure case fix ("vercel" → "Vercel")
            // is a legitimate proper-noun correction worth learning.
            guard !heard.isEmpty, !corrected.isEmpty, heard != corrected else { return }
            result.append(Correction(heard: heard, corrected: corrected))
        }

        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                flush()
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                heardRun.append(a[i]); i += 1
            } else {
                correctedRun.append(b[j]); j += 1
            }
        }
        heardRun.append(contentsOf: a[i...])
        correctedRun.append(contentsOf: b[j...])
        flush()
        return result
    }

    /// Words in the corrected side worth adding to the custom vocabulary:
    /// anything carrying an uppercase letter (proper nouns, acronyms,
    /// CamelCase jargon) — the class of word Whisper can only spell right
    /// if it's expecting it. Plain words are excluded on purpose; the
    /// correction rule already fixes those, and prompt space is limited.
    static func vocabularyCandidates(in corrections: [Correction]) -> [String] {
        var seen = Set<String>()
        return corrections
            .flatMap { $0.corrected.split(whereSeparator: \.isWhitespace) }
            .map { trimPunctuation(String($0)) }
            .filter { word in
                word.count >= 2
                    && word.contains(where: \.isUppercase)
                    && seen.insert(word.lowercased()).inserted
            }
    }

    static func trimPunctuation(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters)
    }
}
