import Foundation

/// Scans an incrementally-growing JSON buffer (the Claude streaming output
/// for `RecommendAndPlanResponse`) and yields ready-to-decode JSON
/// substrings as boundaries are detected:
///
///   1. The recommendation prefix — everything before the `"exercises"` key,
///      sealed with a trailing `}`. Emitted once.
///   2. Each complete exercise object inside the `exercises` array, in
///      order. The array is closed when the matching `]` arrives.
///   3. The `sessionStrategy` string value once it streams in after the
///      exercises array.
///
/// The scanner walks UTF-16 code units (`String.UnicodeScalarView` would
/// also work) tracking only what's necessary: depth of the JSON object
/// nesting, whether we're inside a string, and whether the previous char
/// was a backslash (escape). It never decodes JSON itself — it only
/// returns substrings; the caller decodes with `JSONDecoder` so any
/// edge case (e.g. a partial-but-syntactically-complete trailing chunk)
/// is rejected at the decode site, not here.
///
/// Not thread-safe; the streaming task owns one of these per call.
final class StreamingPlanScanner {
    private var buffer: [Character] = []
    private var pos: Int = 0
    /// Top-level JSON depth. `{` increments, `}` decrements. The root
    /// object opens at depth 1, the exercises array's enclosing braces
    /// nest deeper.
    private var depth: Int = 0
    private var inString: Bool = false
    private var escapeNext: Bool = false

    /// Once we've found `"exercises": [`, this is depth at which a `{`
    /// starts a new exercise object. Equal to (depth at the `[`) — i.e.
    /// inside the array, depth equals base + 1 while we're between items.
    private var exercisesArrayBaseDepth: Int? = nil
    private var exerciseObjectStart: Int? = nil
    /// FIFO of fully-formed exercise JSON substrings ready for the caller
    /// to drain. We push as `}` returns depth back inside the array, and
    /// the caller pops via `consumeNextExerciseJSON`.
    private var pendingExercises: [String] = []
    /// Set once the exercises array is fully consumed (`]` lands at
    /// `exercisesArrayBaseDepth`). After this, `consumeStrategy` looks
    /// for a `sessionStrategy` value.
    private var exercisesArrayClosed: Bool = false

    private var recommendationEmitted: Bool = false
    private var pendingRecommendation: String? = nil

    private var strategyEmitted: Bool = false
    private var pendingStrategy: String? = nil

    /// Feed the entire current buffer (not just new bytes — this scanner
    /// indexes into a Character array and `pos` tracks where we left off).
    func feed(_ fullBuffer: String) {
        // Re-materialize the Character array if it's grown. Cheap because
        // we only do this when new bytes arrived; in the worst case we
        // pay one Array(String) per delta event.
        let updated = Array(fullBuffer)
        guard updated.count > buffer.count else {
            buffer = updated
            return
        }
        buffer = updated
        scan()
    }

    func consumeRecommendationJSON() -> String? {
        guard !recommendationEmitted, let json = pendingRecommendation else { return nil }
        recommendationEmitted = true
        pendingRecommendation = nil
        return json
    }

    func consumeNextExerciseJSON() -> String? {
        guard !pendingExercises.isEmpty else { return nil }
        return pendingExercises.removeFirst()
    }

    func consumeStrategy() -> String? {
        guard !strategyEmitted, let value = pendingStrategy else { return nil }
        strategyEmitted = true
        pendingStrategy = nil
        return value
    }

    // MARK: - Scan

