import SwiftUI
import UIKit

// MARK: - Model

/// One arc on one ring: a muscle group trained in one session.
struct RingArc: Equatable {
    var centerAngleDegrees: Double
    var spanDegrees: Double
    /// 0...1, already combining progress and age.
    var opacity: Double
}

/// One lifting session, drawn as one concentric ring.
struct PortraitRing: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let title: String
    let sets: Int
    let arcs: [RingArc]
    /// Lifts in this session at a heavier working weight than they started.
    let liftsUp: Int
}

/// A non-lifting workout, drawn as a tan hairline between the rings.
struct PortraitHairline: Equatable {
    /// Position on the ring axis: 0 is the first ring, 1 the second, and so
    /// on. Fractional values sit between rings; negative ones predate the
    /// first lifting session and are compressed into the centre.
    var ringPosition: Double
    var centerAngleDegrees: Double
    var spanDegrees: Double
}

struct PortraitModel: Equatable {
    var rings: [PortraitRing]
    var hairlines: [PortraitHairline]

    static let empty = PortraitModel(rings: [], hairlines: [])
    var isEmpty: Bool { rings.isEmpty && hairlines.isEmpty }
}

// MARK: - Encoding

/// Turns training history into rings. Three rules, and they are the whole
/// explanation:
///
/// 1. Every session adds a ring. Rings grow outward in the order you
///    trained, not by the calendar — a month off is not a hole, it is just
///    the next ring. The disc gets bigger the more you lift.
/// 2. Angle is muscle. Upper body on top, legs below, pushing on the right,
///    pulling on the left. Within a ring, each muscle group you hit is one
///    arc, wider the more sets you did.
/// 3. Bold is progress. An arc for a lift still at its first-ever weight is
///    pale; one at +50% is full forest green. Older rings fade a little so
///    the newest work reads first.
///
/// Climbs, runs and rides are tan hairlines slotted between the rings by
/// date, on the horizontal axis, where no muscle group lives. Texture, not
/// mass — this is a portrait of the lifting.
enum TrainingPortrait {

    // MARK: Angles

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

    static func angle(forActivity type: String) -> Double {
        switch type {
        case "running", "cycling", "hiking", "swimming", "rowing", "walking": return 180
        default: return 0
        }
    }

    // MARK: Strokes

    /// `exerciseGroups` is name → muscle group from the library. Names it
    /// doesn't know fall back to a keyword guess, so "Hanging Leg Raises"
    /// with an s still lands on core instead of vanishing.
    static func model(
        sessions: [WorkoutSession],
        activities: [CrossTrainingActivity],
        exerciseGroups: [String: MuscleGroup]
    ) -> PortraitModel {
        var groups: [String: MuscleGroup] = [:]
        for (name, group) in exerciseGroups { groups[name.lowercased()] = group }

        let ordered = sessions
            .filter { session in
                session.entries.contains { !$0.isSkipped && !$0.workingSets.isEmpty }
            }
            .sorted { $0.date < $1.date }
        let count = ordered.count

        // First working weight per lift, oldest first, so a later session
        // compares against where that lift started.
        var baselines: [String: Double] = [:]
        var rings: [PortraitRing] = []

        for (index, session) in ordered.enumerated() {
            var setsByGroup: [MuscleGroup: Int] = [:]
            var progressByGroup: [MuscleGroup: [Double]] = [:]
            var liftsUp = 0
            var totalSets = 0

            for entry in session.sortedEntries where !entry.isSkipped {
                let working = entry.workingSets
                guard !working.isEmpty else { continue }
                let key = entry.exerciseName.lowercased()
                let weight = PlanResolver.workingWeight(of: working) ?? 0
                let first = baselines[key] ?? weight
                if baselines[key] == nil { baselines[key] = weight }

                guard let group = groups[key] ?? MuscleGroupGuess.group(forName: entry.exerciseName) else {
                    continue
                }

                let progress: Double
                if first <= 0 {
                    progress = 0
                } else {
                    progress = min(max((weight - first) / first, 0), 0.5) / 0.5
                }
                if weight > first + 0.01 { liftsUp += 1 }

                setsByGroup[group, default: 0] += working.count
                progressByGroup[group, default: []].append(progress)
                totalSets += working.count
            }

            // Newest ring at full strength, the oldest at 60%.
            let age = count > 1 ? Double(index) / Double(count - 1) : 1
            let ageScale = 0.6 + 0.4 * age

            let arcs = setsByGroup.map { group, sets -> RingArc in
                let progress = progressByGroup[group].map { $0.reduce(0, +) / Double($0.count) } ?? 0
                return RingArc(
                    centerAngleDegrees: angle(for: group),
                    spanDegrees: min(10 + 5 * Double(sets), 48),
                    opacity: min(1, max(0.3, (0.4 + 0.6 * progress) * ageScale))
                )
            }
            .sorted { $0.centerAngleDegrees < $1.centerAngleDegrees }

            rings.append(PortraitRing(
                id: session.id,
                date: session.date,
                title: session.displayName,
                sets: totalSets,
                arcs: arcs,
                liftsUp: liftsUp
            ))
        }

        // Cross-training slots between the rings by date. Before the first
        // session it compresses into the centre; after the last it sits
        // just outside the newest ring.
        let dates = rings.map(\.date)
        let hairlines = activities.map { activity -> PortraitHairline in
            PortraitHairline(
                ringPosition: ringPosition(for: activity.date, sessionDates: dates),
                centerAngleDegrees: angle(forActivity: activity.type),
                spanDegrees: 10 + min(activity.duration / 600, 25)
            )
        }

        return PortraitModel(rings: rings, hairlines: hairlines)
    }

