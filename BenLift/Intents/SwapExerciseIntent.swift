import AppIntents

/// LiveActivityIntent triggered by the "Swap" button on the Lock Screen Live Activity.
/// Opens the app and posts a notification so the workout view shows the adapt sheet.
struct SwapExerciseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Swap Exercise"
    static var description: IntentDescription = IntentDescription("Suggest an alternative exercise")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .liveActivitySwapTapped, object: nil)
        }
        return .result()
    }
}

extension Notification.Name {
    static let liveActivitySwapTapped = Notification.Name("liveActivitySwapTapped")
}