    private func scan() {
        while pos < buffer.count {
            let c = buffer[pos]

            if escapeNext {
                escapeNext = false
                pos += 1
                continue
            }

            if c == "\\" && inString {
                escapeNext = true
                pos += 1
                continue
            }

            if c == "\"" {
                inString.toggle()
                pos += 1
                continue
            }

            if inString {
                pos += 1
                continue
            }

            switch c {
            case "{":
                // First `{` at depth 0 opens the root. Subsequent `{`s at
                // exercisesArrayBaseDepth + 1 each start a new exercise.
                if let base = exercisesArrayBaseDepth,
                   depth == base + 1,
                   exerciseObjectStart == nil {
                    exerciseObjectStart = pos
                }
                depth += 1

            case "}":
                depth -= 1
                if let base = exercisesArrayBaseDepth,
                   depth == base + 1,
                   let start = exerciseObjectStart {
                    let slice = String(buffer[start...pos])
                    pendingExercises.append(slice)
                    exerciseObjectStart = nil
                }

            case "[":
                // Detect entry into "exercises": [ — only the FIRST array
                // we hit at root depth. We look back for the key by
                // scanning the recent prefix; cheap because we're already
                // at the array start so we know roughly where to look.
                if exercisesArrayBaseDepth == nil && depth == 1 {
                    if isExercisesKey(endingAt: pos) {
                        exercisesArrayBaseDepth = depth
                        emitRecommendationPrefix(beforeArrayAt: pos)
                    }
                }
                depth += 1

            case "]":
                depth -= 1
                if let base = exercisesArrayBaseDepth,
                   depth == base,
                   !exercisesArrayClosed {
                    exercisesArrayClosed = true
                }

            default:
                break
            }

            // After every character, if the array is closed, opportunistically
            // try to extract sessionStrategy. Cheap because it bails fast when
            // not enough text is buffered.
            if exercisesArrayClosed && !strategyEmitted && pendingStrategy == nil {
                tryExtractStrategy()
            }

            pos += 1
        }
    }

    /// Look back from `index` for the literal `"exercises"` key followed
    /// by `:` (with optional whitespace). Walks at most ~30 chars back —
    /// enough to skip whitespace + the key.
    private func isExercisesKey(endingAt index: Int) -> Bool {
        // Build a small look-back string and test with a regex. Bounded
        // to keep the per-`[` scan cost trivial.
        let lookback = max(0, index - 40)
        let prefix = String(buffer[lookback..<index])
        return prefix.range(
            of: #""exercises"\s*:\s*$"#,
            options: .regularExpression
        ) != nil
    }

    /// Build the recommendation JSON: take everything before the `,` that
    /// precedes `"exercises"`, then close it with `}`. The result is a
    /// syntactically valid JSON object with all of the recommendation's
    /// top-level fields (recommendedSessionName, reasoning, etc.).
    private func emitRecommendationPrefix(beforeArrayAt index: Int) {
        guard !recommendationEmitted, pendingRecommendation == nil else { return }
        let prefixString = String(buffer[..<index])
        // Strip JSON fences in case the model emitted ```json (rare on
        // streaming, but cheap to handle).
        let stripped = prefixString
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        // Find the comma that separates the recommendation block from the
        // exercises key. We rely on the fact that the model always emits
        // `..., "exercises": [` after the last recommendation field.
        guard let range = stripped.range(
            of: #",\s*"exercises"\s*:\s*\[?$"#,
            options: .regularExpression
        ) else { return }
        let recBody = String(stripped[..<range.lowerBound])
        // Append `}` to close the recommendation object. recBody ends
        // mid-object (no closing brace yet because the array key would've
        // followed) — we patch it.
        pendingRecommendation = recBody + "\n}"
    }

    /// Look for `"sessionStrategy": "..."` in the buffer past the closed
    /// exercises array and capture the unescaped value. Cheap regex; runs
    /// only after the array closes.
    private func tryExtractStrategy() {
        let tailStart = max(0, pos - 600)
        let tail = String(buffer[tailStart..<min(buffer.count, pos + 1)])
        // Capture group 1 = the string value (no escape handling needed
        // for this app's strategy strings, which don't contain `"` or `\`).
        guard let match = tail.range(
            of: #""sessionStrategy"\s*:\s*"([^"]*)""#,
            options: .regularExpression
        ) else { return }
        let value = String(tail[match])
        // Re-extract the captured value via a NSRegularExpression for the
        // group — cheap, only fires once.
        let regex = try? NSRegularExpression(pattern: #""sessionStrategy"\s*:\s*"([^"]*)""#)
        let range = NSRange(value.startIndex..., in: value)
        if let m = regex?.firstMatch(in: value, range: range),
           m.numberOfRanges >= 2,
           let captured = Range(m.range(at: 1), in: value) {
            pendingStrategy = String(value[captured])
        }
    }
}
