import SwiftUI

struct WatchAddExerciseView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @Environment(\.dismiss) private var dismiss

    private var availableExercises: [WatchExerciseInfo] {
        let alreadyInPlan = Set(workoutVM.exerciseStates.map(\.id))
        let category = workoutVM.currentPlan?.category ?? .push // fallback for exercise pool
        return Self.exercisePool(for: category).filter { !alreadyInPlan.contains($0.name) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                let exercises = availableExercises
                ForEach(Array(exercises.enumerated()), id: \.offset) { _, exercise in
                    Button {
                        workoutVM.addExercise(exercise)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exercise.name)
                                    .font(.caption.bold())
                                    .lineLimit(1)
                                if exercise.suggestedWeight > 0 {
                                    Text("\(Int(exercise.suggestedWeight)) lbs")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundColor(.blue)
                                .font(.caption)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Add")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func exercisePool(for category: WorkoutCategory) -> [WatchExerciseInfo] {
        let defs: [(String, Double)]
        switch category {
        case .push:
            defs = [
                ("Bench Press", 135), ("DB Incline Press", 55), ("DB Flat Press", 55),
                ("Machine Press", 45), ("Incline Barbell Press", 115), ("Landmine Press", 45),
                ("Cable Flys", 17.5), ("Cable Fly (3 Height)", 12.5), ("Pec Deck", 100),
                ("DB Shoulder Press", 45), ("Overhead Press", 85), ("Machine Shoulder Press", 45),
                ("Lateral Raises", 20), ("Cable Lateral Raise", 10), ("Rear Delt Fly", 15),
                ("Skull Crushers", 20), ("Tricep Pushdown", 57.5), ("Tricep Overhead Extension", 47.5),
                ("Dips", 0), ("Close Grip Bench", 115), ("Diamond Push-ups", 0),
                ("Pallof Press", 25), ("Hanging Leg Raise", 0), ("Plank", 0),
            ]
        case .pull:
            defs = [
                ("Pull-ups", 0), ("Chin-ups", 0), ("Lat Pulldown", 145),
                ("One Arm Lat Pulldown", 57.5), ("Neutral Grip Lat Pulldown", 130),
                ("Seated Row", 145), ("Chest Supported Row", 55), ("Barbell Row", 135),
                ("DB Row", 50), ("T-Bar Row", 90), ("Meadows Row", 45),
                ("Seal Row", 40), ("Machine Row", 115), ("Inverted Row", 0),
                ("Face Pulls", 50), ("Reverse Pec Deck", 70),
                ("Barbell Curl", 30), ("Hammer Curl", 25), ("Incline Hammer Curl", 25),
                ("Preacher Curl", 12.5), ("Cable Curl", 30), ("EZ Bar Curl", 45),
                ("Pallof Press", 25), ("Weighted Leg Raises", 10),
            ]
        case .legs:
            defs = [
                ("Squat", 185), ("Front Squat", 135), ("Hack Squat", 45),
                ("Leg Press", 270), ("Goblet Squat", 45), ("Pendulum Squat", 90),
                ("Split Squat", 25), ("Bulgarian Split Squat", 20), ("Step Ups", 10),
                ("Walking Lunges", 25), ("Reverse Lunge", 25),
                ("Leg Extension", 180), ("Sissy Squat", 0),
                ("Romanian Deadlift", 135), ("Deadlift", 225), ("DB Romanian Deadlift", 50),
                ("Hamstring Curl", 100), ("Good Morning", 95), ("Single Leg RDL", 30),
                ("Hip Thrust", 135), ("Kettlebell Swing", 35), ("Cable Kickback", 25),
                ("Calf Raises", 150), ("Seated Calf Raise", 90),
                ("Plank", 0), ("Hanging Leg Raise", 0),
            ]
        }

        return defs.map { name, weight in
            WatchExerciseInfo(
                name: name, sets: 3, targetReps: "8-12",
                suggestedWeight: weight, warmupSets: nil, notes: nil,
                intent: "isolation", lastWeight: nil, lastReps: nil
            )
        }
    }
}