    /// Piecewise-linear date → ring axis. Between two sessions the position
    /// interpolates by date; outside them it is clamped to a half-ring
    /// either side so cardio never dictates the size of the disc.
    static func ringPosition(for date: Date, sessionDates: [Date]) -> Double {
        guard let first = sessionDates.first, let last = sessionDates.last else { return 0 }
        if date <= first {
            let span = max(first.timeIntervalSince(date), 0)
            return -min(0.5, span / (90 * 86_400) * 0.5)   // 90 days before → -0.5
        }
        if date >= last {
            let span = last.timeIntervalSince(date) * -1
            return Double(sessionDates.count - 1) + min(0.5, span / (30 * 86_400) * 0.5)
        }
        for i in 1..<sessionDates.count where date <= sessionDates[i] {
            let a = sessionDates[i - 1], b = sessionDates[i]
            let total = b.timeIntervalSince(a)
            let t = total > 0 ? date.timeIntervalSince(a) / total : 0.5
            return Double(i - 1) + t
        }
        return Double(sessionDates.count - 1)
    }
}

// MARK: - Name → muscle group guess

/// Last resort for an exercise the library doesn't know. Ordered so the
/// ambiguous words resolve sensibly: "leg press" and "shoulder press" are
/// matched before "press" means chest, "leg curl" before "curl" means biceps.
enum MuscleGroupGuess {
    private static let rules: [(MuscleGroup, [String])] = [
        (.calves, ["calf", "calves"]),
        (.hamstrings, ["hamstring", "leg curl", "rdl", "romanian", "deadlift", "nordic", "good morning", "ham raise"]),
        (.quads, ["squat", "lunge", "leg press", "leg extension", "step up", "step-up", "sissy", "pistol"]),
        (.glutes, ["glute", "hip thrust", "kickback", "bridge", "swing", "pull through", "pull-through", "hyperextension", "abduct"]),
        (.core, ["plank", "crunch", "leg raise", "dead bug", "pallof", "woodchop", "carry", "sit-up", "situp", "hollow", "rollout", "ab wheel", "ab ", "abs", "oblique", "russian twist", "knee raise", "l-sit"]),
        (.forearms, ["wrist", "reverse curl", "grip", "farmer"]),
        (.back, ["row", "pulldown", "pull-down", "pull-up", "pullup", "pull up", "chin", "lat ", "shrug", "face pull", "pullover", "rack pull"]),
        (.shoulders, ["shoulder", "lateral raise", "lat raise", "rear delt", "overhead press", "ohp", "arnold", "front raise", "upright row", "y-raise", "y raise", "military"]),
        (.triceps, ["tricep", "pushdown", "push-down", "skull", "dip", "close grip", "jm press", "kickback"]),
        (.biceps, ["curl"]),
        (.chest, ["bench", "chest", "fly", "flye", "push-up", "pushup", "push up", "pec", "incline press", "decline", "floor press", "landmine", "svend"]),
    ]

    static func group(forName name: String) -> MuscleGroup? {
        let lower = " " + name.lowercased() + " "
        for (group, keywords) in rules where keywords.contains(where: { lower.contains($0) }) {
            return group
        }
        return nil
    }
}

// MARK: - View

/// Draws the rings. Square; sized by whatever width it is given.
///
/// No rim, no labels, no axis. Press and hold to see the muscle names and,
/// as you move, the session under your finger.
struct TrainingPortraitView: View {
    let model: PortraitModel
    var showsLabels: Bool = false
    /// Ring under the finger while pressing — drawn at full strength with
    /// the rest dimmed so it is unmistakable.
    var highlightedRing: Int? = nil

    static let innerRadiusFraction: CGFloat = 0.12
    static let outerRadiusFraction: CGFloat = 0.96
    static let labelGutter: CGFloat = 22

