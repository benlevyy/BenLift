import SwiftUI

@Observable
class SettingsViewModel {
    var apiKey: String = ""
    var isTestingConnection: Bool = false
    var connectionTestResult: Bool?

    // Model selections per touchpoint
    @ObservationIgnored
    @AppStorage("modelDailyPlan") var modelDailyPlan: String = "claude-haiku-4-5"
    @ObservationIgnored
    @AppStorage("modelGoalSetting") var modelGoalSetting: String = "claude-haiku-4-5"
    @ObservationIgnored
    @AppStorage("modelMidWorkout") var modelMidWorkout: String = "claude-haiku-4-5"
    @ObservationIgnored
    @AppStorage("modelPostAnalysis") var modelPostAnalysis: String = "claude-haiku-4-5"
    @ObservationIgnored
    @AppStorage("modelWeeklyReview") var modelWeeklyReview: String = "claude-haiku-4-5"

    // Workout preferences
    @ObservationIgnored
    @AppStorage("restTimerDuration") var restTimerDuration: Double = 150 // 2:30
    @ObservationIgnored
    @AppStorage("weightIncrement") var weightIncrement: Double = 5.0
    @ObservationIgnored
    @AppStorage("dumbbellIncrement") var dumbbellIncrement: Double = 2.5
    @ObservationIgnored
    @AppStorage("weightUnit") var weightUnitRaw: String = WeightUnit.lbs.rawValue
    @ObservationIgnored
    @AppStorage("warmUpGeneration") var warmUpGeneration: Bool = true

    // Notifications
    @ObservationIgnored
    @AppStorage("weeklyReviewDay") var weeklyReviewDay: Int = 1 // Sunday
    @ObservationIgnored
    @AppStorage("weeklyReviewEnabled") var weeklyReviewEnabled: Bool = true

    var weightUnit: WeightUnit {
        get { WeightUnit(rawValue: weightUnitRaw) ?? .lbs }
        set { weightUnitRaw = newValue.rawValue }
    }

    func loadAPIKey() {
        apiKey = KeychainService.load(key: KeychainService.apiKeyKey) ?? ""
    }

    func saveAPIKey() {
        guard !apiKey.isEmpty else { return }
        try? KeychainService.save(key: KeychainService.apiKeyKey, value: apiKey)
    }

    var hasAPIKey: Bool {
        !apiKey.isEmpty || KeychainService.load(key: KeychainService.apiKeyKey) != nil
    }

    func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil

        defer { isTestingConnection = false }

        guard let key = KeychainService.load(key: KeychainService.apiKeyKey), !key.isEmpty else {
            connectionTestResult = false
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 10,
            "messages": [["role": "user", "content": "Hi"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            connectionTestResult = httpResponse?.statusCode == 200
        } catch {
            connectionTestResult = false
        }
    }
}
