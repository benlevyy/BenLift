import SwiftUI
import SwiftData
import Charts

struct ProgressionView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selectedExercise: String = "Bench Press"
    @State private var historyVM = HistoryViewModel()

    private let mainCompounds = ["Bench Press", "Squat", "Deadlift", "Overhead Press"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Exercise picker
                Picker("Exercise", selection: $selectedExercise) {
                    ForEach(mainCompounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.segmented)

                // e1RM chart
                e1RMChart

                // Volume trend
                volumeChart
            }
            .padding()
        }
        .navigationTitle("Progression")
    }

    private var e1RMChart: some View {
        let data = historyVM.exerciseHistory(name: selectedExercise, from: modelContext)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Estimated 1RM")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            if data.isEmpty {
                Text("No data yet")
                    .foregroundColor(.secondaryText)
                    .frame(height: 200)
            } else {
                Chart(data, id: \.date) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("e1RM", point.e1RM)
                    )
                    .foregroundStyle(Color.accentBlue)

                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("e1RM", point.e1RM)
                    )
                    .foregroundStyle(Color.accentBlue)
                }
                .frame(height: 200)
                .chartYAxisLabel("lbs")
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private var volumeChart: some View {
        let sessions = historyVM.fetchSessions(from: modelContext)
        let data = sessions.prefix(20).compactMap { session -> (date: Date, volume: Double)? in
            guard session.entries.first(where: { $0.exerciseName == selectedExercise }) != nil else { return nil }
            let entry = session.entries.first(where: { $0.exerciseName == selectedExercise })!
            return (date: session.date, volume: entry.totalVolume)
        }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Volume Per Session")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            if data.isEmpty {
                Text("No data yet")
                    .foregroundColor(.secondaryText)
                    .frame(height: 150)
            } else {
                Chart(data, id: \.date) { point in
                    BarMark(
                        x: .value("Date", point.date),
                        y: .value("Volume", point.volume)
                    )
                    .foregroundStyle(Color.accentBlue.opacity(0.7))
                }
                .frame(height: 150)
                .chartYAxisLabel("lbs")
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }
}
