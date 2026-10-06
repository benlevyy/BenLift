import Foundation

/// The tool surface Claude gets in chat. Every one of these mutates today's
/// plan directly (or reads history) — none of them regenerate the whole plan.
/// That's the difference between "swap the bench" landing as a single edit
/// and the old flow, where any change meant asking for a fresh plan and
/// hoping the rest survived.
///
/// Deliberately NOT using `strict: true`. Strict schemas need every optional
/// field modelled as nullable, and a mismatch there fails the whole call at
/// runtime. The executor validates defensively instead, which degrades to a
/// readable error message rather than a rejected request.
enum ChatTools {

    static let definitions: [[String: Any]] = [
        tool(
            name: "replace_exercise",
            description: """
            Swap one lift in today's plan for a different one. Use when the user \
            can't do a movement (equipment busy or missing, a joint complaining) \
            or wants a different variation. Carries over sets and reps unless you \
            override them, and picks a sensible starting load for the new lift. \
            The result says whether the day's muscle coverage changed.
            """,
            properties: [
                "current_name": string("Exact name of the lift to replace, as it appears in the plan."),
                "new_name": string("Name of the replacement lift."),
                "sets": integer("Working sets. Omit to keep the current count."),
                "target_reps": string("Rep range, e.g. \"8-12\". Omit to keep the current one."),
                "weight": number("Starting load in lbs. Omit to let the app pick from history.")
            ],
            required: ["current_name", "new_name"]
        ),

        tool(
            name: "add_exercise",
            description: """
            Add a lift to today's plan. Use when the user asks for more work on \
            something specific, or wants an accessory they usually do. Without \
            `after` the lift goes last, which is right for isolation work and \
            wrong for a compound — place those with `after`. The result reports \
            the plan's new set count, time and coverage.
            """,
            properties: [
                "name": string("Name of the lift to add."),
                "sets": integer("Working sets."),
                "target_reps": string("Rep range, e.g. \"10-15\"."),
                "weight": number("Load in lbs. Omit to let the app pick from history."),
                "after": string("Name of the lift this should follow. Omit to append at the end.")
            ],
            required: ["name", "sets", "target_reps"]
        ),

        tool(
            name: "remove_exercise",
            description: """
            Drop a lift from today's plan. Use when the user is short on time, \
            wants to cut volume, or can't do the movement at all. If they say \
            never to program it again, also call create_rule.
            """,
            properties: [
                "name": string("Exact name of the lift to remove.")
            ],
            required: ["name"]
        ),

        tool(
            name: "set_load",
            description: """
            Change the numbers on a lift already in the plan — weight, sets, or \
            rep range. Use for "back the bench off ten pounds" or "make it four \
            sets". Only pass the fields that change.
            """,
            properties: [
                "name": string("Exact name of the lift to adjust."),
                "weight": number("New load in lbs."),
                "sets": integer("New working-set count."),
                "target_reps": string("New rep range, e.g. \"5-8\".")
            ],
            required: ["name"]
        ),

        tool(
            name: "reorder",
            description: """
            Move a lift to a different position in the plan. Position is \
            1-based, so 1 puts it first. Use when the user wants to lead with \
            a movement while they're fresh.
            """,
            properties: [
                "name": string("Exact name of the lift to move."),
                "position": integer("1-based target position in the plan.")
            ],
            required: ["name", "position"]
        ),

        tool(
            name: "create_rule",
            description: """
            Record a durable preference that should shape every future plan, not \
            just today's. Use when the user says something like "never program \
            upright rows", "my dumbbells only go to 70", or "remember that". \
            Do NOT use it for one-off changes about today — those are just edits.
            """,
            properties: [
                "kind": enumString(
                    "Which kind of rule this is.",
                    ["exerciseOut", "preferOver", "equipment", "programming"]
                ),
                "subject": string("The lift, equipment, or preference the rule is about."),
                "target": string("For preferOver only: what to use instead of subject."),
                "reason": string("Short reason, shown to the user in Settings.")
            ],
            required: ["kind", "subject"]
        ),

        tool(
            name: "set_focus",
            description: """
            Change what TODAY trains, overriding the split rotation — "let's \
            do legs today instead" is one call, and today's plan is rebuilt \
            from the last session of that day type. Only for changing the day \
            type, never for swapping a single lift. There is no future-day \
            version: tomorrow is decided tomorrow.
            """,
            properties: [
                "muscle_groups": [
                    "type": "array",
                    "description": "Muscle groups to train today.",
                    "items": ["type": "string", "enum": MuscleGroup.allCases.map(\.rawValue)]
                ]
            ],
            required: ["muscle_groups"]
        ),

        tool(
            name: "plan_activity",
            description: """
            Record cross-training the user is doing on a future day — "I'm \
            climbing tomorrow", "long run Saturday". HealthKit only knows \
            what already happened, so this is the only way the app learns \
            about it in advance. Use it whenever they mention a future \
            session, even in passing. Set cancel true to remove one they've \
            called off. This is for non-lifting activity only; lifting days \
            come from the split rotation.
            """,
            properties: [
                "activity_type": enumString(
                    "What they're doing.",
                    PlannedActivity.knownTypes
                ),
                "days_ahead": integer("1 for tomorrow, 2 for the day after, and so on."),
                "note": string("Anything they said about it — \"long one\", \"just easy miles\"."),
                "cancel": boolean("True to remove a previously recorded plan for that day.")
            ],
            required: ["activity_type", "days_ahead"]
        ),

        tool(
            name: "query_history",
            description: """
            Look up what the user actually did. Use before answering questions \
            about progress, stalls, or volume — never guess at numbers. Returns \
            logged sets with dates.
            """,
            properties: [
                "exercise": string("Limit to one lift by name. Omit for all lifts."),
                "muscle_group": enumString(
                    "Limit to one muscle group.",
                    MuscleGroup.allCases.map(\.rawValue)
                ),
                "days": integer("How far back to look. Defaults to 28.")
            ],
            required: []
        )
    ]

    /// Tools available when reviewing a past session. Editing a plan from
    /// three weeks ago is meaningless, so the plan-mutating tools are gone —
    /// but noticing "I always bail on this one, stop programming it" while
    /// looking at an old workout is exactly when a rule is worth writing.
    static let reviewToolNames: Set<String> = ["query_history", "create_rule"]

    static var reviewDefinitions: [[String: Any]] {
        definitions.filter { definition in
            guard let name = definition["name"] as? String else { return false }
            return reviewToolNames.contains(name)
        }
    }

    // MARK: - Schema builders

    private static func tool(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ]
        ]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func enumString(_ description: String, _ values: [String]) -> [String: Any] {
        ["type": "string", "description": description, "enum": values]
    }
}
