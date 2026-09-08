import Foundation

// MARK: - Protocol

protocol CoachServiceProtocol: Sendable {
    func recommendFocus(systemPrompt: String, userPrompt: String, model: String) async throws -> RecoveryRecommendation
    func generateProgram(systemPrompt: String, userPrompt: String, model: String) async throws -> ProgramResponse
    func generateDailyPlan(systemPrompt: String, userPrompt: String, model: String) async throws -> DailyPlanResponse
    func recommendAndPlan(systemPrompt: String, userPrompt: String, model: String) async throws -> RecommendAndPlanResponse
    func streamRecommendAndPlan(systemPrompt: String, userPrompt: String, model: String) -> AsyncThrowingStream<RecommendAndPlanStreamEvent, Error>
    func adaptMidWorkout(systemPrompt: String, userPrompt: String, model: String) async throws -> MidWorkoutAdaptResponse
    func analyzePostWorkout(systemPrompt: String, userPrompt: String, model: String) async throws -> PostWorkoutAnalysisResponse
    func generateWeeklyReview(systemPrompt: String, userPrompt: String, model: String) async throws -> WeeklyReviewResponse
    func refreshIntelligence(systemPrompt: String, userPrompt: String, model: String) async throws -> IntelligenceRefreshResponse

    // MARK: - v5 prompt suite (calendar-driven planner)
    //
    // These three methods own template substitution + request shape internally
    // — callers don't pass system/user prompts, just the structured input.
    // `dailyPlanV5` uses extended thinking; `iterate` and `bootstrap` are cheap
    // non-thinking calls.
    func dailyPlanV5(input: PlannerInput, model: String) async throws -> DailyPlanV5Response
    func streamDailyPlanV5(input: PlannerInput, model: String) -> AsyncThrowingStream<DailyPlanV5StreamEvent, Error>
    func iterate(currentPlan: DailyPlanResponse, userRequest: String, plannerInput: PlannerInput, model: String) async throws -> IterateResponse
    func bootstrap(input: BootstrapInput, model: String) async throws -> BootstrapResponse
}

/// Events emitted while a `recommendAndPlan` call is streaming. Order is
/// roughly: `recommendation` (~1.5s in) → `exercise(...)` repeatedly as
/// each one finishes generating (~every 300–600ms) → `complete` at the
/// very end with the full decoded response. Consumers should drive UI
/// from the per-event payloads and use `complete` for final state
/// (planAdjustments reset, snapshot persistence, etc.).
enum RecommendAndPlanStreamEvent: Sendable {
    case recommendation(RecoveryRecommendation)
    case strategy(String)
    case exercise(PlannedExercise)
    case complete(RecommendAndPlanResponse)
}

/// Streaming events for the v5 planner path.
///
/// v5 uses extended thinking, which the Anthropic SSE stream surfaces via
/// `thinking_delta` events BEFORE any visible text starts. We project that
/// directly to a `.thinking` phase so the Today UI can show "Coach is
/// reasoning..." instead of a generic spinner. Once `content_block_delta`
/// text events arrive, we emit `.drafting` once. The `.complete` event is
/// the canonical final state and carries the parsed v5 response.
///
/// We don't emit per-field events (recommendation / exercise) the way the
/// legacy v1 stream does — v5's response is a single JSON object the
/// consumer wants atomically. Per-field would require a v5-specific
/// scanner; the cost-benefit doesn't pencil out yet.
enum DailyPlanV5StreamEvent: Sendable {
    case thinking
    case drafting
    case complete(DailyPlanV5Response)
}

// MARK: - Errors

enum ClaudeError: Error, LocalizedError {
    case invalidAPIKey
    case networkError(Error)
    case rateLimited
    case malformedResponse(String)
    case serverError(Int, String)
    case noContent

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Invalid API key. Check Settings."
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .rateLimited: return "Rate limited. Try again in a moment."
        case .malformedResponse(let detail): return "Couldn't parse AI response: \(detail)"
        case .serverError(let code, let body): return "Server error (\(code)): \(body.prefix(200))"
        case .noContent: return "Empty response from AI."
        }
    }
}

// MARK: - Claude API Request/Response Types

