import SwiftUI

/// The plan card — the main object on the Today screen and the thing chat
/// edits. Renders the resolver's reasoning inline: which lifts went up, which
/// held, where the numbers came from. None of that costs an API call.
struct PlanCardView: View {
    let plan: DailyPlan
    /// Title shown in the header. "Today's plan" on first render, "Updated
    /// plan" for a card produced by a chat edit.
    var title: String = "Today's plan"
    var showsStart: Bool = true
    var onStart: (() -> Void)?
    /// Shown only once chat has edited the plan — before that, the plan on
    /// screen already is the default, so a reset would do nothing.
    var onReset: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let flag = plan.crossTrainingFlag {
                crossTrainingFlag(flag)
            }

            VStack(spacing: 2) {
                ForEach(plan.sortedLifts) { lift in
                    liftRow(lift)
                }
            }

            footer

            if showsStart {
                startButton
            }
        }
        .padding(14)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            Spacer()
            Text("\(plan.lifts.count) lift\(plan.lifts.count == 1 ? "" : "s") · ~\(plan.estimatedMinutes) min")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .monospacedDigit()
        }
    }

    // MARK: Cross-training flag

    private func crossTrainingFlag(_ flag: CrossTrainingFlag) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "figure.climbing")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.flagAmber)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 3) {
                Text(flag.headline)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.flagAmberText)
                Text(flag.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.flagAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.flagAmber.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: Lift row

    private func liftRow(_ lift: PlannedLift) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(intentColor(lift))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(lift.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text("\(lift.sets) × \(lift.targetReps)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                        .monospacedDigit()

                    if lift.usesStraps {
                        Text("STRAPS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.flagAmber)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.flagAmber.opacity(0.22))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    if let note = lift.noteText {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                Text(formatWeight(lift.weight))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                    .monospacedDigit()
                progressionBadge(lift)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The resolver's decision, made legible. A green "+5" is the app saying
    /// "you earned this"; HOLD is it saying "you missed a rep, same weight".
    @ViewBuilder
    private func progressionBadge(_ lift: PlannedLift) -> some View {
        switch lift.progression {
        case .progressed:
            HStack(spacing: 1) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .heavy))
                Text(formatWeight(lift.progressionDelta))
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.prGreen)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.prGreen.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

        case .deloaded:
            HStack(spacing: 1) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .heavy))
                Text(formatWeight(abs(lift.progressionDelta)))
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.failedRed)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.failedRed.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

        case .held:
            Text("HOLD")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tertiaryText)

        case .new:
            EmptyView()
        }
    }

    // MARK: Footer

    /// Provenance, plus the way back. A plan chat has edited no longer matches
    /// what the resolver would produce, so it says so and offers to rebuild —
    /// rather than leaving the footer claiming a lineage that's now wrong.
    @ViewBuilder
    private var footer: some View {
        if plan.wasEdited {
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                Text("Edited")
                    .font(.system(size: 11.5))
                Spacer(minLength: 8)
                if let onReset {
                    Button {
                        Haptics.selection()
                        onReset()
                    } label: {
                        Text("Reset to default")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(Color.tertiaryText)
            .padding(.leading, 2)
        } else if let note = plan.resolverNote {
            provenance(note)
        }
    }

    private func provenance(_ note: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .semibold))
            Text(note)
                .font(.system(size: 11.5))
                .lineLimit(2)
        }
        .foregroundStyle(Color.tertiaryText)
        .padding(.horizontal, 2)
    }

    private var startButton: some View {
        Button {
            Haptics.impact(.medium)
            onStart?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14))
                Text("Start")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.accent)
            .foregroundStyle(Color.appBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(plan.lifts.isEmpty)
        .opacity(plan.lifts.isEmpty ? 0.4 : 1)
    }

    // MARK: Helpers

    private func intentColor(_ lift: PlannedLift) -> Color {
        switch lift.intentRaw {
        case "primary compound": return .intentPrimary
        case "secondary compound": return .intentSecondary
        case "isolation": return .intentIsolation
        case "finisher": return .intentFinisher
        default:
            // No intent recorded (replayed lifts usually have none) — fall
            // back to position, which tracks intent closely enough in
            // practice: compounds first, isolation last.
            switch lift.order {
            case 0: return .intentPrimary
            case 1: return .intentPrimary
            case 2: return .intentSecondary
            default: return .intentIsolation
            }
        }
    }

    private func formatWeight(_ weight: Double) -> String {
        weight.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(weight))
            : String(format: "%.1f", weight)
    }
}

// MARK: - Collapsed (superseded) card

/// What a plan card shrinks to once a later edit has replaced it. Keeps the
/// transcript readable instead of stacking full plans.
struct CollapsedPlanRow: View {
    let plan: DailyPlan
    let liftCount: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
            Text("\(plan.displayName) · \(liftCount) lift\(liftCount == 1 ? "" : "s")")
                .font(.system(size: 13))
            Spacer()
            Text("superseded")
                .font(.system(size: 11))
                .foregroundStyle(Color.tertiaryText)
        }
        .foregroundStyle(Color.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.cardSurface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
