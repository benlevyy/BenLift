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
        print("[BenLift/API] API key loaded (\(apiKey.prefix(12))...)")

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
