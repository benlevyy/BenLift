// TrainingKnowledgeBase.swift
// BenLift
//
// Evidence-based training knowledge for Claude system prompt.
// This is included (with cache_control) in every API call so Claude
// makes programming decisions grounded in current research rather than
// generic LLM training data.

import Foundation

enum TrainingKnowledgeBase {

    /// The cached portion of the system prompt. ~2500 tokens.
    /// Covers ONLY what Claude needs to make the 5 coaching decisions:
    ///   1. Program design  2. Daily plan  3. Mid-workout adapt
    ///   4. Post-workout analysis  5. Weekly review
    static let knowledgeBase: String = """
    # Training Science Reference (for coaching decisions)

    ## Progressive Overload
    Use double progression as the default scheme: increase reps within a target range, \
    then increase load when the top of the range is hit for all prescribed sets across \
    two consecutive sessions. This is validated for both strength and hypertrophy \
    (Chaves et al. 2024 — load vs rep progression produce equivalent outcomes). \
    For compounds, increase by 5 lbs; for isolation, 2.5–5 lbs.

    ## Proximity to Failure
    The productive zone is 1–3 RIR (reps in reserve). Training to absolute failure \
    provides only trivial additional hypertrophy benefit but significantly worsens \
    recovery and perceived exertion (Refalo et al. 2023 meta-analysis; Robinson et al. \
    2024 dose-response meta-regression). A set logged at X.5 reps (failed final rep) \
    means 0 RIR — that's fine occasionally but should not be the norm for every set. \
    If a user consistently logs failed reps, the weight is too heavy or fatigue is \
    accumulating.

    ## Volume (Weekly Sets Per Muscle Group)
    - 10–20 direct sets/muscle/week is the productive range for most people.
    - Below ~6 sets is suboptimal for growth; above ~30 fractional sets shows \
      undetectable additional benefit (Pelland et al. 2026 meta-regression, 67 studies).
    - Start mesocycles near MEV (~8–10 sets), ramp by 1–2 sets/week, deload when \
      approaching systemic MRV (Israetel volume landmarks framework).
    - Count indirect volume at ~0.5x: e.g. bench press counts as ~1 set chest + \
      ~0.5 set triceps + ~0.5 set front delts.

    ## Rep Ranges
    Hypertrophy occurs across a wide loading spectrum (~30–85%+ 1RM) as long as sets \
    are within 1–3 RIR (Schoenfeld et al. 2017, 2021). The 6–12 range is a practical \
    sweet spot — not physiologically special, but it balances joint stress (heavy loads) \
    and discomfort (very high reps). Use heavier ranges (4–6) for primary compounds \
    targeting strength, moderate (8–12) for secondary compounds, and higher (12–20) \
    for isolation and fatigue-sensitive movements.

    ## Exercise Selection Principles
    1. **Stretch-position exercises are superior or equal for hypertrophy.** Prioritize \
       exercises that load the muscle at long lengths (Maeo 2021, 2023; Kassiano 2023; \
       Wolf 2025). Specific implications:
       - Overhead tricep extensions > pushdowns (~40% more total triceps growth, Maeo 2023)
       - Incline curls > concentration curls (long head stretch, incline curl study 2023)
       - Seated leg curl > lying leg curl (+14% vs +9% hamstring growth, Maeo 2021)
       - Deep squats > partial squats for glute/adductor involvement (Kubo 2019)
    2. **Compounds are necessary but not sufficient.** Bench press under-stimulates \
       lateral delts (~35% activation). Squats under-stimulate rectus femoris vs leg \
       extensions (Zabaleta-Korta 2021). Add targeted isolation work.
    3. **Free weights = machines = cables for hypertrophy** when effort is equalized \
       (Haugen et al. 2023 meta-analysis). Choose based on resistance profile and \
       individual preference.
    4. **Rotate isolation/accessory exercises every 2–4 weeks** for regional hypertrophy \
       benefits (Baz-Valle 2019). Keep primary compounds stable for overload tracking.

    ## Exercise Order
    Exercise order does NOT significantly affect hypertrophy but DOES affect strength \
    in the exercise performed first (Nunes et al. 2021 meta-analysis). Always program \
    the primary compound first. Place lagging/priority muscles earlier in the session.

    ## Rest Periods
    - Compounds targeting strength: 3+ minutes between sets.
    - Hypertrophy work: ≥90 seconds. No meaningful additional benefit above 90s for \
      growth (Singer et al. 2024 Bayesian meta-analysis).
    - Default rest timer: 2:30 (good middle ground).

    ## Autoregulation & Readiness Adjustment
    RPE/RIR-based autoregulation outperforms fixed percentage-based programming for \
    strength gains (Huang et al. 2025 network meta-analysis: APRE 93% SUCRA vs PBRT \
    13%). When adjusting for readiness:
    - **Feeling 1–2 (wrecked):** Drop working weight 10–15%, reduce sets by 1 per \
      exercise, increase rest periods. A lighter session still drives adaptation.
    - **Feeling 3 (average):** Run the plan as prescribed.
    - **Feeling 4–5 (great):** Allow pushing to top of rep range or add 1 set to \
      primary compound. Do NOT increase weight beyond the plan — let the progression \
      scheme handle that.
    - **Poor sleep (<6h):** Expect ~18% reduced MPS (Lamon 2021) and reduced compound \
      strength (Easow 2025). Reduce intensity on compounds, maintain isolation volume. \
      Flag in post-workout analysis.
    - **Low HRV (>1 SD below 7-day rolling mean):** Treat as a caution signal, not a \
      hard stop. Reduce top-set intensity by 5–10%. HRV is NOT validated for \
      strength-specific readiness (Addleman 2024), so never skip a session based on \
      HRV alone.

    ## Deload Protocol
    - **Frequency:** Every 4–6 weeks, or reactively when performance declines across \
      2+ sessions (Rogerson et al. 2024 survey; Bell et al. 2023 Delphi consensus).
    - **How:** Reduce volume (sets) by 30–50%. Maintain or slightly reduce intensity. \
      Keep exercise selection the same. Maintain training frequency.
    - **Duration:** 5–7 days (one week).
    - **Do NOT use complete cessation** — active deloads preserve strength better than \
      total rest (Coleman et al. 2024).

    ## Periodization
    When volume is equated, no periodization model is definitively superior to another \
    (Moesgaard 2022). For this app, use a simple linear volume ramp within mesocycles: \
    start at MEV, add sets weekly, deload, repeat. Undulating rep ranges across the \
    week (heavier first session, lighter second) is a practical way to manage fatigue \
    on 2x/week frequency.

    ## Frequency
    Train each muscle at least 2x/week. Frequency is primarily a volume distribution \
    tool for hypertrophy — it has negligible independent effect once volume is equated \
    (Pelland 2026). For strength, frequency has a small independent positive effect \
    (motor pattern practice).

    ## Post-Workout Analysis Rules
    - A set at X.5 reps means the user attempted and failed the last rep. This is \
      0 RIR. Acknowledge the effort but flag if it's happening every set.
    - A rep PR = completing more reps at a given weight than any previous session. \
      A weight PR = completing the target rep range at a new highest weight.
    - Use Epley formula for e1RM: weight × (1 + reps/30). Track trends, not \
      single-session spikes.
    - Volume compliance: compare actual weekly sets per muscle group against the \
      program's targets. Flag muscles that are >20% under target.
    - DOMS is a poor recovery indicator (Damas 2018). Never tell a user to skip \
      a muscle group because it's sore. Better indicators: performance trends, \
      sleep data, HRV trends, subjective readiness.

    ## Weekly Review Decision Framework
    - **Plateau detection:** If e1RM has not increased over 3+ weeks on a compound, \
      suggest one of: (a) exercise variation swap, (b) rep range change, (c) check \
      recovery factors before blaming programming.
    - **Volume compliance:** If a muscle group is consistently >20% under target, \
      suggest adding an exercise or set. If consistently over by >30%, check if the \
      user is compensating for poor stimulus elsewhere.
    - **Sleep trend:** Declining sleep over 2+ weeks correlates with stalled progress. \
      Flag it prominently and suggest reducing session count before reducing per-session \
      volume.
    - **Program adjustments:** Be conservative. Suggest max 1–2 changes per week. \
      Never overhaul the program based on one bad week.
    """
}
