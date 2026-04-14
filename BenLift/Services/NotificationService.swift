import Foundation
import UserNotifications

/// Local notifications for workout lifecycle + daily reminder. No server/APNS involved.
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    private enum ID {
        static let workoutStarted = "com.benlift.notif.workoutStarted"
        static let workoutCompleted = "com.benlift.notif.workoutCompleted"
        static let workoutAbandoned = "com.benlift.notif.workoutAbandoned"
        static let dailyReminder = "com.benlift.notif.dailyReminder"
    }

    private enum Keys {
        static let workoutsEnabled = "workoutNotificationsEnabled"
        static let dailyEnabled = "dailyReminderEnabled"
        static let dailyHour = "dailyReminderHour"
        static let dailyMinute = "dailyReminderMinute"
    }

    private override init() {
        super.init()
        center.delegate = self
    }

    // Must be called once at app launch to install the delegate and re-sync the
    // daily reminder (iOS drops pending requests across reinstall, not reboot).
    func bootstrap() {
        rescheduleDailyFromSettings()
    }

    // MARK: - Authorization

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("[Notifications] auth error: \(error)")
            return false
        }
    }

    // MARK: - Workout lifecycle

    func notifyWorkoutStarted(sessionName: String) {
        guard workoutsEnabled else { return }
        fire(
            id: ID.workoutStarted,
            title: "Workout Started",
            body: sessionName.isEmpty ? "Let's go." : "\(sessionName) — let's go."
        )
    }

    func notifyWorkoutCompleted(sessionName: String, volume: Int, durationSeconds: TimeInterval) {
        guard workoutsEnabled else { return }
        let mins = max(1, Int(durationSeconds / 60))
        fire(
            id: ID.workoutCompleted,
            title: "Workout Complete — \(sessionName)",
            body: "\(mins) min · \(volume) lbs total volume"
        )
    }

    /// Replaces any pending abandon reminder with a fresh N-minute trigger.
    /// Call on every real user action (set logged, exercise changed).
    func scheduleAbandonReminder(minutes: Int = 30) {
        guard workoutsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Finish your workout?"
        content.body = "No activity in \(minutes) minutes. Tap to wrap it up."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(minutes * 60),
            repeats: false
        )
        let req = UNNotificationRequest(identifier: ID.workoutAbandoned, content: content, trigger: trigger)
        center.add(req)
    }

    func cancelAbandonReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [ID.workoutAbandoned])
    }

    // MARK: - Daily reminder

    func scheduleDailyReminder(hour: Int, minute: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Ready to train?"
        content.body = "Your daily lift awaits."
        content.sound = .default

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

        center.removePendingNotificationRequests(withIdentifiers: [ID.dailyReminder])
        let req = UNNotificationRequest(identifier: ID.dailyReminder, content: content, trigger: trigger)
        center.add(req)
    }

    func cancelDailyReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [ID.dailyReminder])
    }

    /// Reads settings and (re)schedules/cancels the daily reminder accordingly.
    func rescheduleDailyFromSettings() {
        let enabled = UserDefaults.standard.object(forKey: Keys.dailyEnabled) as? Bool ?? false
        if enabled {
            let h = UserDefaults.standard.object(forKey: Keys.dailyHour) as? Int ?? 18
            let m = UserDefaults.standard.object(forKey: Keys.dailyMinute) as? Int ?? 0
            scheduleDailyReminder(hour: h, minute: m)
        } else {
            cancelDailyReminder()
        }
    }

    // MARK: - Helpers

    private var workoutsEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.workoutsEnabled) as? Bool ?? true
    }

    private func fire(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(req)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    // Show banner + sound even when the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
