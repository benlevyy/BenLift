import Foundation

/// The only two things that flow between Watch and Phone during a workout:
/// - `snapshot`: full state, broadcast by the OWNER after every mutation
/// - `command`: action requested by the MIRROR, processed serially by the OWNER
///
/// Mirrors never mutate their own state; they apply snapshots and send commands.
enum WorkoutMessage: Codable {
    case snapshot(WorkoutSnapshot)
    case command(WorkoutCommand)

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> WorkoutMessage? {
        try? JSONDecoder().decode(WorkoutMessage.self, from: data)
    }
}
