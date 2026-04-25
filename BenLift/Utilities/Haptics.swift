import UIKit

/// Tiny haptic helper. Imperative API so it can be fired inline in button
/// action closures — simpler than the view-modifier `.sensoryFeedback` when
/// the trigger is "user tapped this specific button."
///
/// Generators are created per-call; iOS pools them internally so the cost is
/// negligible, and we avoid stale-generator pitfalls across view lifecycles.
enum Haptics {
    /// Light tick for value-stepping actions (weight/reps ±, timer ±30,
    /// picking an option). Same feeling as a UISegmentedControl change.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Medium thump for confirming an action the user will feel invested in
    /// (Log Set, Skip Rest when over). Heavier than selection, lighter than
    /// success.
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Success notification — use sparingly. Reserved for terminal events
    /// (workout saved). Over-using kills the "reward" signal.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Warning — validation failures, undo, destructive confirms.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
