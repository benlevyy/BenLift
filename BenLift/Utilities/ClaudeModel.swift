import Foundation

/// The single model used for every Claude call in the app.
///
/// This is a single-user app — precision beats cost and latency, so there's
/// no per-touchpoint model selection to tune. Replaced five separate
/// `@AppStorage("model...")` knobs (daily plan, goal setting, mid-workout,
/// post-analysis, weekly review) that all defaulted to Haiku, plus a
/// Settings picker that only ever offered Haiku variants as options.
enum ClaudeModel {
    /// Opus 5.5: same context and feature set as Opus 5 at a lower price.
    /// Thinking can't be disabled on it (we never did) and its default
    /// effort is medium rather than high — moot here, since every request
    /// sends `output_config.effort` explicitly from `Intelligence`.
    static let current = "claude-opus-5-5"
}
