import Foundation

// MARK: - System prompt blocks

/// A block of the system prompt. The first block carries the cache breakpoint
/// so Anthropic caches the stable coaching instructions across calls; volatile
/// state (today's plan, history) goes in a later, uncached block. Any byte
/// change in the cached prefix invalidates everything after it, so the split
/// matters.
struct SystemBlock {
    let text: String
    let isCached: Bool

    static func cached(_ text: String) -> SystemBlock {
        SystemBlock(text: text, isCached: true)
    }

    static func dynamic(_ text: String) -> SystemBlock {
        SystemBlock(text: text, isCached: false)
    }
}

// MARK: - Wire types

/// One tool call Claude asked for. `input` is left as a raw dictionary —
/// tool inputs must be JSON-parsed rather than string-matched, since escaping
/// varies between models.
struct ChatToolCall {
    let id: String
    let name: String
    let input: [String: Any]
}

struct ChatToolResult {
    let toolUseId: String
    /// What the app did, fed back so Claude can describe it accurately.
    let content: String
    let isError: Bool

    init(toolUseId: String, content: String, isError: Bool = false) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }
}

struct ChatTokenUsage {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedInputTokens: Int = 0

    mutating func add(_ other: ChatTokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cachedInputTokens += other.cachedInputTokens
    }
}

struct ChatTurnResult {
    var text: String
    var appliedTools: [String]
    var usage: ChatTokenUsage
    var latencySeconds: Double
    /// Set when the model declined the request rather than answering.
    var wasRefusal: Bool = false
}

enum ChatServiceError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case malformedResponse
    case toolLoopExceeded

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key. Add one in Settings."
        case .http(let status, let body):
            return "Claude returned \(status). \(body.prefix(200))"
        case .malformedResponse:
            return "Couldn't read Claude's response."
        case .toolLoopExceeded:
            return "The coach kept editing without finishing. Try rephrasing."
        }
    }
}

// MARK: - Chat Service

/// The app's only network call. One request per message you send — never on
/// open, never on save, never on a timer.
///
/// Runs the tool loop: Claude proposes plan edits as `tool_use` blocks, the
/// caller applies them against SwiftData and hands back results, and the loop
/// continues until Claude stops calling tools and just answers.
@MainActor
final class ChatService {
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"
    private let session = URLSession.shared

    /// Guard against a model that keeps editing forever. Six rounds is far
    /// more than a real request needs.
    private let maxToolRounds = 6

    // MARK: Public entry point

    /// - Parameters:
    ///   - history: prior turns in this thread, oldest first.
    ///   - systemBlocks: stable blocks first (they carry the cache breakpoint).
    ///   - toolHandler: applies the edits and returns one result per call.
    func send(
        userMessage: String,
        history: [(role: String, text: String)],
        systemBlocks: [SystemBlock],
        intelligence: Intelligence,
        toolHandler: @escaping ([ChatToolCall]) async -> [ChatToolResult]
    ) async throws -> ChatTurnResult {

        guard let apiKey = KeychainService.load(key: KeychainService.apiKeyKey), !apiKey.isEmpty else {
            throw ChatServiceError.missingAPIKey
        }

        let started = Date()
        var usage = ChatTokenUsage()
        var appliedTools: [String] = []

        // Build the running message array. Content is always an array of
        // blocks so tool_result turns slot in without reshaping anything.
        var messages: [[String: Any]] = history.map { turn in
            ["role": turn.role, "content": [["type": "text", "text": turn.text]]]
        }
        messages.append(["role": "user", "content": [["type": "text", "text": userMessage]]])

        for _ in 0..<maxToolRounds {
            let (blocks, stopReason, turnUsage) = try await request(
                messages: messages,
                systemBlocks: systemBlocks,
                intelligence: intelligence,
                apiKey: apiKey
            )
            usage.add(turnUsage)

            // Safety classifiers can decline with HTTP 200 — always check
            // stop_reason before trusting the content.
            if stopReason == "refusal" {
                return ChatTurnResult(
                    text: "I can't help with that one.",
                    appliedTools: appliedTools,
                    usage: usage,
                    latencySeconds: Date().timeIntervalSince(started),
                    wasRefusal: true
                )
            }

            let toolCalls = Self.toolCalls(in: blocks)

            guard !toolCalls.isEmpty else {
                return ChatTurnResult(
                    text: Self.text(in: blocks),
                    appliedTools: appliedTools,
                    usage: usage,
                    latencySeconds: Date().timeIntervalSince(started)
                )
            }

            // Echo the assistant turn back verbatim (thinking blocks included)
            // so the conversation stays valid on the next request.
            messages.append(["role": "assistant", "content": blocks])

            let results = await toolHandler(toolCalls)
            appliedTools.append(contentsOf: toolCalls.map { $0.name })

            // All results go back in ONE user message — splitting them trains
            // the model out of making parallel calls.
            let resultBlocks: [[String: Any]] = results.map { result in
                var block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": result.toolUseId,
                    "content": result.content
                ]
                if result.isError { block["is_error"] = true }
                return block
            }
            messages.append(["role": "user", "content": resultBlocks])
        }

        throw ChatServiceError.toolLoopExceeded
    }

    // MARK: One HTTP round trip

    private func request(
        messages: [[String: Any]],
        systemBlocks: [SystemBlock],
        intelligence: Intelligence,
        apiKey: String
    ) async throws -> (blocks: [[String: Any]], stopReason: String?, usage: ChatTokenUsage) {

        let systemPayload: [[String: Any]] = systemBlocks.map { block in
            var dict: [String: Any] = ["type": "text", "text": block.text]
            if block.isCached {
                dict["cache_control"] = ["type": "ephemeral"]
            }
            return dict
        }

        let body: [String: Any] = [
            "model": ClaudeModel.current,
            "max_tokens": 8192,
            // Effort is the latency lever — the model never changes. A swap
            // doesn't need deep reasoning; an injury question does.
            "output_config": ["effort": intelligence.effort],
            "system": systemPayload,
            "messages": messages,
            "tools": ChatTools.definitions
        ]

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ChatServiceError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatServiceError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else {
            throw ChatServiceError.malformedResponse
        }

        var usage = ChatTokenUsage()
        if let u = json["usage"] as? [String: Any] {
            usage.inputTokens = u["input_tokens"] as? Int ?? 0
            usage.outputTokens = u["output_tokens"] as? Int ?? 0
            usage.cachedInputTokens = u["cache_read_input_tokens"] as? Int ?? 0
        }

        return (blocks, json["stop_reason"] as? String, usage)
    }

    // MARK: Block helpers

    private static func toolCalls(in blocks: [[String: Any]]) -> [ChatToolCall] {
        blocks.compactMap { block in
            guard block["type"] as? String == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String else { return nil }
            return ChatToolCall(
                id: id,
                name: name,
                input: block["input"] as? [String: Any] ?? [:]
            )
        }
    }

    private static func text(in blocks: [[String: Any]]) -> String {
        blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
