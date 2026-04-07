import SwiftUI
import SwiftData

struct SplitEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var program: TrainingProgram

    private let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private let options: [(String, String, Color)] = [
        ("push", "Push", Color.pushBlue),
        ("pull", "Pull", Color.pullGreen),
        ("legs", "Legs", Color.legsOrange),
        ("rest", "Rest", Color.secondaryText),
    ]

    @State private var editedSplit: [String] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    HStack {
                        Text(day)
                            .font(.body)

                        Spacer()

                        // Tappable options
                        HStack(spacing: 6) {
                            ForEach(options, id: \.0) { value, label, color in
                                let isSelected = index < editedSplit.count && editedSplit[index] == value
                                Button {
                                    ensureSplitSize()
                                    editedSplit[index] = value
                                } label: {
                                    Text(String(label.prefix(1)))
                                        .font(.caption.bold())
                                        .foregroundColor(isSelected ? .white : color)
                                        .frame(width: 30, height: 30)
                                        .background(isSelected ? color : color.opacity(0.15))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        program.split = editedSplit
                        program.daysPerWeek = editedSplit.filter { $0 != "rest" }.count
                        try? modelContext.save()
                        print("[BenLift] Split updated: \(editedSplit), \(program.daysPerWeek) days/week")
                        dismiss()
                    }
                }
            }
            .onAppear {
                editedSplit = program.split
                ensureSplitSize()
            }
        }
    }

    private func ensureSplitSize() {
        while editedSplit.count < 7 {
            editedSplit.append("rest")
        }
    }
}
