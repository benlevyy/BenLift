import SwiftUI
import UIKit

// MARK: - Stroke

/// One arc on the portrait. Everything the canvas needs and nothing it has
/// to look up — the encoding happens in `TrainingPortrait.strokes`, the view
/// only turns fractions and degrees into points.
struct PortraitStroke: Equatable {
    /// Where on the time axis this sits: 0 is the oldest event (inner
    /// radius), 1 the most recent (outer radius).
    var radiusFraction: Double
    /// SwiftUI convention — 0 is 3 o'clock, positive is clockwise.
    var centerAngleDegrees: Double
    var spanDegrees: Double
    var lineWidth: Double
    var color: Color
}

// MARK: - Encoding

/// Turns training history into strokes. Three rules, and they are the whole
/// explanation:
///
/// 1. Outward is time. Radius is the date, oldest at the centre, newest at
///    the rim. A month off is an empty ring — honest, and meant to be seen.
/// 2. Angle is muscle. Upper body on top, legs below, pushing on the right,
///    pulling on the left. Cross-training sits on the horizontal axis.
/// 3. Bold is progress. A lift drawn at its first-ever working weight is
///    thin and pale; one at +50% is thick and full forest green.
///
/// Nothing decorative. Every stroke is a logged exercise or a HealthKit
/// workout, so the drawing is only as rich as the training was.
enum TrainingPortrait {

    // MARK: Angles

    /// Push group top-right, pull group top-left, legs and core below.
    static func angle(for group: MuscleGroup) -> Double {
        switch group {
        case .chest: return -90
        case .shoulders: return -62
        case .triceps: return -34
        case .back: return -118
        case .biceps: return -146
        case .forearms: return -174
        case .quads: return 155
        case .hamstrings: return 120
        case .core: return 90
        case .glutes: return 60
        case .calves: return 25
        }
    }

    /// Endurance work on the left, climbing and anything we don't recognise
    /// on the right. Both axes are empty of muscle groups, so cross-training
    /// never competes with a lift for the same angle.
    static func angle(forActivity type: String) -> Double {
        switch type {
        case "running", "cycling", "hiking", "swimming", "rowing": return 180
        default: return 0
        }
    }

    static let maxJitterDegrees = 8.0

    /// A stable offset of up to ±8° from the exercise name, so two lifts of
    /// the same group fan out instead of stacking. djb2 over the scalars —
    /// Swift's `hashValue` is reseeded every launch and would redraw the
    /// portrait differently each time the app opened.
    static func jitter(for exerciseName: String) -> Double {
        var hash: UInt32 = 5381
        for scalar in exerciseName.lowercased().unicodeScalars {
            hash = hash &* 33 &+ scalar.value
        }
        let steps = UInt32(maxJitterDegrees * 200) + 1          // 1601 steps of 0.01°
        return Double(hash % steps) / 100 - maxJitterDegrees   // -8.00 … +8.00
    }

    // MARK: Strokes

    /// Oldest first, so the newest strokes land on top when drawn in order.
    /// `exerciseGroups` is name → muscle group; matching is case-insensitive
    /// and an exercise with no group is skipped rather than guessed.
    static func strokes(
        sessions: [WorkoutSession],
        activities: [CrossTrainingActivity],
        exerciseGroups: [String: MuscleGroup]
    ) -> [PortraitStroke] {
        var groups: [String: MuscleGroup] = [:]
        for (name, group) in exerciseGroups {
            groups[name.lowercased()] = group
        }

        struct Pending {
            let date: Date
            let angle: Double
            let span: Double
            let width: Double
            let color: Color
        }
        var pending: [Pending] = []

        // First working weight ever logged per lift. One pass oldest to
        // newest, so the baseline is set before any later session reads it.
        var baselines: [String: Double] = [:]

        for session in sessions.sorted(by: { $0.date < $1.date }) {
            for entry in session.sortedEntries where !entry.isSkipped {
                let working = entry.workingSets
                guard !working.isEmpty else { continue }

                let key = entry.exerciseName.lowercased()
                let weight = PlanResolver.workingWeight(of: working) ?? 0
                let first = baselines[key] ?? weight
                if baselines[key] == nil { baselines[key] = weight }

                guard let group = groups[key] else { continue }

                // Bodyweight lifts have no load to compare, so they stay at
                // progress 0 — present, but never bold.
                let progress: Double
                if first <= 0 {
                    progress = 0
                } else {
                    let gain = (weight - first) / max(first, 1)
                    progress = min(max(gain, 0), 0.5) / 0.5
                }

                pending.append(Pending(
                    date: session.date,
                    angle: angle(for: group) + jitter(for: entry.exerciseName),
                    span: min(6 + 3 * Double(working.count), 24),
                    width: 1.2 + 2.8 * progress,
                    color: Color.accent.opacity(0.45 + 0.55 * progress)
                ))
            }
        }

        for activity in activities {
            pending.append(Pending(
                date: activity.date,
                angle: angle(forActivity: activity.type),
                span: 8 + min(activity.duration / 600, 20),
                width: 1.5,
                color: Color.flagAmber.opacity(0.55)
            ))
        }

        guard let firstDate = pending.map(\.date).min(),
              let lastDate = pending.map(\.date).max() else { return [] }
        let range = lastDate.timeIntervalSince(firstDate)

        return pending
            .sorted { $0.date < $1.date }
            .map { item in
                // A single event (or several on one day) has no span of time
                // to place itself on, so it sits at the middle radius.
                let fraction = range > 0 ? item.date.timeIntervalSince(firstDate) / range : 0.5
                return PortraitStroke(
                    radiusFraction: fraction,
                    centerAngleDegrees: item.angle,
                    spanDegrees: item.span,
                    lineWidth: item.width,
                    color: item.color
                )
            }
    }
}