private struct ClaudeRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: [SystemBlock]
    let messages: [ClaudeMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

/// A system prompt content block. The first block (knowledge base) gets
/// `cache_control: {"type": "ephemeral"}` so Anthropic caches it across calls
/// (~90% cost reduction on the cached portion after the first request).
struct SystemBlock: Encodable {
    let type: String
    let text: String
    let cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }

    struct CacheControl: Encodable {
        let type: String
    }

    static func cached(_ text: String) -> SystemBlock {
        SystemBlock(type: "text", text: text, cacheControl: CacheControl(type: "ephemeral"))
    }

    static func dynamic(_ text: String) -> SystemBlock {
        SystemBlock(type: "text", text: text, cacheControl: nil)
    }
}

private struct ClaudeMessage: Encodable {
    let role: String
    let content: String
}

/// The iterate prompt's `INPUT_JSON` slot is a SUBSET of PlannerInput —
/// just strength, rituals, and constraints. The other PlannerInput fields
/// (recentDays, recovery, etc.) aren't needed for single-exercise edits and
/// would bloat the prompt.
private struct IterateInputSubset: Encodable {
    let strength: [String: PlannerInput.StrengthEntry]
    let rituals: [String]
    let constraints: PlannerInput.Constraints
}

private struct ClaudeAPIResponse: Decodable {
    let content: [ContentBlock]
    let usage: Usage?

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }
}

// MARK: - Live Service

