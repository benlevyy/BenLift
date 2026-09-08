import SwiftUI

/// Approve/dismiss card for a rule Claude wants to create.
///
/// Rules are enforced by the resolver in Swift — an excluded lift simply never
/// appears in a plan again. That's the right amount of force for a decision
/// actually made, and far too much for one inferred from a passing remark. The
/// old app learned this the hard way: it wrote a rule every time an exercise
/// was removed, and those piled up into standing preferences nobody agreed to.
///
/// So every rule stops here first.
struct RuleProposalCard: View {
    let proposal: PendingRuleProposal
    let onApprove: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accent)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Save this as a rule?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.secondaryText)
                    Text(proposal.summary)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = proposal.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(footnote)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    Haptics.selection()
                    onDismiss()
                } label: {
                    Text("No")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.appBackground)
                        .foregroundStyle(Color.bodyText)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.impact(.light)
                    onApprove()
                } label: {
                    Text("Save rule")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.accent)
                        .foregroundStyle(Color.appBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accent.opacity(0.35), lineWidth: 1)
        )
    }

    /// Say what it actually does, in the terms the user will feel it.
    private var footnote: String {
        switch proposal.kind {
        case .exerciseOut:
            return "It won't appear in any plan until you add it back. Applies from today."
        case .preferOver:
            return "Future plans will pick the alternative whenever this slot comes up."
        case .equipment, .programming, .unknown:
            return "The coach reads this on every message, and plans are built around it."
        }
    }
}