// MARK: - View

/// Draws the strokes. Square; sized by whatever width it is given.
struct TrainingPortraitView: View {
    let strokes: [PortraitStroke]
    var showsLabels: Bool = false

    /// Room kept around the drawing for the muscle names, whether or not they
    /// are showing — so tapping for labels never resizes the portrait.
    static let labelGutter: CGFloat = 26
    static let innerRadiusFraction: CGFloat = 0.16
    static let outerRadiusFraction: CGFloat = 0.94
    static let labelOffset: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let half = max(min(size.width, size.height) / 2 - Self.labelGutter, 1)
            let inner = half * Self.innerRadiusFraction
            let outer = half * Self.outerRadiusFraction

            // The rim. Shown as a guide with the labels, and alone when
            // there is nothing to draw yet — the caption below says why.
            if strokes.isEmpty || showsLabels {
                let rim = CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2)
                context.stroke(
                    Path(ellipseIn: rim),
                    with: .color(Color.tertiaryText.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 5])
                )
            }

            for stroke in strokes {
                let radius = inner + (outer - inner) * CGFloat(stroke.radiusFraction)
                let halfSpan = stroke.spanDegrees / 2
                var path = Path()
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: Angle(degrees: stroke.centerAngleDegrees - halfSpan),
                    endAngle: Angle(degrees: stroke.centerAngleDegrees + halfSpan),
                    clockwise: false
                )
                context.stroke(
                    path,
                    with: .color(stroke.color),
                    style: StrokeStyle(lineWidth: CGFloat(stroke.lineWidth), lineCap: .round)
                )
            }

            if showsLabels {
                drawLabels(in: context, size: size, center: center, radius: outer + Self.labelOffset)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Muscle names just outside the rim at their own angles. Each label is
    /// anchored on the side facing the centre, so it always reads outward,
    /// then nudged back inside the canvas if it would run off the edge.
    private func drawLabels(in context: GraphicsContext, size: CGSize, center: CGPoint, radius: CGFloat) {
        for group in MuscleGroup.allCases {
            let radians = TrainingPortrait.angle(for: group) * .pi / 180
            let dx = CGFloat(cos(radians))
            let dy = CGFloat(sin(radians))
            let point = CGPoint(x: center.x + radius * dx, y: center.y + radius * dy)

            let text = context.resolve(
                Text(group.displayName)
                    .font(.caption2)
                    .foregroundStyle(Color.tertiaryText)
            )
            let textSize = text.measure(in: size)

            var origin = CGPoint(
                x: point.x - textSize.width * (0.5 - dx / 2),
                y: point.y - textSize.height * (0.5 - dy / 2)
            )
            origin.x = min(max(origin.x, 0), size.width - textSize.width)
            origin.y = min(max(origin.y, 0), size.height - textSize.height)

            context.draw(text, in: CGRect(origin: origin, size: textSize))
        }
    }
}

// MARK: - Sharing

/// The portrait as a bitmap, for the share sheet. Opaque cream background
/// with a margin so it reads as a picture, not a cutout, wherever it lands.
@MainActor
func portraitImage(strokes: [PortraitStroke], size: CGFloat = 360, showsLabels: Bool = false) -> UIImage? {
    let renderer = ImageRenderer(
        content: TrainingPortraitView(strokes: strokes, showsLabels: showsLabels)
            .frame(width: size, height: size)
            .padding(24)
            .background(Color.appBackground)
    )
    renderer.scale = 3
    renderer.isOpaque = true
    return renderer.uiImage
}