actor ClaudeCoachService: CoachServiceProtocol {
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"
    private let session = URLSession.shared

    func recommendFocus(systemPrompt: String, userPrompt: String, model: String) async throws -> RecoveryRecommendation {
        print("[BenLift/API] recommendFocus called with model: \(model)")
        return try await sendRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, maxTokens: 2048, label: "recommendFocus")
    }

    func generateProgram(systemPrompt: String, userPrompt: String, model: String) async throws -> ProgramResponse {
        print("[BenLift/API] generateProgram called with model: \(model)")
        return try await sendRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, maxTokens: 4096, label: "generateProgram")
    }

    func generateDailyPlan(systemPrompt: String, userPrompt: String, model: String) async throws -> DailyPlanResponse {
        print("[BenLift/API] generateDailyPlan called with model: \(model)")
        return try await sendRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, maxTokens: 2048, label: "generateDailyPlan")
    }

    func recommendAndPlan(systemPrompt: String, userPrompt: String, model: String) async throws -> RecommendAndPlanResponse {
        print("[BenLift/API] recommendAndPlan called with model: \(model)")
        return try await sendRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, maxTokens: 3072, label: "recommendAndPlan")
    }

    /// Streaming variant of `recommendAndPlan`. Emits the recommendation as
    /// soon as its prefix is parseable (~1.5s in on Haiku), then each
    /// exercise as the model finishes writing it (~every 300–600ms).
    /// Falls back to a single `.complete` event on the trailing decode if
    /// scanner missed anything (defensive — the final full-buffer parse
    /// is the source of truth for any consumer that wants atomic state).
    nonisolated func streamRecommendAndPlan(
        systemPrompt: String,
        userPrompt: String,
        model: String
    ) -> AsyncThrowingStream<RecommendAndPlanStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: ClaudeError.noContent)
                    return
                }
                do {
                    try await self.runStream(
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        model: model,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        continuation: AsyncThrowingStream<RecommendAndPlanStreamEvent, Error>.Continuation
    ) async throws {
        guard let apiKey = KeychainService.load(key: KeychainService.apiKeyKey), !apiKey.isEmpty else {
            throw ClaudeError.invalidAPIKey
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60

        // Same payload as the non-streaming call, plus stream:true. We
        // can't reuse `ClaudeRequest` because Encodable doesn't have a
        // way to add an extra key; build a dictionary instead.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 3072,
            "stream": true,
            "system": [
                ["type": "text", "text": TrainingKnowledgeBase.knowledgeBase, "cache_control": ["type": "ephemeral"]],
                ["type": "text", "text": systemPrompt],
            ],
            "messages": [
                ["role": "user", "content": userPrompt],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[BenLift/API] → streamRecommendAndPlan: model=\(model)")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.serverError(0, "Not an HTTP response")
        }
        guard http.statusCode == 200 else {
            // Read remaining bytes for the error body.
            var errorBody = Data()
            for try await byte in bytes { errorBody.append(byte) }
            let body = String(data: errorBody, encoding: .utf8) ?? ""
            print("[BenLift/API] ❌ Stream error \(http.statusCode): \(body)")
            if http.statusCode == 401 { throw ClaudeError.invalidAPIKey }
            if http.statusCode == 429 { throw ClaudeError.rateLimited }
            throw ClaudeError.serverError(http.statusCode, body)
        }

        var textBuffer = ""
        let scanner = StreamingPlanScanner()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for try await line in bytes.lines {
            // Anthropic SSE alternates `event:` and `data:` lines, separated
            // by blank lines. We only care about `data:` lines whose payload
            // is a content_block_delta carrying text.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }

            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let type = event["type"] as? String
            if type == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                textBuffer += text
                scanner.feed(textBuffer)

                // Recommendation — emit once, as soon as the prefix is
                // parseable. The scanner returns the JSON substring; we
                // attempt decode here so a malformed prefix doesn't kill
                // the stream (the final `.complete` parse will catch it).
                if let recJSON = scanner.consumeRecommendationJSON(),
                   let recData = recJSON.data(using: .utf8),
                   let rec = try? decoder.decode(RecoveryRecommendation.self, from: recData) {
                    continuation.yield(.recommendation(rec))
                }

                // Exercises — drain one or more that have completed since
                // the last feed.
                while let exerciseJSON = scanner.consumeNextExerciseJSON() {
                    if let exData = exerciseJSON.data(using: .utf8),
                       let ex = try? decoder.decode(PlannedExercise.self, from: exData) {
                        continuation.yield(.exercise(ex))
                    }
                }

                // Strategy — once the array is done and the trailing
                // sessionStrategy field has finished streaming.
                if let strategy = scanner.consumeStrategy() {
                    continuation.yield(.strategy(strategy))
                }
            }
            // We ignore message_start / content_block_start / ping /
            // message_delta / message_stop — the trailing decode after the
            // loop is the canonical "stream finished" signal.
        }

        // Final atomic decode — single source of truth for any consumer
        // that needs the full payload (volume calc, snapshot persistence).
        let cleaned = Self.stripJSONFences(from: textBuffer)
        guard let finalData = cleaned.data(using: .utf8) else {
            throw ClaudeError.malformedResponse("Could not convert final buffer to data")
        }
        let final = try decoder.decode(RecommendAndPlanResponse.self, from: finalData)
        continuation.yield(.complete(final))
    }

    private static func stripJSONFences(from text: String) -> String {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.firstIndex(of: "{"),
           let last = trimmed.lastIndex(of: "}") {
            return String(trimmed[first...last])
        }
        return trimmed
    }

    func adaptMidWorkout(systemPrompt: String, userPrompt: String, model: String) async throws -> MidWorkoutAdaptResponse {
        print("[BenLift/API] adaptMidWorkout called with model: \(model)")
        return try await sendRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, maxTokens: 1024, label: "adaptMidWorkout")
    }

    func analyzePostWorkout(systemPrompt: String, userPrompt: String, model: String) async throws -> PostWorkoutAnalysisResponse {
        print("[BenLift/API] analyzePostWorkout called with model: \(model)")
        return try await sendRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, maxTokens: 1024, label: "analyzePostWorkout")
    }

    func generateWeeklyReview(systemPrompt: String, userPrompt: String, model: String) async throws -> WeeklyReviewResponse {
        print("[BenLift/API] generateWeeklyReview called with model: \(model)")
        return try await sendRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, maxTokens: 4096, label: "generateWeeklyReview")
    }

    func refreshIntelligence(systemPrompt: String, userPrompt: String, model: String) async throws -> IntelligenceRefreshResponse {
        print("[BenLift/API] refreshIntelligence called with model: \(model)")
        return try await sendRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, maxTokens: 2048, label: "refreshIntelligence")
    }

    // MARK: - v5 prompt suite

    /// daily_plan_v5 — the everyday planning path (see CoachViewModel).
    /// Uses adaptive thinking at `effort: "high"`. `max_tokens` still needs
    /// enough headroom above the visible response for the model's thinking
    /// tokens, sized off `Prompts.DailyPlanV5.thinkingBudget`, so the JSON
    /// isn't truncated after the thinking block.
    func dailyPlanV5(input: PlannerInput, model: String) async throws -> DailyPlanV5Response {
        print("[BenLift/API] dailyPlanV5 called with model: \(model)")

        let inputJSON = try Self.encodeJSON(input)
        let todayDate = Self.todayDateString()
        let system = Prompts.DailyPlanV5.system
            .replacingOccurrences(of: "{{INPUT_JSON}}", with: inputJSON)
            .replacingOccurrences(of: "{{EXERCISE_LIBRARY}}", with: Prompts.exerciseLibrary)
            .replacingOccurrences(of: "{{TODAY_DATE}}", with: todayDate)
        let user = Prompts.DailyPlanV5.user

        let thinkingBudget = Prompts.DailyPlanV5.thinkingBudget
        let maxTokens = thinkingBudget + 4096

        return try await sendThinkingRequest(
            systemPrompt: system,
            userPrompt: user,
            model: model,
            maxTokens: maxTokens,
            thinkingBudget: thinkingBudget,
            label: "dailyPlanV5"
        )
    }

    /// Streaming variant of `dailyPlanV5`. Emits `.thinking` as soon as the
    /// extended-thinking phase begins, `.drafting` when visible text starts
    /// streaming, and `.complete` with the parsed response at the end.
    /// Lets the Today UI advance phase indicators instead of staring at a
    /// generic spinner for ~10–30s.
    nonisolated func streamDailyPlanV5(
        input: PlannerInput,
        model: String
    ) -> AsyncThrowingStream<DailyPlanV5StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: ClaudeError.noContent)
                    return
                }
                do {
                    try await self.runDailyPlanV5Stream(
                        input: input,
                        model: model,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runDailyPlanV5Stream(
        input: PlannerInput,
        model: String,
        continuation: AsyncThrowingStream<DailyPlanV5StreamEvent, Error>.Continuation
    ) async throws {
        guard let apiKey = KeychainService.load(key: KeychainService.apiKeyKey), !apiKey.isEmpty else {
            throw ClaudeError.invalidAPIKey
        }

        let inputJSON = try Self.encodeJSON(input)
        let todayDate = Self.todayDateString()
        let system = Prompts.DailyPlanV5.system
            .replacingOccurrences(of: "{{INPUT_JSON}}", with: inputJSON)
            .replacingOccurrences(of: "{{EXERCISE_LIBRARY}}", with: Prompts.exerciseLibrary)
            .replacingOccurrences(of: "{{TODAY_DATE}}", with: todayDate)
        let user = Prompts.DailyPlanV5.user

        let thinkingBudget = Prompts.DailyPlanV5.thinkingBudget
        let maxTokens = thinkingBudget + 4096

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 120  // longer for thinking budget

        // Same shape as sendThinkingRequest but with stream:true and a
        // singular system block (the v5 system already embeds INPUT_JSON
        // and EXERCISE_LIBRARY — no separate cached knowledge base).
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "thinking": [
                "type": "adaptive",
            ],
            "output_config": [
                "effort": "high",
            ],
            "system": [
                ["type": "text", "text": system, "cache_control": ["type": "ephemeral"]],
            ],
            "messages": [
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[BenLift/API] → streamDailyPlanV5: model=\(model)")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.serverError(0, "Not an HTTP response")
        }
        guard http.statusCode == 200 else {
            var errorBody = Data()
            for try await byte in bytes { errorBody.append(byte) }
            let body = String(data: errorBody, encoding: .utf8) ?? ""
            print("[BenLift/API] ❌ streamDailyPlanV5 error \(http.statusCode): \(body)")
            if http.statusCode == 401 { throw ClaudeError.invalidAPIKey }
            if http.statusCode == 429 { throw ClaudeError.rateLimited }
            throw ClaudeError.serverError(http.statusCode, body)
        }

        var textBuffer = ""
        var emittedThinking = false
        var emittedDrafting = false
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let type = event["type"] as? String

            // Phase detection. content_block_start tells us which kind of
            // block (thinking / text) is starting — emit the matching
            // phase event once per phase. content_block_delta carries the
            // actual text we accumulate for the final parse.
            if type == "content_block_start",
               let block = event["content_block"] as? [String: Any] {
                let blockType = block["type"] as? String
                if blockType == "thinking", !emittedThinking {
                    emittedThinking = true
                    continuation.yield(.thinking)
                } else if blockType == "text", !emittedDrafting {
                    emittedDrafting = true
                    continuation.yield(.drafting)
                }
            } else if type == "content_block_delta",
                      let delta = event["delta"] as? [String: Any] {
                // Accumulate visible text only — `thinking_delta` content
                // is NOT included in the visible response and isn't useful
                // to the consumer's final parse.
                if let text = delta["text"] as? String {
                    if !emittedDrafting {
                        emittedDrafting = true
                        continuation.yield(.drafting)
                    }
                    textBuffer += text
                }
            }
        }

        // Final atomic decode — single source of truth for the consumer.
        let cleaned = Self.stripJSONFences(from: textBuffer)
        guard let finalData = cleaned.data(using: .utf8) else {
            throw ClaudeError.malformedResponse("Could not convert v5 buffer to data")
        }
        let final = try decoder.decode(DailyPlanV5Response.self, from: finalData)
        continuation.yield(.complete(final))
    }

    /// iterate — surgical edit OR conversational answer. Cheap (no thinking).
    /// The `INPUT_JSON` slot is a SUBSET of PlannerInput per the prompt
    /// (just strength, rituals, constraints) — built inline below.
    func iterate(
        currentPlan: DailyPlanResponse,
        userRequest: String,
        plannerInput: PlannerInput,
        model: String
    ) async throws -> IterateResponse {
        print("[BenLift/API] iterate called with model: \(model)")

        // Iterate prompt only needs strength, rituals, and constraints from
        // PlannerInput — encode just that subset to keep the payload tight.
        let subset = IterateInputSubset(
            strength: plannerInput.strength,
            rituals: plannerInput.rituals,
            constraints: plannerInput.constraints
        )
        let inputJSON = try Self.encodeJSON(subset)
        let currentPlanJSON = try Self.encodeJSON(currentPlan)

        let system = Prompts.Iterate.system
            .replacingOccurrences(of: "{{CURRENT_PLAN_JSON}}", with: currentPlanJSON)
            .replacingOccurrences(of: "{{INPUT_JSON}}", with: inputJSON)
            .replacingOccurrences(of: "{{USER_REQUEST}}", with: userRequest)
        let user = Prompts.Iterate.user

        return try await sendRequest(
            systemPrompt: system,
            userPrompt: user,
            model: model,
            maxTokens: 1024,
            label: "iterate"
        )
    }

    /// bootstrap — one-time program design from onboarding answers. Seeds
    /// calendar pattern, rotation, weekly volume, progression scheme. Cheap
    /// (no thinking — pattern engine corrects this over the first 2-3 weeks
    /// of real workouts).
    func bootstrap(input: BootstrapInput, model: String) async throws -> BootstrapResponse {
        print("[BenLift/API] bootstrap called with model: \(model)")

        let onboardingJSON = try Self.encodeJSON(input)
        let system = Prompts.Bootstrap.system
            .replacingOccurrences(of: "{{ONBOARDING_JSON}}", with: onboardingJSON)
            .replacingOccurrences(of: "{{EXERCISE_LIBRARY}}", with: Prompts.exerciseLibrary)
        let user = Prompts.Bootstrap.user

        return try await sendRequest(
            systemPrompt: system,
            userPrompt: user,
            model: model,
            maxTokens: 2048,
            label: "bootstrap"
        )
    }

    // MARK: - Helpers for v5 suite

    /// Encode any Codable to a pretty JSON string. Used to inline structured
    /// input into the prompt template's `{{...}}` slots.
    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func todayDateString() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: Date())
    }

    /// Variant of `sendRequest` that enables Anthropic adaptive thinking.
    /// Uses raw JSON serialization (rather than `ClaudeRequest`) because the
    /// thinking/effort config doesn't fit the existing struct.
    private func sendThinkingRequest<T: Decodable>(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        maxTokens: Int,
        thinkingBudget: Int,
        label: String,
        retryCount: Int = 0
    ) async throws -> T {
        guard let apiKey = KeychainService.load(key: KeychainService.apiKeyKey), !apiKey.isEmpty else {
            print("[BenLift/API] ❌ No API key found in Keychain")
            throw ClaudeError.invalidAPIKey
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 90  // thinking adds latency

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "thinking": [
                "type": "adaptive",
            ],
            "output_config": [
                "effort": "high",
            ],
            "system": [
                ["type": "text", "text": TrainingKnowledgeBase.knowledgeBase, "cache_control": ["type": "ephemeral"]],
                ["type": "text", "text": systemPrompt],
            ],
            "messages": [
                ["role": "user", "content": userPrompt],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[BenLift/API] → \(label): model=\(model), maxTokens=\(maxTokens), thinking=\(thinkingBudget)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            print("[BenLift/API] ❌ Network error: \(error)")
            throw ClaudeError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.serverError(0, "Not an HTTP response")
        }

        print("[BenLift/API] ← \(label): HTTP \(httpResponse.statusCode), \(data.count) bytes")

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "(not utf8)"
            print("[BenLift/API] ❌ Error body: \(errorBody)")
        }

        if httpResponse.statusCode == 429 && retryCount < 1 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await sendThinkingRequest(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model,
                maxTokens: maxTokens,
                thinkingBudget: thinkingBudget,
                label: label,
                retryCount: retryCount + 1
            )
        }
        if (500...503).contains(httpResponse.statusCode) && retryCount < 1 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await sendThinkingRequest(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model,
                maxTokens: maxTokens,
                thinkingBudget: thinkingBudget,
                label: label,
                retryCount: retryCount + 1
            )
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            if httpResponse.statusCode == 401 { throw ClaudeError.invalidAPIKey }
            if httpResponse.statusCode == 429 { throw ClaudeError.rateLimited }
            let friendlyMessage = Self.extractErrorMessage(from: data) ?? errorBody
            throw ClaudeError.serverError(httpResponse.statusCode, friendlyMessage)
        }

        let apiResponse: ClaudeAPIResponse
        do {
            apiResponse = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        } catch {
            let rawBody = String(data: data, encoding: .utf8) ?? "(not utf8)"
            print("[BenLift/API] ❌ Failed to decode API response: \(error)")
            print("[BenLift/API] Raw response: \(rawBody.prefix(500))")
            throw ClaudeError.malformedResponse("API response decode error: \(error.localizedDescription)")
        }

        // Thinking responses interleave `thinking` + `text` content blocks —
        // we want the final visible text block.
        guard let textBlock = apiResponse.content.first(where: { $0.type == "text" }),
              let text = textBlock.text else {
            throw ClaudeError.noContent
        }

        if let usage = apiResponse.usage {
            print("[BenLift/API] ✓ Tokens: \(usage.inputTokens) in, \(usage.outputTokens) out")
        }

        return try Self.parseJSONResponse(text: text, label: label)
    }

    /// Strip markdown fences and decode the JSON object boundary. Shared
    /// between the thinking and non-thinking paths.
    private static func parseJSONResponse<T: Decodable>(text: String, label: String) throws -> T {
        let stripped = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let cleanedText: String
        if let firstBrace = stripped.firstIndex(of: "{"),
           let lastBrace = stripped.lastIndex(of: "}") {
            cleanedText = String(stripped[firstBrace...lastBrace])
        } else {
            cleanedText = stripped
        }

        print("[BenLift/API] \(label) response (\(cleanedText.count) chars): \(cleanedText.prefix(300))...")

        guard let jsonData = cleanedText.data(using: .utf8) else {
            throw ClaudeError.malformedResponse("Could not convert to data")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            let result = try decoder.decode(T.self, from: jsonData)
            print("[BenLift/API] ✅ \(label) decoded successfully")
            return result
        } catch {
            print("[BenLift/API] ❌ JSON decode error for \(T.self): \(error)")
            print("[BenLift/API] Full JSON was: \(cleanedText)")
            throw ClaudeError.malformedResponse("\(T.self) decode: \(error.localizedDescription)")
        }
    }

    // MARK: - Core Request

    /// Builds system blocks: the knowledge base (cached) + the per-call system prompt (dynamic).
    private func buildSystemBlocks(systemPrompt: String) -> [SystemBlock] {
        [
            .cached(TrainingKnowledgeBase.knowledgeBase),
            .dynamic(systemPrompt)
        ]
    }

    private func sendRequest<T: Decodable>(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        maxTokens: Int,
        label: String,
        retryCount: Int = 0
    ) async throws -> T {
        guard let apiKey = KeychainService.load(key: KeychainService.apiKeyKey), !apiKey.isEmpty else {
            print("[BenLift/API] ❌ No API key found in Keychain")
            throw ClaudeError.invalidAPIKey
        }
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 30

        let body = ClaudeRequest(
            model: model,
            maxTokens: maxTokens,
            system: buildSystemBlocks(systemPrompt: systemPrompt),
            messages: [ClaudeMessage(role: "user", content: userPrompt)]
        )
        let encodedBody = try JSONEncoder().encode(body)
        request.httpBody = encodedBody

        print("[BenLift/API] → \(label): model=\(model), maxTokens=\(maxTokens), bodySize=\(encodedBody.count) bytes")
        print("[BenLift/API] → System prompt (\(systemPrompt.count) chars): \(systemPrompt.prefix(200))...")
        print("[BenLift/API] → User prompt (\(userPrompt.count) chars):\n\(userPrompt)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            print("[BenLift/API] ❌ Network error: \(error)")
            throw ClaudeError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            print("[BenLift/API] ❌ Not an HTTP response")
            throw ClaudeError.serverError(0, "Not an HTTP response")
        }

        print("[BenLift/API] ← \(label): HTTP \(httpResponse.statusCode), \(data.count) bytes")

        // Log error response bodies
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "(not utf8)"
            print("[BenLift/API] ❌ Error body: \(errorBody)")
        }

        // Handle retryable errors
        if httpResponse.statusCode == 429 && retryCount < 1 {
            print("[BenLift/API] ⏳ Rate limited, retrying in 2s...")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await sendRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, maxTokens: maxTokens, label: label, retryCount: retryCount + 1)
        }

        if (500...503).contains(httpResponse.statusCode) && retryCount < 1 {
            print("[BenLift/API] ⏳ Server error \(httpResponse.statusCode), retrying in 2s...")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await sendRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, maxTokens: maxTokens, label: label, retryCount: retryCount + 1)
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            if httpResponse.statusCode == 401 { throw ClaudeError.invalidAPIKey }
            if httpResponse.statusCode == 429 { throw ClaudeError.rateLimited }
            // Try to extract the human-readable message from the API error
            let friendlyMessage = Self.extractErrorMessage(from: data) ?? errorBody
            throw ClaudeError.serverError(httpResponse.statusCode, friendlyMessage)
        }

        // Parse Claude response
        let apiResponse: ClaudeAPIResponse
        do {
            apiResponse = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        } catch {
            let rawBody = String(data: data, encoding: .utf8) ?? "(not utf8)"
            print("[BenLift/API] ❌ Failed to decode API response: \(error)")
            print("[BenLift/API] Raw response: \(rawBody.prefix(500))")
            throw ClaudeError.malformedResponse("API response decode error: \(error.localizedDescription)")
        }

        guard let textBlock = apiResponse.content.first(where: { $0.type == "text" }),
              let text = textBlock.text else {
            print("[BenLift/API] ❌ No text content in response")
            throw ClaudeError.noContent
        }

        if let usage = apiResponse.usage {
            var tokenLog = "[BenLift/API] ✓ Tokens: \(usage.inputTokens) in, \(usage.outputTokens) out"
            if let cacheWrite = usage.cacheCreationInputTokens, cacheWrite > 0 {
                tokenLog += " | cache WRITE: \(cacheWrite) tokens"
            }
            if let cacheRead = usage.cacheReadInputTokens, cacheRead > 0 {
                tokenLog += " | cache HIT: \(cacheRead) tokens (90% savings)"
            }
            print(tokenLog)
        }

        // Extract JSON object — strip markdown, trailing text, anything outside { }
        let stripped = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the JSON object boundaries
        let cleanedText: String
        if let firstBrace = stripped.firstIndex(of: "{"),
           let lastBrace = stripped.lastIndex(of: "}") {
            cleanedText = String(stripped[firstBrace...lastBrace])
        } else {
            cleanedText = stripped
        }

        print("[BenLift/API] Claude response (\(cleanedText.count) chars): \(cleanedText.prefix(300))...")

        guard let jsonData = cleanedText.data(using: .utf8) else {
            throw ClaudeError.malformedResponse("Could not convert to data")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            let result = try decoder.decode(T.self, from: jsonData)
            print("[BenLift/API] ✅ \(label) decoded successfully")
            return result
        } catch {
            print("[BenLift/API] ❌ JSON decode error for \(T.self): \(error)")
            print("[BenLift/API] Full JSON was: \(cleanedText)")
            throw ClaudeError.malformedResponse("\(T.self) decode: \(error.localizedDescription)")
        }
    }

    /// Extract human-readable error message from Claude API error JSON
    private static func extractErrorMessage(from data: Data) -> String? {
        struct APIError: Decodable {
            let error: ErrorDetail
            struct ErrorDetail: Decodable {
                let message: String
            }
        }
        return (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
    }
}
