import Foundation

/// An in-session record of a user-initiated adjustment (swap, adapt, weight change).
/// These accumulate during a planning or workout session so subsequent LLM calls
/// can see prior adjustments and spot patterns (e.g., 3 consecutive pressing swaps
/// -> likely shoulder issue even if the user never named it).
/// Not persisted — cleared when a new plan is generated or a workout starts/ends.
struct AdjustmentRecord: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let kind: Kind
    /// One-line human summary rendered into prompts verbatim.
    /// Example: "Swapped Overhead Press -> Cable Lateral Raise"
    let summary: String

    enum Kind: String {
        case swap
        case weight
        case addExercise
        case removeExercise
        case skip
        case restAdjust
    }

    init(kind: Kind, summary: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
    }

    /// Formats an array into the "Prior adjustments" block for prompts.
    /// Returns empty string when the array is empty so callers can concatenate unconditionally.
    static func promptBlock(_ records: [AdjustmentRecord]) -> String {
        guard !records.isEmpty else { return "" }
        let lines = records.suffix(8).map { r in
            "- \(r.summary)"
        }.joined(separator: "\n")
        return """

        Prior adjustments in this session (most recent last):
        \(lines)

        Look for patterns — consecutive swaps of the same muscle group or movement pattern often \
        indicate an emerging constraint (injury, fatigue, equipment) even if the user hasn't named \
        it. Consider whether this new request is consistent with prior adjustments, and do not \
        suggest a replacement that conflicts with one the user already rejected.
        """
    }
}