    /// Geometry shared by the canvas and the hit-test.
    struct Layout {
        let center: CGPoint
        let inner: CGFloat
        let outer: CGFloat
        let ringCount: Int

        /// Distance between ring centres. One ring sits at the midpoint.
        var spacing: CGFloat {
            ringCount > 1 ? (outer - inner) / CGFloat(ringCount) : (outer - inner)
        }

        func radius(forRingPosition position: Double) -> CGFloat {
            guard ringCount > 0 else { return (inner + outer) / 2 }
            if ringCount == 1 { return (inner + outer) / 2 + CGFloat(position) * spacing * 0.5 }
            return inner + spacing * (CGFloat(position) + 0.5)
        }

        /// Band thickness for a ring: most of the spacing, leaving a sliver
        /// of paper between neighbours, and never so thin it disappears.
        var ringThickness: CGFloat { max(2.5, min(spacing * 0.72, 22)) }

        func ringIndex(at point: CGPoint) -> Int? {
            guard ringCount > 0 else { return nil }
            let d = hypot(point.x - center.x, point.y - center.y)
            let raw = Int(((d - inner) / spacing).rounded(.down))
            guard raw >= 0, raw < ringCount else { return nil }
            return raw
        }
    }

    static func layout(in size: CGSize, ringCount: Int, labelled: Bool) -> Layout {
        let gutter = labelled ? labelGutter : 6
        let half = max(min(size.width, size.height) / 2 - gutter, 1)
        return Layout(
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            inner: half * innerRadiusFraction,
            outer: half * outerRadiusFraction,
            ringCount: ringCount
        )
    }

    var body: some View {
        Canvas { context, size in
            // Gutter is constant so a press never resizes the disc.
            let layout = Self.layout(in: size, ringCount: model.rings.count, labelled: true)

            if model.isEmpty {
                // Nothing yet: a single faint ring where the first one will go.
                let r = layout.radius(forRingPosition: 0)
                let rect = CGRect(x: layout.center.x - r, y: layout.center.y - r, width: r * 2, height: r * 2)
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(Color.tertiaryText.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 5])
                )
                return
            }

            // Hairlines first so lifting sits on top of them.
            for line in model.hairlines {
                let radius = layout.radius(forRingPosition: line.ringPosition)
                guard radius > 2 else { continue }
                drawArc(
                    in: context, layout: layout, radius: radius,
                    centerAngle: line.centerAngleDegrees, span: line.spanDegrees,
                    width: 1,
                    color: Color.flagAmber.opacity(highlightedRing == nil ? 0.5 : 0.2)
                )
            }

            for (index, ring) in model.rings.enumerated() {
                let radius = layout.radius(forRingPosition: Double(index))
                let dim: Double
                if let highlightedRing {
                    dim = highlightedRing == index ? 1.15 : 0.3
                } else {
                    dim = 1
                }
                for arc in ring.arcs {
                    drawArc(
                        in: context, layout: layout, radius: radius,
                        centerAngle: arc.centerAngleDegrees, span: arc.spanDegrees,
                        width: layout.ringThickness,
                        color: Color.accent.opacity(min(1, arc.opacity * dim))
                    )
                }
            }

            if showsLabels {
                drawLabels(in: context, size: size, layout: layout)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func drawArc(
        in context: GraphicsContext, layout: Layout, radius: CGFloat,
        centerAngle: Double, span: Double, width: CGFloat, color: Color
    ) {
        var path = Path()
        path.addArc(
            center: layout.center,
            radius: radius,
            startAngle: Angle(degrees: centerAngle - span / 2),
            endAngle: Angle(degrees: centerAngle + span / 2),
            clockwise: false
        )
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// Muscle names just outside the outermost ring, anchored on the side
    /// facing the centre so they read outward, nudged inside the canvas.
    private func drawLabels(in context: GraphicsContext, size: CGSize, layout: Layout) {
        let radius = layout.outer + 4
        for group in MuscleGroup.allCases {
            let radians = TrainingPortrait.angle(for: group) * .pi / 180
            let dx = CGFloat(cos(radians)), dy = CGFloat(sin(radians))
            let point = CGPoint(x: layout.center.x + radius * dx, y: layout.center.y + radius * dy)

            let text = context.resolve(
                Text(group.displayName)
                    .font(.caption2)
                    .foregroundStyle(Color.secondaryText)
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
func portraitImage(model: PortraitModel, size: CGFloat = 360) -> UIImage? {
    let renderer = ImageRenderer(
        content: TrainingPortraitView(model: model)
            .frame(width: size, height: size)
            .padding(24)
            .background(Color.appBackground)
    )
    renderer.scale = 3
    renderer.isOpaque = true
    return renderer.uiImage
}
